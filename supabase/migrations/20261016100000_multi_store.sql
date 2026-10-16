-- =====================================================================
-- Multiple stores (profiles). Every business row belongs to a store.
--
-- How a request knows its store:
--   * the app sends header  x-store-id: <uuid>  on every API / function call
--   * pg_cron jobs set      app.store_id         per store (for_each_store)
-- public.current_store_id() resolves it (NULL when unknown → nothing visible).
--
-- Isolation:
--   * a RESTRICTIVE RLS policy on every table: store_id = current_store_id()
--   * the finance views filter on current_store_id() themselves, so SECURITY
--     DEFINER functions that read them are scoped too
--   * definer functions that touch tables directly filter explicitly
-- Existing data moves into the first store ("HavenWear").
-- =====================================================================

create table public.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);
alter table public.stores enable row level security;
create policy "viewer can read" on public.stores for select to authenticated using ((select public.has_role('viewer')));
grant select on public.stores to authenticated;

insert into public.stores (id, name) values ('b1a5e000-0000-4000-8000-000000000001', 'HavenWear');

create or replace function public.current_store_id()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  raw text;
  v uuid;
begin
  raw := nullif(coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'x-store-id',
    current_setting('app.store_id', true)), '');
  if raw is null then
    return null;
  end if;
  begin
    v := raw::uuid;
  exception when others then
    return null;
  end;
  if not exists (select 1 from public.stores where id = v) then
    return null;
  end if;
  return v;
end;
$$;
revoke execute on function public.current_store_id() from public, anon;
grant execute on function public.current_store_id() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- store_id on every business table (existing rows → HavenWear)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'app_settings','integrations','orders','order_lines','product_cost_rules','shipments','shipment_events',
    'courier_rate_cards','settlement_batches','settlement_lines','bank_accounts','bank_imports','bank_transactions',
    'settlement_bank_matches','expense_categories','expenses','recurring_expenses','recurring_expense_skips',
    'sync_runs','sync_state','alerts'
  ] loop
    execute format('alter table public.%I add column store_id uuid references public.stores (id) on delete cascade', t);
    execute format('update public.%I set store_id = %L where store_id is null', t, 'b1a5e000-0000-4000-8000-000000000001');
    execute format('alter table public.%I alter column store_id set not null', t);
    execute format('alter table public.%I alter column store_id set default public.current_store_id()', t);
    execute format('create index %I on public.%I (store_id)', t || '_store_idx', t);
    execute format('create policy "same store only" on public.%I as restrictive for all to authenticated using (store_id = (select public.current_store_id())) with check (store_id = (select public.current_store_id()))', t);
  end loop;
end $$;

-- audit_log: store is optional (role changes etc. are global)
alter table public.audit_log add column store_id uuid references public.stores (id) on delete cascade default public.current_store_id();
create policy "same store only" on public.audit_log as restrictive for all to authenticated
  using (store_id is null or store_id = (select public.current_store_id()));

-- ---------------------------------------------------------------------
-- Uniqueness is per store
-- ---------------------------------------------------------------------
alter table public.app_settings drop constraint app_settings_pkey, add primary key (store_id, key);
alter table public.integrations drop constraint integrations_pkey, add primary key (store_id, provider);
alter table public.sync_state drop constraint sync_state_pkey, add primary key (store_id, key);
alter table public.shipments drop constraint shipments_tracking_number_key, add constraint shipments_store_tracking_key unique (store_id, tracking_number);
alter table public.settlement_batches drop constraint settlement_batches_file_sha256_key, add constraint settlement_batches_store_sha_key unique (store_id, file_sha256);
alter table public.expense_categories drop constraint expense_categories_name_key, add constraint expense_categories_store_name_key unique (store_id, name);
alter table public.courier_rate_cards drop constraint courier_rate_cards_courier_effective_from_key, add constraint courier_rate_cards_store_courier_from_key unique (store_id, courier, effective_from);
drop index public.expenses_external_uniq;
create unique index expenses_external_uniq on public.expenses (store_id, source, external_key) where external_key is not null;
drop index public.alerts_open_uniq;
create unique index alerts_open_uniq on public.alerts (store_id, kind, entity_type, entity_id) where status = 'open';

-- ---------------------------------------------------------------------
-- Settings / rates helpers read the current store
-- ---------------------------------------------------------------------
create or replace function public.setting_num(p_key text, p_field text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (value ->> p_field)::numeric from public.app_settings
                   where key = p_key and store_id = public.current_store_id()), p_default);
$$;

create or replace function public.courier_cod_tax_percent(p_courier text, p_on date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select r.cod_tax_percent from public.courier_rate_cards r
    where r.courier = p_courier and r.effective_from <= coalesce(p_on, current_date)
      and r.store_id = public.current_store_id()
    order by r.effective_from desc limit 1), 0);
$$;

-- ---------------------------------------------------------------------
-- Views: scoped to the current store at the base tables
-- ---------------------------------------------------------------------
drop view public.v_order_profit;
drop view public.v_order_finance;
drop view public.v_tracking_settlement;
drop view public.v_batch_bank_status;
drop view public.v_order_shipment;
drop view public.v_line_costs;

create view public.v_line_costs with (security_invoker = true) as
select l.id, l.order_id, o.order_date, l.title, l.variant_title, l.sku, l.product_id, l.variant_id,
  l.quantity, l.current_quantity, l.unit_price,
  coalesce(l.unit_cost, r.unit_cost, 0)::numeric(14,2) as unit_cost,
  case when l.unit_cost is not null then 'shopify' when r.id is not null then 'rule:' || r.name else 'none' end as cost_source,
  (l.current_quantity * coalesce(l.unit_cost, r.unit_cost, 0))::numeric(14,2) as line_cogs,
  l.store_id
from public.order_lines l
join public.orders o on o.id = l.order_id
left join lateral (
  select pr.id, pr.name, pr.unit_cost
  from public.product_cost_rules pr
  where pr.store_id = l.store_id and pr.active and pr.effective_from <= o.order_date
    and ((pr.match_type = 'variant' and pr.match_value = l.variant_id::text)
      or (pr.match_type = 'sku' and l.sku is not null and lower(trim(pr.match_value)) = lower(trim(l.sku)))
      or (pr.match_type = 'keyword' and exists (
            select 1 from unnest(string_to_array(coalesce(pr.match_value, ''), ',')) kw
            where length(trim(kw)) > 0 and l.title ilike '%' || trim(kw) || '%'))
      or pr.match_type = 'default')
  order by case pr.match_type when 'variant' then 0 when 'sku' then 1 when 'keyword' then 2 else 3 end,
           pr.priority, pr.effective_from desc
  limit 1
) r on l.unit_cost is null
where l.store_id = public.current_store_id();

create view public.v_batch_bank_status with (security_invoker = true) as
select b.id as batch_id, b.courier, b.statement_date, b.total_net,
  coalesce(sum(m.amount), 0)::numeric(14,2) as matched_amount,
  (coalesce(sum(m.amount), 0) >= b.total_net - public.setting_num('reconciliation', 'bank_match_tolerance', 1)) as is_banked,
  max(bt.txn_date) as banked_on,
  b.store_id
from public.settlement_batches b
left join public.settlement_bank_matches m on m.batch_id = b.id
left join public.bank_transactions bt on bt.id = m.bank_transaction_id
where b.voided_at is null and b.store_id = public.current_store_id()
group by b.id;

create view public.v_tracking_settlement with (security_invoker = true) as
select sl.tracking_number,
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

create view public.v_order_shipment with (security_invoker = true) as
select distinct on (s.order_id)
  s.order_id, s.id as shipment_id, s.tracking_number, s.courier, s.fulfilled_at,
  coalesce(s.manual_status, s.status) as status, s.status_raw, s.status_at, s.delivered_at, s.returned_at,
  s.is_final, s.manual_status is not null as is_manual, s.last_checked_at, s.check_error, s.courier_financials
from public.shipments s
where s.store_id = public.current_store_id()
order by s.order_id, s.fulfilled_at desc nulls last, s.id desc;

create view public.v_order_finance with (security_invoker = true) as
with lines as (
  select order_id, sum(current_quantity)::int as units, sum(line_cogs)::numeric(14,2) as cogs,
         bool_or(cost_source = 'none') as missing_cost
  from public.v_line_costs group by order_id
),
base as (
  select
    o.id as order_id, o.name, o.order_date, o.created_at_shop, o.customer_name, o.phone, o.city,
    o.is_cod, o.cancelled_at, o.financial_status, o.current_total, o.total_tax, o.shipping_charged, o.total_discounts,
    coalesce(l.units, 0) as units, coalesce(l.cogs, 0) as cogs, coalesce(l.missing_cost, false) as missing_cost,
    sh.shipment_id, sh.tracking_number,
    coalesce(sh.courier, case when sh.shipment_id is null then null else 'unknown' end) as courier,
    sh.status as shipment_status, sh.status_raw, sh.status_at, sh.fulfilled_at, sh.delivered_at, sh.returned_at,
    sh.is_manual, sh.check_error, sh.courier_financials as api_fin,
    ts.settled_cod, ts.settled_net, ts.actual_charges, ts.delivered_batch_count, ts.has_return_line,
    ts.all_banked, ts.last_statement_date, ts.banked_on,
    rc.delivery_charge, rc.return_charge, rc.cod_fee_percent, coalesce(rc.cod_tax_percent, 0) as cod_tax_percent,
    o.store_id
  from public.orders o
  left join lines l on l.order_id = o.id
  left join public.v_order_shipment sh on sh.order_id = o.id
  left join public.v_tracking_settlement ts on ts.tracking_number = sh.tracking_number
  left join lateral (
    select r.delivery_charge, r.return_charge, r.cod_fee_percent, r.cod_tax_percent
    from public.courier_rate_cards r
    where r.store_id = o.store_id and r.courier = coalesce(sh.courier, 'unknown') and r.effective_from <= o.order_date
    order by r.effective_from desc limit 1
  ) rc on true
  where o.store_id = public.current_store_id()
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
  select st.*,
    case when st.money_state in ('with_courier', 'settled_unbanked', 'in_bank')
         then coalesce(st.settled_cod, (st.api_fin ->> 'invoicePayment')::numeric, st.current_total) else 0 end as cod_collected,
    case
      when st.money_state in ('with_courier', 'settled_unbanked', 'in_bank')
           or (st.money_state = 'prepaid' and st.shipment_id is not null)
        then nullif(coalesce((st.api_fin ->> 'transactionFee')::numeric, 0) + coalesce((st.api_fin ->> 'transactionTax')::numeric, 0), 0)
      when st.money_state in ('returned', 'returning', 'lost')
        then nullif(coalesce((st.api_fin ->> 'reversalFee')::numeric, 0) + coalesce((st.api_fin ->> 'reversalTax')::numeric, 0), 0)
    end as api_charges
  from staged st
),
taxed as (
  select p.*, round(p.cod_collected * p.cod_tax_percent / 100, 2) as cod_tax from priced p
)
select
  s.order_id, s.name, s.order_date, s.created_at_shop, s.customer_name, s.phone, s.city,
  s.is_cod, s.cancelled_at, s.financial_status,
  s.current_total, s.total_tax, s.shipping_charged, s.total_discounts,
  s.units, s.cogs, s.missing_cost,
  s.shipment_id, s.tracking_number, s.courier, s.shipment_status, s.status_raw, s.status_at,
  s.fulfilled_at, s.delivered_at, s.returned_at, s.is_manual, s.check_error,
  s.money_state,
  (case when s.is_cod and s.money_state not in ('cancelled', 'returned', 'returning', 'lost') then s.current_total else 0 end)::numeric(14,2) as expected_cod,
  coalesce(s.settled_cod, 0)::numeric(14,2) as settled_cod,
  coalesce(s.settled_net, 0)::numeric(14,2) as settled_net,
  s.last_statement_date, s.banked_on,
  coalesce(s.delivered_batch_count, 0) as settlement_count,
  (case when s.actual_charges is not null then 'actual' when s.api_charges is not null then 'courier_api' else 'estimate' end) as courier_cost_source,
  (case
     when s.actual_charges is not null then s.actual_charges
     when s.api_charges is not null then s.api_charges + s.cod_tax
     when s.money_state in ('with_courier', 'settled_unbanked', 'in_bank')
       then coalesce(s.delivery_charge, 0) + round(s.current_total * coalesce(s.cod_fee_percent, 0) / 100, 2) + s.cod_tax
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
   or (s.money_state = 'prepaid' and s.shipment_status = 'delivered')) as is_final,
  s.cod_tax::numeric(14,2) as cod_withholding_tax,
  s.store_id
from taxed s;

create view public.v_order_profit with (security_invoker = true) as
select
  f.*,
  (case when f.is_delivered then f.current_total - f.total_tax else 0 end)::numeric(14,2) as revenue,
  (case when f.is_delivered then f.cogs
        when f.is_returned or f.money_state = 'lost'
          then round(f.cogs * (case when f.money_state = 'lost' then 100 else public.setting_num('returns', 'inventory_loss_percent', 0) end) / 100, 2)
        else 0 end)::numeric(14,2) as cogs_recognised,
  (case
     when f.is_delivered then (f.current_total - f.total_tax) - f.cogs - f.courier_cost - f.packaging_cost
     when f.is_returned or f.money_state = 'lost'
       then -(f.courier_cost
              + (case when public.setting_num('returns', 'count_packaging_on_return', 1) = 1 then f.packaging_cost else 0 end)
              + round(f.cogs * (case when f.money_state = 'lost' then 100 else public.setting_num('returns', 'inventory_loss_percent', 0) end) / 100, 2))
     else null
   end)::numeric(14,2) as contribution
from public.v_order_finance f;

grant select on public.v_line_costs, public.v_batch_bank_status, public.v_tracking_settlement,
  public.v_order_shipment, public.v_order_finance, public.v_order_profit to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Definer functions that touch tables directly: add store filters
-- (text patches; each pattern must exist or the migration fails)
-- ---------------------------------------------------------------------
create or replace function pg_temp.patch(p_fn text, p_pairs text[])
returns void
language plpgsql
as $$
declare
  d text := pg_get_functiondef(p_fn::regprocedure);
  i int;
begin
  for i in 1 .. array_length(p_pairs, 1) by 2 loop
    if position(p_pairs[i] in d) = 0 then
      raise exception 'patch %: pattern not found: %', p_fn, p_pairs[i];
    end if;
    d := replace(d, p_pairs[i], p_pairs[i + 1]);
  end loop;
  execute d;
end;
$$;

select pg_temp.patch('public.import_settlement(text,text,text,text,date,jsonb,text)', array[
  'where file_sha256 = p_file_sha256;', 'where file_sha256 = p_file_sha256 and store_id = public.current_store_id();',
  'where s.tracking_number = sl.tracking_number);', 'where s.tracking_number = sl.tracking_number and s.store_id = sl.store_id);'
]);

select pg_temp.patch('public.void_settlement_batch(bigint,text)', array[
  'where id = p_batch_id and voided_at is null;', 'where id = p_batch_id and voided_at is null and store_id = public.current_store_id();',
  'delete from public.settlement_bank_matches where batch_id = p_batch_id;',
  'delete from public.settlement_bank_matches where batch_id = p_batch_id and store_id = public.current_store_id();'
]);

select pg_temp.patch('public.import_bank_statement(bigint,text,text,jsonb)', array[
  'select 1 from public.bank_accounts where id = p_account_id)', 'select 1 from public.bank_accounts where id = p_account_id and store_id = public.current_store_id())'
]);

select pg_temp.patch('public.auto_match_settlements()', array[
  'where t.credit > 0 and', 'where t.store_id = public.current_store_id() and t.credit > 0 and',
  'where t.category is null and exists', 'where t.store_id = public.current_store_id() and t.category is null and exists'
]);

select pg_temp.patch('public.set_shipment_status(bigint,public.shipment_status,text)', array[
  'where id = p_shipment_id;', 'where id = p_shipment_id and store_id = public.current_store_id();'
]);

select pg_temp.patch('public.refresh_alerts()', array[
  'join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
  where not exists (select 1 from public.shipments s where s.tracking_number = sl.tracking_number);',
  'join public.settlement_batches b on b.id = sl.batch_id and b.voided_at is null
  where b.store_id = public.current_store_id()
    and not exists (select 1 from public.shipments s where s.tracking_number = sl.tracking_number and s.store_id = b.store_id);',
  'where r.courier = p.courier and r.effective_from <= p.order_date',
  'where r.store_id = p.store_id and r.courier = p.courier and r.effective_from <= p.order_date',
  'where a.kind = n.kind and a.entity_type = n.entity_type and a.entity_id = n.entity_id and a.status = ''ignored'')',
  'where a.store_id = public.current_store_id() and a.kind = n.kind and a.entity_type = n.entity_type and a.entity_id = n.entity_id and a.status = ''ignored'')',
  'on conflict (kind, entity_type, entity_id) where status = ''open''',
  'on conflict (store_id, kind, entity_type, entity_id) where status = ''open''',
  'where a.status = ''open'' and a.last_seen_at < run_start;',
  'where a.store_id = public.current_store_id() and a.status = ''open'' and a.last_seen_at < run_start;',
  '''open'', (select count(*) from public.alerts where status = ''open''),',
  '''open'', (select count(*) from public.alerts where status = ''open'' and store_id = public.current_store_id()),'
]);

select pg_temp.patch('public.build_api_settlements()', array[
  'where s.courier = ''postex''', 'where s.store_id = public.current_store_id() and s.courier = ''postex''',
  'where sl.tracking_number = s.tracking_number and b.voided_at is null and b.source = ''file'');',
  'where sl.tracking_number = s.tracking_number and b.store_id = s.store_id and b.voided_at is null and b.source = ''file'');',
  'on conflict (file_sha256) do nothing;', 'on conflict (store_id, file_sha256) do nothing;',
  'join public.settlement_batches b on b.file_sha256 = ''api:postex:'' || a.cpr and b.voided_at is null',
  'join public.settlement_batches b on b.file_sha256 = ''api:postex:'' || a.cpr and b.store_id = public.current_store_id() and b.voided_at is null',
  'where t.batch_id = b.id and b.source = ''api'';', 'where t.batch_id = b.id and b.source = ''api'' and b.store_id = public.current_store_id();'
]);

select pg_temp.patch('public.apply_courier_payments(jsonb)', array[
  'where s.id = r.id;', 'where s.id = r.id and s.store_id = public.current_store_id();'
]);

select pg_temp.patch('public.apply_tracking_updates(jsonb,jsonb)', array[
  'where s.id = u.id;', 'where s.id = u.id and s.store_id = public.current_store_id();'
]);

select pg_temp.patch('public.apply_ad_spend(jsonb)', array[
  'join public.expense_categories c on c.name = m.category', 'join public.expense_categories c on c.name = m.category and c.store_id = public.current_store_id()',
  'on conflict (source, external_key) where external_key is not null', 'on conflict (store_id, source, external_key) where external_key is not null',
  'where e.source = ''triplewhale''', 'where e.store_id = public.current_store_id() and e.source = ''triplewhale'''
]);

-- recurring: runs for every store from cron, or the current store from the app
select pg_temp.patch('public.generate_recurring_expenses()', array[
  'period_start, period_end, recurring_id, created_by)', 'period_start, period_end, recurring_id, created_by, store_id)',
  'r.id, r.created_by', 'r.id, r.created_by, r.store_id',
  'where r.active', 'where r.active and (public.current_store_id() is null or r.store_id = public.current_store_id())'
]);

-- integrations: secrets per store
select pg_temp.patch('public.integration_get_secret(text)', array[
  'where provider = p_provider;', 'where provider = p_provider and store_id = public.current_store_id();'
]);
select pg_temp.patch('public.integration_save(text,jsonb,jsonb,jsonb,uuid,text,text)', array[
  'where provider = p_provider for update;', 'where provider = p_provider and store_id = public.current_store_id() for update;',
  '''integration:'' || p_provider', '''integration:'' || public.current_store_id() || '':'' || p_provider',
  'where provider = p_provider;', 'where provider = p_provider and store_id = public.current_store_id();'
]);
select pg_temp.patch('public.integration_disconnect(text,uuid)', array[
  'where provider = p_provider for update;', 'where provider = p_provider and store_id = public.current_store_id() for update;',
  'where provider = p_provider;', 'where provider = p_provider and store_id = public.current_store_id();'
]);

-- ---------------------------------------------------------------------
-- Cron: run per store
-- ---------------------------------------------------------------------
create or replace function public.cron_call(p_function text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  s record;
  n bigint := 0;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'hk_project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'hk_cron_secret';
  if v_url is null or v_secret is null then
    raise warning 'cron_call: hk_project_url / hk_cron_secret not set in Vault';
    return null;
  end if;
  for s in select id from public.stores loop
    perform net.http_post(
      url := rtrim(v_url, '/') || '/functions/v1/' || p_function,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret, 'x-store-id', s.id::text),
      body := jsonb_build_object('store_id', s.id),
      timeout_milliseconds := 150000);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.cron_call(text) from public, anon, authenticated;

create or replace function public.reconcile_all_stores()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare s record;
begin
  for s in select id from public.stores loop
    perform set_config('app.store_id', s.id::text, true);
    perform public.auto_match_settlements();
    perform public.refresh_alerts();
  end loop;
  perform set_config('app.store_id', '', true);
end;
$$;
revoke execute on function public.reconcile_all_stores() from public, anon, authenticated;

select cron.unschedule('hk-reconcile');
select cron.schedule('hk-reconcile', '40 */2 * * *', $$select public.reconcile_all_stores()$$);

-- ---------------------------------------------------------------------
-- Create a store (admin): seeds settings, categories, rates, integrations
-- ---------------------------------------------------------------------
create or replace function public.create_store(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v uuid;
  tmpl uuid := 'b1a5e000-0000-4000-8000-000000000001';
begin
  if not public.has_role('admin') then
    raise exception 'Only admins can add stores' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Store name is required';
  end if;
  insert into public.stores (name) values (trim(p_name)) returning id into v;

  insert into public.app_settings (store_id, key, value, description)
  select v, key, value, description from public.app_settings where store_id = tmpl;

  insert into public.integrations (store_id, provider, display_name, kind, config)
  select v, provider, display_name, kind,
         case when provider = 'shopify' then jsonb_build_object('api_version', coalesce(config ->> 'api_version', '2026-07')) else '{}'::jsonb end
  from public.integrations where store_id = tmpl;

  insert into public.expense_categories (store_id, name, kind)
  select v, name, kind from public.expense_categories where store_id = tmpl;

  insert into public.courier_rate_cards (store_id, courier, delivery_charge, return_charge, cod_fee_percent, cod_tax_percent, effective_from)
  select v, courier, delivery_charge, return_charge, cod_fee_percent, cod_tax_percent, '2000-01-01'
  from public.courier_rate_cards r where store_id = tmpl and effective_from = '2000-01-01';

  insert into public.product_cost_rules (store_id, name, match_type, match_value, unit_cost, priority)
  values (v, 'Default', 'default', null, 0, 1000);
  return v;
end;
$$;
revoke execute on function public.create_store(text) from public, anon;
grant execute on function public.create_store(text) to authenticated;

create or replace function public.rename_store(p_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_role('admin') then
    raise exception 'Only admins can rename stores' using errcode = '42501';
  end if;
  update public.stores set name = trim(p_name) where id = p_id;
end;
$$;
revoke execute on function public.rename_store(uuid, text) from public, anon;
grant execute on function public.rename_store(uuid, text) to authenticated;
