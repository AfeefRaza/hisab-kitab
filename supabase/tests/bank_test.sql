-- =====================================================================
-- Bank reconciliation: description parsing, own-account transfers, fee pairing,
-- saved rules applied to past transactions. Synthetic data; everything is rolled back.
-- Run against a project that has the migrations applied (store id = the first store).
-- =====================================================================
begin;
select set_config('request.headers', '{"x-store-id": "b1a5e000-0000-4000-8000-000000000001"}', true);
insert into auth.users (id, email, aud, role, instance_id)
values ('00000000-0000-0000-0000-0000000000a1', 'test-admin@example.com', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a1';
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';

do $$
declare p record; acc bigint; t bigint; r jsonb; st text;
begin
  select * into p from public.bank_parse_description('Money Transferred To ACME TRADERS PAKISTAN A C 1902-XXXX6021 STAN (997898)');
  if p.counterparty <> 'ACME TRADERS PAKISTAN' or p.counterparty_account <> '1902-XXXX6021' or p.stan <> '997898' then
    raise exception 'FAIL bank parse: %', row_to_json(p); end if;
  select * into p from public.bank_parse_description('Raast P2P Fund transfer to TEST SUPPLIER PK23BAHLxxx5601 AMEZNPKKA0117');
  if p.counterparty <> 'TEST SUPPLIER' or p.counterparty_account <> 'PK23BAHLXXX5601' or p.channel <> 'raast' then
    raise exception 'FAIL raast parse: %', row_to_json(p); end if;

  insert into public.bank_accounts (name, bank) values ('Rule Test', 'Meezan Bank') returning id into acc;
  perform public.import_bank_statement(acc, 's.pdf', 'sha-rule-test',
    '[{"date":"2020-02-01","description":"Charges Taxes Plus FED - STAN(1111)","debit":5,"balance":995},
      {"date":"2020-02-01","description":"Money Transferred to TEST OWNER-XXXX3504 STAN(1111)","debit":5000,"balance":-4005},
      {"date":"2020-02-02","description":"Money Transferred To ACME TRADERS A C 1902-XXXX6021 STAN (2222)","debit":12000,"balance":-16005},
      {"date":"2020-02-09","description":"Money Transferred To ACME TRADERS A C 1902-XXXX6021 STAN (3333)","debit":8000,"balance":-24005}]'::jsonb,
    '{"account_title":"TEST OWNER"}'::jsonb);

  -- transfers to the account holder's own name are own-account transfers
  select category into st from public.bank_transactions where account_id = acc and description like 'Money Transferred to TEST OWNER%';
  if st is distinct from 'owner_transfer' then raise exception 'FAIL own-account transfer categorised as %', st; end if;
  -- the FED charge belongs to the transfer with the same STAN
  if (select fee_for_id from public.bank_transactions where account_id = acc and description like 'Charges%') is null then
    raise exception 'FAIL fee not paired with its transfer'; end if;
  -- "always for this account" categorises the other payment to the same account
  select id into t from public.bank_transactions where account_id = acc and stan = '2222';
  r := public.set_bank_category(t, 'supplier', 'account');
  if (r ->> 'applied_to')::int <> 1 or (select category from public.bank_transactions where account_id = acc and stan = '3333') <> 'supplier' then
    raise exception 'FAIL account rule did not categorise the other payment: %', r; end if;
end $$;

select 'BANK TESTS PASSED' as result;
rollback;
