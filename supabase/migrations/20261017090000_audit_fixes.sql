-- =====================================================================
-- Fixes from the HavenWear audit (16 Oct 2026)
--   C1  "Waiting for Delivery" was classified as delivered → revenue/COD recognised early
--   C2  misclassified parcels were final, so later return events were never fetched;
--       delivered_at survived a return; stored events never got re-classified
--   C3  COD-not-settled alerts on parcels that were not actually delivered (follows C1/C2)
--   A1  high-courier-charge alert compared a tax-inclusive charge with a tax-exclusive rate
--   R1  "deposit missing" claimed without any bank data covering the period
--   U3  audit log filled with no-change updates from syncs
-- =====================================================================

-- ---------------------------------------------------------------------
-- C2: tracking updates clear stale delivered/returned dates and re-classify
-- stored events when the mapping improves
-- ---------------------------------------------------------------------
create or replace function public.apply_tracking_updates(p_updates jsonb, p_events jsonb)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_count int;
begin
  update public.shipments s set
    status = coalesce(u.status, s.status),
    status_raw = coalesce(u.status_raw, s.status_raw),
    status_at = case
      when u.status is null then s.status_at
      when u.status_at is not null then u.status_at
      when u.status <> s.status or s.status_at is null then now()
      else s.status_at end,
    delivered_at = case
      when u.status is null then s.delivered_at
      when u.status = 'delivered' then coalesce(s.delivered_at, u.status_at, now())
      else null end,
    returned_at = case
      when u.status is null then s.returned_at
      when u.status = 'returned' then coalesce(s.returned_at, u.status_at, now())
      else null end,
    is_final = case when u.status is null then s.is_final
                    else u.status in ('delivered', 'returned', 'cancelled', 'lost') end,
    check_error = u.error,
    last_checked_at = now(),
    next_check_at = now() + make_interval(mins => greatest(coalesce(u.next_minutes, 240), 0))
  from jsonb_to_recordset(p_updates) as u(
    id bigint, status public.shipment_status, status_raw text, status_at timestamptz, error text, next_minutes int)
  where s.id = u.id and s.store_id = public.current_store_id();
  get diagnostics v_count = row_count;

  insert into public.shipment_events (shipment_id, status, status_raw, event_at, source)
  select e.shipment_id, e.status, e.status_raw, e.event_at, 'courier'
  from jsonb_to_recordset(coalesce(p_events, '[]'::jsonb)) as e(
    shipment_id bigint, status public.shipment_status, status_raw text, event_at timestamptz)
  where exists (select 1 from public.shipments s where s.id = e.shipment_id and s.store_id = public.current_store_id())
  on conflict (shipment_id, status_raw, event_at) do update set status = excluded.status
    where public.shipment_events.status is distinct from excluded.status;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- C1 backfill: re-classify stored courier events with the corrected rules
-- (same rules as normalizeStatus / postexStatus in _shared/couriers.ts)
-- ---------------------------------------------------------------------
update public.shipment_events e set status = x.fixed
from (
  select id,
    case
      when status_raw ~* '(un-?assigned|cancel)' then 'cancelled'
      when status_raw ~* 'returned (at|to) (merchant|shipper|origin|vendor|seller)' then 'returned'
      when status_raw ~* '(en ?route|on route|departed|dispatched|forwarded) to (merchant|shipper|origin|vendor|seller)' then 'return_in_transit'
      when status = 'delivered'
           and (status_raw !~* '\mdelivered\M' or status_raw ~* '(waiting|awaiting|pending|for delivery|to be delivered|not delivered|undelivered)')
        then 'in_transit'
      else status::text
    end::public.shipment_status as fixed
  from public.shipment_events
) x
where x.id = e.id and e.status is distinct from x.fixed;

-- Re-derive each parcel's status from its latest event; anything no longer
-- final is re-checked on the next tracking run.
update public.shipments s set
  status = l.status,
  status_raw = l.status_raw,
  status_at = coalesce(l.event_at, s.status_at),
  delivered_at = case when l.status = 'delivered'
                      then coalesce(s.delivered_at, (select min(e.event_at) from public.shipment_events e
                                                     where e.shipment_id = s.id and e.status = 'delivered'))
                      end,
  returned_at = case when l.status = 'returned' then coalesce(s.returned_at, l.event_at) end,
  is_final = l.status in ('delivered', 'returned', 'cancelled', 'lost'),
  next_check_at = case when l.status in ('delivered', 'returned', 'cancelled', 'lost') then s.next_check_at else now() end
from (
  select distinct on (shipment_id) shipment_id, status, status_raw, event_at
  from public.shipment_events
  order by shipment_id, event_at desc nulls last, id desc
) l
where l.shipment_id = s.id
  and (s.status is distinct from l.status
       or (l.status <> 'delivered' and s.delivered_at is not null)
       or (l.status <> 'returned' and s.returned_at is not null));

-- ---------------------------------------------------------------------
-- C1: delivery is recognised only from an explicit delivered event, a manual
-- override, or the courier paying the parcel's COD in a statement/CPR (a
-- payout proves delivery even when the tracking feed lags).
-- ---------------------------------------------------------------------
create or replace view public.v_order_shipment with (security_invoker = true) as
select distinct on (s.order_id)
  s.order_id, s.id as shipment_id, s.tracking_number, s.courier, s.fulfilled_at,
  case
    when s.manual_status is not null then s.manual_status
    when s.status in ('booked', 'in_transit', 'out_for_delivery', 'delivery_failed', 'unknown') and pay.paid_on is not null
      then 'delivered'::public.shipment_status
    else s.status
  end as status,
  s.status_raw, s.status_at,
  coalesce(s.delivered_at,
           case when s.manual_status is null and s.status in ('booked', 'in_transit', 'out_for_delivery', 'delivery_failed', 'unknown')
                then pay.paid_on::timestamptz end) as delivered_at,
  s.returned_at,
  s.is_final, s.manual_status is not null as is_manual, s.last_checked_at, s.check_error, s.courier_financials
from public.shipments s
left join lateral (
  select min(coalesce(b.statement_date, b.imported_at::date)) as paid_on
  from public.settlement_lines sl
  join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null and b.store_id = s.store_id
  where sl.tracking_number = s.tracking_number and sl.line_kind = 'delivered' and sl.cod_amount > 0
) pay on true
where s.store_id = public.current_store_id()
order by s.order_id, s.fulfilled_at desc nulls last, s.id desc;

-- ---------------------------------------------------------------------
-- A1 + R1 + C3: alert rules
-- ---------------------------------------------------------------------
create or replace function public.refresh_alerts()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  run_start timestamptz := clock_timestamp();
  overdue int := public.setting_num('reconciliation', 'settlement_overdue_days', 10)::int;
  stuck int := public.setting_num('reconciliation', 'stuck_days', 5)::int;
  win int := public.setting_num('reconciliation', 'bank_match_window_days', 10)::int;
  tol numeric := public.setting_num('reconciliation', 'cod_mismatch_tolerance', 1);
  v_store uuid := public.current_store_id();
  v_bank_until date;
  v_resolved int;
begin
  perform public.assert_role('finance');

  -- Latest date the imported bank statements cover (null = no bank data at all)
  select max(t.txn_date) into v_bank_until from public.bank_transactions t where t.store_id = v_store;

  create temporary table if not exists _new_alerts (
    kind text, severity text, entity_type text, entity_id text, title text, detail text, amount numeric
  ) on commit drop;
  truncate _new_alerts;

  -- Only parcels with a confirmed delivery reach 'with_courier' (C1), so these are real arrears
  insert into _new_alerts
  select 'settlement_overdue',
         case when coalesce(f.delivered_at, f.status_at, f.fulfilled_at) < now() - make_interval(days => overdue * 2) then 'critical' else 'warning' end,
         'order', f.order_id::text,
         'COD not settled by ' || upper(f.courier) || ': ' || f.name,
         format('Delivered %s days ago (courier event: %s), Rs %s still with courier',
                (current_date - coalesce(f.delivered_at, f.status_at, f.fulfilled_at)::date),
                coalesce(f.status_raw, f.shipment_status::text), f.expected_cod),
         f.expected_cod
  from public.v_order_finance f
  where f.money_state = 'with_courier'
    and coalesce(f.delivered_at, f.status_at, f.fulfilled_at) < now() - make_interval(days => overdue);

  insert into _new_alerts
  select 'cod_mismatch', 'critical', 'order', f.order_id::text,
         'COD mismatch on ' || f.name,
         format('Order total Rs %s, courier settled COD Rs %s', f.current_total, f.settled_cod),
         f.settled_cod - f.current_total
  from public.v_order_finance f
  where f.is_cod and f.settlement_count > 0 and not (f.settled_cod = 0 and f.financial_status = 'PAID')
    and abs(f.settled_cod - f.current_total) > tol;

  insert into _new_alerts
  select 'unknown_settlement_parcel', 'warning', 'settlement_line', sl.id::text,
         'Unknown parcel in ' || upper(b.courier) || ' statement: ' || sl.tracking_number,
         'Not found in synced Shopify orders. Sync older orders or check the tracking number.',
         sl.net_amount
  from public.settlement_lines sl
  join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
  where b.store_id = v_store
    and not exists (select 1 from public.shipments s where s.tracking_number = sl.tracking_number and s.store_id = b.store_id);

  insert into _new_alerts
  select 'settled_but_returned', 'critical', 'order', f.order_id::text,
         'Settled but marked returned: ' || f.name,
         format('Courier paid Rs %s for a parcel the tracking shows as %s', f.settled_cod, f.shipment_status),
         f.settled_cod
  from public.v_order_finance f
  where f.settlement_count > 0 and f.settled_cod > 0
    and f.shipment_status in ('returned', 'return_in_transit');

  insert into _new_alerts
  select 'duplicate_settlement', 'critical', 'order', f.order_id::text,
         'Parcel settled ' || f.settlement_count || ' times: ' || f.name,
         'Same tracking number appears as delivered in multiple courier statements.',
         f.settled_cod
  from public.v_order_finance f
  where f.settlement_count > 1;

  -- R1: a deposit is "missing" only when imported bank statements cover the
  -- expected arrival window; otherwise the payout is merely unverified.
  insert into _new_alerts
  select 'bank_deposit_missing', 'critical', 'settlement_batch', bs.batch_id::text,
         upper(bs.courier) || ' settlement not found in bank',
         format('Batch #%s dated %s: Rs %s expected, Rs %s matched. Bank statements imported up to %s.',
                bs.batch_id, coalesce(bs.statement_date::text, '—'), bs.total_net, bs.matched_amount, v_bank_until),
         bs.total_net - bs.matched_amount
  from public.v_batch_bank_status bs
  join public.settlement_batches b on b.id = bs.batch_id
  where not bs.is_banked and bs.total_net > 0
    and coalesce(bs.statement_date, b.imported_at::date) < current_date - win
    and v_bank_until >= coalesce(bs.statement_date, b.imported_at::date) + win;

  insert into _new_alerts
  select 'bank_data_missing', 'warning', 'bank', v_store::text,
         count(*) || ' courier payout(s) cannot be verified: no bank statement covers them',
         format('Rs %s across statements dated %s to %s. %s Import the bank statement of the account couriers pay into (Bank → Import).',
                sum(bs.total_net - bs.matched_amount), min(coalesce(bs.statement_date, b.imported_at::date)),
                max(coalesce(bs.statement_date, b.imported_at::date)),
                case when v_bank_until is null then 'No bank statements imported yet.'
                     else 'Bank statements imported up to ' || v_bank_until || '.' end),
         sum(bs.total_net - bs.matched_amount)
  from public.v_batch_bank_status bs
  join public.settlement_batches b on b.id = bs.batch_id
  where not bs.is_banked and bs.total_net > 0
    and (v_bank_until is null or v_bank_until < coalesce(bs.statement_date, b.imported_at::date) + win)
  having count(*) > 0;

  insert into _new_alerts
  select 'stuck_shipment', 'warning', 'order', f.order_id::text,
         'No movement for ' || (current_date - coalesce(f.status_at, f.fulfilled_at)::date) || ' days: ' || f.name,
         format('%s %s — last status: %s', upper(f.courier), f.tracking_number, coalesce(f.status_raw, f.shipment_status::text)),
         f.expected_cod
  from public.v_order_finance f
  where f.money_state in ('booked', 'in_transit', 'returning')
    and coalesce(f.status_at, f.fulfilled_at) < now() - make_interval(days => stuck);

  -- A1: compare like with like — the statement charge includes COD fee and COD
  -- withholding tax, so the expectation must include them too.
  insert into _new_alerts
  select 'courier_overcharge', 'info', 'order', p.order_id::text,
         'High courier charges on ' || p.name,
         format('Charged Rs %s vs expected ~Rs %s (delivery %s%s%s%s)', p.courier_cost, rc.expected, rc.delivery_charge,
                case when p.is_returned then ' + return ' || rc.return_charge else '' end,
                case when rc.cod_fee > 0 then ' + COD fee ' || rc.cod_fee else '' end,
                case when rc.cod_tax > 0 then ' + COD tax ' || rc.cod_tax else '' end),
         p.courier_cost - rc.expected
  from public.v_order_finance p
  join lateral (
    select r.delivery_charge, r.return_charge, c.cod_fee, c.cod_tax,
           r.delivery_charge + case when p.is_returned then r.return_charge else 0 end + c.cod_fee + c.cod_tax as expected
    from public.courier_rate_cards r
    cross join lateral (
      select
        case when p.is_delivered and p.is_cod
             then round(coalesce(nullif(p.settled_cod, 0), p.current_total) * coalesce(r.cod_fee_percent, 0) / 100, 2) else 0 end as cod_fee,
        case when p.is_delivered and p.is_cod
             then round(coalesce(nullif(p.settled_cod, 0), p.current_total) * coalesce(r.cod_tax_percent, 0) / 100, 2) else 0 end as cod_tax
    ) c
    where r.store_id = p.store_id and r.courier = p.courier and r.effective_from <= p.order_date
    order by r.effective_from desc limit 1
  ) rc on true
  where p.courier_cost_source = 'actual' and rc.expected > 0
    and p.courier_cost > rc.expected * 1.15 + 20;

  insert into _new_alerts
  select 'cancelled_but_delivered', 'warning', 'order', f.order_id::text,
         'Cancelled order was delivered: ' || f.name,
         'Shopify order is cancelled but the courier shows it delivered. Confirm the cash is collected.',
         f.current_total
  from public.v_order_finance f
  where f.cancelled_at is not null and f.shipment_status = 'delivered';

  insert into _new_alerts
  select 'tracking_error', 'info', 'order', f.order_id::text,
         'Tracking failing for ' || f.name,
         f.check_error, null
  from public.v_order_finance f
  where f.check_error is not null and not coalesce(f.is_final, false);

  insert into public.alerts (kind, severity, entity_type, entity_id, title, detail, amount, last_seen_at)
  select n.kind, n.severity, n.entity_type, n.entity_id, n.title, n.detail, n.amount, run_start
  from _new_alerts n
  where not exists (
    select 1 from public.alerts a
    where a.store_id = v_store and a.kind = n.kind and a.entity_type = n.entity_type and a.entity_id = n.entity_id and a.status = 'ignored')
  on conflict (store_id, kind, entity_type, entity_id) where status = 'open'
  do update set severity = excluded.severity, title = excluded.title, detail = excluded.detail,
                amount = excluded.amount, last_seen_at = excluded.last_seen_at;

  update public.alerts a set status = 'resolved', resolved_at = now(), resolution_note = 'Auto-resolved: condition cleared'
  where a.store_id = v_store and a.status = 'open' and a.last_seen_at < run_start;
  get diagnostics v_resolved = row_count;

  return jsonb_build_object(
    'open', (select count(*) from public.alerts where status = 'open' and store_id = v_store),
    'auto_resolved', v_resolved
  );
end;
$$;

-- ---------------------------------------------------------------------
-- U3: no audit entry for updates that change nothing but bookkeeping columns
-- ---------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  rec_id text;
  noise constant text[] := array['updated_at', 'last_checked_at', 'next_check_at', 'payment_checked_at',
                                 'payment_next_check_at', 'check_error', 'last_sync_at', 'synced_at'];
begin
  if tg_op = 'UPDATE' and (to_jsonb(old) - noise) = (to_jsonb(new) - noise) then
    return new;
  end if;
  rec_id := coalesce(
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'id',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'key',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'provider'
  );
  insert into public.audit_log (actor, actor_email, action, table_name, record_id, old_data, new_data)
  values (
    (select auth.uid()),
    (select auth.jwt() ->> 'email'),
    tg_op,
    tg_table_name,
    rec_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;
revoke execute on function public.audit_trigger() from public, anon, authenticated;

-- Recompute alerts for every store with the corrected data
select public.reconcile_all_stores();

-- R1: the dashboard shows how far imported bank statements reach (null = none)
do $do$
declare d text := pg_get_functiondef('public.finance_summary(date,date)'::regprocedure);
begin
  if position('bank_until' in d) = 0 then
    d := replace(d, $x$'unbanked_batches', (select count(*)$x$,
      $x$'bank_until', (select max(txn_date) from public.bank_transactions),
    'unbanked_batches', (select count(*)$x$);
    execute d;
  end if;
end
$do$;

-- PostEx pays some COD upfront (CPR lines with courier status "PostEx WareHouse",
-- "Out For Delivery"…) and claws it back on return, so a payout proves delivery
-- only when the statement line itself says the parcel was delivered.
create or replace view public.v_order_shipment with (security_invoker = true) as
select distinct on (s.order_id)
  s.order_id, s.id as shipment_id, s.tracking_number, s.courier, s.fulfilled_at,
  case
    when s.manual_status is not null then s.manual_status
    when s.status in ('booked', 'in_transit', 'out_for_delivery', 'delivery_failed', 'unknown') and pay.paid_on is not null
      then 'delivered'::public.shipment_status
    else s.status
  end as status,
  s.status_raw, s.status_at,
  coalesce(s.delivered_at,
           case when s.manual_status is null and s.status in ('booked', 'in_transit', 'out_for_delivery', 'delivery_failed', 'unknown')
                then pay.paid_on::timestamptz end) as delivered_at,
  s.returned_at,
  s.is_final, s.manual_status is not null as is_manual, s.last_checked_at, s.check_error, s.courier_financials
from public.shipments s
left join lateral (
  select min(coalesce(b.statement_date, b.imported_at::date)) as paid_on
  from public.settlement_lines sl
  join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null and b.store_id = s.store_id
  where sl.tracking_number = s.tracking_number and sl.line_kind = 'delivered' and sl.cod_amount > 0
    and sl.courier_status ~* '\mdelivered\M'
    and sl.courier_status !~* '(waiting|awaiting|pending|for delivery|not delivered|undelivered|return)'
) pay on true
where s.store_id = public.current_store_id()
order by s.order_id, s.fulfilled_at desc nulls last, s.id desc;

-- A1 follow-up: COD tax/fee are withheld on whatever COD the courier paid out
-- (including upfront payouts), so the expected charge uses the paid COD.
do $do$
declare d text := pg_get_functiondef('public.refresh_alerts()'::regprocedure);
begin
  d := replace(d,
    $x$case when p.is_delivered and p.is_cod
             then round(coalesce(nullif(p.settled_cod, 0), p.current_total) * coalesce(r.cod_fee_percent, 0) / 100, 2) else 0 end as cod_fee$x$,
    $x$case when p.settled_cod > 0 or (p.is_delivered and p.is_cod)
             then round(coalesce(nullif(p.settled_cod, 0), p.current_total) * coalesce(r.cod_fee_percent, 0) / 100, 2) else 0 end as cod_fee$x$);
  d := replace(d,
    $x$case when p.is_delivered and p.is_cod
             then round(coalesce(nullif(p.settled_cod, 0), p.current_total) * coalesce(r.cod_tax_percent, 0) / 100, 2) else 0 end as cod_tax$x$,
    $x$case when p.settled_cod > 0 or (p.is_delivered and p.is_cod)
             then round(coalesce(nullif(p.settled_cod, 0), p.current_total) * coalesce(r.cod_tax_percent, 0) / 100, 2) else 0 end as cod_tax$x$);
  execute d;
end
$do$;

select public.reconcile_all_stores();
