# Hisab Kitab — Analysis of the Existing Lovable App

_Analyzed 2026-10-03, before any rebuild work. Source: the Lovable export in this folder._

## 1. Architecture as built

| Layer | What exists |
|---|---|
| Client | React 18 + Vite + shadcn/ui SPA, 7 routes (Dashboard, City, Courier, Settlements, Returns, In-Transit, 404). Global `OrderContext` holds orders in memory. |
| Backend | Lovable Cloud Supabase project `dhintdzzeewuyrphxtrq` (not in the owner's Supabase org). |
| Edge functions | `shopify-orders` (fetch + enrich, 880 lines), `process-settlement` (courier file import), `update-order-status` (manual override). |
| Database | 2 tables only: `order_settlements` (keyed by tracking number), `order_status_overrides` (keyed by order name). |
| Integrations | Shopify Admin GraphQL `2023-10`; couriers BlueEx, M&P, Tranzo, PostEx, XPS (credentials in Supabase function secrets). |

**Data flow:** every page load calls `shopify-orders`, which pages through *all* Shopify orders in the date range, then live-queries *every* tracking number at every courier, then returns the whole list to the browser. Nothing about orders, shipments or statuses is stored. All money calculations happen in the browser.

**Courier detection** is by tracking-number prefix: `503` BlueEx, `559` M&P, `T00` Tranzo, 14 digits starting `2x` PostEx, `KI`/`12…` XPS.

## 2. Features present
- Dashboard KPIs: revenue (delivered only), costs, net profit, margin, delivery/return %, return units & sourcing loss, unfulfilled, in-transit, errors, AOV, marketing cost/unit, ROAS; daily/weekly trend charts.
- Manual cost inputs: marketing (lump sum), tax %, delivery & return charge per parcel, flyer, polybag; keyword-based sourcing-cost rules (fallback when Shopify unit cost is missing).
- Order table with status filter, search, sort, CSV export, manual status override.
- Settlements: upload courier payment files (BlueEx, XPS, M&P, Tranzo), match to delivered orders, paid vs pending.
- Courier analytics, city analytics, return analysis (RTO vs in-return), in-transit with "stuck" detection (>2 days no update).

## 3. Bugs found

### Financial accuracy (highest priority)
1. **Settlements likely never load.** `order_settlements` RLS allows only `authenticated` users (migration `20260116…`), but the app has no login, so the browser reads with the anon key and gets zero rows. Every delivered order then shows as **pending**, so collected money looks uncollected.
2. **BlueEx parser can mark unpaid parcels as paid.** `paidAmount = parseFloat(amountReceived) || orderAmount`: a blank or 0 "Amount Received" falls back to the full COD amount. `getVal('amount')` also matches the *first* header containing "amount", which can be the wrong column.
3. **`paid_at` is the upload time**, not the settlement date, and pending rows get a `paid_at` too, so cash-flow timing is wrong.
4. **Re-uploads overwrite history.** Upsert on `tracking_number` lets an older or partial file flip a *paid* parcel back to *pending*. There's no batch record, no file hash and no audit trail.
5. **No PostEx settlement parser**, although PostEx is an active courier, so PostEx COD can never be reconciled.
6. **M&P parser** treats every row as paid (`COD − charges`) whatever its status. **XPS** ignores the file's own Net Amount for delivered rows.
7. **Revenue = Shopify `totalPrice`**: it includes the shipping fee charged to the customer and taxes, and ignores refunds, edits, discounts after the fact, partial COD and prepaid vs COD.
8. **Courier charges are a single flat input** (Rs 200 / Rs 100), even though actual charges are present in the settlement files.
9. **All cost settings live only in browser memory** (marketing, packaging, tax, sourcing rules). They reset on every refresh, and marketing is a lump sum not tied to the selected period.
10. **"Cancelled" is classified as Returned** (`isReturnedStatus` matches `cancel`), so cancelled orders incur return charges and packaging loss. Picking "Cancelled" in the override menu does the same.
11. **Courier error texts fall into "In Transit"**: e.g. `Status Unknown`, M&P free-text messages and `Tracking Details Not Found` (the error check doesn't match "details not found").
12. **Return "loss" counts full sourcing cost** of returned goods, although RTO stock normally returns to inventory. This overstates losses; it should be a configurable policy.
13. Only the **first fulfillment and first tracking number** are read; `lineItems(first: 10)` silently truncates bigger orders; cancelled Shopify orders aren't excluded.

### Functional
14. **Refresh / Try Again** call `fetchOrders()` with no dates, so data silently switches to "last 2 months" while the date picker still shows the old range.
15. **Inconsistent date windows**: Dashboard sends PKT (`+05:00`) bounds, while Settlements and In-Transit send bare `yyyy-MM-dd` (UTC), so order sets are off by up to 5 hours at day edges.
16. **Shared global order list**: every page refetches with its own range and overwrites the others.
17. Upload toast reads `data.processedCount` (undefined); the function returns `totalRecords`.
18. Tranzo and XPS return no status date, so "stuck" detection falls back to fulfillment date and is meaningless for them.
19. Shopify API version `2023-10` is far outside Shopify's support window.

## 4. Security review
- **Critical:** all three edge functions have `verify_jwt = false` and no auth check. Anyone who knows the project URL can download every order (order numbers, cities, amounts), overwrite settlement records and change order statuses.
- No user login, roles or audit log in the app.
- CORS `*` on all functions.
- `.env` is not in `.gitignore` (it only holds the publishable key, so low risk, but it should be ignored).
- Changing any API credential requires editing secrets inside Lovable; there's no in-app configuration.

## 5. Performance bottlenecks
- Full Shopify re-pagination (100/page, 500 ms sleep between pages) **plus** a live courier call for every parcel, on **every page view**. Large date ranges risk edge-function timeouts (150 s wall clock).
- M&P, Tranzo and XPS are queried one parcel at a time (concurrency 8). Delivered and returned parcels are re-tracked forever although their status is final.
- `select('*')` on the full settlements table, and unpaginated tables rendering thousands of rows.

## 6. Rebuild direction (summary)
Persist everything in Supabase and sync incrementally: orders by `updated_at`, and courier tracking only for non-final shipments, on a schedule. Calculate money server-side in SQL views as an order-level **money-state ledger**: pending → in transit → delivered (collected by courier) → in a settlement batch → matched to a bank deposit; or returned / cancelled; plus costs and profit. Require login with roles and RLS on every table. Store credentials server-side in Supabase Vault, managed from an Integrations page that has test / mask / replace actions. Rebuild the client in Flutter.
