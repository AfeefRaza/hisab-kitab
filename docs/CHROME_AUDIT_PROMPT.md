# Hisab Kitab — full data-accuracy audit (prompt for Claude in Chrome)

You are auditing **Hisab Kitab**, a web app that answers "Where is our money?" for a Pakistani cash-on-delivery (COD) e-commerce business (store: HavenWear). It pulls orders from Shopify and parcel tracking and payments from couriers (PostEx, XPS, Tranzo, others), imports courier payout statements (CPRs) and bank statements, and reports revenue, cash with couriers, profit and alerts.

**Your goal:** find every bug, and above all every place where the app's **data is wrong, missing, duplicated, stale or misleading**. Prove each finding by checking the app against the original sources (Shopify admin, the PostEx merchant portal, the XPS portal) in other tabs. Then write a detailed audit report.

## Sites

| Site | URL | Use it for |
|---|---|---|
| Hisab Kitab (the app under audit) | https://afeefraza.github.io/hisab-kitab/ | Everything being audited |
| Shopify admin (source of truth for orders) | https://admin.shopify.com (HavenWear store) | Order counts, values, cancellations, refunds, fulfilments, tracking numbers |
| PostEx merchant portal (source of truth for PostEx parcels and payments) | the merchant portal I'm signed in to; if you can't find it, ask me | Parcel status history, delivery and return events, CPRs, charges, COD tax, reversals |
| PostEx public tracker | https://postex.pk/tracking | Status checks when the portal is unavailable |
| XPS portal | the XPS portal I'm signed in to; ask me for the link if needed | XPS parcels, status, charges, payouts |

## Rules (follow strictly)

1. **Read-only.** Do not create, edit, import, delete, void, match, unmatch, resolve or ignore anything in any of these sites. Don't change settings, rate cards or integrations, and don't run "Sync". If a check really needs a write (for example, refreshing one order's tracking), ask me first and wait for my yes.
2. **Never type passwords, API keys or tokens.** If a site asks you to sign in, stop and ask me to sign in myself. Don't solve CAPTCHAs.
3. **Protect customer data.** Don't copy customer names, phone numbers or addresses into the report. Refer to orders by order number (for example `#haven33684`) and tracking number only.
4. Don't download files unless I approve. Do your reconciliation on screen.
5. **Separate proven from suspected.** Label every finding **Confirmed** (you saw both sides disagree, with numbers), **Likely** (strong evidence, not fully proven) or **Unverified** (you couldn't access the source). Never present an estimate as a fact.
6. Record the exact date and time of every comparison. The app and the sources change as syncs run.

## What the app is supposed to do (use this to judge correctness)

**Pages:** Dashboard ("Where is our money?"), Orders, Shipments, Settlements, Bank, Expenses, Profitability, Alerts, Settings (costs, sync, users, audit log) and Integrations. There's a **store switcher** in the top bar. Make sure you're on **HavenWear**, and check that switching stores never shows another store's data.

**The period picker** (top bar) filters by *order placement date, Pakistan time*. Settlements and the "Unsettled COD" report are **all-time** and are labelled that way.

**Each order has exactly one "money state":**

| Money state | Meaning |
|---|---|
| unfulfilled | not shipped |
| booked | label created |
| in_transit | with the courier, including failed attempts and "Waiting for Delivery" |
| with_courier | delivered, COD collected, not yet in any courier payout statement |
| settled_unbanked | in a courier statement (CPR), not matched to a bank deposit |
| in_bank | statement matched to a bank credit |
| prepaid | paid online |
| returning / returned | on the way back / back with the merchant |
| lost | lost by the courier |
| cancelled | cancelled before delivery |

**Delivery recognition (critical).** Revenue and COD receivable count only after an explicit delivery event such as "Delivered to Customer". "Waiting for Delivery", "Enroute for Delivery", attempts and "Delivery Under Review" are **not** deliveries. "En Route to Merchant Warehouse" means the parcel is **returning**.

**PostEx sometimes pays COD upfront** in a CPR while the parcel is still at its warehouse, then reverses the payment if the parcel comes back. So a CPR line alone doesn't prove delivery. A parcel that was paid and later returned should raise a **"Settled but returned"** alert.

**Courier cost per parcel:**
- Priority: the actual charge from the courier statement, then the courier's API fee, then the rate-card estimate.
- The PostEx rate card is Rs106 delivery plus **4% COD withholding tax on the COD amount**.
- The "High courier charge" alert must compare like with like, with tax included on both sides.

**Profit per delivered order:** revenue − product cost (COGS) − courier cost (including COD tax) − packaging. Returns lose shipping and packaging. Net profit = contribution − expenses (including Triple Whale ad spend and recurring expenses, prorated by day).

**Bank:** a deposit is called "missing" only when the imported bank statements cover that payout's window. Otherwise the app shows "bank data missing / unverified". (No bank statement may have been imported yet. If so, note it as a verification gap, not as missing money.)

**Recently fixed** (on 17 Oct 2026, after an earlier audit). Verify each fix holds:
- `#haven33684` should be returned, Rs0 revenue.
- `#haven33633` should be returning or returned, with no courier receivable.
- `#haven33968` should be delivered only if PostEx shows a delivery event.
- `#haven33317` should not have a false high-charge alert.

## Audit plan (work through all of it)

### A. Order intake: app vs Shopify

1. For the current month to date, and separately for last month: compare the app's order count and order value with Shopify's (Analytics → Reports → Orders / Total sales, or the Orders list filtered by date). Check the timezone is Pakistan time on both sides.
2. Compare day by day for the current month. List every day that doesn't match and find the specific orders responsible.
3. Pick 25 orders across states (delivered, returned, cancelled, prepaid, edited/refunded, multi-item, multiple fulfilments). For each, compare these fields between the app's order detail and Shopify:
   - order number and total
   - current total after edits and refunds
   - payment method (COD vs prepaid)
   - cancellation
   - line items and quantities
   - fulfilment tracking number and courier
4. Look for orders that are missing, duplicated, wrongly COD/prepaid, cancelled but counted, or carrying the wrong tracking number or courier.

### B. Parcel status: app vs PostEx and XPS

1. In Orders, filter Courier = PostEx and review every money state. Take a sample of **at least 40 PostEx parcels**:
   - every parcel the app shows as with_courier or delivered in the last 30 days
   - 10 returned
   - 10 in transit/booked older than 7 days
   - every parcel named in an open alert

   For each one, open the PostEx portal (or public tracker) and compare the latest status, its timestamp and the full event history with the app's order timeline.
2. Flag:
   - "delivered" in the app without a delivery event at PostEx
   - delivered or returned at PostEx but still in transit in the app
   - returns not reflected in the app
   - wrong event dates
   - parcels the app stopped tracking
3. Do the same for **XPS** (and Tranzo if it has parcels). Integrations shows parcel counts per courier. If XPS shows "connected" but the app has no XPS parcels while the XPS portal does, that is a **data completeness bug**: list the missing tracking numbers and their Shopify orders.
4. Check the Integrations page: last sync time, parcel counts, and any connected-but-never-synced warnings.

### C. Courier money: CPRs, charges and receivables vs PostEx

1. Settlements → Statements: compare the app's PostEx statements with the CPRs in the PostEx portal, one CPR at a time:
   - CPR number and date
   - parcel count
   - total COD, charges and net amount
   - which parcels are in it

   Find missing CPRs, duplicated CPRs, and parcels in a CPR that the app didn't link to an order.
2. For 15 parcels, compare each charge component (delivery fee, COD tax, reversal fee, other deductions) with PostEx. Is the app's courier cost right? Is the 4% COD tax applied to the correct base?
3. "Unsettled COD" report and Dashboard → "Cash still with couriers": recompute it from PostEx (delivered parcels not yet in any CPR) and compare totals by courier and by age bucket. Also check that clicking a report row shows the same parcels the row counts.
4. "Settled but returned" alerts: for each one, confirm at PostEx that the parcel was paid and then returned, and whether PostEx has already reversed the payment in a later CPR.
5. "High courier charge" alerts: take 15. For each, work out the correct expected charge from the rate card plus COD tax and judge whether the alert is genuine. Note any pattern, such as a second PostEx price tier (Rs159) or return fees the rate card doesn't include.

### D. Profit and dashboard maths

1. For 10 delivered and 5 returned orders, recompute contribution by hand from the order-detail figures (revenue, COGS, courier cost, packaging) and compare with the app.
2. On the Dashboard, for the current month: check that the P&L lines add up (revenue − COGS − courier − packaging = contribution; contribution − expenses = net profit). Check that the money-state tiles sum to the order totals, and that the numbers match Profitability and the Orders page filtered the same way.
3. Expenses: confirm recurring expenses (salaries, rent) are prorated correctly for partial months, that category amounts add up to the total, and that ad spend matches Triple Whale if you can open it (read-only).
4. Product costs: flag orders using the default Rs850 cost or "missing cost", and say how much of COGS is estimated rather than actual.

### E. Alerts, bank and everything else

1. For every alert type, take up to 5 alerts and check against the sources whether each one is true. Also look for problems that exist but have no alert, such as parcels stuck for more than 7 days, delivered COD unpaid for more than 10 days, or COD mismatches.
2. Bank: if there's no bank data, confirm the app says so clearly everywhere (Dashboard, Settlements, Alerts) and doesn't claim money is missing.
3. Exercise the UI and note anything broken:
   - global search (order number, tracking number, phone)
   - filters and sorting on every list
   - CSV export (don't download unless I approve; just check the button works)
   - period picker presets and the ◀ ▶ arrows
   - the store switcher
   - order timeline
   - mobile width
   - empty, loading and error states

   Also note wrong labels, confusing wording and console errors.
4. Settings → Audit log: are real changes recorded? Is it free of noise?

## Report format (write the report in chat as Markdown)

1. **Executive summary.** A trust verdict for each area (Shopify intake, parcel status, courier cash, profit, alerts, bank), the top 5 issues, and the total amount of money affected (confirmed vs. at risk).
2. **Method.** What you checked, sample sizes, timestamps, and which sources you could and couldn't open.
3. **Reconciliation tables.** App vs source for each check above, with the differences.
4. **Findings**, most severe first. For each finding give:
   - ID and title
   - severity: Critical / High / Medium / Low
   - status: Confirmed / Likely / Unverified
   - where in the app
   - evidence (order and tracking numbers, the app's value vs the source's value, timestamp)
   - expected vs actual behaviour
   - financial impact in Rs (proven vs exposure)
   - likely cause
   - recommended fix
   - an acceptance check a developer can run to prove it's fixed
5. **Order lifecycle traces.** 6–8 orders followed from Shopify → courier → CPR → bank, showing where each one is right or wrong.
6. **Configuration issues.** Rate cards, product costs, missing integrations (for example a courier you ship with but haven't connected) and missing bank data: things the owner must fix rather than the developer.
7. **What's still unverified** and which source would settle it.

Start by opening the app and the Dashboard on HavenWear, then work through sections A to E in order. Keep a running list of findings as you go. Ask me whenever you need a sign-in, a missing link or permission for any action that changes data.
