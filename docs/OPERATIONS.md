# Operations runbook

## Daily routine (10 minutes)

1. **Dashboard** — check *Cash still with couriers* and *Settled, awaiting bank*.
2. **Alerts** — work the critical ones first (COD mismatch, paid twice, settled-but-returned, deposit missing). Resolve with a note, or ignore with a reason.
3. **Settlements → Import statement** — upload every courier payment file you received. Review the preview issues before importing.
4. **Bank → Import statement** — upload the latest bank statement (overlaps are fine; duplicates are skipped). Auto-match runs immediately; match the rest manually.
5. **Expenses** — add ad spend and other costs (or record them from bank debits).

## Weekly

* **Settlements → Unsettled COD** — chase couriers for anything in the 15–30 and 30+ day buckets.
* **Shipments → Stuck** — escalate parcels with no movement.
* **Profitability** — review courier and city delivery rates; consider stopping COD to cities with low delivery rates.

## Importing courier statements

* Supported: `.xlsx`, `.csv`, and the HTML-based `.xls` exports BlueEx/XPS produce. Old binary `.xls`: open in Excel → *Save As* `.xlsx`.
* Columns are detected automatically (tracking, COD, charges, taxes/fuel, net, reference, status). If something is wrong, open **Column mapping** and fix it — totals update live.
* Returned parcels on a statement are imported as `returned` lines (COD 0, charges only).
* The same file can't be imported twice. If a file was wrong, open the statement and **Void** it (with a reason), then import the corrected file.

## Manual status overrides

Order → **Set status manually** when a courier's tracking is wrong (e.g. delivered but API says in transit). Overrides win over courier tracking until cleared and are audit-logged.

## Changing costs

* Product cost: best set as *Cost per item* in Shopify. Otherwise Settings → Costs & rules → product cost rules.
* Courier rates changed? Add a **new** rate card row with the new effective date — history stays correct.
* Packaging, tax, return-loss %, thresholds: Settings → Costs & rules (admin). All figures recalculate instantly.

## Troubleshooting

| Symptom | Check |
|---|---|
| Dashboard empty | Settings → Sync → recent runs. Shopify connected? Run *Backfill older orders* |
| Sync run `error` | Error text in Settings → Sync; usually expired/invalid credentials → Integrations → Test connection |
| Parcels show *Tracking error* | Courier credentials or courier API down; Shipments → *Refresh these* later |
| "Unknown parcel in statement" alert | Order is older than synced history → backfill from an earlier date, or the tracking number differs in Shopify |
| Statement not auto-matched | Amount differs (bank fee) or several equal deposits — match manually on Bank → Reconcile |
| A user can't see anything | They are `pending` — Settings → Users → give a role |

## Monitoring

* `sync_runs` (Settings → Sync) keeps 60 days of history.
* Supabase dashboard → Edge Functions → Logs for function errors; Database → Cron jobs for schedules (`hk-sync-orders`, `hk-sync-tracking`, `hk-reconcile`, `hk-prune-sync-runs`).
* Free-tier Supabase projects pause after a week without traffic; the cron jobs keep the project active.
