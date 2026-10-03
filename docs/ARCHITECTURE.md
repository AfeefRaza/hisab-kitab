# Architecture

## Overview

```
┌──────────────┐   HTTPS (publishable key + user JWT)    ┌──────────────────────────────────────┐
│ Flutter PWA  │ ─────────────────────────────────────▶ │ Supabase                              │
│ GitHub Pages │   PostgREST: tables/views/RPCs (RLS)    │  Postgres: data + finance engine (SQL)│
└──────────────┘   Edge Functions: sync, integrations    │  Vault: integration secrets           │
                                                          │  pg_cron → Edge Functions (scheduled) │
                                                          └───────┬───────────────┬──────────────┘
                                                                  │               │
                                                          Shopify Admin    PostEx / BlueEx / M&P /
                                                          GraphQL API      Tranzo / XPS tracking APIs
```

Design principles:

1. **The database is the source of truth.** Orders, shipments and tracking events are persisted. The legacy app re-fetched every order and every parcel from external APIs on every page view; now pages read pre-synced data in milliseconds.
2. **Money is calculated in one place: SQL views.** `v_order_finance` → `v_order_profit` → `finance_summary()`. The client only displays. A single formula means dashboard, order detail, CSV and profitability always agree.
3. **Secrets never reach the client.** Integrations are managed through an admin-only edge function; secrets live in Vault and are readable only by `service_role`.
4. **Everything financial is auditable.** Imports are immutable batches (void, never edit); every change to settings, costs, matches, expenses, roles and manual statuses is in `audit_log`.

## Data model

| Table | Purpose |
|---|---|
| `orders`, `order_lines` | Mirror of Shopify (incl. refunds/edits via `current_total`, `current_quantity`) |
| `shipments`, `shipment_events` | One row per tracking number; full status history; manual override fields |
| `settlement_batches`, `settlement_lines` | Courier COD statements; one batch per file (SHA-256 unique) |
| `bank_accounts`, `bank_imports`, `bank_transactions` | Bank statements; rows de-duplicated by content hash |
| `settlement_bank_matches` | Which bank credit(s) paid which courier statement |
| `expenses`, `expense_categories` | Operating costs, optionally spread across a period |
| `product_cost_rules`, `courier_rate_cards` | Fallback product cost; courier charge estimates (effective-dated) |
| `app_settings` | Packaging, tax, return policy, reconciliation thresholds |
| `integrations` | Non-secret config + masked hints + Vault secret id |
| `alerts`, `audit_log`, `sync_runs`, `sync_state`, `profiles` | Operations, audit, sync cursor, users/roles |

## Money states

Every order is in exactly one state (`v_order_finance.money_state`):

| State | Meaning | Money is… |
|---|---|---|
| `unfulfilled` | Not shipped | expected |
| `booked` | Label created | expected |
| `in_transit` | With courier (incl. failed attempts) | on the road |
| `with_courier` | **Delivered**, cash collected, not in any statement | at the courier |
| `settled_unbanked` | In a courier statement, deposit not matched | in transfer |
| `in_bank` | Statement matched to bank credit(s) | ✅ ours |
| `prepaid` | Paid online | via gateway |
| `returning` / `returned` | Return in transit / back with us | lost (shipping, packaging) |
| `lost` | Lost by courier | claim |
| `cancelled` | Cancelled before delivery | none |

## Profit formula (per order, recognised when final)

```
Delivered:  contribution = (current_total − tax) − COGS − courier cost − packaging
Returned:   contribution = −(courier cost [delivery + return] + packaging* + COGS × loss%)
Lost:       contribution = −(courier cost + packaging + 100% COGS)
Not final:  contribution = NULL (not yet earned or lost)

Net profit (period) = Σ contribution − expenses (allocated to period, excl. inventory purchases) − tax
```

* **COGS**: Shopify "Cost per item" → else product cost rule (variant → SKU → keyword → default).
* **Courier cost**: actual charges from imported statements when present, otherwise the effective rate card.
* **Packaging**: flyer per parcel + polybag per unit (*on returns configurable).
* Periods are by **order date in Pakistan time** (Asia/Karachi), so cohorts are stable.

Validated by [supabase/tests/finance_engine_test.sql](../supabase/tests/finance_engine_test.sql) against hand-calculated figures.

## Sync design

| Job | Schedule | Strategy |
|---|---|---|
| `sync-orders` | every 30 min | Shopify GraphQL, `updated_at >= cursor`, sorted by `UPDATED_AT` ascending, 25 orders/page, 110 s budget, resumable. Cursor saved in `sync_state`. Backfill: Settings → Sync |
| `sync-tracking` | hourly | Only shipments with `is_final = false` and `next_check_at <= now()`, ≤ 600 per run, grouped per courier (PostEx bulk 50/call, BlueEx batch 25/call). Next check 2–6 h depending on status; delivered/returned/cancelled/lost are never checked again |
| `sync-payments` | every 3 h | PostEx `v1/payment-status/{tn}` for delivered/returned parcels until their CPR is known. `build_api_settlements()` creates one settlement batch per CPR (`source = 'api'`): delivered line = COD − fee − tax, returned line = −(reversal fee + tax). Parcels already in a manually imported statement are skipped |
| reconcile | every 2 h | `auto_match_settlements()` + `refresh_alerts()` (also run after each import) |

pg_cron calls the edge functions with a random secret kept in Vault (`hk_cron_secret`).

## Reconciliation

* **Settlement import**: client parses the file (xlsx/csv/HTML-xls), auto-maps columns, sends rows to `preview_settlement()` to show unknown parcels / COD mismatches / duplicates, then `import_settlement()` inserts the batch atomically. Same file twice is rejected (SHA-256).
* **Bank matching**: a statement is matched to a bank credit only when unambiguous — amount within tolerance, date within window, exactly one candidate on both sides. Everything else is matched manually on the Bank page.
* **Alerts** are regenerated idempotently: open alerts are upserted, alerts whose condition cleared auto-resolve, ignored alerts never come back.
