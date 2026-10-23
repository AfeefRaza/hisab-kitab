// PostEx courier money sync.
// 1) Reads PostEx's own order list (get-all-order) for a booking-date window. It carries
//    every parcel's current status, COD paid (reservePayment), weight-tier fee and return
//    (reversal) fee — so figures are refreshed on every run instead of frozen at the first
//    look, and parcels booked directly in the PostEx portal are picked up too.
// 2) For delivered/returned parcels not fully paid yet, reads the payment status (CPR number).
// 3) Rebuilds the CPR statements from those figures (build_api_settlements).
// Body: { from?: 'YYYY-MM-DD' } widens the window (backfill); default is the last 60 days.
// Auth: finance+ user JWT, or pg_cron via x-cron-secret.
import { authenticate, chunk, handle, json, mapWithConcurrency, resolveStore, storeClient } from "../_shared/http.ts";

const BATCH_LIMIT = 400;
const DEFAULT_WINDOW_DAYS = 60;
const POSTEX = "https://api.postex.pk/services/integration/api/order";
// Money/status fields only — the list also carries customer details, which we don't store here
const FIN_KEYS = [
  "invoicePayment", "transactionFee", "transactionTax", "upfrontPayment", "reservePayment",
  "balancePayment", "reversalFee", "reversalTax", "transactionStatus", "orderRefNumber", "transactionDate",
];

async function getJson(url: string, token: string, timeoutMs = 30000): Promise<{ status: number; body: any }> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { headers: { token }, signal: ctrl.signal });
    const text = await res.text();
    let body: any = null;
    try { body = JSON.parse(text); } catch { /* ignore */ }
    return { status: res.status, body };
  } finally {
    clearTimeout(t);
  }
}

function pickFin(dist: any): Record<string, unknown> | null {
  if (!dist) return null;
  const out: Record<string, unknown> = {};
  for (const k of FIN_KEYS) if (dist[k] !== undefined) out[k] = dist[k];
  return Object.keys(out).length ? out : null;
}

/** Courier status is final for money purposes: delivered or back with the merchant. */
const finalFin = (f: any) => /^(delivered|return)$/i.test(String(f?.transactionStatus ?? "").trim());

const pktDay = (offsetDays = 0) => new Date(Date.now() + 5 * 3600_000 + offsetDays * 86400_000).toISOString().slice(0, 10);

/** PostEx order list in 10-day slices (the API filters by booking date). */
async function listOrders(token: string, from: string, to: string): Promise<{ items: any[]; errors: number }> {
  const slices: [string, string][] = [];
  for (let d = Date.parse(from); d <= Date.parse(to); d += 10 * 86400_000) {
    const end = Math.min(d + 9 * 86400_000, Date.parse(to));
    slices.push([new Date(d).toISOString().slice(0, 10), new Date(end).toISOString().slice(0, 10)]);
  }
  const items: any[] = [];
  let errors = 0;
  await mapWithConcurrency(slices, 2, async ([s, e]) => {
    const { status, body } = await getJson(`${POSTEX}/v1/get-all-order?orderStatusId=0&startDate=${s}&endDate=${e}`, token, 60000);
    if (status !== 200 || !Array.isArray(body?.dist)) {
      errors++;
      return;
    }
    items.push(...body.dist);
  });
  return { items, errors };
}

Deno.serve(handle(async (req) => {
  const started = Date.now();
  const body = await req.json().catch(() => ({})) as { shipment_ids?: number[]; store_id?: string; from?: string };
  const storeId = await resolveStore(req, body);
  const db = storeClient(storeId);
  const caller = await authenticate(req, db, "finance");

  const { data: secret } = await db.rpc("integration_get_secret", { p_provider: "postex" });
  if (!secret?.token) return json(req, { skipped: "PostEx not connected" });
  const token = secret.token as string;

  const { data: run } = await db.from("sync_runs")
    .insert({ store_id: storeId, kind: "payments", trigger: caller.kind === "cron" ? "cron" : "manual" })
    .select("id").single();

  let fatal: string | null = null;
  const stats: Record<string, unknown> = {};
  try {
    // ---- 1) fresh figures for every parcel in the window ---------------------------------
    const to = pktDay(0);
    const from = body.from && /^\d{4}-\d{2}-\d{2}$/.test(body.from) ? body.from : pktDay(-DEFAULT_WINDOW_DAYS);
    const list = body.shipment_ids?.length ? { items: [], errors: 0 } : await listOrders(token, from, to);
    const finByTn = new Map<string, { fin: Record<string, unknown>; item: any }>();
    for (const item of list.items) {
      const tn = String(item?.trackingNumber ?? "").trim().toUpperCase();
      const fin = pickFin(item);
      if (tn && fin) finByTn.set(tn, { fin, item });
    }

    // Our PostEx parcels (paged — PostgREST returns at most 1000 rows per request)
    const known = new Map<string, { id: number; fin: unknown }>();
    for (let page = 0; ; page++) {
      const { data, error } = await db.from("shipments").select("id, tracking_number, courier_financials")
        .eq("store_id", storeId).eq("courier", "postex").order("id").range(page * 1000, page * 1000 + 999);
      if (error) throw new Error(error.message);
      for (const s of data ?? []) known.set(s.tracking_number, { id: s.id, fin: s.courier_financials });
      if ((data ?? []).length < 1000) break;
    }

    const finUpdates: { id: number; financials: Record<string, unknown> }[] = [];
    const discovered: Record<string, unknown>[] = [];
    for (const [tn, { fin, item }] of finByTn) {
      const k = known.get(tn);
      if (k) {
        if (JSON.stringify(k.fin) !== JSON.stringify(fin)) finUpdates.push({ id: k.id, financials: fin });
      } else if (!/^unbooked$/i.test(String(item.transactionStatus ?? ""))) {
        // Booked directly in PostEx (replacement, exchange, manual order) — not in any Shopify fulfilment
        discovered.push({
          tracking_number: tn,
          order_ref: String(item.orderRefNumber ?? "").slice(0, 120),
          booked_at: item.transactionDate ?? null,
          financials: fin,
        });
      }
    }
    let refreshed = 0, added = 0;
    for (const part of chunk(finUpdates, 500)) {
      const { data, error } = await db.rpc("apply_courier_financials", { p_rows: part });
      if (error) throw new Error(`Saving courier figures failed: ${error.message}`);
      refreshed += data ?? 0;
    }
    if (discovered.length) {
      const { data, error } = await db.rpc("upsert_courier_parcels", { p_courier: "postex", p_rows: discovered });
      if (error) throw new Error(`Adding PostEx-only parcels failed: ${error.message}`);
      added = data ?? 0;
    }
    Object.assign(stats, { window: { from, to }, listed: list.items.length, list_errors: list.errors, figures_refreshed: refreshed, postex_only_added: added });

    // ---- 2) payment status (CPR) for parcels whose money is final ------------------------
    let q = db.from("shipments").select("id, tracking_number, courier_financials").eq("store_id", storeId).eq("courier", "postex").limit(BATCH_LIMIT);
    if (body.shipment_ids?.length) {
      q = q.in("id", body.shipment_ids.slice(0, BATCH_LIMIT));
    } else {
      q = q.eq("payment_complete", false)
        .or("status.in.(delivered,returned,return_in_transit),courier_financials->>transactionStatus.ilike.delivered,courier_financials->>transactionStatus.ilike.return")
        .lte("payment_next_check_at", new Date().toISOString()).order("payment_next_check_at");
    }
    const { data: due, error } = await q;
    if (error) throw new Error(error.message);
    const rows = due ?? [];

    // Parcels outside the list window: refresh their figures from bulk tracking
    const fin = new Map<string, Record<string, unknown>>();
    const needFin = rows.filter((r) => !finalFin(r.courier_financials)).map((r) => r.tracking_number);
    await mapWithConcurrency(chunk(needFin, 50), 3, async (batch) => {
      const { status, body } = await getJson(`${POSTEX}/v1/track-bulk-order?TrackingNumbers=${encodeURIComponent(batch.join(","))}`, token);
      if (status !== 200) return;
      for (const item of body?.dist ?? []) {
        const d = item?.trackingResponse ?? item;
        const tn = String(d?.trackingNumber ?? "").toUpperCase();
        const f = pickFin(d);
        if (tn && f) fin.set(tn, f);
      }
    });

    let errors = 0, settled = 0;
    const updates = await mapWithConcurrency(rows, 6, async (r) => {
      if (Date.now() - started > 120_000) return null; // time budget; the rest is picked up next run
      const current = fin.get(r.tracking_number) ?? r.courier_financials;
      const { status, body } = await getJson(`${POSTEX}/v1/payment-status/${encodeURIComponent(r.tracking_number)}`, token);
      if (status !== 200 || !body?.dist) {
        errors++;
        return { id: r.id, financials: fin.get(r.tracking_number) ?? null, payment: null, complete: false, next_hours: 12 };
      }
      const p = Array.isArray(body.dist) ? body.dist[0] : body.dist;
      // Live PostEx responses use cpr1 / cpr1Date (docs say cprNumber_1); accept both.
      const cpr = p?.cpr1 ?? p?.cprNumber_1;
      if (p && !p.cpr1 && p.cprNumber_1) {
        p.cpr1 = p.cprNumber_1;
        p.cpr1Date ??= p.settlementDate ?? p.upfrontPaymentDate;
      }
      // Complete only once paid AND the courier's own figures are final (fees no longer change)
      const complete = p?.settle === true && !!cpr && finalFin(current);
      if (p?.settle === true) settled++;
      return { id: r.id, financials: fin.get(r.tracking_number) ?? null, payment: p, complete, next_hours: p?.settle ? 24 : 12 };
    });
    const payUpdates = updates.filter((u) => u !== null);

    let applied = 0;
    if (payUpdates.length) {
      const { data, error: e1 } = await db.rpc("apply_courier_payments", { p_rows: payUpdates });
      if (e1) throw new Error(`Saving payments failed: ${e1.message}`);
      applied = data ?? 0;
    }
    // Always rebuild: idempotent, and picks up refreshed figures for already-paid parcels
    const { data: built, error: e2 } = await db.rpc("build_api_settlements");
    if (e2) throw new Error(`Building settlements failed: ${e2.message}`);
    await db.rpc("auto_match_settlements");
    await db.rpc("refresh_alerts");
    Object.assign(stats, { checked: rows.length, applied, settled, errors, built });
  } catch (e) {
    fatal = e instanceof Error ? e.message : String(e);
  }

  const errs = Number(stats.errors ?? 0) + Number(stats.list_errors ?? 0);
  await db.from("sync_runs").update({
    finished_at: new Date().toISOString(),
    status: fatal ? "error" : (errs === 0 ? "ok" : "partial"),
    stats,
    error: fatal ?? (errs ? `${errs} PostEx request(s) failed` : null),
  }).eq("id", run?.id);
  if (fatal) return json(req, { ...stats, error: fatal }, 500);
  return json(req, stats);
}));
