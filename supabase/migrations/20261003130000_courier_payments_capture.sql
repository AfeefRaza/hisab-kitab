-- =====================================================================
-- Automatic courier payment (CPR) capture — PostEx payment-status API.
-- sync-payments stores the raw financial fields + payment status per parcel;
-- build_api_settlements() (next migration) turns them into settlement batches.
-- =====================================================================
alter table public.shipments
  add column if not exists courier_financials jsonb,
  add column if not exists payment_info jsonb,
  add column if not exists payment_checked_at timestamptz,
  add column if not exists payment_next_check_at timestamptz not null default now(),
  add column if not exists payment_complete boolean not null default false;

create index if not exists shipments_payment_due_idx on public.shipments (payment_next_check_at)
  where not payment_complete;

alter table public.sync_runs drop constraint if exists sync_runs_kind_check;
alter table public.sync_runs add constraint sync_runs_kind_check
  check (kind in ('orders', 'tracking', 'alerts', 'bank_match', 'payments'));

create or replace function public.apply_courier_payments(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v int;
begin
  update public.shipments s set
    courier_financials = coalesce(r.financials, s.courier_financials),
    payment_info = coalesce(r.payment, s.payment_info),
    payment_checked_at = now(),
    payment_complete = coalesce(r.complete, false),
    payment_next_check_at = now() + make_interval(hours => coalesce(r.next_hours, 12))
  from jsonb_to_recordset(p_rows) as r(id bigint, financials jsonb, payment jsonb, complete boolean, next_hours int)
  where s.id = r.id;
  get diagnostics v = row_count;
  return v;
end;
$$;
revoke execute on function public.apply_courier_payments(jsonb) from public, anon, authenticated;
grant execute on function public.apply_courier_payments(jsonb) to service_role;
