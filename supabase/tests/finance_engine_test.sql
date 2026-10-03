-- =====================================================================
-- Finance engine regression test. Runs inside a transaction and rolls back.
-- Run: paste into the Supabase SQL editor (or `psql -f`). Raises an
-- exception on the first failed assertion; prints 'ALL FINANCE TESTS PASSED'.
--
-- Hand-calculated expectations (rate card 200 deliver / 100 return,
-- flyer 5 / parcel, polybag 10 / unit, default unit cost 850, tax 0%):
--  O1 COD 3000, cost 1000, delivered, settled 3000-250=2750, banked
--       contribution = 3000-1000-250-15            = 1735   state in_bank
--  O2 COD 2000, 2 units no cost (850 each), delivered, unsettled
--       contribution = 2000-1700-200(est)-25        =   75   state with_courier
--  O3 COD 1500, cost 600, returned
--       contribution = -(200+100 + 15 + 0% of 600)  = -315   state returned
--  O4 COD 1000, not shipped                                   state unfulfilled
--  O5 cancelled                                               state cancelled
--  O6 COD 2600, cost 900, delivered, settled COD 2500 (mismatch!) charges 200
--       contribution = 2600-900-200-15              = 1485   state settled_unbanked
--  O7 COD 1800, in transit, no movement 10 days               state in_transit (stuck)
--  Revenue 7600, contribution 2980, marketing 1000 → net 1980, delivery rate 75%
-- =====================================================================
begin;

-- Deterministic fixtures: the test's own rate cards and settings (rolled back at the end)
update public.courier_rate_cards set delivery_charge = 200, return_charge = 100, cod_fee_percent = 0, cod_tax_percent = 0;
update public.app_settings set value = '{"flyer_per_parcel": 5, "polybag_per_unit": 10}' where key = 'packaging';
update public.app_settings set value = '{"income_tax_percent": 0}' where key = 'tax';
update public.app_settings set value = '{"inventory_loss_percent": 0, "count_packaging_on_return": 1}' where key = 'returns';
delete from public.product_cost_rules where match_type <> 'default';
update public.product_cost_rules set unit_cost = 850, active = true where match_type = 'default';

-- Act as an admin user so RLS + role checks run for real
insert into auth.users (id, email, aud, role, instance_id)
values ('00000000-0000-0000-0000-0000000000a1', 'test-admin@example.com', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a1';

insert into public.orders (id, name, created_at_shop, updated_at_shop, cancelled_at, is_cod, current_total, total_price, city) values
  (9000001, '#T1', '2020-01-05 10:00+05', now(), null, true, 3000, 3000, 'Lahore'),
  (9000002, '#T2', '2020-01-05 11:00+05', now(), null, true, 2000, 2000, 'Karachi'),
  (9000003, '#T3', '2020-01-06 10:00+05', now(), null, true, 1500, 1500, 'Lahore'),
  (9000004, '#T4', '2020-01-06 12:00+05', now(), null, true, 1000, 1000, 'Multan'),
  (9000005, '#T5', '2020-01-07 10:00+05', now(), '2020-01-07 12:00+05', true, 1200, 1200, 'Multan'),
  (9000006, '#T6', '2020-01-07 15:00+05', now(), null, true, 2600, 2600, 'Karachi'),
  (9000007, '#T7', '2020-01-08 09:00+05', now(), null, true, 1800, 1800, 'Quetta');

insert into public.order_lines (id, order_id, title, quantity, current_quantity, unit_price, unit_cost) values
  (1, 9000001, 'Black Hoodie', 1, 1, 3000, 1000),
  (2, 9000002, 'Mystery Item', 2, 2, 1000, null),
  (3, 9000003, 'Black Hoodie', 1, 1, 1500, 600),
  (4, 9000004, 'Cap', 1, 1, 1000, 300),
  (5, 9000005, 'Cap', 1, 1, 1200, 300),
  (6, 9000006, 'Jacket', 1, 1, 2600, 900),
  (7, 9000007, 'Jacket', 1, 1, 1800, 900);

insert into public.shipments (order_id, tracking_number, courier, fulfilled_at, status, status_at, delivered_at, returned_at, is_final) values
  (9000001, '22000000000001', 'postex', '2020-01-05 18:00+05', 'delivered', '2020-01-07 12:00+05', '2020-01-07 12:00+05', null, true),
  (9000002, '22000000000002', 'postex', '2020-01-05 18:00+05', 'delivered', '2020-01-08 12:00+05', '2020-01-08 12:00+05', null, true),
  (9000003, '50300000003', 'blueex', '2020-01-06 18:00+05', 'returned', '2020-01-12 12:00+05', null, '2020-01-12 12:00+05', true),
  (9000006, '55900000006', 'mnp', '2020-01-07 18:00+05', 'delivered', '2020-01-09 12:00+05', '2020-01-09 12:00+05', null, true),
  (9000007, 'T00000007', 'tranzo', now() - interval '10 days', 'in_transit', now() - interval '10 days', null, null, false);

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","email":"test-admin@example.com"}';

-- Courier statements
select public.import_settlement('postex', 'postex-1.xlsx', 'sha-test-1', 'PX-1', '2020-01-12',
  '[{"tracking_number":"22000000000001","cod_amount":3000,"courier_charges":250}]'::jsonb);
select public.import_settlement('mnp', 'mnp-1.xlsx', 'sha-test-2', 'MNP-1', (current_date - 20),
  '[{"tracking_number":"55900000006","cod_amount":2500,"courier_charges":200}]'::jsonb);

-- Duplicate file must be rejected
do $$
begin
  perform public.import_settlement('postex', 'postex-1-copy.xlsx', 'sha-test-1', 'PX-1', '2020-01-12',
    '[{"tracking_number":"22000000000001","cod_amount":3000,"courier_charges":250}]'::jsonb);
  raise exception 'FAIL: duplicate settlement file was accepted';
exception when unique_violation then null;
end $$;

-- Bank account + statement with the PostEx deposit (2750) → auto-match
insert into public.bank_accounts (name, bank) values ('Test Meezan', 'Meezan');
select public.import_bank_statement(
  (select id from public.bank_accounts where name = 'Test Meezan'), 'stmt.csv', 'sha-bank-1',
  '[{"date":"2020-01-14","description":"IBFT POSTEX PVT LTD","credit":2750,"balance":10000},
    {"date":"2020-01-14","description":"Office rent","debit":500,"balance":9500}]'::jsonb);

-- Marketing expense in window
insert into public.expenses (expense_date, category_id, amount)
values ('2020-01-06', (select id from public.expense_categories where name = 'Facebook / Meta Ads'), 1000);

do $$
declare
  s jsonb := public.finance_summary('2020-01-01', '2020-01-10');
  pnl jsonb := s -> 'pnl';
  st text;
  c numeric;
  procedure_ok boolean;
begin
  -- money states
  select money_state into st from public.v_order_profit where order_id = 9000001;
  if st <> 'in_bank' then raise exception 'FAIL O1 state %, expected in_bank', st; end if;
  select money_state into st from public.v_order_profit where order_id = 9000002;
  if st <> 'with_courier' then raise exception 'FAIL O2 state %', st; end if;
  select money_state into st from public.v_order_profit where order_id = 9000003;
  if st <> 'returned' then raise exception 'FAIL O3 state %', st; end if;
  select money_state into st from public.v_order_profit where order_id = 9000004;
  if st <> 'unfulfilled' then raise exception 'FAIL O4 state %', st; end if;
  select money_state into st from public.v_order_profit where order_id = 9000005;
  if st <> 'cancelled' then raise exception 'FAIL O5 state %', st; end if;
  select money_state into st from public.v_order_profit where order_id = 9000006;
  if st <> 'settled_unbanked' then raise exception 'FAIL O6 state %', st; end if;
  select money_state into st from public.v_order_profit where order_id = 9000007;
  if st <> 'in_transit' then raise exception 'FAIL O7 state %', st; end if;

  -- per-order contribution
  select contribution into c from public.v_order_profit where order_id = 9000001;
  if c <> 1735 then raise exception 'FAIL O1 contribution %, expected 1735', c; end if;
  select contribution into c from public.v_order_profit where order_id = 9000002;
  if c <> 75 then raise exception 'FAIL O2 contribution %, expected 75', c; end if;
  select contribution into c from public.v_order_profit where order_id = 9000003;
  if c <> -315 then raise exception 'FAIL O3 contribution %, expected -315', c; end if;
  select contribution into c from public.v_order_profit where order_id = 9000006;
  if c <> 1485 then raise exception 'FAIL O6 contribution %, expected 1485', c; end if;
  select contribution into c from public.v_order_profit where order_id = 9000007;
  if c is not null then raise exception 'FAIL O7 contribution should be null (not final), got %', c; end if;

  -- summary
  if (pnl ->> 'revenue')::numeric <> 7600 then raise exception 'FAIL revenue %', pnl ->> 'revenue'; end if;
  if (pnl ->> 'contribution')::numeric <> 2980 then raise exception 'FAIL contribution %', pnl ->> 'contribution'; end if;
  if (pnl ->> 'marketing')::numeric <> 1000 then raise exception 'FAIL marketing %', pnl ->> 'marketing'; end if;
  if (pnl ->> 'net_profit')::numeric <> 1980 then raise exception 'FAIL net_profit %', pnl ->> 'net_profit'; end if;
  if (pnl ->> 'delivery_rate')::numeric <> 75 then raise exception 'FAIL delivery_rate %', pnl ->> 'delivery_rate'; end if;
  if (pnl ->> 'return_loss')::numeric <> 315 then raise exception 'FAIL return_loss %', pnl ->> 'return_loss'; end if;
  if (s -> 'money_states' -> 'with_courier' ->> 'amount')::numeric <> 2000 then
    raise exception 'FAIL with_courier amount %', s -> 'money_states' -> 'with_courier';
  end if;

  -- reconciliation
  if not exists (select 1 from public.settlement_bank_matches m join public.settlement_batches b on b.id = m.batch_id
                 where b.statement_ref = 'PX-1' and m.method = 'auto' and m.amount = 2750) then
    raise exception 'FAIL PostEx batch was not auto-matched to the 2750 bank credit';
  end if;
  if exists (select 1 from public.settlement_bank_matches m join public.settlement_batches b on b.id = m.batch_id
             where b.statement_ref = 'MNP-1') then
    raise exception 'FAIL M&P batch should not be matched';
  end if;

  -- alerts
  if not exists (select 1 from public.alerts where kind = 'settlement_overdue' and entity_id = '9000002' and status = 'open') then
    raise exception 'FAIL missing settlement_overdue alert for O2'; end if;
  if not exists (select 1 from public.alerts where kind = 'cod_mismatch' and entity_id = '9000006' and amount = -100) then
    raise exception 'FAIL missing cod_mismatch alert for O6'; end if;
  if not exists (select 1 from public.alerts where kind = 'bank_deposit_missing' and status = 'open') then
    raise exception 'FAIL missing bank_deposit_missing alert'; end if;
  if not exists (select 1 from public.alerts where kind = 'stuck_shipment' and entity_id = '9000007') then
    raise exception 'FAIL missing stuck_shipment alert for O7'; end if;
  if exists (select 1 from public.alerts where entity_id = '9000001' and status = 'open') then
    raise exception 'FAIL O1 is fully reconciled but has an open alert'; end if;

  -- timeline has order → shipment → settlement → bank
  if (select count(distinct kind) from public.order_timeline(9000001) where kind in ('order','shipment','settlement','bank')) <> 4 then
    raise exception 'FAIL O1 timeline incomplete';
  end if;

  raise notice 'ALL FINANCE TESTS PASSED';
end $$;

-- A viewer must not be able to import (demote as the server, then act as the user again)
reset role;
set local request.jwt.claims = '{}';
update public.profiles set role = 'viewer' where id = '00000000-0000-0000-0000-0000000000a1';
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
do $$
begin
  perform public.import_settlement('postex', 'x.xlsx', 'sha-viewer', null, null, '[{"tracking_number":"1","cod_amount":1}]'::jsonb);
  raise exception 'FAIL viewer could import a settlement';
exception when insufficient_privilege then null;
end $$;

-- COD withholding tax: 4% on PostEx → O2 (with courier, rate-card estimate) costs 200 + 4% of 2000 = 280
reset role;
update public.courier_rate_cards set cod_tax_percent = 4 where courier = 'postex';
do $$
declare c numeric; t numeric;
begin
  select courier_cost, cod_withholding_tax into c, t from public.v_order_finance where order_id = 9000002;
  if c <> 280 or t <> 80 then raise exception 'FAIL COD tax: cost %, tax % (expected 280 / 80)', c, t; end if;
end $$;

select 'ALL FINANCE TESTS PASSED' as result;
rollback;
