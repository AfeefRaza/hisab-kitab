// Courier payment (CPR) sync. For delivered/returned parcels whose payment is
// not complete yet, fetches the courier's financial fields and payment status,
// stores the raw responses, then builds settlement batches (one per CPR) in SQL.
// Currently PostEx (the only courier with a payment-status API).
// Auth: finance+ user JWT, or pg_cron via x-cron-secret.
import { authenticate, chunk, handle, json, mapWithConcurrency, serviceClient } from "../_shared/http.ts";

const BATCH_LIMIT = 400;
const POSTEX = "https://api.postex.pk/services/integration/api/order";
// Fields PostEx returns on tracking responses that describe money
const FIN_KEYS = [
  "invoicePayment", "transactionFee", "transactionTax", "upfrontPayment", "reservePayment",
  "balancePayment", "reversalFee", "reversalTax", "transactionStatus", "orderRefNumber",
];

async function getJson(url: string, token: string): Promise<{ status: number; body: any }> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 20000);
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

Deno.serve(handle(async (req) => {
  const db = serviceClient();
  const caller = await authenticate(req, db, "finance");
  const body = await req.json().catch(() => ({})) as { shipment_ids?: number[] };

  const { data: secret } = await db.rpc("integration_get_secret", { p_provider: "postex" });
  if (!secret?.token) return json(req, { skipped: "PostEx not connected" });
  const token = secret.token as string;

  const { data: run } = await db.from("sync_runs")
    .insert({ kind: "payments", trigger: caller.kind === "cron" ? "cron" : "manual" })
    .select("id").single();

  let q = db.from("shipments").select("id, tracking_number, courier_financials").eq("courier", "postex").limit(BATCH_LIMIT);
  if (body.shipment_ids?.length) {
    q = q.in("id", body.shipment_ids.slice(0, BATCH_LIMIT));
  } else {
    q = q.eq("payment_complete", false).in("status", ["delivered", "returned"])
      .lte("payment_next_check_at", new Date().toISOString()).order("payment_next_check_at");
  }
  const { data: due, error } = await q;
  if (error) throw new Error(error.message);
  const rows = due ?? [];

  // 1) financial fields via bulk tracking (only for parcels we don't have them for)
  const fin = new Map<string, Record<string, unknown>>();
  const needFin = rows.filter((r) => !r.courier_financials).map((r) => r.tracking_number);
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

  // 2) payment status per parcel
  let errors = 0, settled = 0;
  const updates = await mapWithConcurrency(rows, 6, async (r) => {
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
    const hasFin = !!(fin.get(r.tracking_number) ?? r.courier_financials);
    const complete = p?.settle === true && !!cpr && hasFin;
    if (p?.settle === true) settled++;
    return { id: r.id, financials: fin.get(r.tracking_number) ?? null, payment: p, complete, next_hours: p?.settle ? 24 : 12 };
  });

  let applied = 0, built: unknown = null;
  if (updates.length) {
    const { data, error: e1 } = await db.rpc("apply_courier_payments", { p_rows: updates });
    if (e1) throw new Error(`Saving payments failed: ${e1.message}`);
    applied = data ?? 0;
    const { data: b, error: e2 } = await db.rpc("build_api_settlements");
    if (e2) throw new Error(`Building settlements failed: ${e2.message}`);
    built = b;
    await db.rpc("auto_match_settlements");
    await db.rpc("refresh_alerts");
  }

  const stats = { checked: rows.length, applied, settled, errors, built };
  await db.from("sync_runs").update({
    finished_at: new Date().toISOString(),
    status: errors === 0 ? "ok" : (errors < rows.length ? "partial" : "error"),
    stats,
    error: errors ? `${errors} payment lookups failed` : null,
  }).eq("id", run?.id);
  return json(req, stats);
}));
