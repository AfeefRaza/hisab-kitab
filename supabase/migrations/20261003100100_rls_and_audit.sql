-- =====================================================================
-- Row Level Security + audit trail
-- Roles: pending (no access) < viewer (read) < finance (operate) < admin.
-- Server-side sync/edge functions use service_role and bypass RLS.
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','app_settings','integrations','orders','order_lines','product_cost_rules',
    'shipments','shipment_events','courier_rate_cards','settlement_batches','settlement_lines',
    'bank_accounts','bank_imports','bank_transactions','settlement_bank_matches',
    'expense_categories','expenses','sync_runs','sync_state','alerts','audit_log'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Read access for viewer+ on business tables
do $$
declare t text;
begin
  foreach t in array array[
    'app_settings','orders','order_lines','product_cost_rules','shipments','shipment_events',
    'courier_rate_cards','settlement_batches','settlement_lines','bank_accounts','bank_imports',
    'bank_transactions','settlement_bank_matches','expense_categories','expenses','sync_runs','alerts'
  ] loop
    execute format(
      'create policy "viewer can read" on public.%I for select to authenticated using ((select public.has_role(''viewer'')))', t);
  end loop;
end $$;

-- Write access for finance+ on operator-managed tables
do $$
declare t text;
begin
  foreach t in array array[
    'product_cost_rules','courier_rate_cards','expense_categories','expenses',
    'bank_accounts','settlement_bank_matches'
  ] loop
    execute format('create policy "finance can insert" on public.%I for insert to authenticated with check ((select public.has_role(''finance'')))', t);
    execute format('create policy "finance can update" on public.%I for update to authenticated using ((select public.has_role(''finance''))) with check ((select public.has_role(''finance'')))', t);
    execute format('create policy "finance can delete" on public.%I for delete to authenticated using ((select public.has_role(''finance'')))', t);
  end loop;
end $$;

-- Finance may annotate bank transactions (category / note) and work alerts
create policy "finance can update" on public.bank_transactions for update to authenticated
  using ((select public.has_role('finance'))) with check ((select public.has_role('finance')));
create policy "finance can update" on public.alerts for update to authenticated
  using ((select public.has_role('finance'))) with check ((select public.has_role('finance')));

-- Settings: admin writes
create policy "admin can update" on public.app_settings for update to authenticated
  using ((select public.has_role('admin'))) with check ((select public.has_role('admin')));

-- Integrations: finance+ can read masked metadata; writes only via edge function
create policy "finance can read" on public.integrations for select to authenticated
  using ((select public.has_role('finance')));

-- Sync state: finance+ read
create policy "finance can read" on public.sync_state for select to authenticated
  using ((select public.has_role('finance')));

-- Profiles: everyone reads own row; admins read & manage all
create policy "read own profile" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.has_role('admin')));
create policy "update own name or admin" on public.profiles for update to authenticated
  using (id = (select auth.uid()) or (select public.has_role('admin')))
  with check (id = (select auth.uid()) or (select public.has_role('admin')));

-- Audit log: admins read; nobody writes directly
create policy "admin can read" on public.audit_log for select to authenticated
  using ((select public.has_role('admin')));

-- ---------------------------------------------------------------------
-- Audit trigger
-- ---------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  rec_id text;
begin
  rec_id := coalesce(
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'id',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'key',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'provider'
  );
  insert into public.audit_log (actor, actor_email, action, table_name, record_id, old_data, new_data)
  values (
    (select auth.uid()),
    (select auth.jwt() ->> 'email'),
    tg_op,
    tg_table_name,
    rec_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','app_settings','integrations','product_cost_rules','courier_rate_cards',
    'settlement_batches','bank_accounts','bank_imports','settlement_bank_matches',
    'expense_categories','expenses'
  ] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- Shipments: only audit manual overrides (courier updates are high-volume)
create trigger audit_shipments_manual
  after update of manual_status, manual_note on public.shipments
  for each row
  when (old.manual_status is distinct from new.manual_status or old.manual_note is distinct from new.manual_note)
  execute function public.audit_trigger();

-- Audit log for bank transaction categorisation
create trigger audit_bank_transactions_update
  after update of category, note on public.bank_transactions
  for each row execute function public.audit_trigger();

-- Lock down the default grants: anon gets nothing.
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
