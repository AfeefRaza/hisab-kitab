// Courier tracking sync. Only checks shipments that are not final and are due
// (next_check_at <= now), so delivered/returned parcels are never re-tracked.
// Auth: finance+ user JWT, or pg_cron via x-cron-secret.
import { authenticate, handle, json, serviceClient } from "../_shared/http.ts";
import { type Courier, FINAL_STATUSES, trackMany, type TrackResult } from "../_shared/couriers.ts";

const BATCH_LIMIT = 600;

const NEXT_CHECK_MINUTES: Record<string, number> = {
  booked: 360, in_transit: 240, out_for_delivery: 120, delivery_failed: 180,
  return_in_transit: 360, unknown: 360,
};

Deno.serve(handle(async (req) => {
  const db = serviceClient();
  const caller = await authenticate(req, db, "finance");
  const body = await req.json().catch(() => ({})) as { shipment_ids?: number[] };

  const { data: run } = await db.from("sync_runs")
    .insert({ kind: "tracking", trigger: caller.kind === "cron" ? "cron" : "manual" })
    .select("id").single();

  let q = db.from("shipments").select("id, tracking_number, courier").limit(BATCH_LIMIT);
  if (body.shipment_ids?.length) {
    q = q.in("id", body.shipment_ids.slice(0, BATCH_LIMIT));
  } else {
    q = q.eq("is_final", false).lte("next_check_at", new Date().toISOString()).order("next_check_at");
  }
  const { data: due, error } = await q;
  if (error) throw new Error(error.message);

  const byCourier = new Map<Courier, { id: number; tracking_number: string }[]>();
  for (const s of due ?? []) {
    const list = byCourier.get(s.courier as Courier) ?? [];
    list.push(s);
    byCourier.set(s.courier as Courier, list);
  }

  const updates: Record<string, unknown>[] = [];
  const events: Record<string, unknown>[] = [];
  const perCourier: Record<string, { checked: number; ok: number; errors: number }> = {};

  await Promise.all([...byCourier.entries()].map(async ([courier, list]) => {
    const stat = { checked: list.length, ok: 0, errors: 0 };
    perCourier[courier] = stat;
    let results: Map<string, TrackResult>;
    try {
      const creds = courier === "mnp" || courier === "unknown"
        ? null
        : (await db.rpc("integration_get_secret", { p_provider: courier })).data;
      results = await trackMany(courier, list.map((s) => s.tracking_number), creds);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      results = new Map(list.map((s) => [s.tracking_number, { ok: false, error: msg } as TrackResult]));
    }
    for (const s of list) {
      const r = results.get(s.tracking_number) ?? { ok: false, error: "No response from courier" };
      if (r.ok) {
        stat.ok++;
        updates.push({
          id: s.id, status: r.status, status_raw: r.raw.slice(0, 300), status_at: r.at, error: null,
          next_minutes: FINAL_STATUSES.includes(r.status) ? 0 : (NEXT_CHECK_MINUTES[r.status] ?? 240),
        });
        for (const e of r.events.slice(-30)) {
          events.push({ shipment_id: s.id, status: e.status, status_raw: e.raw.slice(0, 300), event_at: e.at });
        }
      } else {
        stat.errors++;
        updates.push({ id: s.id, status: null, status_raw: null, status_at: null, error: r.error.slice(0, 300), next_minutes: 360 });
      }
    }
  }));

  let applied = 0;
  if (updates.length) {
    const { data, error: upErr } = await db.rpc("apply_tracking_updates", { p_updates: updates, p_events: events });
    if (upErr) throw new Error(`Saving tracking failed: ${upErr.message}`);
    applied = data ?? 0;
  }
  await db.rpc("refresh_alerts");
  for (const c of Object.keys(perCourier)) {
    if (perCourier[c].ok > 0) {
      await db.from("integrations").update({ last_sync_at: new Date().toISOString() }).eq("provider", c);
    }
  }

  const totalErr = Object.values(perCourier).reduce((a, b) => a + b.errors, 0);
  const stats = { due: due?.length ?? 0, applied, events: events.length, couriers: perCourier };
  await db.from("sync_runs").update({
    finished_at: new Date().toISOString(),
    status: totalErr === 0 ? "ok" : (totalErr < (due?.length ?? 0) ? "partial" : "error"),
    stats,
    error: totalErr ? `${totalErr} parcel(s) could not be tracked` : null,
  }).eq("id", run?.id);

  return json(req, stats);
}));
