-- =====================================================================
-- 1) Prepaid = Shopify payment status. An order is prepaid only when Shopify says it is
--    paid (e.g. bank transfer confirmed from the WhatsApp receipt and marked paid);
--    "payment pending" is COD/unpaid whatever the payment method name says.
-- 2) Orders cancelled or not confirmed before dispatch, from the team's order tags:
--      cancelled      tag contains "cancelled"/"canceled" ("Cancelled", "❌ Order Cancelled",
--                     "Fraud Risk Order Cancelled", …)
--      not_confirmed  tag "Not Confirmed" (any case/spacing; not "notconfirmeddispatched")
--    A tag applies only while the parcel never moved — courier movement wins.
-- =====================================================================

-- ---------------------------------------------------------------- 1) prepaid
update public.orders set is_cod = coalesce(financial_status, '') not in ('PAID', 'PARTIALLY_REFUNDED', 'REFUNDED')
where is_cod is distinct from (coalesce(financial_status, '') not in ('PAID', 'PARTIALLY_REFUNDED', 'REFUNDED'));

-- ---------------------------------------------------------------- 2) tags
create or replace function public.order_tag_status(p_tags text[])
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when exists (select 1 from unnest(coalesce(p_tags, '{}')) t where t ~* 'cancell?ed') then 'cancelled'
    when exists (select 1 from unnest(coalesce(p_tags, '{}')) t
                 where regexp_replace(lower(t), '[^a-z]', '', 'g') = 'notconfirmed') then 'not_confirmed'
  end
$$;

do $do$
declare
  d text := pg_get_viewdef('public.v_order_finance'::regclass, true);
  marker text := $x$WHEN b.cancelled_at IS NOT NULL OR b.shipment_status = 'cancelled'::shipment_status THEN 'cancelled'::text$x$;
begin
  if position('order_tag_status' in d) = 0 then
    if position(marker in d) = 0 then raise exception 'money_state case not found'; end if;
    d := replace(d, marker,
      $x$WHEN (b.shipment_id IS NULL OR b.shipment_status = ANY (ARRAY['booked'::shipment_status, 'unknown'::shipment_status, 'cancelled'::shipment_status]))
                         AND public.order_tag_status((SELECT o2.tags FROM orders o2 WHERE o2.id = b.order_id)) = 'cancelled' THEN 'cancelled'::text
                    WHEN (b.shipment_id IS NULL OR b.shipment_status = ANY (ARRAY['booked'::shipment_status, 'unknown'::shipment_status, 'cancelled'::shipment_status]))
                         AND public.order_tag_status((SELECT o2.tags FROM orders o2 WHERE o2.id = b.order_id)) = 'not_confirmed' THEN 'not_confirmed'::text
                    $x$ || marker);
    -- no COD expected and no packaging used for orders that never shipped
    d := replace(d, $x$ARRAY['cancelled'::text, 'returned'::text, 'returning'::text, 'lost'::text]$x$,
                    $x$ARRAY['cancelled'::text, 'not_confirmed'::text, 'returned'::text, 'returning'::text, 'lost'::text]$x$);
    d := replace(d, $x$shipment_id IS NOT NULL AND money_state <> 'cancelled'::text$x$,
                    $x$shipment_id IS NOT NULL AND (money_state <> ALL (ARRAY['cancelled'::text, 'not_confirmed'::text]))$x$);
    if position($x$'not_confirmed'::text, 'returned'::text$x$ in d) = 0
       or position($x$ARRAY['cancelled'::text, 'not_confirmed'::text]))$x$ in d) = 0 then
      raise exception 'v_order_finance patch incomplete';
    end if;
    execute 'create or replace view public.v_order_finance with (security_invoker = true) as ' || d;
  end if;
end
$do$;

-- Gross sales, in-progress counts and breakdowns leave out orders that never shipped
do $do$
declare
  f text;
  d text;
begin
  foreach f in array array['finance_daily(date,date)', 'finance_summary(date,date)', 'profit_breakdown(date,date,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('not_confirmed' in d) = 0 then
      d := replace(d, $x$money_state <> 'cancelled'$x$, $x$money_state not in ('cancelled', 'not_confirmed')$x$);
      d := replace(d, $x$money_state not in ('cancelled'))$x$, $x$money_state not in ('cancelled', 'not_confirmed'))$x$);
      if position('not_confirmed' in d) = 0 then raise exception '% patch did not apply', f; end if;
      execute d;
    end if;
  end loop;
end
$do$;
