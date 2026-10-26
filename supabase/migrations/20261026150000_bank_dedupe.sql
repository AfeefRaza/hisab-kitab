-- =====================================================================
-- Overlapping statements never count a transaction twice
--   (e.g. a 1-month statement, then a 1-year statement that includes the same month)
-- * Fingerprint, unique per bank account:
--     with a running balance  → date + money in + money out + balance after the transaction
--                               (the text can differ between exports/PDF layouts; the
--                               balance chain cannot)
--     without a balance       → date + amounts + reference + description with spacing,
--                               punctuation and case removed
--   plus the occurrence number within the file, so genuinely repeated rows still count.
-- * A statement for another account number is refused instead of creating a second
--   copy of the same transactions under a different account.
-- =====================================================================

create or replace function public.bank_row_key(p_date date, p_description text, p_reference text,
                                               p_debit numeric, p_credit numeric, p_balance numeric)
returns text
language sql
immutable
set search_path to ''
as $$
  select md5(case
    when p_balance is not null then concat_ws('|', 'b', p_date, round(p_debit, 2), round(p_credit, 2), round(p_balance, 2))
    else concat_ws('|', 'd', p_date, round(p_debit, 2), round(p_credit, 2),
                   regexp_replace(lower(coalesce(p_reference, '')), '[^a-z0-9]', '', 'g'),
                   regexp_replace(lower(coalesce(p_description, '')), '[^a-z0-9]', '', 'g'))
  end)
$$;

-- Re-key what is already imported (occurrence numbered per import, in file order)
update public.bank_transactions t set row_hash = x.k
from (
  select id, public.bank_row_key(txn_date, description, reference, debit, credit, balance) || ':' ||
         row_number() over (partition by account_id, import_id,
                            public.bank_row_key(txn_date, description, reference, debit, credit, balance) order by id) as k
  from public.bank_transactions
) x
where x.id = t.id and t.row_hash is distinct from x.k;

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
  v_hint text;
  v_last4 text := nullif(p_meta ->> 'account_last4', '');
  v_other text;
begin
  perform public.assert_role('finance');

  select account_hint into v_hint from public.bank_accounts where id = p_account_id and store_id = public.current_store_id();
  if not found then
    raise exception 'Bank account % not found', p_account_id;
  end if;
  -- the statement says which account it is: refuse to file it under a different one
  if v_last4 is not null and v_hint is not null and v_hint <> v_last4 then
    raise exception 'This statement is for account ending %, but you chose the account ending %. Pick the right account.', v_last4, v_hint;
  end if;
  if v_last4 is not null and v_hint is null then
    select name into v_other from public.bank_accounts
    where store_id = public.current_store_id() and account_hint = v_last4 and id <> p_account_id limit 1;
    if v_other is not null then
      raise exception 'This statement belongs to "%" (account ending %). Import it into that account so overlapping transactions are not counted twice.', v_other, v_last4;
    end if;
  end if;
  if exists (select 1 from public.bank_imports where account_id = p_account_id and file_sha256 = p_file_sha256) then
    raise exception 'This exact statement file was already imported for this account' using errcode = '23505';
  end if;

  if p_meta is not null then
    update public.bank_accounts set
      holder_name = coalesce(holder_name, nullif(p_meta ->> 'account_title', '')),
      account_hint = coalesce(account_hint, v_last4),
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
    select r.*, public.bank_row_key(d, descr, ref, debit, credit, balance) as base_hash from r
  ),
  h as (
    select k.*, base_hash || ':' || row_number() over (partition by base_hash order by ord) as row_hash from k
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
