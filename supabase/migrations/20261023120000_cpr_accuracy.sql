-- =====================================================================
-- Fixes from the HavenWear data-accuracy audit (23 Oct 2026)
--   F1/F2/F3  CPRs were rebuilt from a per-parcel snapshot taken once, while the parcel
--             was still at the PostEx warehouse: COD = booked amount, fees = 0, never
--             refreshed. Now PostEx's own order list refreshes every parcel, COD paid =
--             reservePayment (+upfront/balance), returns carry their reversal fees, and
--             statements are fully rebuilt (stale lines removed).
--   F5        parcels booked directly in PostEx (replacements, exchanges, manual orders)
--             are stored as courier parcels; linked to a Shopify order only when that
--             order has no parcel of its own.
--   F6        unpicked labels are "booked"; Shopify-cancelled labels are cancelled
--             (until the courier shows movement); alert on labels not picked up in 3 days.
--   F8        charge alerts compare with the parcel's own PostEx fee (weight tier).
--   F10       "settled but returned" shows the net amount.
--   F11       rate cards get a fuel surcharge (XPS charges 25%).
-- =====================================================================

-- ---------------------------------------------------------------- schema
alter table public.shipments alter column order_id drop not null;
alter table public.shipments add column if not exists source text not null default 'shopify'
  check (source in ('shopify', 'courier'));
alter table public.shipments add column if not exists courier_order_ref text;
comment on column public.shipments.source is 'shopify = from a Shopify fulfilment; courier = found only in the courier''s own order list';

alter table public.courier_rate_cards add column if not exists fuel_surcharge_percent numeric(6,2) not null default 0
  check (fuel_surcharge_percent between 0 and 100);
-- XPS invoices add a 25% fuel surcharge on delivery charges (XPS invoice SI-25242)
update public.courier_rate_cards set fuel_surcharge_percent = 25 where courier = 'xps' and fuel_surcharge_percent = 0;

-- Order views only see parcels that belong to an order
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
where s.store_id = public.current_store_id() and s.order_id is not null
order by s.order_id, s.fulfilled_at desc nulls last, s.id desc;

-- F11: fallback estimates include the fuel surcharge
do $do$
declare d text := pg_get_viewdef('public.v_order_finance'::regclass, true);
begin
  if position('fuel_surcharge_percent' in d) = 0 then
    d := regexp_replace(d,
      'SELECT r\.delivery_charge,\s+r\.return_charge,',
      'SELECT r.delivery_charge * (1 + r.fuel_surcharge_percent / 100) AS delivery_charge, r.return_charge * (1 + r.fuel_surcharge_percent / 100) AS return_charge,');
    if position('fuel_surcharge_percent' in d) = 0 then
      raise exception 'v_order_finance rate-card lateral not found';
    end if;
    execute 'create or replace view public.v_order_finance with (security_invoker = true) as ' || d;
  end if;
end
$do$;

-- ---------------------------------------------------------------- courier data
-- Fresh per-parcel money/status from the courier's order list
create or replace function public.apply_courier_financials(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare v int;
begin
  update public.shipments s set courier_financials = r.financials
  from jsonb_to_recordset(p_rows) as r(id bigint, financials jsonb)
  where s.id = r.id and s.store_id = public.current_store_id()
    and s.courier_financials is distinct from r.financials;
  get diagnostics v = row_count;
  return v;
end;
$$;

-- F5: parcels that exist only in the courier's portal
create or replace function public.upsert_courier_parcels(p_courier text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare v int;
begin
  insert into public.shipments (order_id, tracking_number, courier, source, courier_order_ref, fulfilled_at,
                                courier_financials, status, next_check_at)
  select
    (select o.id from public.orders o
      where o.store_id = public.current_store_id()
        and lower(o.name) = '#' || ltrim(lower(trim(r.order_ref)), '#')
        and not exists (select 1 from public.shipments x where x.order_id = o.id)
      limit 1),
    upper(r.tracking_number), p_courier, 'courier', left(r.order_ref, 120), r.booked_at,
    r.financials, 'unknown', now()
  from jsonb_to_recordset(p_rows) as r(tracking_number text, order_ref text, booked_at timestamptz, financials jsonb)
  where coalesce(r.tracking_number, '') <> ''
  on conflict (store_id, tracking_number) do nothing;
  get diagnostics v = row_count;
  return v;
end;
$$;

-- F6: labels whose Shopify fulfilment was cancelled and that never moved
create or replace function public.cancel_unpicked_shipments(p_tracking text[])
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare v int;
begin
  update public.shipments s set
    manual_status = 'cancelled',
    manual_note = 'Auto: Shopify fulfilment cancelled and the courier never picked the parcel up',
    manual_at = now()
  where s.store_id = public.current_store_id()
    and s.tracking_number = any (p_tracking)
    and s.manual_status is null
    and s.status in ('booked', 'unknown', 'cancelled')
    and not exists (select 1 from public.shipment_events e
                    where e.shipment_id = s.id and e.status not in ('booked', 'unknown', 'cancelled'));
  get diagnostics v = row_count;
  return v;
end;
$$;

-- Tracking updates: an auto-cancel is lifted as soon as the courier shows movement
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
    manual_status = case when s.manual_note like 'Auto: Shopify fulfilment cancelled%'
                              and u.status is not null and u.status not in ('booked', 'unknown', 'cancelled')
                         then null else s.manual_status end,
    manual_note = case when s.manual_note like 'Auto: Shopify fulfilment cancelled%'
                            and u.status is not null and u.status not in ('booked', 'unknown', 'cancelled')
                       then null else s.manual_note end,
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

-- ---------------------------------------------------------------- F1/F2/F3: statements
create or replace function public.build_api_settlements()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_batches int;
  v_lines int;
  v_removed int;
begin
  create temporary table if not exists _api_src (
    tracking_number text, cpr text, cpr_date date, kind text,
    cod numeric, charges numeric, tax numeric, net numeric,
    order_ref text, courier_status text, raw jsonb
  ) on commit drop;
  truncate _api_src;

  -- One line per parcel in its CPR. The courier's own (fresh) status decides delivered vs
  -- returned; COD counts as paid only for delivered parcels and only what PostEx paid out
  -- (reservePayment/upfront/balance — invoicePayment is the booked COD, also on returns).
  insert into _api_src
  select s.tracking_number,
         s.payment_info ->> 'cpr1',
         ((s.payment_info ->> 'cpr1Date')::timestamptz at time zone 'Asia/Karachi')::date,
         x.kind,
         case when x.kind <> 'delivered' then 0
              when fr.fresh then coalesce((f ->> 'reservePayment')::numeric, 0) + coalesce((f ->> 'upfrontPayment')::numeric, 0)
                                + coalesce((f ->> 'balancePayment')::numeric, 0)
              else coalesce((f ->> 'invoicePayment')::numeric, 0) end,
         coalesce((f ->> 'transactionFee')::numeric, 0)
           + case when x.kind = 'returned' then coalesce((f ->> 'reversalFee')::numeric, 0) else 0 end,
         coalesce((f ->> 'transactionTax')::numeric, 0)
           + case when x.kind = 'returned' then coalesce((f ->> 'reversalTax')::numeric, 0) else 0 end,
         0,
         coalesce(f ->> 'orderRefNumber', s.courier_order_ref),
         f ->> 'transactionStatus',
         jsonb_build_object('financials', f, 'payment', s.payment_info)
  from public.shipments s
  cross join lateral (select s.courier_financials as f) ff
  cross join lateral (select coalesce(f ->> 'transactionStatus', '') ~* '^(delivered|return)' as fresh) fr
  cross join lateral (
    select case
      when f ->> 'transactionStatus' ~* '^delivered' then 'delivered'
      when f ->> 'transactionStatus' ~* '^return' then 'returned'
      when s.status = 'delivered' then 'delivered'
      when s.status in ('returned', 'return_in_transit') then 'returned'
    end as kind
  ) x
  where s.store_id = public.current_store_id() and s.courier = 'postex'
    and s.payment_info ->> 'settle' = 'true'
    and coalesce(s.payment_info ->> 'cpr1', '') <> ''
    and s.courier_financials is not null
    and x.kind is not null
    and not exists (
      select 1 from public.settlement_lines sl
      join public.settlement_batches b on b.id = sl.batch_id
      where sl.tracking_number = s.tracking_number and b.store_id = s.store_id and b.voided_at is null and b.source = 'file');

  update _api_src set tax = tax + round(cod * public.courier_cod_tax_percent('postex', cpr_date) / 100, 2) where kind = 'delivered';
  update _api_src set net = round(cod - charges - tax, 2) where true;

  -- Lines that no longer match the courier's data (wrong kind, moved CPR, gone) are removed
  delete from public.settlement_lines sl
  using public.settlement_batches b
  where b.id = sl.batch_id and b.source = 'api' and b.store_id = public.current_store_id()
    and not exists (select 1 from _api_src a
                    where a.tracking_number = sl.tracking_number and a.kind = sl.line_kind
                      and b.file_sha256 = 'api:postex:' || a.cpr);
  get diagnostics v_removed = row_count;

  insert into public.settlement_batches (courier, file_name, file_sha256, statement_ref, statement_date, source, note)
  select distinct on (cpr) 'postex', 'PostEx API', 'api:postex:' || cpr, cpr, cpr_date, 'api',
         'Built from PostEx''s per-parcel payment data'
  from _api_src
  order by cpr, cpr_date
  on conflict (store_id, file_sha256) do nothing;
  get diagnostics v_batches = row_count;

  insert into public.settlement_lines (batch_id, tracking_number, order_ref, line_kind, cod_amount, courier_charges,
                                       other_deductions, net_amount, courier_status, raw)
  select b.id, a.tracking_number, a.order_ref, a.kind, a.cod, a.charges, a.tax, a.net, a.courier_status, a.raw
  from _api_src a
  join public.settlement_batches b on b.file_sha256 = 'api:postex:' || a.cpr and b.store_id = public.current_store_id() and b.voided_at is null
  on conflict (batch_id, tracking_number, line_kind) do update set
    cod_amount = excluded.cod_amount, courier_charges = excluded.courier_charges,
    other_deductions = excluded.other_deductions, net_amount = excluded.net_amount,
    order_ref = excluded.order_ref, courier_status = excluded.courier_status, raw = excluded.raw
  where (public.settlement_lines.cod_amount, public.settlement_lines.courier_charges, public.settlement_lines.other_deductions,
         public.settlement_lines.net_amount, public.settlement_lines.courier_status)
        is distinct from (excluded.cod_amount, excluded.courier_charges, excluded.other_deductions,
                          excluded.net_amount, excluded.courier_status);
  get diagnostics v_lines = row_count;

  update public.settlement_batches b set
    row_count = coalesce(t.n, 0), total_cod = coalesce(t.cod, 0),
    total_charges = coalesce(t.charges, 0), total_net = coalesce(t.net, 0)
  from public.settlement_batches b2
  left join (
    select sl.batch_id, count(*) n,
           sum(sl.cod_amount) filter (where sl.line_kind = 'delivered') cod,
           sum(sl.courier_charges + sl.other_deductions) charges,
           sum(sl.net_amount) net
    from public.settlement_lines sl
    group by sl.batch_id
  ) t on t.batch_id = b2.id
  where b2.id = b.id and b.source = 'api' and b.store_id = public.current_store_id()
    and (b.row_count, b.total_cod, b.total_charges, b.total_net)
        is distinct from (coalesce(t.n, 0), coalesce(t.cod, 0), coalesce(t.charges, 0), coalesce(t.net, 0));

  return jsonb_build_object('new_batches', v_batches, 'lines_upserted', v_lines, 'lines_removed', v_removed);
end;
$$;

-- ---------------------------------------------------------------- F6: status backfill
-- "At HavenWear Warehouse" = label made at the merchant, not picked up yet → booked
update public.shipment_events e set status = 'booked'
from public.shipments s
where s.id = e.shipment_id and s.courier = 'postex'
  and e.status_raw ~* '^at .+ warehouse$' and e.status_raw !~* 'postex'
  and e.status <> 'booked';

update public.shipments s set
  status = l.status, status_raw = l.status_raw, status_at = coalesce(l.event_at, s.status_at),
  is_final = l.status in ('delivered', 'returned', 'cancelled', 'lost')
from (
  select distinct on (shipment_id) shipment_id, status, status_raw, event_at
  from public.shipment_events
  order by shipment_id, event_at desc nulls last, id desc
) l
where l.shipment_id = s.id and s.status is distinct from l.status and l.status = 'booked';

-- ---------------------------------------------------------------- off-Shopify parcel charges in P&L
do $do$
declare d text := pg_get_functiondef('public.finance_summary(date,date)'::regprocedure);
begin
  if position('courier_other' in d) = 0 then
    d := replace(d, 'cash jsonb;', 'cash jsonb;
  v_other numeric;');
    d := replace(d, $x$  pnl := pnl || jsonb_build_object(
    'expenses', exp_total,$x$, $x$  -- Courier charges on parcels outside Shopify orders (replacements, exchanges, manual bookings)
  select coalesce(sum(sl.courier_charges + sl.other_deductions), 0) into v_other
  from public.settlement_lines sl
  join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
  join public.shipments s on s.tracking_number = sl.tracking_number and s.store_id = b.store_id
  where s.order_id is null and coalesce(b.statement_date, b.imported_at::date) between p_from and p_to;

  pnl := pnl || jsonb_build_object(
    'courier_other', v_other,
    'expenses', exp_total,$x$);
    d := replace(d, $x$'net_before_tax', (pnl ->> 'contribution')::numeric - exp_total$x$,
                    $x$'net_before_tax', (pnl ->> 'contribution')::numeric - exp_total - v_other$x$);
    if position('into v_other' in d) = 0 or position('exp_total - v_other' in d) = 0 then
      raise exception 'finance_summary patch did not apply';
    end if;
    execute d;
  end if;
end
$do$;

-- ---------------------------------------------------------------- alerts (F2, F6, F8, F10)
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
  unpicked int := public.setting_num('reconciliation', 'unpicked_label_days', 3)::int;
  win int := public.setting_num('reconciliation', 'bank_match_window_days', 10)::int;
  tol numeric := public.setting_num('reconciliation', 'cod_mismatch_tolerance', 1);
  v_store uuid := public.current_store_id();
  v_bank_until date;
  v_resolved int;
begin
  perform public.assert_role('finance');

  select max(t.txn_date) into v_bank_until from public.bank_transactions t where t.store_id = v_store;

  create temporary table if not exists _new_alerts (
    kind text, severity text, entity_type text, entity_id text, title text, detail text, amount numeric
  ) on commit drop;
  truncate _new_alerts;

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
         'Not found in synced Shopify orders or the courier''s order list. Sync older orders or check the tracking number.',
         sl.net_amount
  from public.settlement_lines sl
  join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
  where b.store_id = v_store
    and not exists (select 1 from public.shipments s where s.tracking_number = sl.tracking_number and s.store_id = b.store_id);

  insert into _new_alerts
  select 'settled_but_returned', 'critical', 'order', f.order_id::text,
         'Settled but marked returned: ' || f.name,
         format('Courier paid Rs %s net (COD Rs %s) for a parcel the tracking shows as %s', f.settled_net, f.settled_cod, f.shipment_status),
         f.settled_net
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

  -- F6: label printed but the courier never collected the parcel
  insert into _new_alerts
  select 'label_not_picked', case when f.fulfilled_at < now() - make_interval(days => unpicked * 7) then 'critical' else 'warning' end,
         'order', f.order_id::text,
         'Label not picked up for ' || (current_date - f.fulfilled_at::date) || ' days: ' || f.name,
         format('%s %s — last status: %s. Book the pickup, or cancel the label in the courier portal and the fulfilment in Shopify.',
                upper(f.courier), f.tracking_number, coalesce(f.status_raw, 'booked')),
         f.expected_cod
  from public.v_order_finance f
  where f.money_state = 'booked'
    and f.fulfilled_at < now() - make_interval(days => unpicked);

  insert into _new_alerts
  select 'stuck_shipment', 'warning', 'order', f.order_id::text,
         'No movement for ' || (current_date - coalesce(f.status_at, f.fulfilled_at)::date) || ' days: ' || f.name,
         format('%s %s — last status: %s', upper(f.courier), f.tracking_number, coalesce(f.status_raw, f.shipment_status::text)),
         f.expected_cod
  from public.v_order_finance f
  where f.money_state in ('in_transit', 'returning')
    and coalesce(f.status_at, f.fulfilled_at) < now() - make_interval(days => stuck);

  -- F8: compare with the parcel's own courier fee (PostEx prices by weight tier) when the
  -- courier reported one; otherwise with the rate card (incl. fuel surcharge).
  insert into _new_alerts
  select 'courier_overcharge', 'info', 'order', p.order_id::text,
         'High courier charges on ' || p.name,
         format('Charged Rs %s vs expected ~Rs %s (%s)', p.courier_cost, e.expected, e.basis),
         p.courier_cost - e.expected
  from public.v_order_finance p
  join public.shipments s on s.id = p.shipment_id
  join lateral (
    select r.delivery_charge, r.return_charge, r.cod_fee_percent, r.cod_tax_percent, r.fuel_surcharge_percent
    from public.courier_rate_cards r
    where r.store_id = p.store_id and r.courier = p.courier and r.effective_from <= p.order_date
    order by r.effective_from desc limit 1
  ) rc on true
  cross join lateral (
    select case when p.settled_cod > 0 or (p.is_delivered and p.is_cod) then coalesce(nullif(p.settled_cod, 0), p.current_total) else 0 end as cod,
           s.courier_financials as f
  ) c
  cross join lateral (
    select
      case when coalesce(c.f ->> 'transactionStatus', '') ~* '^(delivered|return)'
           then round(coalesce((c.f ->> 'transactionFee')::numeric, 0) + coalesce((c.f ->> 'transactionTax')::numeric, 0)
                      + case when p.is_returned then coalesce((c.f ->> 'reversalFee')::numeric, 0) + coalesce((c.f ->> 'reversalTax')::numeric, 0) else 0 end
                      + c.cod * coalesce(rc.cod_tax_percent, 0) / 100, 2)
           else round((rc.delivery_charge + case when p.is_returned then rc.return_charge else 0 end) * (1 + rc.fuel_surcharge_percent / 100)
                      + c.cod * (coalesce(rc.cod_fee_percent, 0) + coalesce(rc.cod_tax_percent, 0)) / 100, 2)
      end as expected,
      case when coalesce(c.f ->> 'transactionStatus', '') ~* '^(delivered|return)'
           then 'courier''s own fee for this parcel + COD tax' else 'rate card' end as basis
  ) e
  where p.courier_cost_source = 'actual' and e.expected > 0
    and p.courier_cost > e.expected * 1.15 + 20;

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

revoke execute on function public.apply_courier_financials(jsonb) from public, anon, authenticated;
revoke execute on function public.upsert_courier_parcels(text, jsonb) from public, anon, authenticated;
revoke execute on function public.cancel_unpicked_shipments(text[]) from public, anon, authenticated;
grant execute on function public.apply_courier_financials(jsonb) to service_role;
grant execute on function public.upsert_courier_parcels(text, jsonb) to service_role;
grant execute on function public.cancel_unpicked_shipments(text[]) to service_role;

select public.reconcile_all_stores();

-- Parcels whose reference is an order number we don't have are unsynced Shopify orders
-- (older than Shopify's 60-day window without read_all_orders), not extra parcels
do $do$
declare d text := pg_get_functiondef('public.finance_summary(date,date)'::regprocedure);
begin
  if position('unsynced Shopify order' in d) = 0 then
    d := replace(d, $x$  where s.order_id is null and coalesce(b.statement_date, b.imported_at::date) between p_from and p_to;$x$,
      $x$  where s.order_id is null and coalesce(b.statement_date, b.imported_at::date) between p_from and p_to
    -- a reference that looks like an order number we don't have is an unsynced Shopify order
    -- (e.g. older than Shopify's 60-day window), not an extra parcel: its revenue is missing too
    and not (coalesce(s.courier_order_ref, '') ~* '^\s*#?[a-z]+\d{3,}\s*$'
             and not exists (select 1 from public.orders o where o.store_id = s.store_id
                             and lower(o.name) = '#' || ltrim(lower(trim(s.courier_order_ref)), '#')));$x$);
    if position('unsynced Shopify order' in d) = 0 then raise exception 'finance_summary patch did not apply'; end if;
    execute d;
  end if;
end
$do$;

-- Couriers sometimes repeat an identical history entry; de-duplicate before the event upsert
do $do$
declare d text := pg_get_functiondef('public.apply_tracking_updates(jsonb,jsonb)'::regprocedure);
begin
  if position('select distinct on (e.shipment_id, e.status_raw, e.event_at)' in d) = 0 then
    d := replace(d,
      $x$  select e.shipment_id, e.status, e.status_raw, e.event_at, 'courier'
  from jsonb_to_recordset$x$,
      $x$  -- couriers sometimes repeat an identical history entry; one row per key or the upsert fails
  select distinct on (e.shipment_id, e.status_raw, e.event_at) e.shipment_id, e.status, e.status_raw, e.event_at, 'courier'
  from jsonb_to_recordset$x$);
    if position('distinct on (e.shipment_id' in d) = 0 then raise exception 'apply_tracking_updates patch did not apply'; end if;
    execute d;
  end if;
end
$do$;
