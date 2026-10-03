-- =====================================================================
-- Build courier settlement batches from API payment data (PostEx CPRs).
--
-- PostEx payment-status returns per parcel: settle, cpr1 (CPR number),
-- cpr1Date, settlementDate. Tracking returns invoicePayment, transactionFee,
-- transactionTax (delivered) and reversalFee, reversalTax (returned).
-- One CPR = one weekly remittance covering many parcels, so:
--   batch  = one per CPR (file_sha256 'api:postex:<CPR>', source 'api')
--   line   = delivered: COD − fee − tax ; returned: −(reversal fee + tax)
--   batch net = expected bank deposit for that CPR
-- Idempotent: re-running updates lines and totals as more parcels arrive.
-- Parcels already covered by a manually imported statement are skipped.
-- =====================================================================

alter table public.settlement_batches
  add column if not exists source text not null default 'file' check (source in ('file', 'api'));

create or replace function public.build_api_settlements()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batches int;
  v_lines int;
begin
  create temporary table if not exists _api_src (
    tracking_number text, cpr text, cpr_date date, kind text,
    cod numeric, charges numeric, tax numeric, net numeric,
    order_ref text, courier_status text, raw jsonb
  ) on commit drop;
  truncate _api_src;

  insert into _api_src
  select s.tracking_number,
         s.payment_info ->> 'cpr1',
         ((s.payment_info ->> 'cpr1Date')::timestamptz at time zone 'Asia/Karachi')::date,
         x.kind,
         case when x.kind = 'delivered' then coalesce((f ->> 'invoicePayment')::numeric, 0) else 0 end,
         case when x.kind = 'delivered' then coalesce((f ->> 'transactionFee')::numeric, 0) else coalesce((f ->> 'reversalFee')::numeric, 0) end,
         case when x.kind = 'delivered' then coalesce((f ->> 'transactionTax')::numeric, 0) else coalesce((f ->> 'reversalTax')::numeric, 0) end,
         0,
         f ->> 'orderRefNumber',
         f ->> 'transactionStatus',
         jsonb_build_object('financials', f, 'payment', s.payment_info)
  from public.shipments s
  cross join lateral (select s.courier_financials as f) ff
  cross join lateral (
    select case when coalesce(f ->> 'transactionStatus', '') ~* 'return' or s.status in ('returned', 'return_in_transit')
                then 'returned' else 'delivered' end as kind
  ) x
  where s.courier = 'postex'
    and s.payment_info ->> 'settle' = 'true'
    and coalesce(s.payment_info ->> 'cpr1', '') <> ''
    and s.courier_financials is not null
    and not exists (
      select 1 from public.settlement_lines sl
      join public.settlement_batches b on b.id = sl.batch_id
      where sl.tracking_number = s.tracking_number and b.voided_at is null and b.source = 'file');

  update _api_src set net = round(cod - charges - tax, 2) where true;  -- pg_safeupdate needs a WHERE

  insert into public.settlement_batches (courier, file_name, file_sha256, statement_ref, statement_date, source, note)
  select distinct on (cpr) 'postex', 'PostEx API', 'api:postex:' || cpr, cpr, cpr_date, 'api',
         'Auto-imported from the PostEx payment-status API'
  from _api_src
  order by cpr, cpr_date
  on conflict (file_sha256) do nothing;
  get diagnostics v_batches = row_count;

  insert into public.settlement_lines (batch_id, tracking_number, order_ref, line_kind, cod_amount, courier_charges,
                                       other_deductions, net_amount, courier_status, raw)
  select b.id, a.tracking_number, a.order_ref, a.kind, a.cod, a.charges, a.tax, a.net, a.courier_status, a.raw
  from _api_src a
  join public.settlement_batches b on b.file_sha256 = 'api:postex:' || a.cpr and b.voided_at is null
  on conflict (batch_id, tracking_number, line_kind) do update set
    cod_amount = excluded.cod_amount, courier_charges = excluded.courier_charges,
    other_deductions = excluded.other_deductions, net_amount = excluded.net_amount,
    order_ref = excluded.order_ref, courier_status = excluded.courier_status, raw = excluded.raw;
  get diagnostics v_lines = row_count;

  -- refresh totals of API batches
  update public.settlement_batches b set
    row_count = t.n, total_cod = t.cod, total_charges = t.charges, total_net = t.net
  from (
    select sl.batch_id, count(*) n,
           coalesce(sum(sl.cod_amount) filter (where sl.line_kind = 'delivered'), 0) cod,
           coalesce(sum(sl.courier_charges + sl.other_deductions), 0) charges,
           coalesce(sum(sl.net_amount), 0) net
    from public.settlement_lines sl
    group by sl.batch_id
  ) t
  where t.batch_id = b.id and b.source = 'api';

  return jsonb_build_object('new_batches', v_batches, 'lines_upserted', v_lines);
end;
$$;
revoke execute on function public.build_api_settlements() from public, anon, authenticated;
grant execute on function public.build_api_settlements() to service_role;

-- Payment sync every 3 hours (only parcels whose payment isn't complete)
select cron.schedule('hk-sync-payments', '25 */3 * * *', $$select public.cron_call('sync-payments')$$);
