-- =====================================================================
-- Bank reconciliation & analysis
--   * every bank transaction gets a counterparty, account, channel and STAN reference,
--     parsed from the bank's description (Meezan formats; works for most PK banks)
--   * categories: saved rules (by account / name / text) > automatic patterns;
--     a manual category is never overwritten
--   * bank fees are paired with the transfer they belong to (same STAN)
--   * matching: courier payouts ↔ CPRs (incl. one deposit paying several CPRs),
--     customer bank transfers ↔ paid Shopify orders, bank debits ↔ recorded expenses
--   * bank_reconciliation(): expected vs actual vs difference per area, with the
--     unmatched items, an explanation and the action needed
-- =====================================================================

-- ---------------------------------------------------------------- schema
alter table public.bank_accounts add column if not exists holder_name text;

create table if not exists public.bank_rules (
  id bigint generated always as identity primary key,
  store_id uuid not null default public.current_store_id() references public.stores (id) on delete cascade,
  match_field text not null check (match_field in ('account', 'name', 'text')),
  pattern text not null check (length(trim(pattern)) >= 3),
  category text not null,
  label text,
  learned boolean not null default false,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists bank_rules_uniq on public.bank_rules (store_id, match_field, upper(pattern));
alter table public.bank_rules enable row level security;
create policy "same store only" on public.bank_rules as restrictive for all
  using (store_id = (select public.current_store_id())) with check (store_id = (select public.current_store_id()));
create policy "viewer can read" on public.bank_rules for select using ((select public.has_role('viewer')));
create policy "finance can insert" on public.bank_rules for insert with check ((select public.has_role('finance')));
create policy "finance can update" on public.bank_rules for update using ((select public.has_role('finance'))) with check ((select public.has_role('finance')));
create policy "finance can delete" on public.bank_rules for delete using ((select public.has_role('finance')));
create trigger audit_bank_rules after insert or update or delete on public.bank_rules for each row execute function public.audit_trigger();

alter table public.bank_transactions
  add column if not exists counterparty text,
  add column if not exists counterparty_account text,
  add column if not exists channel text,
  add column if not exists stan text,
  add column if not exists category_source text check (category_source in ('auto', 'rule', 'manual', 'match')),
  add column if not exists rule_id bigint references public.bank_rules (id) on delete set null,
  add column if not exists fee_for_id bigint references public.bank_transactions (id) on delete set null;
create index if not exists bank_transactions_account_date_idx on public.bank_transactions (store_id, txn_date);
create index if not exists bank_transactions_cp_account_idx on public.bank_transactions (store_id, upper(counterparty_account));

create table if not exists public.bank_order_matches (
  id bigint generated always as identity primary key,
  store_id uuid not null default public.current_store_id() references public.stores (id) on delete cascade,
  bank_transaction_id bigint not null references public.bank_transactions (id) on delete cascade,
  order_id bigint not null references public.orders (id) on delete cascade,
  amount numeric(14,2) not null,
  method text not null default 'manual' check (method in ('auto', 'manual')),
  matched_by uuid references auth.users (id) on delete set null,
  matched_at timestamptz not null default now(),
  unique (bank_transaction_id, order_id)
);
create index if not exists bank_order_matches_order_idx on public.bank_order_matches (order_id);
alter table public.bank_order_matches enable row level security;
create policy "same store only" on public.bank_order_matches as restrictive for all
  using (store_id = (select public.current_store_id())) with check (store_id = (select public.current_store_id()));
create policy "viewer can read" on public.bank_order_matches for select using ((select public.has_role('viewer')));
create policy "finance can insert" on public.bank_order_matches for insert with check ((select public.has_role('finance')));
create policy "finance can delete" on public.bank_order_matches for delete using ((select public.has_role('finance')));

-- Which bank category each expense category is paid as
alter table public.expense_categories add column if not exists bank_category text;
insert into public.expense_categories (store_id, name, kind)
select s.id, x.name, x.kind
from public.stores s
cross join (values ('DTF Printing', 'inventory'), ('Supplier Payments', 'inventory')) as x(name, kind)
where not exists (select 1 from public.expense_categories c where c.store_id = s.id and c.name = x.name);
update public.expense_categories set bank_category = case
  when name ~* 'meta|facebook' then 'meta_ads'
  when kind = 'marketing' then 'other_ads'
  when name ~* 'dtf' then 'dtf_printing'
  when name ~* 'supplier' then 'supplier'
  when kind = 'inventory' then 'inventory'
  when kind = 'payroll' or name ~* 'salar' then 'salaries'
  when name ~* 'software|app' then 'shopify_apps'
  when name ~* 'bank charge' then 'bank_charges'
  when kind = 'tax' then 'taxes'
  else 'operational' end
where bank_category is null;

-- ---------------------------------------------------------------- parsing
-- Counterparty, its (masked) account, channel and STAN from a bank description
create or replace function public.bank_parse_description(p text)
returns table (counterparty text, counterparty_account text, channel text, stan text)
language plpgsql
immutable
set search_path to ''
as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\s+', ' ', 'g');
  m text[];
begin
  stan := (regexp_match(d, 'STAN\s*\(?\s*(\d{4,})', 'i'))[1];
  channel := case
    when d ~* '^(charges|taxes)|charges taxes|\mFED\M' and d !~* 'transfer|received' then 'fee'
    when d ~* 'annual fee|card fee|sms (alert )?charges|cheque book|excise' then 'fee'
    when d ~* 'raast' then 'raast'
    when d ~* 'money received|received from|inward|ibft.*from|credit transfer from' then 'transfer_in'
    when d ~* 'money transferred|fund transfer|transferred to|ibft|outward' then 'transfer_out'
    when d ~* 'atm|cash withdrawal' then 'cash'
    when d ~* '\mpos\M|purchase|visa|mastercard|paypak|online payment' then 'card'
    when d ~* 'cheque|chq|clearing' then 'cheque'
    else 'other' end;

  -- masked account: Raast IBAN, "9909-XXXX8022", "-XXXX3504", "XXXX9545"
  counterparty_account := upper(coalesce(
    (regexp_match(d, '(PK\d{2}[A-Z]{4}x{2,4}\d{3,4})', 'i'))[1],
    (regexp_match(d, '(\d{4}-X{4}[0-9A-Z]{4})', 'i'))[1],
    (regexp_match(d, '(X{4}\d{4})', 'i'))[1]));

  -- name = text after "transferred to / received from", cut at the first account / STAN marker
  m := regexp_match(d, '(?:money transferred to|fund transfer to|transferred to|transfer to|money received from|received from|transfer from)\s+(.*)$', 'i');
  counterparty := regexp_replace(coalesce(m[1], ''), '(\s+A ?C\s+\d|\s*-\s*X{4}|\s*-?\s*\mSTAN\M|\s+PK\d{2}[A-Z]{4}|\s+\d{4}-X{4}).*$', '', 'i');
  counterparty := nullif(trim(both ' -' from counterparty), '');
  if counterparty ~* '^X{4}' or counterparty ~ '^\d' then counterparty := null; end if;
  if counterparty is not null then counterparty := upper(regexp_replace(counterparty, '\s+', ' ', 'g')); end if;
  return next;
end;
$$;

-- ---------------------------------------------------------------- categorise
create or replace function public.bank_classify()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_store uuid := public.current_store_id();
  v_rule int;
  v_auto int;
begin
  perform public.assert_role('finance');

  -- 1) parse descriptions once
  update public.bank_transactions t set
    counterparty = p.counterparty, counterparty_account = p.counterparty_account, channel = p.channel, stan = p.stan
  from public.bank_transactions t2
  cross join lateral public.bank_parse_description(t2.description) p
  where t2.id = t.id and t.store_id = v_store and t.channel is null;

  -- 2) fee rows belong to the transfer with the same STAN on the same day
  update public.bank_transactions f set fee_for_id = x.id
  from public.bank_transactions x
  where f.store_id = v_store and x.store_id = v_store and f.fee_for_id is null
    and f.channel = 'fee' and f.stan is not null and x.stan = f.stan and x.id <> f.id
    and x.account_id = f.account_id and x.txn_date = f.txn_date and x.channel <> 'fee';

  -- 3) drop rule categories whose rule is gone, then (re)apply rules; manual / match stay
  update public.bank_transactions set category = null, category_source = null
  where store_id = v_store and category_source = 'rule' and rule_id is null;

  update public.bank_transactions t set category = x.category, rule_id = x.rule_id, category_source = 'rule'
  from (
    select t2.id, r.category, r.id as rule_id
    from public.bank_transactions t2
    cross join lateral (
      select r.* from public.bank_rules r
      where r.store_id = v_store and (
        (r.match_field = 'account' and upper(t2.counterparty_account) = upper(r.pattern)) or
        (r.match_field = 'name' and upper(t2.counterparty) = upper(r.pattern)) or
        (r.match_field = 'text' and t2.description ilike '%' || r.pattern || '%'))
      order by case r.match_field when 'account' then 1 when 'name' then 2 else 3 end, r.learned, r.id desc
      limit 1
    ) r
    where t2.store_id = v_store and coalesce(t2.category_source, 'auto') in ('auto', 'rule')
  ) x
  where x.id = t.id and (t.category is distinct from x.category or t.rule_id is distinct from x.rule_id);
  get diagnostics v_rule = row_count;

  -- 4) automatic patterns for what is still unknown
  update public.bank_transactions t set category = x.cat, category_source = 'auto'
  from (
    select t2.id,
      case
        when t2.channel = 'fee' or t2.fee_for_id is not null then 'bank_charges'
        when exists (select 1 from public.bank_accounts a where a.id = t2.account_id and a.holder_name is not null
                     and regexp_replace(upper(coalesce(t2.counterparty, '')), '[^A-Z]', '', 'g')
                       = regexp_replace(upper(a.holder_name), '[^A-Z]', '', 'g')) then 'owner_transfer'
        when t2.description ~* 'facebook|\mmeta\M|fb ?ads|facebk|instagram' and t2.debit > 0 then 'meta_ads'
        when t2.description ~* 'google|tiktok|snapchat' and t2.debit > 0 then 'other_ads'
        when t2.description ~* 'shopify|canva|google workspace|zoho|chatgpt|openai' and t2.debit > 0 then 'shopify_apps'
        when t2.description ~* 'postex|post ex|blue ?ex|leopards|\mtcs\M|m ?& ?p|mulphilog|trax|tranzo|\mxps\M|call ?courier' and t2.credit > 0 then 'courier_settlement'
        when t2.description ~* 'salar|payroll|wages' then 'salaries'
        when t2.description ~* 'reversal|reversed|refund|returned' then 'refund'
        when t2.description ~* 'k-?electric|ssgc|sui gas|ptcl|nayatel|storm ?fiber|jazz|zong|telenor|ufone|\mrent\M|internet' and t2.debit > 0 then 'operational'
        when t2.description ~* '\mfbr\M|income tax|sales tax|withholding' then 'taxes'
        when t2.description ~* 'dtf' then 'dtf_printing'
      end as cat
    from public.bank_transactions t2
    where t2.store_id = v_store and t2.category_source is null
  ) x
  where x.id = t.id and x.cat is not null;
  get diagnostics v_auto = row_count;

  return jsonb_build_object('by_rule', v_rule, 'auto', v_auto);
end;
$$;

-- ---------------------------------------------------------------- matching
-- Courier payouts ↔ CPRs: 1:1 first, then one deposit paying 2–4 CPRs together.
-- Bank amounts are often rounded (183,192 for a 183,191.17 CPR), so a small tolerance applies.
create or replace function public.auto_match_settlements()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_count int := 0;
  v_n int;
  tol numeric := greatest(public.setting_num('reconciliation', 'bank_match_tolerance', 1), 1);
  win int := public.setting_num('reconciliation', 'bank_match_window_days', 10)::int;
  c record;
  combo bigint[];
begin
  perform public.assert_role('finance');

  create temporary table if not exists _open_batches (batch_id bigint, remaining numeric, ref_date date) on commit drop;
  create temporary table if not exists _open_credits (id bigint, txn_date date, remaining numeric) on commit drop;

  for i in 1..2 loop
    truncate _open_batches; truncate _open_credits;
    insert into _open_batches
    select bs.batch_id, bs.total_net - bs.matched_amount, coalesce(bs.statement_date, b.imported_at::date)
    from public.v_batch_bank_status bs
    join public.settlement_batches b on b.id = bs.batch_id
    where not bs.is_banked and bs.total_net - bs.matched_amount > tol;

    insert into _open_credits
    select t.id, t.txn_date, t.credit - coalesce(sum(m.amount), 0)
    from public.bank_transactions t
    left join public.settlement_bank_matches m on m.bank_transaction_id = t.id
    where t.store_id = public.current_store_id() and t.credit > 0
      and (t.category is null or t.category = 'courier_settlement')
    group by t.id
    having t.credit - coalesce(sum(m.amount), 0) > tol;

    if i = 1 then
      -- one deposit = one CPR (unique on both sides)
      with pairs as (
        select ob.batch_id, oc.id as txn_id, least(ob.remaining, oc.remaining) as amount
        from _open_batches ob
        join _open_credits oc on abs(oc.remaining - ob.remaining) <= tol
         and oc.txn_date between ob.ref_date - 3 and ob.ref_date + win
      )
      insert into public.settlement_bank_matches (batch_id, bank_transaction_id, amount, method, matched_by)
      select p.batch_id, p.txn_id, p.amount, 'auto', (select auth.uid()) from pairs p
      where (select count(*) from pairs p2 where p2.batch_id = p.batch_id) = 1
        and (select count(*) from pairs p3 where p3.txn_id = p.txn_id) = 1
      on conflict do nothing;
      get diagnostics v_n = row_count;
      v_count := v_count + v_n;
    else
      -- one deposit = several CPRs paid together (dated before the deposit)
      for c in select * from _open_credits order by txn_date loop
        with recursive cand as (
          select batch_id, remaining, row_number() over (order by ref_date, batch_id) as rn
          from _open_batches
          where ref_date between c.txn_date - (win + 14) and c.txn_date
            and batch_id not in (select batch_id from public.settlement_bank_matches)
        ),
        combos as (
          select array[batch_id] as ids, remaining as total, rn from cand
          union all
          select co.ids || ca.batch_id, co.total + ca.remaining, ca.rn
          from combos co join cand ca on ca.rn > co.rn
          where array_length(co.ids, 1) < 4 and co.total + ca.remaining <= c.remaining + tol
        )
        select ids into combo from combos
        where array_length(ids, 1) >= 2 and abs(total - c.remaining) <= tol
        order by array_length(ids, 1), abs(total - c.remaining)
        limit 1;
        if combo is not null then
          insert into public.settlement_bank_matches (batch_id, bank_transaction_id, amount, method, matched_by)
          select ob.batch_id, c.id, ob.remaining, 'auto', (select auth.uid())
          from _open_batches ob where ob.batch_id = any (combo)
          on conflict do nothing;
          get diagnostics v_n = row_count;
          v_count := v_count + v_n;
          delete from _open_batches where batch_id = any (combo);
          combo := null;
        end if;
      end loop;
    end if;
  end loop;

  update public.bank_transactions t set category = 'courier_settlement', category_source = 'match'
  where t.store_id = public.current_store_id() and coalesce(t.category_source, 'auto') <> 'manual'
    and (t.category is distinct from 'courier_settlement' or t.category_source is distinct from 'match')
    and exists (select 1 from public.settlement_bank_matches m where m.bank_transaction_id = t.id);

  -- Learn: an account that paid a matched CPR is the courier's account from now on
  insert into public.bank_rules (match_field, pattern, category, label, learned)
  select distinct 'account', upper(t.counterparty_account), 'courier_settlement',
         upper(b.courier) || ' payouts (learned from matched CPRs)', true
  from public.bank_transactions t
  join public.settlement_bank_matches m on m.bank_transaction_id = t.id
  join public.settlement_batches b on b.id = m.batch_id
  where t.store_id = public.current_store_id() and t.counterparty_account is not null
  on conflict do nothing;

  return v_count;
end;
$$;

-- Customer bank transfers ↔ Shopify orders marked paid (prepaid by transfer)
create or replace function public.match_customer_payments()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare v int;
begin
  perform public.assert_role('finance');
  with credits as (
    select t.id, t.txn_date, t.credit
    from public.bank_transactions t
    where t.store_id = public.current_store_id() and t.credit > 0
      and (t.category is null or t.category = 'customer_payment')
      and not exists (select 1 from public.bank_order_matches x where x.bank_transaction_id = t.id)
      and not exists (select 1 from public.settlement_bank_matches x where x.bank_transaction_id = t.id)
  ),
  orders as (
    select o.id, o.current_total, (o.created_at_shop at time zone 'Asia/Karachi')::date as d
    from public.orders o
    where o.store_id = public.current_store_id() and o.cancelled_at is null
      and (not o.is_cod or exists (select 1 from unnest(o.payment_gateways) g where g ~* 'bank|deposit|transfer'))
      and not exists (select 1 from public.bank_order_matches x where x.order_id = o.id)
  ),
  pairs as (
    select c.id as txn_id, o.id as order_id, c.credit as amount
    from credits c join orders o on abs(o.current_total - c.credit) <= 1 and c.txn_date between o.d - 3 and o.d + 15
  )
  insert into public.bank_order_matches (bank_transaction_id, order_id, amount, method, matched_by)
  select p.txn_id, p.order_id, p.amount, 'auto', (select auth.uid()) from pairs p
  where (select count(*) from pairs p2 where p2.txn_id = p.txn_id) = 1
    and (select count(*) from pairs p3 where p3.order_id = p.order_id) = 1
  on conflict do nothing;
  get diagnostics v = row_count;

  update public.bank_transactions t set category = 'customer_payment', category_source = 'match'
  where t.store_id = public.current_store_id() and coalesce(t.category_source, 'auto') <> 'manual'
    and t.category is distinct from 'customer_payment'
    and exists (select 1 from public.bank_order_matches m where m.bank_transaction_id = t.id);
  return v;
end;
$$;

-- Bank debits ↔ expenses recorded in the app (same amount, within a week)
create or replace function public.match_expenses()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare v int;
begin
  perform public.assert_role('finance');
  with debits as (
    select t.id, t.txn_date, t.debit
    from public.bank_transactions t
    where t.store_id = public.current_store_id() and t.debit > 0
      and coalesce(t.category, '') not in ('owner_transfer', 'bank_charges', 'loan')
      and not exists (select 1 from public.expenses e where e.bank_transaction_id = t.id)
  ),
  exps as (
    select e.id, e.amount, e.expense_date
    from public.expenses e
    where e.store_id = public.current_store_id() and e.bank_transaction_id is null
      and coalesce(e.source, 'manual') not in ('triplewhale')
      and coalesce(e.payment_method, 'bank') = 'bank'
  ),
  pairs as (
    select d.id as txn_id, x.id as expense_id
    from debits d join exps x on abs(x.amount - d.debit) <= 1 and d.txn_date between x.expense_date - 7 and x.expense_date + 7
  )
  update public.expenses e set bank_transaction_id = p.txn_id
  from pairs p
  where e.id = p.expense_id
    and (select count(*) from pairs p2 where p2.txn_id = p.txn_id) = 1
    and (select count(*) from pairs p3 where p3.expense_id = p.expense_id) = 1;
  get diagnostics v = row_count;

  update public.bank_transactions t set category = c.bank_category, category_source = 'match'
  from public.expenses e join public.expense_categories c on c.id = e.category_id
  where e.bank_transaction_id = t.id and t.store_id = public.current_store_id()
    and t.category_source is null and c.bank_category is not null;
  return v;
end;
$$;

-- Everything, in order — run after every import and whenever rules change
create or replace function public.bank_run_matching()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare r jsonb;
begin
  perform public.assert_role('finance');
  r := public.bank_classify();
  r := r || jsonb_build_object('courier_matches', public.auto_match_settlements());
  r := r || public.bank_classify(); -- learned courier accounts apply to their other credits too
  r := r || jsonb_build_object('order_matches', public.match_customer_payments(),
                               'expense_matches', public.match_expenses());
  perform public.refresh_alerts();
  return r;
end;
$$;

-- Manual category, optionally saved as a rule for this account / name (applied to the past too)
create or replace function public.set_bank_category(p_txn bigint, p_category text, p_rule text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  t public.bank_transactions;
  v_pattern text;
  v_rule bigint;
  v_affected int := 0;
begin
  perform public.assert_role('finance');
  select * into t from public.bank_transactions where id = p_txn and store_id = public.current_store_id();
  if not found then raise exception 'Transaction not found'; end if;

  update public.bank_transactions set
    category = nullif(p_category, ''),
    category_source = case when nullif(p_category, '') is null then null else 'manual' end,
    rule_id = null,
    note = coalesce(p_note, note)
  where id = p_txn;

  if p_rule in ('account', 'name') and nullif(p_category, '') is not null then
    v_pattern := case p_rule when 'account' then t.counterparty_account else t.counterparty end;
    if v_pattern is null then raise exception 'This transaction has no % to build a rule from', p_rule; end if;
    insert into public.bank_rules (match_field, pattern, category, label, created_by)
    values (p_rule, upper(v_pattern), p_category, coalesce(t.counterparty, t.counterparty_account), (select auth.uid()))
    on conflict (store_id, match_field, upper(pattern)) do update set category = excluded.category, learned = false
    returning id into v_rule;
    perform public.bank_run_matching();
    select count(*) into v_affected from public.bank_transactions where rule_id = v_rule;
  end if;
  return jsonb_build_object('rule_id', v_rule, 'applied_to', v_affected);
end;
$$;

-- ---------------------------------------------------------------- import
drop function if exists public.import_bank_statement(bigint, text, text, jsonb);
create or replace function public.import_bank_statement(p_account_id bigint, p_file_name text, p_file_sha256 text, p_rows jsonb, p_meta jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_import bigint;
  v_inserted int;
  v_total int;
  v_match jsonb;
begin
  perform public.assert_role('finance');

  if not exists (select 1 from public.bank_accounts where id = p_account_id and store_id = public.current_store_id()) then
    raise exception 'Bank account % not found', p_account_id;
  end if;
  if exists (select 1 from public.bank_imports where account_id = p_account_id and file_sha256 = p_file_sha256) then
    raise exception 'This exact statement file was already imported for this account' using errcode = '23505';
  end if;

  -- what the statement says about the account (holder name lets us spot own-account transfers)
  if p_meta is not null then
    update public.bank_accounts set
      holder_name = coalesce(holder_name, nullif(p_meta ->> 'account_title', '')),
      account_hint = coalesce(account_hint, nullif(p_meta ->> 'account_last4', '')),
      bank = coalesce(nullif(bank, ''), nullif(p_meta ->> 'bank', ''))
    where id = p_account_id;
  end if;

  v_total := jsonb_array_length(p_rows);

  insert into public.bank_imports (account_id, file_name, file_sha256, row_count, date_from, date_to, imported_by)
  select p_account_id, p_file_name, p_file_sha256, v_total,
         coalesce((p_meta ->> 'from')::date, min((x ->> 'date')::date)), coalesce((p_meta ->> 'to')::date, max((x ->> 'date')::date)),
         (select auth.uid())
  from jsonb_array_elements(p_rows) x
  returning id into v_import;

  with r as (
    select (x ->> 'date')::date as d,
           left(coalesce(trim(x ->> 'description'), ''), 500) as descr,
           nullif(trim(x ->> 'reference'), '') as ref,
           round(abs(coalesce((x ->> 'debit')::numeric, 0)), 2) as debit,
           round(abs(coalesce((x ->> 'credit')::numeric, 0)), 2) as credit,
           round((x ->> 'balance')::numeric, 2) as balance,
           ord
    from jsonb_array_elements(p_rows) with ordinality as t(x, ord)
  ),
  k as (
    select r.*,
      md5(concat_ws('|', d, lower(descr), coalesce(ref, ''), debit, credit, coalesce(balance::text, ''))) as base_hash
    from r
  ),
  h as (
    select k.*, base_hash || ':' || row_number() over (partition by base_hash order by ord) as row_hash
    from k
  )
  insert into public.bank_transactions (account_id, import_id, txn_date, description, reference, debit, credit, balance, row_hash)
  select p_account_id, v_import, d, descr, ref, debit, credit, balance, row_hash
  from h
  where d is not null and (debit > 0 or credit > 0)
  order by ord
  on conflict (account_id, row_hash) do nothing;

  get diagnostics v_inserted = row_count;
  update public.bank_imports set row_count = v_inserted where id = v_import;

  v_match := public.bank_run_matching();

  return jsonb_build_object('import_id', v_import, 'rows', v_total, 'inserted', v_inserted,
                            'duplicates_skipped', v_total - v_inserted) || v_match;
end;
$$;

-- ---------------------------------------------------------------- analysis
create or replace function public.bank_reconciliation(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_store uuid := public.current_store_id();
  win int := public.setting_num('reconciliation', 'bank_match_window_days', 10)::int;
  v_cov_from date;
  v_cov_to date;
  v_from date;  -- analysed window = requested period ∩ dates the bank statements cover
  v_to date;
  areas jsonb := '[]'::jsonb;
  a jsonb;
  k record;
  v_exp numeric; v_act numeric; v_mat numeric; v_diff numeric;
  v_items jsonb;
  v_status text; v_expl text; v_action text;
begin
  if not public.has_role('viewer') then raise exception 'not authorised' using errcode = '42501'; end if;

  select min(txn_date), max(txn_date) into v_cov_from, v_cov_to from public.bank_transactions where store_id = v_store;
  v_from := greatest(p_from, coalesce(v_cov_from, p_from));
  v_to := least(p_to, coalesce(v_cov_to, p_to));

  -- ---- courier payouts
  with b as (
    select bs.batch_id, b.courier, b.statement_ref, bs.statement_date, bs.total_net, bs.matched_amount
    from public.v_batch_bank_status bs join public.settlement_batches b on b.id = bs.batch_id
    where b.voided_at is null and bs.total_net > 0
      and (coalesce(bs.statement_date, b.imported_at::date) between v_from and v_to
           or exists (select 1 from public.settlement_bank_matches m join public.bank_transactions t on t.id = m.bank_transaction_id
                      where m.batch_id = bs.batch_id and t.txn_date between v_from and v_to))
  )
  select coalesce(sum(total_net), 0), coalesce(sum(least(matched_amount, total_net)), 0),
         coalesce(jsonb_agg(jsonb_build_object('kind', 'cpr', 'id', batch_id, 'ref', statement_ref, 'courier', courier, 'date', statement_date,
                  'amount', round(total_net - matched_amount, 2),
                  'note', case when v_cov_to is null or statement_date + win > v_cov_to
                               then 'Bank statement does not cover the payment window yet'
                               else 'Not found in the bank' end) order by statement_date)
                  filter (where total_net - matched_amount > 1), '[]')
    into v_exp, v_mat, v_items from b;
  select coalesce(sum(credit), 0) into v_act from public.bank_transactions
  where store_id = v_store and category = 'courier_settlement' and txn_date between v_from and v_to;
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object('kind', 'bank', 'id', t.id, 'date', t.txn_date, 'description', t.description,
                     'amount', t.credit - coalesce(m.s, 0), 'note', 'Courier money in the bank not tied to any CPR'))
    from public.bank_transactions t
    left join lateral (select sum(amount) s from public.settlement_bank_matches where bank_transaction_id = t.id) m on true
    where t.store_id = v_store and t.category = 'courier_settlement' and t.txn_date between v_from and v_to
      and t.credit - coalesce(m.s, 0) > 1), '[]');
  v_diff := round(v_exp - v_mat, 2);
  areas := areas || jsonb_build_array(jsonb_build_object(
    'key', 'courier', 'label', 'Courier payouts (PostEx & others)', 'direction', 'in',
    'expected', v_exp, 'actual', v_act, 'matched', v_mat, 'difference', v_diff,
    'status', case when v_exp = 0 and v_act = 0 then 'empty' when abs(v_diff) <= 5 then 'ok' when v_cov_to is null then 'unknown' else 'bad' end,
    'expected_label', 'Courier CPRs (net payable)', 'actual_label', 'Courier credits in bank',
    'explanation', case
      when v_cov_to is null then 'No bank statement imported, so courier payouts cannot be verified.'
      when abs(v_diff) <= 5 then 'Every courier payout in this period is in the bank.'
      else format('Rs %s of courier payouts could not be found in the bank. Recent CPRs may still be in transit; older ones may be unpaid or paid to another account.', to_char(v_diff, 'FM999,999,999,990')) end,
    'action', case when abs(v_diff) <= 5 then null else 'Import the latest statement, or ask the courier for proof of payment for the CPRs listed.' end,
    'items', v_items));

  -- ---- prepaid orders (bank transfers)
  with o as (
    select o.id, o.name, o.current_total, (o.created_at_shop at time zone 'Asia/Karachi')::date d,
           coalesce((select sum(m.amount) from public.bank_order_matches m where m.order_id = o.id), 0) as matched
    from public.orders o
    where o.store_id = v_store and o.cancelled_at is null and not o.is_cod
      and not exists (select 1 from unnest(o.payment_gateways) g where g ~* 'shopify_payments|stripe|paypal|payfast|safepay|card|jazzcash|easypaisa')
      and (o.created_at_shop at time zone 'Asia/Karachi')::date between v_from and v_to
  )
  select coalesce(sum(current_total), 0), coalesce(sum(least(matched, current_total)), 0),
         coalesce(jsonb_agg(jsonb_build_object('kind', 'order', 'id', id, 'ref', name, 'date', d, 'amount', current_total - matched,
                  'note', 'Marked paid in Shopify, but no matching bank credit found — verify the receipt')
                  order by d) filter (where current_total - matched > 1), '[]')
    into v_exp, v_mat, v_items from o;
  select coalesce(sum(credit), 0) into v_act from public.bank_transactions
  where store_id = v_store and category = 'customer_payment' and txn_date between v_from and v_to;
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object('kind', 'bank', 'id', t.id, 'date', t.txn_date, 'description', t.description, 'amount', t.credit,
                     'note', 'Customer transfer not linked to an order — match it, or mark the order paid in Shopify'))
    from public.bank_transactions t
    where t.store_id = v_store and t.category = 'customer_payment' and t.txn_date between v_from and v_to
      and not exists (select 1 from public.bank_order_matches m where m.bank_transaction_id = t.id)), '[]');
  v_diff := round(v_exp - v_mat, 2);
  areas := areas || jsonb_build_array(jsonb_build_object(
    'key', 'prepaid', 'label', 'Prepaid orders (bank transfers)', 'direction', 'in',
    'expected', v_exp, 'actual', v_act, 'matched', v_mat, 'difference', v_diff,
    'status', case when v_exp = 0 and v_act = 0 then 'empty' when abs(v_diff) <= 5 then 'ok' when v_cov_to is null then 'unknown' else 'warn' end,
    'expected_label', 'Orders marked paid in Shopify', 'actual_label', 'Customer transfers in bank',
    'explanation', case
      when abs(v_diff) <= 5 then 'Every order marked paid has a matching bank transfer.'
      else format('Rs %s of orders are marked paid in Shopify without a matching bank credit. The receipt may be fake, the money may have gone to another account, or the customer paid in parts.', to_char(v_diff, 'FM999,999,999,990')) end,
    'action', case when abs(v_diff) <= 5 then null else 'Check each order''s WhatsApp receipt against the bank; link the transfer or set the order back to payment pending.' end,
    'items', v_items));

  -- ---- spending areas: what the app recorded vs what the bank paid
  for k in select * from (values
      ('meta_ads', 'Meta / Facebook ads'), ('other_ads', 'Other ads'), ('supplier', 'Suppliers'),
      ('dtf_printing', 'DTF printing'), ('inventory', 'Inventory & production'), ('shopify_apps', 'Shopify & apps'),
      ('salaries', 'Salaries'), ('operational', 'Operational expenses'), ('taxes', 'Taxes')) as x(key, label)
  loop
    select coalesce(sum(e.amount), 0) into v_exp
    from public.expenses e join public.expense_categories c on c.id = e.category_id
    where e.store_id = v_store and c.bank_category = k.key and e.expense_date between v_from and v_to;
    select coalesce(sum(t.debit), 0) into v_act from public.bank_transactions t
    where t.store_id = v_store and t.category = k.key and t.txn_date between v_from and v_to;
    select coalesce(sum(t.debit), 0) into v_mat from public.bank_transactions t
    where t.store_id = v_store and t.category = k.key and t.txn_date between v_from and v_to
      and exists (select 1 from public.expenses e where e.bank_transaction_id = t.id);
    if v_exp = 0 and v_act = 0 then continue; end if;
    v_items := coalesce((
      select jsonb_agg(jsonb_build_object('kind', 'bank', 'id', t.id, 'date', t.txn_date, 'description', t.description, 'amount', t.debit,
                       'note', 'Paid from the bank but not recorded as an expense in the app') order by t.txn_date)
      from public.bank_transactions t
      where t.store_id = v_store and t.category = k.key and t.txn_date between v_from and v_to
        and not exists (select 1 from public.expenses e where e.bank_transaction_id = t.id)), '[]')
      || coalesce((
      select jsonb_agg(jsonb_build_object('kind', 'expense', 'id', e.id, 'date', e.expense_date,
                       'description', coalesce(e.vendor, e.description, c.name), 'amount', e.amount,
                       'note', 'Recorded in the app, no bank payment found') order by e.expense_date)
      from public.expenses e join public.expense_categories c on c.id = e.category_id
      where e.store_id = v_store and c.bank_category = k.key and e.expense_date between v_from and v_to
        and e.bank_transaction_id is null and coalesce(e.source, 'manual') <> 'triplewhale'
        and coalesce(e.payment_method, 'bank') = 'bank'), '[]');
    v_diff := round(v_act - v_exp, 2);
    v_status := case when abs(v_diff) <= greatest(5, v_exp * 0.02) then 'ok' when v_cov_to is null then 'unknown' else 'warn' end;
    if k.key = 'meta_ads' then
      v_expl := case
        when v_status = 'ok' then 'Bank payments for Meta match the ad spend recorded.'
        when v_diff > 0 then format('The bank paid Rs %s more for Meta than the ad spend recorded — prepaid top-ups or agent fees, or spend that never reached the app.', to_char(v_diff, 'FM999,999,999,990'))
        else format('Rs %s of recorded ad spend was not paid from this bank account — usually a card or another account pays Meta directly.', to_char(-v_diff, 'FM999,999,999,990')) end;
      v_action := case when v_status = 'ok' then null when v_diff > 0 then 'Check the Meta billing history for this period against the bank payments.' else 'Import the statement of the card/account that pays Meta, or confirm the spend.' end;
    else
      v_expl := case
        when v_status = 'ok' then 'Bank payments match what is recorded in the app.'
        when v_diff > 0 then format('The bank paid Rs %s more than the app has recorded — unrecorded expenses or overspending.', to_char(v_diff, 'FM999,999,999,990'))
        else format('Rs %s recorded in the app has no bank payment — paid in cash or from another account, not paid yet, or recorded twice.', to_char(-v_diff, 'FM999,999,999,990')) end;
      v_action := case when v_status = 'ok' then null when v_diff > 0 then 'Record the bank payments listed below as expenses.' else 'Confirm how the expenses listed below were paid.' end;
    end if;
    areas := areas || jsonb_build_array(jsonb_build_object(
      'key', k.key, 'label', k.label, 'direction', 'out',
      'expected', v_exp, 'actual', v_act, 'matched', v_mat, 'difference', v_diff, 'status', v_status,
      'expected_label', 'Recorded in Hisab Kitab', 'actual_label', 'Paid from bank',
      'explanation', v_expl, 'action', v_action, 'items', v_items));
  end loop;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'clipped', v_cov_to is not null and (v_from > p_from or v_to < p_to)),
    'coverage', jsonb_build_object('from', v_cov_from, 'to', v_cov_to,
       'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'bank', a.bank, 'from', x.f, 'to', x.t, 'closing', x.bal)), '[]')
                    from public.bank_accounts a
                    left join lateral (select min(txn_date) f, max(txn_date) t,
                                              (select balance from public.bank_transactions b2 where b2.account_id = a.id order by txn_date desc, id desc limit 1) bal
                                       from public.bank_transactions b where b.account_id = a.id) x on true
                    where a.store_id = v_store)),
    'totals', (select jsonb_build_object(
        'money_in', coalesce(sum(credit), 0), 'money_out', coalesce(sum(debit), 0),
        'explained_in', coalesce(sum(credit) filter (where category is not null), 0),
        'explained_out', coalesce(sum(debit) filter (where category is not null), 0),
        'review_count', count(*) filter (where category is null),
        'review_in', coalesce(sum(credit) filter (where category is null), 0),
        'review_out', coalesce(sum(debit) filter (where category is null), 0))
      from public.bank_transactions where store_id = v_store and txn_date between p_from and p_to),
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'in', i, 'out', o, 'n', n) order by o + i desc), '[]')
      from (select coalesce(category, 'needs_review') category, sum(credit) i, sum(debit) o, count(*) n
            from public.bank_transactions where store_id = v_store and txn_date between p_from and p_to group by 1) x),
    'areas', areas,
    'review', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', txn_date, 'description', description,
                 'counterparty', counterparty, 'account', counterparty_account, 'credit', credit, 'debit', debit) order by greatest(credit, debit) desc), '[]')
      from (select * from public.bank_transactions where store_id = v_store and txn_date between p_from and p_to and category is null
            order by greatest(credit, debit) desc limit 50) r),
    'duplicates', (select coalesce(jsonb_agg(jsonb_build_object('a', a.id, 'b', b.id, 'date', a.txn_date, 'amount', a.debit + a.credit,
                       'description', a.description)), '[]')
      from public.bank_transactions a join public.bank_transactions b
        on b.store_id = a.store_id and b.id > a.id and b.debit = a.debit and b.credit = a.credit
       and b.txn_date between a.txn_date and a.txn_date + 2
       and coalesce(b.counterparty_account, b.counterparty, '') = coalesce(a.counterparty_account, a.counterparty, '')
       and coalesce(a.counterparty_account, a.counterparty) is not null and coalesce(a.channel, '') <> 'fee'
       and coalesce(a.category, '') not in ('owner_transfer', 'bank_charges')
       and a.debit + a.credit >= 1000
      where a.store_id = v_store and a.txn_date between p_from and p_to),
    'balance_breaks', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', txn_date, 'expected', expected, 'balance', balance)), '[]')
      from (select id, txn_date, balance, round(lag(balance) over w + credit - debit, 2) expected
            from public.bank_transactions where store_id = v_store and balance is not null
            window w as (partition by account_id order by txn_date, id)) x
      where x.expected is not null and abs(x.expected - x.balance) > 0.01 and x.txn_date between p_from and p_to)
  );
end;
$$;

revoke execute on function public.bank_classify() from public, anon;
revoke execute on function public.match_customer_payments() from public, anon;
revoke execute on function public.match_expenses() from public, anon;
revoke execute on function public.bank_run_matching() from public, anon;
revoke execute on function public.set_bank_category(bigint, text, text, text) from public, anon;
revoke execute on function public.bank_reconciliation(date, date) from public, anon;
revoke execute on function public.import_bank_statement(bigint, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.bank_classify(), public.match_customer_payments(), public.match_expenses(),
  public.bank_run_matching(), public.set_bank_category(bigint, text, text, text),
  public.bank_reconciliation(date, date), public.import_bank_statement(bigint, text, text, jsonb, jsonb) to authenticated;
