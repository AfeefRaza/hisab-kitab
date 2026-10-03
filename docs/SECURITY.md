# Security

## Authentication & roles

* Supabase Auth, email + password. Every screen requires a session; the router redirects to `/login` otherwise.
* Roles in `profiles.role` (enum, ordered): `pending` < `viewer` < `finance` < `admin`.
  * **pending** — signed up, sees nothing until approved.
  * **viewer** — read-only access to all financial data.
  * **finance** — imports, bank matching, expenses, manual statuses, cost rules, rate cards, sync.
  * **admin** — plus settings, integrations, users, audit log.
* The first account becomes admin (bootstrap). Users can't change their own role; only admins change roles (DB trigger `guard_profile_role`).

## Database

* **RLS is enabled on every table.** Policies call `has_role()` (security definer, `search_path=''`).
* `anon` has no table or function privileges. All functions have `EXECUTE` revoked from `PUBLIC` and granted explicitly.
* Write RPCs (`import_settlement`, `import_bank_statement`, `set_shipment_status`, `void_settlement_batch`, …) are `SECURITY DEFINER` with an explicit `assert_role('finance')`, so imports are atomic and validated server-side.
* Views use `security_invoker = true` so RLS applies to whoever queries them.
* Supabase security advisor: no findings for anon access. "Signed-in users can execute SECURITY DEFINER function" warnings are expected for the role-checked RPCs above.

## Secrets

| Secret | Where it lives | Who can read it |
|---|---|---|
| Shopify / courier credentials | Supabase **Vault** (encrypted), referenced by `integrations.vault_secret_id` | `service_role` only (edge functions) via `integration_get_secret()` |
| Cron secret (`hk_cron_secret`) | Vault | `service_role` |
| Service-role key | Supabase-managed env of edge functions | never leaves Supabase |
| Supabase URL + publishable key | Flutter build (`--dart-define`) | public by design |

* The Integrations page never receives saved secrets — only masked hints like `••••a1b2`. To replace a secret, type a new one; blank keeps the old one.
* Credentials are **tested before they are saved**; failing credentials are not activated.
* `.gitignore` blocks `.env*` (except `.env.example`), keys, keystores and service-account files.

## Edge functions

* `integrations` — gateway JWT verification on, plus admin-role check.
* `sync-orders`, `sync-tracking` — accept a valid user JWT with finance role, or the Vault cron secret (min 32 chars, constant secret compared in Postgres). Unauthenticated requests get 401.
* CORS can be locked to the Pages origin with the function secret `ALLOWED_ORIGINS`. Auth is bearer-token based (no cookies), so `*` does not enable CSRF.

## Data protection

* Bank accounts store only the last 4 digits.
* Customer names/phones come from Shopify only if the Shopify app has protected-customer-data access; otherwise sync continues without them.
* `audit_log` records who changed what (before/after JSON) for settings, cost rules, rate cards, imports, matches, expenses, categories, integrations metadata, roles and manual statuses.

## Reporting a problem

Rotate any exposed credential immediately in the provider (Shopify/courier portal), then Reconfigure it in Settings → Integrations.
