-- =====================================================================
-- Finance engine: "Where is our money?"
--
-- Every order is placed in exactly one money_state:
--   unfulfilled       order placed, not shipped yet
--   cancelled         cancelled before delivery (no money expected)
--   booked            label created, courier hasn't moved it
--   in_transit        with courier, on the way to customer (incl. failed attempts)
--   with_courier      DELIVERED, cash collected by courier, not in any settlement
--   settled_unbanked  courier listed it in a settlement statement, deposit not yet
--                     matched to a bank credit
--   in_bank           settlement batch matched to a bank deposit  ✅
--   returning         return in transit back to us
--   returned          returned to us (no revenue; shipping + packaging lost)
--   lost              lost by courier (claim)
--   prepaid           paid online; money via payment gateway, not COD
--
-- Profit is recognised only for final orders (delivered / returned / lost).
-- =====================================================================

-- Helper: read a numeric setting
create or replace function public.setting_num(p_key text, p_field text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (value ->> p_field)::numeric from public.app_settings where key = p_key), p_default);
$$;
grant execute on function public.setting_num(text, text, numeric) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Line-level cost resolution (Shopify unit cost → variant rule → SKU rule
-- → keyword rule → default rule)
-- ---------------------------------------------------------------------
create or replace view public.v_line_costs
with (security_invoker = true) as
select
  l.id,
  l.order_id,
  o.order_date,
  l.title,
  l.variant_title,
  l.sku,
  l.product_id,
  l.variant_id,
  l.quantity,
  l.current_quantity,
  l.unit_price,
  coalesce(l.unit_cost, r.unit_cost, 0)::numeric(14,2) as unit_cost,
  case when l.unit_cost is not null then 'shopify'
       when r.id is not null then 'rule:' || r.name
       else 'none' end as cost_source,
  (l.current_quantity * coalesce(l.unit_cost, r.unit_cost, 0))::numeric(14,2) as line_cogs
from public.order_lines l
join public.orders o on o.id = l.order_id
left join lateral (
  select pr.id, pr.name, pr.unit_cost
  from public.product_cost_rules pr
  where pr.active
    and pr.effective_from <= o.order_date
    and (
      (pr.match_type = 'variant' and pr.match_value = l.variant_id::text)
      or (pr.match_type = 'sku' and l.sku is not null and lower(trim(pr.match_value)) = lower(trim(l.sku)))
      or (pr.match_type = 'keyword' and exists (
            select 1 from unnest(string_to_array(coalesce(pr.match_value, ''), ',')) kw
            where length(trim(kw)) > 0 and l.title ilike '%' || trim(kw) || '%'))
      or pr.match_type = 'default'
    )
  order by
    case pr.match_type when 'variant' then 0 when 'sku' then 1 when 'keyword' then 2 else 3 end,
    pr.priority,
    pr.effective_from desc
  limit 1
) r on l.unit_cost is null;

-- ---------------------------------------------------------------------
-- Settlement aggregates per tracking number (non-voided batches only)
-- ---------------------------------------------------------------------
create or replace view public.v_batch_bank_status
with (security_invoker = true) as
select
  b.id as batch_id,
  b.courier,
  b.statement_date,
  b.total_net,
  coalesce(sum(m.amount), 0)::numeric(14,2) as matched_amount,
  (coalesce(sum(m.amount), 0) >= b.total_net - public.setting_num('reconciliation', 'bank_match_tolerance', 1)) as is_banked,
  max(bt.txn_date) as banked_on
from public.settlement_batches b
left join public.settlement_bank_matches m on m.batch_id = b.id
left join public.bank_transactions bt on bt.id = m.bank_transaction_id
where b.voided_at is null
group by b.id;

create or replace view public.v_tracking_settlement
with (security_invoker = true) as
select
  sl.tracking_number,
  sum(sl.cod_amount) filter (where sl.line_kind = 'delivered')::numeric(14,2) as settled_cod,
  sum(sl.net_amount)::numeric(14,2) as settled_net,
  sum(sl.courier_charges + sl.other_deductions)::numeric(14,2) as actual_charges,
  count(distinct sl.batch_id) filter (where sl.line_kind = 'delivered') as delivered_batch_count,
  bool_or(sl.line_kind = 'returned') as has_return_line,
  bool_and(bs.is_banked) as all_banked,
  max(bs.statement_date) as last_statement_date,
  max(bs.banked_on) as banked_on,
  array_agg(distinct sl.batch_id) as batch_ids
from public.settlement_lines sl
join public.v_batch_bank_status bs on bs.batch_id = sl.batch_id
group by sl.tracking_number;

-- ---------------------------------------------------------------------
-- Primary shipment per order (latest fulfilment)
-- ---------------------------------------------------------------------
create or replace view public.v_order_shipment
with (security_invoker = true) as
select distinct on (s.order_id)
  s.order_id,
  s.id as shipment_id,
  s.tracking_number,
  s.courier,
  s.fulfilled_at,
  coalesce(s.manual_status, s.status) as status,
  s.status_raw,
  s.status_at,
  s.delivered_at,
  s.returned_at,
  s.is_final,
  s.manual_status is not null as is_manual,
  s.last_checked_at,
  s.check_error
from public.shipments s
order by s.order_id, s.fulfilled_at desc nulls last, s.id desc;

-- ---------------------------------------------------------------------
-- Order finance — one row per order, the heart of the system
-- ---------------------------------------------------------------------
create or replace view public.v_order_finance
with (security_invoker = true) as
with lines as (
  select order_id,
         sum(current_quantity)::int as units,
         sum(line_cogs)::numeric(14,2) as cogs,
         bool_or(cost_source = 'none') as missing_cost
  from public.v_line_costs
  group by order_id
),
base as (
  select
    o.id as order_id,
    o.name,
    o.order_date,
    o.created_at_shop,
    o.customer_name,
    o.phone,
    o.city,
    o.is_cod,
    o.cancelled_at,
    o.financial_status,
    o.current_total,
    o.total_tax,
    o.shipping_charged,
    o.total_discounts,
    coalesce(l.units, 0) as units,
    coalesce(l.cogs, 0) as cogs,
    coalesce(l.missing_cost, false) as missing_cost,
    sh.shipment_id,
    sh.tracking_number,
    coalesce(sh.courier, case when sh.shipment_id is null then null else 'unknown' end) as courier,
    sh.status as shipment_status,
    sh.status_raw,
    sh.status_at,
    sh.fulfilled_at,
    sh.delivered_at,
    sh.returned_at,
    sh.is_manual,
    sh.check_error,
    ts.settled_cod,
    ts.settled_net,
    ts.actual_charges,
    ts.delivered_batch_count,
    ts.has_return_line,
    ts.all_banked,
    ts.last_statement_date,
    ts.banked_on,
    rc.delivery_charge,
    rc.return_charge,
    rc.cod_fee_percent
  from public.orders o
  left join lines l on l.order_id = o.id
  left join public.v_order_shipment sh on sh.order_id = o.id
  left join public.v_tracking_settlement ts on ts.tracking_number = sh.tracking_number
  left join lateral (
    select r.delivery_charge, r.return_charge, r.cod_fee_percent
    from public.courier_rate_cards r
    where r.courier = coalesce(sh.courier, 'unknown') and r.effective_from <= o.order_date
    order by r.effective_from desc
    limit 1
  ) rc on true
),
staged as (
  select b.*,
    case
      when b.shipment_status = 'delivered' and not b.is_cod then 'prepaid'
      when b.shipment_status = 'delivered' and b.settled_cod is null then 'with_courier'
      when b.shipment_status = 'delivered' and coalesce(b.all_banked, false) then 'in_bank'
      when b.shipment_status = 'delivered' then 'settled_unbanked'
      when b.shipment_status = 'returned' then 'returned'
      when b.shipment_status = 'return_in_transit' then 'returning'
      when b.shipment_status = 'lost' then 'lost'
      when b.cancelled_at is not null or b.shipment_status = 'cancelled' then 'cancelled'
      when b.shipment_id is null then case when b.is_cod then 'unfulfilled' else 'prepaid' end
      when b.shipment_status = 'booked' then 'booked'
      else 'in_transit'
    end as money_state
  from base b
)
select
  s.order_id, s.name, s.order_date, s.created_at_shop, s.customer_name, s.phone, s.city,
  s.is_cod, s.cancelled_at, s.financial_status,
  s.current_total, s.total_tax, s.shipping_charged, s.total_discounts,
  s.units, s.cogs, s.missing_cost,
  s.shipment_id, s.tracking_number, s.courier, s.shipment_status, s.status_raw, s.status_at,
  s.fulfilled_at, s.delivered_at, s.returned_at, s.is_manual, s.check_error,
  s.money_state,
  -- money expected from the courier for this order
  (case when s.is_cod and s.money_state not in ('cancelled', 'returned', 'returning', 'lost') then s.current_total else 0 end)::numeric(14,2) as expected_cod,
  coalesce(s.settled_cod, 0)::numeric(14,2) as settled_cod,
  coalesce(s.settled_net, 0)::numeric(14,2) as settled_net,
  s.last_statement_date,
  s.banked_on,
  coalesce(s.delivered_batch_count, 0) as settlement_count,
  -- courier cost: actual from statements when present, else rate card estimate
  (case when s.actual_charges is not null then 'actual' else 'estimate' end) as courier_cost_source,
  (case
     when s.actual_charges is not null then s.actual_charges
     when s.money_state in ('with_courier', 'settled_unbanked', 'in_bank')
       then coalesce(s.delivery_charge, 0) + round(s.current_total * coalesce(s.cod_fee_percent, 0) / 100, 2)
     when s.money_state = 'prepaid' and s.shipment_id is not null then coalesce(s.delivery_charge, 0)
     when s.money_state in ('returned', 'returning', 'lost')
       then coalesce(s.delivery_charge, 0) + coalesce(s.return_charge, 0)
     else 0
   end)::numeric(14,2) as courier_cost,
  (case when s.shipment_id is not null and s.money_state <> 'cancelled'
        then public.setting_num('packaging', 'flyer_per_parcel', 0) + s.units * public.setting_num('packaging', 'polybag_per_unit', 0)
        else 0 end)::numeric(14,2) as packaging_cost,
  (s.money_state in ('with_courier', 'settled_unbanked', 'in_bank', 'prepaid') and s.shipment_status = 'delivered') as is_delivered,
  (s.money_state in ('returned', 'returning')) as is_returned,
  (s.money_state in ('with_courier', 'settled_unbanked', 'in_bank', 'returned', 'returning', 'lost')
   or (s.money_state = 'prepaid' and s.shipment_status = 'delivered')) as is_final
from staged s;

-- Profit per order, layered on top so the formula lives in one place
create or replace view public.v_order_profit
with (security_invoker = true) as
select
  f.*,
  (case when f.is_delivered then f.current_total - f.total_tax else 0 end)::numeric(14,2) as revenue,
  (case when f.is_delivered then f.cogs
        when f.is_returned or f.money_state = 'lost'
          then round(f.cogs * (case when f.money_state = 'lost' then 100 else public.setting_num('returns', 'inventory_loss_percent', 0) end) / 100, 2)
        else 0 end)::numeric(14,2) as cogs_recognised,
  (case
     when f.is_delivered
       then (f.current_total - f.total_tax) - f.cogs - f.courier_cost - f.packaging_cost
     when f.is_returned or f.money_state = 'lost'
       then -(f.courier_cost
              + (case when public.setting_num('returns', 'count_packaging_on_return', 1) = 1 then f.packaging_cost else 0 end)
              + round(f.cogs * (case when f.money_state = 'lost' then 100 else public.setting_num('returns', 'inventory_loss_percent', 0) end) / 100, 2))
     else null
   end)::numeric(14,2) as contribution
from public.v_order_finance f;

-- ---------------------------------------------------------------------
-- Expenses allocated to a date window (spread expenses pro-rata by day)
-- ---------------------------------------------------------------------
create or replace function public.expenses_in_period(p_from date, p_to date)
returns table (category_id bigint, category text, kind text, amount numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.id, c.name, c.kind,
    sum(
      case
        when e.period_start is null then e.amount
        else round(e.amount
             * greatest(0, (least(e.period_end, p_to) - greatest(e.period_start, p_from) + 1))
             / (e.period_end - e.period_start + 1)::numeric, 2)
      end
    )::numeric(14,2)
  from public.expenses e
  join public.expense_categories c on c.id = e.category_id
  where (e.period_start is null and e.expense_date between p_from and p_to)
     or (e.period_start is not null and e.period_start <= p_to and e.period_end >= p_from)
  group by c.id, c.name, c.kind;
$$;

-- ---------------------------------------------------------------------
-- Executive summary for a date window (order-date cohort)
-- ---------------------------------------------------------------------
create or replace function public.finance_summary(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  result jsonb;
  pnl jsonb;
  states jsonb;
  exp_total numeric;
  exp_marketing numeric;
  exp_by_cat jsonb;
  cash jsonb;
  tax_pct numeric := public.setting_num('tax', 'income_tax_percent', 0);
begin
  if not public.has_role('viewer') then
    raise exception 'not authorised' using errcode = '42501';
  end if;

  select coalesce(jsonb_object_agg(money_state, jsonb_build_object('orders', n, 'amount', amt)), '{}'::jsonb)
  into states
  from (
    select money_state, count(*) as n, sum(current_total)::numeric(14,2) as amt
    from public.v_order_profit
    where order_date between p_from and p_to
    group by money_state
  ) x;

  select jsonb_build_object(
    'orders', count(*),
    'delivered', count(*) filter (where is_delivered),
    'returned', count(*) filter (where is_returned),
    'final', count(*) filter (where is_final),
    'units_delivered', coalesce(sum(units) filter (where is_delivered), 0),
    'gross_sales', coalesce(sum(current_total) filter (where money_state <> 'cancelled'), 0),
    'revenue', coalesce(sum(revenue), 0),
    'cogs', coalesce(sum(cogs_recognised), 0),
    'courier_cost', coalesce(sum(courier_cost) filter (where is_final), 0),
    'packaging_cost', coalesce(sum(packaging_cost) filter (where is_final and (is_delivered or public.setting_num('returns', 'count_packaging_on_return', 1) = 1)), 0),
    'return_loss', coalesce(-sum(contribution) filter (where is_returned or money_state = 'lost'), 0),
    'contribution', coalesce(sum(contribution), 0),
    'expected_cod_open', coalesce(sum(expected_cod) filter (where money_state in ('booked', 'in_transit', 'with_courier', 'settled_unbanked', 'unfulfilled')), 0),
    'courier_cost_estimated_orders', count(*) filter (where is_final and courier_cost_source = 'estimate'),
    'missing_cost_orders', count(*) filter (where missing_cost and is_delivered)
  )
  into pnl
  from public.v_order_profit
  where order_date between p_from and p_to;

  select coalesce(sum(amount), 0), coalesce(sum(amount) filter (where kind = 'marketing'), 0),
         coalesce(jsonb_agg(jsonb_build_object('category', category, 'kind', kind, 'amount', amount) order by amount desc), '[]'::jsonb)
  into exp_total, exp_marketing, exp_by_cat
  from public.expenses_in_period(p_from, p_to)
  where kind <> 'inventory';   -- inventory purchases are capitalised, COGS covers them

  -- Cash view: what actually moved in the window, by statement / bank date
  select jsonb_build_object(
    'settled_net', coalesce((select sum(total_net) from public.settlement_batches
                            where voided_at is null and statement_date between p_from and p_to), 0),
    'bank_courier_credits', coalesce((select sum(m.amount) from public.settlement_bank_matches m
                                     join public.bank_transactions t on t.id = m.bank_transaction_id
                                     where t.txn_date between p_from and p_to), 0),
    'unbanked_batches', (select count(*) from public.v_batch_bank_status where not is_banked),
    'unbanked_amount', coalesce((select sum(total_net - matched_amount) from public.v_batch_bank_status where not is_banked), 0)
  ) into cash;

  pnl := pnl || jsonb_build_object(
    'expenses', exp_total,
    'marketing', exp_marketing,
    'net_before_tax', (pnl ->> 'contribution')::numeric - exp_total
  );
  pnl := pnl || jsonb_build_object(
    'tax', greatest(0, round(((pnl ->> 'net_before_tax')::numeric) * tax_pct / 100, 2)),
    'net_profit', (pnl ->> 'net_before_tax')::numeric
                  - greatest(0, round(((pnl ->> 'net_before_tax')::numeric) * tax_pct / 100, 2)),
    'roas', case when exp_marketing > 0 then round((pnl ->> 'revenue')::numeric / exp_marketing, 2) end,
    'delivery_rate', case when ((pnl ->> 'delivered')::int + (pnl ->> 'returned')::int) > 0
                     then round(100.0 * (pnl ->> 'delivered')::int / ((pnl ->> 'delivered')::int + (pnl ->> 'returned')::int), 1) end,
    'aov', case when (pnl ->> 'delivered')::int > 0 then round((pnl ->> 'revenue')::numeric / (pnl ->> 'delivered')::int, 0) end
  );

  result := jsonb_build_object(
    'from', p_from, 'to', p_to,
    'money_states', states,
    'pnl', pnl,
    'expenses_by_category', exp_by_cat,
    'cash', cash,
    'open_alerts', (select jsonb_build_object(
        'critical', count(*) filter (where severity = 'critical'),
        'warning', count(*) filter (where severity = 'warning'),
        'info', count(*) filter (where severity = 'info'))
      from public.alerts where status = 'open'),
    'last_sync', (select jsonb_object_agg(kind, finished_at) from (
        select distinct on (kind) kind, finished_at from public.sync_runs
        where status in ('ok', 'partial') order by kind, started_at desc) s)
  );
  return result;
end;
$$;

-- Daily series for charts
create or replace function public.finance_daily(p_from date, p_to date)
returns table (
  day date, orders bigint, delivered bigint, returned bigint, in_progress bigint,
  gross_sales numeric, revenue numeric, contribution numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  select d::date,
    count(p.order_id),
    count(p.order_id) filter (where p.is_delivered),
    count(p.order_id) filter (where p.is_returned),
    count(p.order_id) filter (where not p.is_final and p.money_state not in ('cancelled')),
    coalesce(sum(p.current_total) filter (where p.money_state <> 'cancelled'), 0),
    coalesce(sum(p.revenue), 0),
    coalesce(sum(p.contribution), 0)
  from generate_series(p_from, p_to, interval '1 day') d
  left join public.v_order_profit p on p.order_date = d::date
  group by d
  order by d;
$$;

-- Breakdown by dimension: courier | city | product
create or replace function public.profit_breakdown(p_from date, p_to date, p_dimension text)
returns table (
  key text, orders bigint, delivered bigint, returned bigint, delivery_rate numeric,
  revenue numeric, cogs numeric, courier_cost numeric, contribution numeric, expected_open numeric
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_dimension = 'product' then
    return query
    select lc.title,
      count(distinct p.order_id),
      count(distinct p.order_id) filter (where p.is_delivered),
      count(distinct p.order_id) filter (where p.is_returned),
      round(100.0 * count(distinct p.order_id) filter (where p.is_delivered)
            / nullif(count(distinct p.order_id) filter (where p.is_delivered or p.is_returned), 0), 1),
      -- allocate order-level amounts to lines by price share
      coalesce(sum(p.revenue * lc.share), 0)::numeric(14,2),
      coalesce(sum(case when p.is_delivered then lc.line_cogs else 0 end), 0)::numeric(14,2),
      coalesce(sum(p.courier_cost * lc.share) filter (where p.is_final), 0)::numeric(14,2),
      coalesce(sum(p.contribution * lc.share), 0)::numeric(14,2),
      coalesce(sum(p.expected_cod * lc.share) filter (where not p.is_final), 0)::numeric(14,2)
    from public.v_order_profit p
    join (
      select v.order_id, v.title, v.line_cogs,
        coalesce((v.unit_price * v.current_quantity) / nullif(sum(v.unit_price * v.current_quantity) over (partition by v.order_id), 0),
                 1.0 / count(*) over (partition by v.order_id)) as share
      from public.v_line_costs v
      where v.current_quantity > 0
    ) lc on lc.order_id = p.order_id
    where p.order_date between p_from and p_to
    group by lc.title
    order by 9 desc nulls last;
  else
    return query
    select
      case when p_dimension = 'courier' then coalesce(p.courier, 'not shipped')
           else coalesce(initcap(trim(p.city)), 'Unknown') end,
      count(*),
      count(*) filter (where p.is_delivered),
      count(*) filter (where p.is_returned),
      round(100.0 * count(*) filter (where p.is_delivered) / nullif(count(*) filter (where p.is_delivered or p.is_returned), 0), 1),
      coalesce(sum(p.revenue), 0)::numeric(14,2),
      coalesce(sum(p.cogs_recognised), 0)::numeric(14,2),
      coalesce(sum(p.courier_cost) filter (where p.is_final), 0)::numeric(14,2),
      coalesce(sum(p.contribution), 0)::numeric(14,2),
      coalesce(sum(p.expected_cod) filter (where not p.is_final), 0)::numeric(14,2)
    from public.v_order_profit p
    where p.order_date between p_from and p_to
      and p.money_state <> 'cancelled'
    group by 1
    order by 2 desc;
  end if;
end;
$$;

-- Complete financial timeline for one order
create or replace function public.order_timeline(p_order_id bigint)
returns table (at timestamptz, kind text, title text, detail text, amount numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from (
    select o.created_at_shop, 'order', 'Order placed ' || o.name,
           concat_ws(' · ', o.customer_name, o.city, case when o.is_cod then 'COD' else 'Prepaid' end),
           o.total_price
    from public.orders o where o.id = p_order_id
    union all
    select o.cancelled_at, 'cancelled', 'Order cancelled', o.cancel_reason, null
    from public.orders o where o.id = p_order_id and o.cancelled_at is not null
    union all
    select o.updated_at_shop, 'refund', 'Refunded in Shopify', null, -o.total_refunded
    from public.orders o where o.id = p_order_id and o.total_refunded > 0
    union all
    select s.fulfilled_at, 'shipment', 'Shipped with ' || upper(s.courier), s.tracking_number, null
    from public.shipments s where s.order_id = p_order_id
    union all
    select e.event_at, 'tracking', initcap(replace(e.status::text, '_', ' ')), e.status_raw, null
    from public.shipment_events e join public.shipments s on s.id = e.shipment_id
    where s.order_id = p_order_id
    union all
    select s.manual_at, 'manual', 'Status manually set to ' || replace(s.manual_status::text, '_', ' '), s.manual_note, null
    from public.shipments s where s.order_id = p_order_id and s.manual_status is not null
    union all
    select coalesce(b.statement_date::timestamptz, b.imported_at), 'settlement',
           'In ' || upper(b.courier) || ' settlement ' || coalesce(b.statement_ref, b.file_name),
           format('COD %s − charges %s − deductions %s', sl.cod_amount, sl.courier_charges, sl.other_deductions),
           sl.net_amount
    from public.settlement_lines sl
    join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
    join public.shipments s on s.tracking_number = sl.tracking_number
    where s.order_id = p_order_id
    union all
    select t.txn_date::timestamptz, 'bank', 'Deposited to bank: ' || a.name, t.description, m.amount
    from public.settlement_bank_matches m
    join public.bank_transactions t on t.id = m.bank_transaction_id
    join public.bank_accounts a on a.id = t.account_id
    join public.settlement_lines sl on sl.batch_id = m.batch_id
    join public.shipments s on s.tracking_number = sl.tracking_number
    where s.order_id = p_order_id
  ) x(at, kind, title, detail, amount)
  where at is not null
  order by at;
$$;

-- Global search across orders, tracking numbers, settlements, bank lines
create or replace function public.global_search(p_query text, p_limit int default 20)
returns table (kind text, id text, title text, subtitle text, amount numeric, at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select trim(p_query) as t)
  (select 'order', o.id::text, o.name,
          concat_ws(' · ', o.customer_name, o.phone, o.city), o.current_total, o.created_at_shop
   from public.orders o, q
   where length(q.t) >= 2 and (
     o.name ilike '%' || q.t || '%' or o.customer_name ilike '%' || q.t || '%'
     or o.phone ilike '%' || q.t || '%' or o.city ilike q.t || '%')
   order by o.created_at_shop desc limit p_limit)
  union all
  (select 'order', s.order_id::text, o.name, upper(s.courier) || ' ' || s.tracking_number, o.current_total, s.fulfilled_at
   from public.shipments s join public.orders o on o.id = s.order_id, q
   where length(q.t) >= 4 and s.tracking_number ilike '%' || q.t || '%'
   limit p_limit)
  union all
  (select 'settlement', b.id::text, upper(b.courier) || ' · ' || coalesce(b.statement_ref, b.file_name),
          b.row_count || ' parcels', b.total_net, b.imported_at
   from public.settlement_batches b, q
   where length(q.t) >= 3 and (b.statement_ref ilike '%' || q.t || '%' or b.file_name ilike '%' || q.t || '%')
   limit p_limit)
  union all
  (select 'bank', t.id::text, t.description, coalesce(t.reference, ''), t.credit - t.debit, t.txn_date::timestamptz
   from public.bank_transactions t, q
   where length(q.t) >= 3 and (t.description ilike '%' || q.t || '%' or t.reference ilike '%' || q.t || '%')
   order by t.txn_date desc limit p_limit);
$$;

grant execute on function public.expenses_in_period(date, date) to authenticated;
grant execute on function public.finance_summary(date, date) to authenticated;
grant execute on function public.finance_daily(date, date) to authenticated;
grant execute on function public.profit_breakdown(date, date, text) to authenticated;
grant execute on function public.order_timeline(bigint) to authenticated;
grant execute on function public.global_search(text, int) to authenticated;
