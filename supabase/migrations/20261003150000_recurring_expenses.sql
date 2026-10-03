-- =====================================================================
-- Recurring expenses (rent, salaries, subscriptions…)
-- A rule generates one expense per month, allocated to that month
-- (period_start/period_end = the calendar month). Generated entries are
-- normal expenses: edit a month's amount freely; deleting a month skips it
-- permanently (it is not regenerated).
-- =====================================================================

create table public.recurring_expenses (
  id bigint generated always as identity primary key,
  category_id bigint not null references public.expense_categories (id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  vendor text,
  description text,
  payment_method text check (payment_method in ('bank', 'cash', 'card', 'wallet', 'other')),
  day_of_month integer not null default 1 check (day_of_month between 1 and 28),
  start_month date not null check (extract(day from start_month) = 1),
  end_month date check (end_month is null or extract(day from end_month) = 1),
  active boolean not null default true,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_month is null or end_month >= start_month)
);
create index recurring_expenses_category_idx on public.recurring_expenses (category_id);
create trigger recurring_expenses_touch before update on public.recurring_expenses
  for each row execute function public.touch_updated_at();
create trigger audit_recurring_expenses after insert or update or delete on public.recurring_expenses
  for each row execute function public.audit_trigger();

alter table public.recurring_expenses enable row level security;
create policy "viewer can read" on public.recurring_expenses for select to authenticated using ((select public.has_role('viewer')));
create policy "finance can insert" on public.recurring_expenses for insert to authenticated with check ((select public.has_role('finance')));
create policy "finance can update" on public.recurring_expenses for update to authenticated
  using ((select public.has_role('finance'))) with check ((select public.has_role('finance')));
create policy "finance can delete" on public.recurring_expenses for delete to authenticated using ((select public.has_role('finance')));
grant select, insert, update, delete on public.recurring_expenses to authenticated;

alter table public.expenses add column if not exists recurring_id bigint references public.recurring_expenses (id) on delete set null;
create unique index if not exists expenses_recurring_month_uniq on public.expenses (recurring_id, period_start) where recurring_id is not null;

-- Months the user deleted on purpose
create table public.recurring_expense_skips (
  recurring_id bigint not null references public.recurring_expenses (id) on delete cascade,
  month date not null,
  primary key (recurring_id, month)
);
alter table public.recurring_expense_skips enable row level security;
create policy "viewer can read" on public.recurring_expense_skips for select to authenticated using ((select public.has_role('viewer')));

create or replace function public.remember_recurring_skip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.recurring_id is not null and old.period_start is not null then
    insert into public.recurring_expense_skips (recurring_id, month)
    values (old.recurring_id, old.period_start) on conflict do nothing;
  end if;
  return old;
end;
$$;
create trigger expenses_recurring_skip after delete on public.expenses
  for each row execute function public.remember_recurring_skip();
revoke execute on function public.remember_recurring_skip() from public, anon, authenticated;

-- Generate every due month up to the current month (PKT). Idempotent.
create or replace function public.generate_recurring_expenses()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v int;
  this_month date := date_trunc('month', (now() at time zone 'Asia/Karachi'))::date;
begin
  perform public.assert_role('finance');
  insert into public.expenses (expense_date, category_id, amount, vendor, description, payment_method,
                               period_start, period_end, recurring_id, created_by)
  select
    least(m::date + (r.day_of_month - 1), (m + interval '1 month - 1 day')::date),
    r.category_id, r.amount, r.vendor,
    r.description,
    r.payment_method,
    m::date, (m + interval '1 month - 1 day')::date,
    r.id, r.created_by
  from public.recurring_expenses r
  cross join lateral generate_series(r.start_month, least(coalesce(r.end_month, this_month), this_month), interval '1 month') m
  where r.active
    and not exists (select 1 from public.recurring_expense_skips k where k.recurring_id = r.id and k.month = m::date)
  on conflict (recurring_id, period_start) where recurring_id is not null do nothing;
  get diagnostics v = row_count;
  return v;
end;
$$;
revoke execute on function public.generate_recurring_expenses() from public, anon;
grant execute on function public.generate_recurring_expenses() to authenticated, service_role;

-- Daily at 00:30 PKT
select cron.schedule('hk-recurring-expenses', '30 19 * * *', $$select public.generate_recurring_expenses()$$);
