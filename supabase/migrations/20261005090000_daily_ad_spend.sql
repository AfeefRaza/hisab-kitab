-- Daily series now includes ad spend (marketing expenses allocated per day),
-- so the dashboard can chart spend against sales and contribution.
drop function if exists public.finance_daily(date, date);

create function public.finance_daily(p_from date, p_to date)
returns table (
  day date, orders bigint, delivered bigint, returned bigint, in_progress bigint,
  gross_sales numeric, revenue numeric, contribution numeric, ad_spend numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ),
  o as (
    select dd.day,
      count(p.order_id) as orders,
      count(p.order_id) filter (where p.is_delivered) as delivered,
      count(p.order_id) filter (where p.is_returned) as returned,
      count(p.order_id) filter (where not p.is_final and p.money_state not in ('cancelled')) as in_progress,
      coalesce(sum(p.current_total) filter (where p.money_state <> 'cancelled'), 0) as gross_sales,
      coalesce(sum(p.revenue), 0) as revenue,
      coalesce(sum(p.contribution), 0) as contribution
    from days dd
    left join public.v_order_profit p on p.order_date = dd.day
    group by dd.day
  ),
  a as (
    select dd.day,
      coalesce(sum(e.amount / ((coalesce(e.period_end, e.expense_date) - coalesce(e.period_start, e.expense_date)) + 1)), 0) as ad_spend
    from days dd
    left join public.expenses e
      on dd.day between coalesce(e.period_start, e.expense_date) and coalesce(e.period_end, e.expense_date)
     and exists (select 1 from public.expense_categories c where c.id = e.category_id and c.kind = 'marketing')
    group by dd.day
  )
  select o.day, o.orders, o.delivered, o.returned, o.in_progress, o.gross_sales, o.revenue, o.contribution,
         round(a.ad_spend, 2)
  from o join a using (day)
  order by o.day;
$$;
revoke execute on function public.finance_daily(date, date) from public, anon;
grant execute on function public.finance_daily(date, date) to authenticated;
