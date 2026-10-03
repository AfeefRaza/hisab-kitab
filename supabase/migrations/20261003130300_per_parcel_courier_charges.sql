-- =====================================================================
-- Per-parcel courier charges: when no settlement line exists yet, use the
-- courier's own fee + tax for that parcel (PostEx returns transactionFee /
-- transactionTax, or reversalFee / reversalTax for returns) before falling
-- back to the flat rate card. courier_cost_source: actual | courier_api | estimate
-- =====================================================================
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
  s.check_error,
  s.courier_financials
from public.shipments s
order by s.order_id, s.fulfilled_at desc nulls last, s.id desc;

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
    sh.courier_financials as api_fin,
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
),
priced as (
  -- the courier's own per-parcel charge (fee + tax) when its API provides it
  select st.*,
    case
      when st.money_state in ('with_courier', 'settled_unbanked', 'in_bank')
           or (st.money_state = 'prepaid' and st.shipment_id is not null)
        then nullif(coalesce((st.api_fin ->> 'transactionFee')::numeric, 0) + coalesce((st.api_fin ->> 'transactionTax')::numeric, 0), 0)
      when st.money_state in ('returned', 'returning', 'lost')
        then nullif(coalesce((st.api_fin ->> 'reversalFee')::numeric, 0) + coalesce((st.api_fin ->> 'reversalTax')::numeric, 0), 0)
    end as api_charges
  from staged st
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
  (case when s.actual_charges is not null then 'actual' when s.api_charges is not null then 'courier_api' else 'estimate' end) as courier_cost_source,
  (case
     when s.actual_charges is not null then s.actual_charges
     when s.api_charges is not null then s.api_charges
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
from priced s;
