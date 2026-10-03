// Incremental Shopify → Supabase order sync.
// Orders are fetched oldest-updated first, so the saved cursor (last processed
// updated_at) is always a safe resume point, even when a run hits its time budget.
// Auth: finance+ user JWT, or pg_cron via x-cron-secret.
import { authenticate, handle, HttpError, json, serviceClient } from "../_shared/http.ts";
import { detectCourier } from "../_shared/couriers.ts";
import { mapOrder, ORDERS_QUERY, ORDERS_QUERY_NO_PII, ShopifyClient } from "../_shared/shopify.ts";

const TIME_BUDGET_MS = 110_000;
const DEFAULT_LOOKBACK_DAYS = 90;

Deno.serve(handle(async (req) => {
  const started = Date.now();
  const db = serviceClient();
  const caller = await authenticate(req, db, "finance");
  const body = await req.json().catch(() => ({})) as { from?: string };

  const { data: integ } = await db.from("integrations").select("config, enabled").eq("provider", "shopify").single();
  const { data: secret } = await db.rpc("integration_get_secret", { p_provider: "shopify" });
  if (!integ?.enabled || !secret) throw new HttpError(400, "Shopify is not connected. Open Settings → Integrations.");

  const client = new ShopifyClient(integ.config, secret);

  const { data: run } = await db.from("sync_runs")
    .insert({ kind: "orders", trigger: caller.kind === "cron" ? "cron" : "manual" })
    .select("id").single();

  const { data: state } = await db.from("sync_state").select("value").eq("key", "orders_cursor").maybeSingle();
  let since: string;
  if (body.from && /^\d{4}-\d{2}-\d{2}$/.test(body.from)) {
    since = new Date(`${body.from}T00:00:00+05:00`).toISOString();
  } else if (state?.value?.updated_at) {
    since = state.value.updated_at;
  } else {
    since = new Date(Date.now() - DEFAULT_LOOKBACK_DAYS * 86400_000).toISOString();
  }

  let query = ORDERS_QUERY;
  let cursor: string | null = null;
  let hasNext = true;
  let pages = 0;
  let orderCount = 0;
  let shipmentCount = 0;
  let lastUpdated: string | null = null;
  let errorMsg: string | null = null;

  try {
    while (hasNext && Date.now() - started < TIME_BUDGET_MS) {
      let data: any;
      try {
        data = await client.query(query, { cursor, query: `updated_at:>='${since}'` });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (query === ORDERS_QUERY && /ACCESS_DENIED|protected customer|not approved/i.test(msg)) {
          console.warn("No access to customer PII fields; continuing without name/phone");
          query = ORDERS_QUERY_NO_PII;
          continue;
        }
        throw e;
      }
      const conn = data.orders;
      const mapped = (conn.nodes as any[]).map(mapOrder);
      pages++;

      if (mapped.length > 0) {
        const { error: oErr } = await db.from("orders").upsert(mapped.map((m) => m.order), { onConflict: "id" });
        if (oErr) throw new Error(`Saving orders failed: ${oErr.message}`);

        const lines = mapped.flatMap((m) => m.lines).filter((l) => l.id != null);
        if (lines.length) {
          const { error: lErr } = await db.from("order_lines").upsert(lines, { onConflict: "id" });
          if (lErr) throw new Error(`Saving order lines failed: ${lErr.message}`);
        }

        const shipments = mapped.flatMap((m) =>
          m.shipments.map((s) => ({
            order_id: m.order.id,
            tracking_number: s.tracking_number,
            courier: detectCourier(s.tracking_number, s.company),
            courier_company_raw: s.company,
            fulfillment_id: s.fulfillment_id,
            fulfilled_at: s.fulfilled_at,
          }))
        );
        if (shipments.length) {
          // Only fulfilment columns are written; courier status columns are untouched on conflict.
          const { error: sErr } = await db.from("shipments").upsert(shipments, { onConflict: "tracking_number" });
          if (sErr) throw new Error(`Saving shipments failed: ${sErr.message}`);
        }

        orderCount += mapped.length;
        shipmentCount += shipments.length;
        lastUpdated = mapped[mapped.length - 1].order.updated_at_shop as string;
      }

      hasNext = conn.pageInfo.hasNextPage;
      cursor = conn.pageInfo.endCursor;
    }
  } catch (e) {
    errorMsg = e instanceof Error ? e.message : String(e);
  }

  if (lastUpdated) {
    await db.from("sync_state").upsert({ key: "orders_cursor", value: { updated_at: lastUpdated }, updated_at: new Date().toISOString() });
  }
  const finishedAll = !hasNext && !errorMsg;
  if (finishedAll) {
    await db.from("integrations").update({ last_sync_at: new Date().toISOString() }).eq("provider", "shopify");
    await db.rpc("refresh_alerts");
  }
  const stats = { orders: orderCount, shipments: shipmentCount, pages, since, has_more: hasNext && !errorMsg };
  await db.from("sync_runs").update({
    finished_at: new Date().toISOString(),
    status: errorMsg ? (orderCount > 0 ? "partial" : "error") : "ok",
    stats,
    error: errorMsg,
  }).eq("id", run?.id);

  if (errorMsg && orderCount === 0) throw new HttpError(502, errorMsg);
  return json(req, { ...stats, error: errorMsg });
}));
