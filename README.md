# Hisab Kitab

**Where is our money?** — the internal financial operating system for a Pakistani COD e-commerce business.

Hisab Kitab follows every order and every rupee from Shopify, through the courier, through the courier's COD settlement, into the bank, and onto the P&L:

```
Not shipped → Booked → In transit → Delivered (cash with courier) → Settled by courier → In bank ✅
                                   ↘ Returning → Returned (shipping + packaging lost)
```

It replaces the earlier Lovable/React prototype (see [docs/ANALYSIS.md](docs/ANALYSIS.md) for the audit and [docs/REBUILD_NOTES.md](docs/REBUILD_NOTES.md) for what was fixed).

## Features

| Area | What you get |
|---|---|
| **Executive dashboard** | Money by stage (where every rupee is), P&L, net profit, delivery rate, cash with couriers, unbanked settlements, daily trend |
| **Orders** | Server-side search/filter/sort, CSV export, per-order profit, **complete financial timeline** (order → shipment → tracking → courier statement → bank deposit) |
| **Shipments** | In-transit, stuck and returning parcels with ageing; on-demand tracking refresh; manual status override (audited) |
| **Courier settlements** | Import PostEx / BlueEx / M&P / Tranzo / XPS statements (xlsx, csv, courier .xls/HTML), auto column mapping, server-side preview of mismatches, atomic import, duplicate-file protection, void with reason, unsettled-COD ageing by courier |
| **Bank** | Import any bank CSV/xlsx statement, de-duplication across overlapping statements, automatic matching of courier deposits, manual matching, record debits as expenses |
| **Expenses** | Categories (marketing, payroll, rent…), spread an expense over a period, linked to bank transactions |
| **Profitability** | By courier, city and product: delivery rate, revenue, courier cost, contribution, margin |
| **Alerts / reconciliation centre** | COD unsettled too long, COD mismatch, paid twice, settled-but-returned, bank deposit missing, stuck parcels, courier overcharges, unknown parcels, tracking errors — auto-resolve when fixed |
| **Integrations** | Admin page: Shopify + couriers — Configure / Test connection / Reconnect / Disconnect; secrets stored in Supabase Vault, masked, never shown again |
| **Security** | Login required, roles (pending / viewer / finance / admin), RLS on every table, audit log of every financial change |
| **Automation** | Shopify sync every 30 min (only changed orders), courier tracking hourly (only open parcels), bank matching + alerts every 2 h |
| **Install as an app** | Progressive Web App — add to home screen on iPhone/Android, works like a native app |

## Repository layout

```
app/                    Flutter app (web/PWA; Android & iOS projects included)
  lib/core/             config, formatting, theme, global state
  lib/data/             Supabase API layer + domain models
  lib/import/           settlement & bank statement parsers (pure Dart, unit-tested)
  lib/features/         screens
  lib/ui/               shell (navigation, search, sync) + shared widgets
  test/                 unit tests
supabase/
  migrations/           database schema, RLS, finance engine, reconciliation, cron
  functions/            Edge Functions (Deno): sync-orders, sync-tracking, integrations
  tests/                SQL regression test for the finance engine
docs/                   analysis, architecture, deployment, security, operations
.github/workflows/      CI (analyze + tests) and GitHub Pages deployment
```

## Quick start (local development)

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) 3.47+, optionally [Deno](https://deno.com) 2.x and the [Supabase CLI](https://supabase.com/docs/guides/cli).

```bash
cp .env.example app/.env          # then fill SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY
cd app
flutter pub get
flutter run -d chrome --dart-define-from-file=.env
```

Tests:

```bash
cd app && flutter analyze && flutter test
cd supabase/functions && deno test --allow-env --allow-net=jsr.io _shared/
```

The SQL finance-engine test ([supabase/tests/finance_engine_test.sql](supabase/tests/finance_engine_test.sql)) runs inside a transaction and rolls back; paste it into the Supabase SQL editor.

## Deployment

Pushing to `main` runs CI and deploys the web app to GitHub Pages. Full setup — new Supabase project, migrations, edge functions, cron, auth URLs, repository variables — is in **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**.

## Configuration & secrets

* Client build config (public only): `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `APP_ENV` — see [.env.example](.env.example).
* Shopify and courier credentials are **not** environment variables. An admin enters them in **Settings → Integrations**; they are tested server-side and stored encrypted in Supabase Vault.
* Never commit `.env` files, service-role keys or API tokens. `.gitignore` blocks them.

Details: [docs/SECURITY.md](docs/SECURITY.md).

## Documentation

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — data model, money states, profit formula, sync design
* [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — setting up Supabase, GitHub Pages, environments
* [docs/OPERATIONS.md](docs/OPERATIONS.md) — day-to-day runbook, imports, troubleshooting
* [docs/SECURITY.md](docs/SECURITY.md) — auth, roles, RLS, secrets
* [docs/ANALYSIS.md](docs/ANALYSIS.md) / [docs/REBUILD_NOTES.md](docs/REBUILD_NOTES.md) — legacy audit and fixes
