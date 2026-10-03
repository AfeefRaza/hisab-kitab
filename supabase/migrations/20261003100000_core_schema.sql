-- =====================================================================
-- Hisab Kitab — core schema
-- Single-business finance system: orders, shipments, courier settlements,
-- bank statements, expenses, costs, alerts, audit.
-- All money is numeric(14,2) in PKR. All timestamps are timestamptz;
-- business dates are derived in Asia/Karachi.
-- =====================================================================

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------
-- Users & roles
-- ---------------------------------------------------------------------
create type public.app_role as enum ('pending', 'viewer', 'finance', 'admin');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  full_name text,
  role public.app_role not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Role lookup used by every RLS policy. SECURITY DEFINER so policies on
-- profiles itself don't recurse; STABLE so it is evaluated once per query.
create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.role from public.profiles p where p.id = (select auth.uid())),
    'pending'::public.app_role
  );
$$;

create or replace function public.has_role(min_role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- enum order: pending < viewer < finance < admin
  select public.current_app_role() >= min_role;
$$;

revoke all on function public.current_app_role() from public, anon;
revoke all on function public.has_role(public.app_role) from public, anon;
grant execute on function public.current_app_role() to authenticated, service_role;
grant execute on function public.has_role(public.app_role) to authenticated, service_role;

-- First user to sign up becomes admin; everyone after is 'pending' until an
-- admin approves them. This replaces open sign-up access.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  is_first boolean;
begin
  perform pg_advisory_xact_lock(hashtext('hk_first_user'));
  select not exists (select 1 from public.profiles) into is_first;
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    coalesce(new.email, ''),
    new.raw_user_meta_data ->> 'full_name',
    case when is_first then 'admin'::public.app_role else 'pending'::public.app_role end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Shared updated_at trigger
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- Users may not change their own role; only admins may change roles.
create or replace function public.guard_profile_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- server-side contexts (service_role / migrations) have no auth.uid()
  if (select auth.uid()) is null then
    return new;
  end if;
  if new.role is distinct from old.role and not public.has_role('admin') then
    raise exception 'Only admins can change roles' using errcode = '42501';
  end if;
  if new.role is distinct from old.role and old.id = (select auth.uid()) then
    raise exception 'Admins cannot change their own role' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_role before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ---------------------------------------------------------------------
-- Settings (non-secret business configuration, key/value)
-- ---------------------------------------------------------------------
create table public.app_settings (
  key text primary key,
  value jsonb not null,
  description text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
create trigger app_settings_touch before update on public.app_settings
  for each row execute function public.touch_updated_at();

insert into public.app_settings (key, value, description) values
  ('packaging', '{"flyer_per_parcel": 5, "polybag_per_unit": 10}', 'Packaging cost per shipped parcel / unit (PKR)'),
  ('tax', '{"income_tax_percent": 0}', 'Tax % applied to positive net profit in P&L'),
  ('returns', '{"inventory_loss_percent": 0, "count_packaging_on_return": 1}', 'Share of COGS lost when a parcel is returned (0 = stock goes back to inventory)'),
  ('reconciliation', '{"settlement_overdue_days": 10, "bank_match_window_days": 10, "bank_match_tolerance": 1, "cod_mismatch_tolerance": 1, "stuck_days": 5}', 'Reconciliation thresholds'),
  ('sync', '{"orders_every_minutes": 30, "tracking_every_minutes": 60, "backfill_from": null}', 'Sync schedule');

-- ---------------------------------------------------------------------
-- Integrations: non-secret config here; secrets live in Supabase Vault and
-- are only reachable through service_role functions (see migration 3).
-- ---------------------------------------------------------------------
create table public.integrations (
  provider text primary key
    check (provider in ('shopify', 'postex', 'blueex', 'mnp', 'tranzo', 'xps')),
  display_name text not null,
  kind text not null check (kind in ('store', 'courier')),
  enabled boolean not null default false,
  config jsonb not null default '{}'::jsonb,          -- e.g. shop domain, api version
  secret_hint jsonb not null default '{}'::jsonb,     -- masked values, e.g. {"token":"••••a1b2"}
  vault_secret_id uuid,                               -- vault.secrets.id (JSON of secret fields)
  status text not null default 'not_configured'
    check (status in ('not_configured', 'connected', 'error', 'disabled')),
  last_tested_at timestamptz,
  last_test_message text,
  last_sync_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
create trigger integrations_touch before update on public.integrations
  for each row execute function public.touch_updated_at();

insert into public.integrations (provider, display_name, kind, config) values
  ('shopify', 'Shopify', 'store', '{"api_version": "2026-07"}'),
  ('postex', 'PostEx', 'courier', '{}'),
  ('blueex', 'BlueEx', 'courier', '{}'),
  ('mnp', 'M&P', 'courier', '{}'),
  ('tranzo', 'Tranzo', 'courier', '{}'),
  ('xps', 'XPS', 'courier', '{}');

-- ---------------------------------------------------------------------
-- Orders (mirrored from Shopify)
-- ---------------------------------------------------------------------
create table public.orders (
  id bigint primary key,                   -- Shopify legacy numeric id
  name text not null,                      -- "#1234"
  created_at_shop timestamptz not null,
  updated_at_shop timestamptz not null,
  processed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  financial_status text,                   -- PENDING, PAID, REFUNDED, ...
  fulfillment_status text,                 -- UNFULFILLED, FULFILLED, ...
  payment_gateways text[] not null default '{}',
  is_cod boolean not null default true,
  currency text not null default 'PKR',
  subtotal numeric(14,2) not null default 0,
  total_discounts numeric(14,2) not null default 0,
  shipping_charged numeric(14,2) not null default 0,  -- shipping fee charged to customer
  total_tax numeric(14,2) not null default 0,
  total_price numeric(14,2) not null default 0,       -- original total
  total_refunded numeric(14,2) not null default 0,
  current_total numeric(14,2) not null default 0,     -- after edits/refunds
  outstanding numeric(14,2) not null default 0,       -- what the customer still owes (COD amount)
  customer_name text,
  phone text,
  city text,
  province text,
  tags text[] not null default '{}',
  note text,
  synced_at timestamptz not null default now(),
  order_date date generated always as ((created_at_shop at time zone 'Asia/Karachi')::date) stored
);
create index orders_order_date_idx on public.orders (order_date desc);
create index orders_name_idx on public.orders (name);
create index orders_updated_idx on public.orders (updated_at_shop);
create index orders_city_idx on public.orders (lower(city));
create index orders_search_trgm on public.orders
  using gin ((coalesce(name,'') || ' ' || coalesce(customer_name,'') || ' ' || coalesce(phone,'') || ' ' || coalesce(city,'')) extensions.gin_trgm_ops);

create table public.order_lines (
  id bigint primary key,                   -- Shopify line item id
  order_id bigint not null references public.orders (id) on delete cascade,
  title text not null,
  variant_title text,
  sku text,
  product_id bigint,
  variant_id bigint,
  quantity integer not null,
  current_quantity integer not null,       -- after removals/refunds
  unit_price numeric(14,2) not null default 0,
  unit_cost numeric(14,2)                  -- Shopify inventory unit cost, null if unset
);
create index order_lines_order_idx on public.order_lines (order_id);
create index order_lines_variant_idx on public.order_lines (variant_id);

-- Fallback sourcing cost rules (used when Shopify unit cost is missing).
-- match_type: sku = exact SKU, variant = exact variant id, keyword = title contains any keyword
create table public.product_cost_rules (
  id bigint generated always as identity primary key,
  name text not null,
  match_type text not null check (match_type in ('sku', 'variant', 'keyword', 'default')),
  match_value text,                        -- sku / variant id / comma-separated keywords
  unit_cost numeric(14,2) not null check (unit_cost >= 0),
  priority integer not null default 100,   -- lower wins
  effective_from date not null default '2000-01-01',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger product_cost_rules_touch before update on public.product_cost_rules
  for each row execute function public.touch_updated_at();
insert into public.product_cost_rules (name, match_type, match_value, unit_cost, priority)
values ('Default', 'default', null, 850, 1000);

-- ---------------------------------------------------------------------
-- Shipments & tracking
-- ---------------------------------------------------------------------
create type public.shipment_status as enum (
  'booked', 'in_transit', 'out_for_delivery', 'delivery_failed',
  'delivered', 'return_in_transit', 'returned', 'cancelled', 'lost', 'unknown'
);

create table public.shipments (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders (id) on delete cascade,
  tracking_number text not null unique,
  courier text not null,                   -- postex, blueex, mnp, tranzo, xps, unknown
  courier_company_raw text,                -- company as written in Shopify
  fulfillment_id bigint,
  fulfilled_at timestamptz,
  status public.shipment_status not null default 'booked',
  status_raw text,
  status_at timestamptz,                   -- when courier reported the current status
  delivered_at timestamptz,
  returned_at timestamptz,
  is_final boolean not null default false,
  manual_status public.shipment_status,    -- override, wins over courier status
  manual_note text,
  manual_by uuid references auth.users (id) on delete set null,
  manual_at timestamptz,
  last_checked_at timestamptz,
  next_check_at timestamptz not null default now(),
  check_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger shipments_touch before update on public.shipments
  for each row execute function public.touch_updated_at();
create index shipments_order_idx on public.shipments (order_id);
create index shipments_due_idx on public.shipments (next_check_at) where not is_final;
create index shipments_status_idx on public.shipments (status);
create index shipments_courier_idx on public.shipments (courier);

create table public.shipment_events (
  id bigint generated always as identity primary key,
  shipment_id bigint not null references public.shipments (id) on delete cascade,
  status public.shipment_status not null,
  status_raw text,
  event_at timestamptz,
  source text not null default 'courier',  -- courier | manual | settlement
  created_at timestamptz not null default now(),
  unique nulls not distinct (shipment_id, status_raw, event_at)
);
create index shipment_events_shipment_idx on public.shipment_events (shipment_id, event_at);

-- Courier rate cards (estimates when actual charges are not yet known)
create table public.courier_rate_cards (
  id bigint generated always as identity primary key,
  courier text not null,
  delivery_charge numeric(14,2) not null default 0,  -- forward charge incl. tax/fuel
  return_charge numeric(14,2) not null default 0,    -- extra charged on RTO
  cod_fee_percent numeric(6,3) not null default 0,   -- % of COD collected, if any
  effective_from date not null default '2000-01-01',
  created_at timestamptz not null default now(),
  unique (courier, effective_from)
);
insert into public.courier_rate_cards (courier, delivery_charge, return_charge) values
  ('postex', 200, 100), ('blueex', 200, 100), ('mnp', 200, 100),
  ('tranzo', 200, 100), ('xps', 200, 100), ('unknown', 200, 100);

-- ---------------------------------------------------------------------
-- Courier settlements (COD remittance statements)
-- ---------------------------------------------------------------------
create table public.settlement_batches (
  id bigint generated always as identity primary key,
  courier text not null,
  file_name text not null,
  file_sha256 text not null unique,         -- the same file can never be imported twice
  statement_ref text,                       -- courier's invoice / payment ref
  statement_date date,                      -- date the courier says it paid
  row_count integer not null default 0,
  total_cod numeric(14,2) not null default 0,
  total_charges numeric(14,2) not null default 0,
  total_net numeric(14,2) not null default 0,   -- expected bank deposit
  note text,
  imported_by uuid references auth.users (id) on delete set null,
  imported_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references auth.users (id) on delete set null
);
create index settlement_batches_courier_idx on public.settlement_batches (courier, statement_date);

create table public.settlement_lines (
  id bigint generated always as identity primary key,
  batch_id bigint not null references public.settlement_batches (id) on delete cascade,
  tracking_number text not null,
  order_ref text,
  line_kind text not null default 'delivered' check (line_kind in ('delivered', 'returned', 'adjustment')),
  cod_amount numeric(14,2) not null default 0,
  courier_charges numeric(14,2) not null default 0,  -- delivery + fuel + gst etc.
  other_deductions numeric(14,2) not null default 0,
  net_amount numeric(14,2) not null default 0,       -- cod - charges - deductions
  courier_status text,
  raw jsonb not null default '{}'::jsonb,
  unique (batch_id, tracking_number, line_kind)
);
create index settlement_lines_tracking_idx on public.settlement_lines (tracking_number);

-- ---------------------------------------------------------------------
-- Bank accounts & statements
-- ---------------------------------------------------------------------
create table public.bank_accounts (
  id bigint generated always as identity primary key,
  name text not null,
  bank text,
  account_hint text,                        -- last 4 digits only
  opening_balance numeric(14,2) not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.bank_imports (
  id bigint generated always as identity primary key,
  account_id bigint not null references public.bank_accounts (id) on delete restrict,
  file_name text not null,
  file_sha256 text not null,
  row_count integer not null default 0,
  date_from date,
  date_to date,
  imported_by uuid references auth.users (id) on delete set null,
  imported_at timestamptz not null default now(),
  unique (account_id, file_sha256)
);

create table public.bank_transactions (
  id bigint generated always as identity primary key,
  account_id bigint not null references public.bank_accounts (id) on delete restrict,
  import_id bigint references public.bank_imports (id) on delete cascade,
  txn_date date not null,
  description text not null default '',
  reference text,
  debit numeric(14,2) not null default 0 check (debit >= 0),
  credit numeric(14,2) not null default 0 check (credit >= 0),
  balance numeric(14,2),
  row_hash text not null,                  -- dedupe across overlapping statements
  category text,                           -- 'courier_settlement', 'expense', 'transfer', 'other'
  note text,
  created_at timestamptz not null default now(),
  unique (account_id, row_hash)
);
create index bank_transactions_date_idx on public.bank_transactions (account_id, txn_date);
create index bank_transactions_import_idx on public.bank_transactions (import_id);

-- A settlement batch is reconciled when matched to one or more bank credits.
create table public.settlement_bank_matches (
  id bigint generated always as identity primary key,
  batch_id bigint not null references public.settlement_batches (id) on delete cascade,
  bank_transaction_id bigint not null references public.bank_transactions (id) on delete cascade,
  amount numeric(14,2) not null,
  method text not null default 'manual' check (method in ('auto', 'manual')),
  matched_by uuid references auth.users (id) on delete set null,
  matched_at timestamptz not null default now(),
  unique (batch_id, bank_transaction_id)
);
create index sbm_txn_idx on public.settlement_bank_matches (bank_transaction_id);

-- ---------------------------------------------------------------------
-- Expenses
-- ---------------------------------------------------------------------
create table public.expense_categories (
  id bigint generated always as identity primary key,
  name text not null unique,
  kind text not null default 'operating' check (kind in ('marketing', 'operating', 'payroll', 'inventory', 'tax', 'other')),
  active boolean not null default true
);
insert into public.expense_categories (name, kind) values
  ('Facebook / Meta Ads', 'marketing'), ('Google Ads', 'marketing'), ('TikTok Ads', 'marketing'),
  ('Influencers', 'marketing'), ('Salaries', 'payroll'), ('Rent', 'operating'),
  ('Utilities & Internet', 'operating'), ('Software & Apps', 'operating'),
  ('Packaging Material', 'operating'), ('Bank Charges', 'operating'),
  ('Inventory Purchase', 'inventory'), ('Taxes', 'tax'), ('Miscellaneous', 'other');

create table public.expenses (
  id bigint generated always as identity primary key,
  expense_date date not null,
  category_id bigint not null references public.expense_categories (id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  vendor text,
  description text,
  payment_method text check (payment_method in ('bank', 'cash', 'card', 'wallet', 'other')),
  bank_transaction_id bigint references public.bank_transactions (id) on delete set null,
  -- spread an expense (e.g. annual software) over a period for P&L
  period_start date,
  period_end date,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_start is null or period_end >= period_start)
);
create trigger expenses_touch before update on public.expenses
  for each row execute function public.touch_updated_at();
create index expenses_date_idx on public.expenses (expense_date);
create index expenses_category_idx on public.expenses (category_id);
create index expenses_bank_txn_idx on public.expenses (bank_transaction_id);

-- ---------------------------------------------------------------------
-- Sync runs, alerts, audit
-- ---------------------------------------------------------------------
create table public.sync_runs (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('orders', 'tracking', 'alerts', 'bank_match')),
  trigger text not null default 'manual' check (trigger in ('manual', 'cron')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'ok', 'partial', 'error')),
  stats jsonb not null default '{}'::jsonb,
  error text
);
create index sync_runs_kind_idx on public.sync_runs (kind, started_at desc);

create table public.sync_state (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.alerts (
  id bigint generated always as identity primary key,
  kind text not null,
  severity text not null check (severity in ('info', 'warning', 'critical')),
  entity_type text not null,               -- order | shipment | settlement_batch | settlement_line | bank_transaction
  entity_id text not null,
  title text not null,
  detail text,
  amount numeric(14,2),
  status text not null default 'open' check (status in ('open', 'resolved', 'ignored')),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users (id) on delete set null,
  resolution_note text
);
-- one open alert per (kind, entity)
create unique index alerts_open_uniq on public.alerts (kind, entity_type, entity_id) where status = 'open';
create index alerts_status_idx on public.alerts (status, severity);

create table public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid,
  actor_email text,
  action text not null,                    -- INSERT | UPDATE | DELETE | custom
  table_name text,
  record_id text,
  old_data jsonb,
  new_data jsonb
);
create index audit_log_at_idx on public.audit_log (at desc);
create index audit_log_record_idx on public.audit_log (table_name, record_id);
