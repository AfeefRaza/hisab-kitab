-- =====================================================================
-- Operations: imports, reconciliation, manual overrides, alerts
-- Write RPCs are SECURITY DEFINER with an explicit role check so that each
-- import is atomic (all rows or nothing) and validated server-side.
-- =====================================================================

create or replace function public.normalize_tracking(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[\s''"]+', '', 'g')), '');
$$;

-- Called from SECURITY DEFINER functions: allow service/cron (no user) or a user with min role
create or replace function public.assert_role(min_role public.app_role)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null and not public.has_role(min_role) then
    raise exception 'Requires % role', min_role using errcode = '42501';
  end if;
  if (select auth.uid()) is null and coalesce(current_setting('request.jwt.claim.role', true), '') = 'anon' then
    raise exception 'not authorised' using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Settlement import: preview (read-only) and commit (atomic)
-- p_lines: [{tracking_number, order_ref, line_kind, cod_amount, courier_charges,
--            other_deductions, net_amount, courier_status, raw}]
-- ---------------------------------------------------------------------
create or replace function public.preview_settlement(p_lines jsonb)
returns table (
  tracking_number text, line_kind text, cod_amount numeric, net_amount numeric,
  order_id bigint, order_name text, expected_cod numeric, money_state text,
  shipment_status text, already_settled boolean, issue text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with l as (
    select public.normalize_tracking(x ->> 'tracking_number') as tn,
           coalesce(x ->> 'line_kind', 'delivered') as kind,
           coalesce((x ->> 'cod_amount')::numeric, 0) as cod,
           coalesce((x ->> 'net_amount')::numeric,
                    coalesce((x ->> 'cod_amount')::numeric, 0) - coalesce((x ->> 'courier_charges')::numeric, 0)
                    - coalesce((x ->> 'other_deductions')::numeric, 0)) as net
    from jsonb_array_elements(p_lines) x
  )
  select l.tn, l.kind, l.cod, l.net,
    f.order_id, f.name, f.expected_cod, f.money_state, f.shipment_status::text,
    coalesce(ts.delivered_batch_count, 0) > 0,
    case
      when f.order_id is null then 'Tracking number not found in Shopify orders'
      when l.kind = 'delivered' and coalesce(ts.delivered_batch_count, 0) > 0 then 'Already settled in another statement'
      when l.kind = 'delivered' and f.shipment_status in ('returned', 'return_in_transit') then 'Paid as delivered but parcel is marked returned'
      when l.kind = 'delivered' and f.is_cod and abs(l.cod - f.current_total) > public.setting_num('reconciliation', 'cod_mismatch_tolerance', 1)
        then format('COD %s differs from order total %s', l.cod, f.current_total)
    end
  from l
  left join public.v_order_finance f on f.tracking_number = l.tn
  left join public.v_tracking_settlement ts on ts.tracking_number = l.tn;
$$;

create or replace function public.import_settlement(
  p_courier text,
  p_file_name text,
  p_file_sha256 text,
  p_statement_ref text,
  p_statement_date date,
  p_lines jsonb,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch bigint;
  v_existing bigint;
  v_lines int;
  v_unknown int;
begin
  perform public.assert_role('finance');

  if p_courier not in ('postex', 'blueex', 'mnp', 'tranzo', 'xps', 'other') then
    raise exception 'Unknown courier %', p_courier;
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'No settlement lines in file';
  end if;

  select id into v_existing from public.settlement_batches where file_sha256 = p_file_sha256;
  if v_existing is not null then
    raise exception 'This exact file was already imported as batch #%', v_existing using errcode = '23505';
  end if;

  insert into public.settlement_batches (courier, file_name, file_sha256, statement_ref, statement_date, note, imported_by)
  values (p_courier, p_file_name, p_file_sha256, nullif(trim(p_statement_ref), ''), p_statement_date, p_note, (select auth.uid()))
  returning id into v_batch;

  -- Collapse duplicate rows for the same parcel within one file
  insert into public.settlement_lines (
    batch_id, tracking_number, order_ref, line_kind, cod_amount, courier_charges,
    other_deductions, net_amount, courier_status, raw)
  select v_batch, tn, max(order_ref), kind,
         sum(cod), sum(charges), sum(deductions), sum(net), max(status), jsonb_agg(raw)
  from (
    select public.normalize_tracking(x ->> 'tracking_number') as tn,
           nullif(trim(x ->> 'order_ref'), '') as order_ref,
           coalesce(nullif(x ->> 'line_kind', ''), 'delivered') as kind,
           round(coalesce((x ->> 'cod_amount')::numeric, 0), 2) as cod,
           round(coalesce((x ->> 'courier_charges')::numeric, 0), 2) as charges,
           round(coalesce((x ->> 'other_deductions')::numeric, 0), 2) as deductions,
           round(coalesce((x ->> 'net_amount')::numeric,
                 coalesce((x ->> 'cod_amount')::numeric, 0) - coalesce((x ->> 'courier_charges')::numeric, 0)
                 - coalesce((x ->> 'other_deductions')::numeric, 0)), 2) as net,
           x ->> 'courier_status' as status,
           coalesce(x -> 'raw', '{}'::jsonb) as raw
    from jsonb_array_elements(p_lines) x
  ) r
  where tn is not null
  group by tn, kind;

  get diagnostics v_lines = row_count;

  update public.settlement_batches b set
    row_count = v_lines,
    total_cod = s.cod, total_charges = s.charges, total_net = s.net
  from (
    select coalesce(sum(cod_amount) filter (where line_kind = 'delivered'), 0) as cod,
           coalesce(sum(courier_charges + other_deductions), 0) as charges,
           coalesce(sum(net_amount), 0) as net
    from public.settlement_lines where batch_id = v_batch
  ) s
  where b.id = v_batch;

  select count(*) into v_unknown
  from public.settlement_lines sl
  where sl.batch_id = v_batch
    and not exists (select 1 from public.shipments s where s.tracking_number = sl.tracking_number);

  perform public.auto_match_settlements();
  perform public.refresh_alerts();

  return jsonb_build_object(
    'batch_id', v_batch,
    'lines', v_lines,
    'unknown_parcels', v_unknown,
    'total_net', (select total_net from public.settlement_batches where id = v_batch)
  );
end;
$$;

create or replace function public.void_settlement_batch(p_batch_id bigint, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_role('finance');
  update public.settlement_batches
     set voided_at = now(), voided_by = (select auth.uid()),
         note = concat_ws(' | ', note, 'VOIDED: ' || coalesce(p_reason, ''))
   where id = p_batch_id and voided_at is null;
  delete from public.settlement_bank_matches where batch_id = p_batch_id;
  perform public.refresh_alerts();
end;
$$;

-- ---------------------------------------------------------------------
-- Bank statement import
-- p_rows: [{date: 'YYYY-MM-DD', description, reference, debit, credit, balance}]
-- ---------------------------------------------------------------------
create or replace function public.import_bank_statement(
  p_account_id bigint,
  p_file_name text,
  p_file_sha256 text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import bigint;
  v_inserted int;
  v_total int;
begin
  perform public.assert_role('finance');

  if not exists (select 1 from public.bank_accounts where id = p_account_id) then
    raise exception 'Bank account % not found', p_account_id;
  end if;
  if exists (select 1 from public.bank_imports where account_id = p_account_id and file_sha256 = p_file_sha256) then
    raise exception 'This exact statement file was already imported for this account' using errcode = '23505';
  end if;

  v_total := jsonb_array_length(p_rows);

  insert into public.bank_imports (account_id, file_name, file_sha256, row_count, date_from, date_to, imported_by)
  select p_account_id, p_file_name, p_file_sha256, v_total,
         min((x ->> 'date')::date), max((x ->> 'date')::date), (select auth.uid())
  from jsonb_array_elements(p_rows) x
  returning id into v_import;

  with r as (
    select (x ->> 'date')::date as d,
           left(coalesce(trim(x ->> 'description'), ''), 500) as descr,
           nullif(trim(x ->> 'reference'), '') as ref,
           round(abs(coalesce((x ->> 'debit')::numeric, 0)), 2) as debit,
           round(abs(coalesce((x ->> 'credit')::numeric, 0)), 2) as credit,
           round((x ->> 'balance')::numeric, 2) as balance,
           ord
    from jsonb_array_elements(p_rows) with ordinality as t(x, ord)
  ),
  k as (
    select r.*,
      md5(concat_ws('|', d, lower(descr), coalesce(ref, ''), debit, credit, coalesce(balance::text, ''))) as base_hash
    from r
  ),
  h as (
    -- identical rows in one file (same day, same text, same amount) are kept apart by occurrence #
    select k.*, base_hash || ':' || row_number() over (partition by base_hash order by ord) as row_hash
    from k
  )
  insert into public.bank_transactions (account_id, import_id, txn_date, description, reference, debit, credit, balance, row_hash, category)
  select p_account_id, v_import, d, descr, ref, debit, credit, balance, row_hash,
    case when credit > 0 and descr ~* '(postex|post ex|blue ?ex|m ?& ?p|mulphilog|muller|tranzo|xps|leopards|trax|call ?courier)' then 'courier_settlement' end
  from h
  where d is not null and (debit > 0 or credit > 0)
  on conflict (account_id, row_hash) do nothing;

  get diagnostics v_inserted = row_count;
  update public.bank_imports set row_count = v_inserted where id = v_import;

  perform public.auto_match_settlements();
  perform public.refresh_alerts();

  return jsonb_build_object('import_id', v_import, 'rows', v_total, 'inserted', v_inserted, 'duplicates_skipped', v_total - v_inserted);
end;
$$;

-- ---------------------------------------------------------------------
-- Auto-match settlement batches to bank credits.
-- A pair is matched only when it is unambiguous: the batch has exactly one
-- candidate credit AND that credit has exactly one candidate batch.
-- ---------------------------------------------------------------------
create or replace function public.auto_match_settlements()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
  tol numeric := public.setting_num('reconciliation', 'bank_match_tolerance', 1);
  win int := public.setting_num('reconciliation', 'bank_match_window_days', 10)::int;
begin
  perform public.assert_role('finance');

  with open_batches as (
    select bs.batch_id, bs.total_net - bs.matched_amount as remaining,
           coalesce(bs.statement_date, b.imported_at::date) as ref_date
    from public.v_batch_bank_status bs
    join public.settlement_batches b on b.id = bs.batch_id
    where not bs.is_banked and bs.total_net > 0
  ),
  open_credits as (
    select t.id, t.txn_date, t.credit - coalesce(sum(m.amount), 0) as remaining
    from public.bank_transactions t
    left join public.settlement_bank_matches m on m.bank_transaction_id = t.id
    where t.credit > 0 and coalesce(t.category, 'courier_settlement') = 'courier_settlement'
    group by t.id
    having t.credit - coalesce(sum(m.amount), 0) > tol
  ),
  pairs as (
    select ob.batch_id, oc.id as txn_id, ob.remaining as amount
    from open_batches ob
    join open_credits oc
      on abs(oc.remaining - ob.remaining) <= tol
     and oc.txn_date between ob.ref_date - 3 and ob.ref_date + win
  ),
  unique_pairs as (
    select p.* from pairs p
    where (select count(*) from pairs p2 where p2.batch_id = p.batch_id) = 1
      and (select count(*) from pairs p3 where p3.txn_id = p.txn_id) = 1
  )
  insert into public.settlement_bank_matches (batch_id, bank_transaction_id, amount, method, matched_by)
  select batch_id, txn_id, amount, 'auto', (select auth.uid()) from unique_pairs
  on conflict do nothing;

  get diagnostics v_count = row_count;

  update public.bank_transactions t set category = 'courier_settlement'
  where t.category is null and exists (select 1 from public.settlement_bank_matches m where m.bank_transaction_id = t.id);

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Manual shipment status override (null clears the override)
-- ---------------------------------------------------------------------
create or replace function public.set_shipment_status(p_shipment_id bigint, p_status public.shipment_status, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_role('finance');
  update public.shipments set
    manual_status = p_status,
    manual_note = nullif(trim(p_note), ''),
    manual_by = (select auth.uid()),
    manual_at = now()
  where id = p_shipment_id;
  if not found then
    raise exception 'Shipment % not found', p_shipment_id;
  end if;
  if p_status is not null then
    insert into public.shipment_events (shipment_id, status, status_raw, event_at, source)
    values (p_shipment_id, p_status, 'Manual: ' || coalesce(p_note, ''), now(), 'manual')
    on conflict do nothing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Alerts / reconciliation center
-- ---------------------------------------------------------------------
create or replace function public.refresh_alerts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_start timestamptz := clock_timestamp();
  overdue int := public.setting_num('reconciliation', 'settlement_overdue_days', 10)::int;
  stuck int := public.setting_num('reconciliation', 'stuck_days', 5)::int;
  win int := public.setting_num('reconciliation', 'bank_match_window_days', 10)::int;
  tol numeric := public.setting_num('reconciliation', 'cod_mismatch_tolerance', 1);
  v_resolved int;
begin
  perform public.assert_role('finance');

  create temporary table if not exists _new_alerts (
    kind text, severity text, entity_type text, entity_id text, title text, detail text, amount numeric
  ) on commit drop;
  truncate _new_alerts;

  -- 1. Delivered COD with no settlement after N days
  insert into _new_alerts
  select 'settlement_overdue',
         case when coalesce(f.delivered_at, f.status_at, f.fulfilled_at) < now() - make_interval(days => overdue * 2) then 'critical' else 'warning' end,
         'order', f.order_id::text,
         'COD not settled by ' || upper(f.courier) || ': ' || f.name,
         format('Delivered %s days ago, Rs %s still with courier',
                (current_date - coalesce(f.delivered_at, f.status_at, f.fulfilled_at)::date), f.expected_cod),
         f.expected_cod
  from public.v_order_finance f
  where f.money_state = 'with_courier'
    and coalesce(f.delivered_at, f.status_at, f.fulfilled_at) < now() - make_interval(days => overdue);

  -- 2. COD amount mismatch
  insert into _new_alerts
  select 'cod_mismatch', 'critical', 'order', f.order_id::text,
         'COD mismatch on ' || f.name,
         format('Order total Rs %s, courier settled COD Rs %s', f.current_total, f.settled_cod),
         f.settled_cod - f.current_total
  from public.v_order_finance f
  where f.is_cod and f.settlement_count > 0
    and abs(f.settled_cod - f.current_total) > tol;

  -- 3. Settlement line for a parcel we don't know
  insert into _new_alerts
  select 'unknown_settlement_parcel', 'warning', 'settlement_line', sl.id::text,
         'Unknown parcel in ' || upper(b.courier) || ' statement: ' || sl.tracking_number,
         'Not found in synced Shopify orders. Sync older orders or check the tracking number.',
         sl.net_amount
  from public.settlement_lines sl
  join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
  where not exists (select 1 from public.shipments s where s.tracking_number = sl.tracking_number);

  -- 4. Paid as delivered but shipment is a return
  insert into _new_alerts
  select 'settled_but_returned', 'critical', 'order', f.order_id::text,
         'Settled but marked returned: ' || f.name,
         format('Courier paid Rs %s for a parcel the tracking shows as %s', f.settled_cod, f.shipment_status),
         f.settled_cod
  from public.v_order_finance f
  where f.settlement_count > 0 and f.settled_cod > 0
    and f.shipment_status in ('returned', 'return_in_transit');

  -- 5. Same parcel paid in more than one statement
  insert into _new_alerts
  select 'duplicate_settlement', 'critical', 'order', f.order_id::text,
         'Parcel settled ' || f.settlement_count || ' times: ' || f.name,
         'Same tracking number appears as delivered in multiple courier statements.',
         f.settled_cod
  from public.v_order_finance f
  where f.settlement_count > 1;

  -- 6. Courier says paid, deposit not seen in bank
  insert into _new_alerts
  select 'bank_deposit_missing', 'critical', 'settlement_batch', bs.batch_id::text,
         upper(bs.courier) || ' settlement not found in bank',
         format('Batch #%s dated %s: Rs %s expected, Rs %s matched',
                bs.batch_id, coalesce(bs.statement_date::text, '—'), bs.total_net, bs.matched_amount),
         bs.total_net - bs.matched_amount
  from public.v_batch_bank_status bs
  join public.settlement_batches b on b.id = bs.batch_id
  where not bs.is_banked and bs.total_net > 0
    and coalesce(bs.statement_date, b.imported_at::date) < current_date - win;

  -- 7. Stuck shipments
  insert into _new_alerts
  select 'stuck_shipment', 'warning', 'order', f.order_id::text,
         'No movement for ' || (current_date - coalesce(f.status_at, f.fulfilled_at)::date) || ' days: ' || f.name,
         format('%s %s — last status: %s', upper(f.courier), f.tracking_number, coalesce(f.status_raw, f.shipment_status::text)),
         f.expected_cod
  from public.v_order_finance f
  where f.money_state in ('booked', 'in_transit', 'returning')
    and coalesce(f.status_at, f.fulfilled_at) < now() - make_interval(days => stuck);

  -- 8. Courier charged much more than the rate card
  insert into _new_alerts
  select 'courier_overcharge', 'info', 'order', p.order_id::text,
         'High courier charges on ' || p.name,
         format('Charged Rs %s vs rate card ~Rs %s', p.courier_cost, rc.expected),
         p.courier_cost - rc.expected
  from public.v_order_finance p
  join lateral (
    select (r.delivery_charge + case when p.is_returned then r.return_charge else 0 end) as expected
    from public.courier_rate_cards r
    where r.courier = p.courier and r.effective_from <= p.order_date
    order by r.effective_from desc limit 1
  ) rc on true
  where p.courier_cost_source = 'actual' and rc.expected > 0
    and p.courier_cost > rc.expected * 1.25 + 50;

  -- 9. Cancelled in Shopify but delivered
  insert into _new_alerts
  select 'cancelled_but_delivered', 'warning', 'order', f.order_id::text,
         'Cancelled order was delivered: ' || f.name,
         'Shopify order is cancelled but the courier shows it delivered. Confirm the cash is collected.',
         f.current_total
  from public.v_order_finance f
  where f.cancelled_at is not null and f.shipment_status = 'delivered';

  -- 10. Courier tracking errors
  insert into _new_alerts
  select 'tracking_error', 'info', 'order', f.order_id::text,
         'Tracking failing for ' || f.name,
         f.check_error, null
  from public.v_order_finance f
  where f.check_error is not null and not coalesce(f.is_final, false);

  -- Upsert open alerts; never resurrect ones a user ignored
  insert into public.alerts (kind, severity, entity_type, entity_id, title, detail, amount, last_seen_at)
  select n.kind, n.severity, n.entity_type, n.entity_id, n.title, n.detail, n.amount, run_start
  from _new_alerts n
  where not exists (
    select 1 from public.alerts a
    where a.kind = n.kind and a.entity_type = n.entity_type and a.entity_id = n.entity_id and a.status = 'ignored')
  on conflict (kind, entity_type, entity_id) where status = 'open'
  do update set severity = excluded.severity, title = excluded.title, detail = excluded.detail,
                amount = excluded.amount, last_seen_at = excluded.last_seen_at;

  -- Anything open that no longer applies resolves itself
  update public.alerts a set status = 'resolved', resolved_at = now(), resolution_note = 'Auto-resolved: condition cleared'
  where a.status = 'open' and a.last_seen_at < run_start;
  get diagnostics v_resolved = row_count;

  return jsonb_build_object(
    'open', (select count(*) from public.alerts where status = 'open'),
    'auto_resolved', v_resolved
  );
end;
$$;

revoke all on function public.import_settlement(text, text, text, text, date, jsonb, text) from public, anon;
revoke all on function public.void_settlement_batch(bigint, text) from public, anon;
revoke all on function public.import_bank_statement(bigint, text, text, jsonb) from public, anon;
revoke all on function public.auto_match_settlements() from public, anon;
revoke all on function public.set_shipment_status(bigint, public.shipment_status, text) from public, anon;
revoke all on function public.refresh_alerts() from public, anon;
revoke all on function public.assert_role(public.app_role) from public, anon;
grant execute on function public.preview_settlement(jsonb) to authenticated;
grant execute on function public.import_settlement(text, text, text, text, date, jsonb, text) to authenticated, service_role;
grant execute on function public.void_settlement_batch(bigint, text) to authenticated, service_role;
grant execute on function public.import_bank_statement(bigint, text, text, jsonb) to authenticated, service_role;
grant execute on function public.auto_match_settlements() to authenticated, service_role;
grant execute on function public.set_shipment_status(bigint, public.shipment_status, text) to authenticated, service_role;
grant execute on function public.refresh_alerts() to authenticated, service_role;
grant execute on function public.assert_role(public.app_role) to authenticated, service_role;
grant execute on function public.normalize_tracking(text) to authenticated, service_role;
