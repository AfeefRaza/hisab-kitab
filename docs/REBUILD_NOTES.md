# Rebuild notes — how each legacy issue was resolved

References are to the numbered findings in [ANALYSIS.md](ANALYSIS.md).

| # | Legacy problem | Resolution in the rebuild |
|---|---|---|
| 1 | Settlements never loaded (RLS vs no login) | Real login + roles; all reads authenticated |
| 2 | BlueEx blank "Amount Received" treated as fully paid | Net = courier's figure if present, else COD − charges − deductions; unit test covers it |
| 3 | `paid_at` = upload time | Statement date entered per batch; bank date from matched deposit |
| 4 | Re-uploads overwrote history | Immutable batches, SHA-256 duplicate-file block, void-with-reason, audit log |
| 5 | No PostEx settlement import | Generic column-mapped importer handles PostEx and any courier |
| 6 | M&P/XPS parsers ignored status / net | Net column respected; returns imported as `returned` lines with COD 0 |
| 7 | Revenue = original total incl. tax, no refunds | Revenue = `current_total − tax` (after edits/refunds), recognised on delivery |
| 8 | Flat courier charge | Actual charges from statements; effective-dated rate cards as fallback |
| 9 | Costs lost on refresh | Persisted settings, cost rules, rate cards, expenses |
| 10 | Cancelled counted as returned | Separate `cancelled` status and money state; unit test |
| 11 | Courier error texts counted as in transit | Errors stored as `check_error`, never as a status; unit test |
| 12 | Full COGS counted as return loss | Configurable return inventory-loss % (default 0 — stock comes back) |
| 13 | Only first tracking number; 10 line items max | All fulfilments/tracking numbers; 30 lines/order; cancelled fulfilments skipped |
| 14 | Refresh silently changed date range | Single global period state; sync never changes the period |
| 15 | Mixed UTC / PKT date windows | Order date computed in Asia/Karachi in the database |
| 16 | Pages overwrote each other's data | Persisted data; each page queries its own view |
| 17 | Upload toast "undefined records" | Import returns explicit counts |
| 18 | No status dates for Tranzo/XPS | First-seen time of a new status is stored as its date |
| 19 | Shopify API 2023-10 | Configurable, default 2026-07 |
| Sec | Edge functions open to the internet | JWT/role checks or Vault cron secret; anon has no grants |
| Perf | Live re-fetch of every order + parcel per page view | Incremental sync + tracking only for open parcels; pages read indexed tables |
