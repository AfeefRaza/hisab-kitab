// Daily ad spend per channel from Triple Whale → automatic marketing expenses.
// Default: refresh the last 3 days (PKT). Body { from: 'YYYY-MM-DD' } backfills (max 400 days).
// Auth: finance+ user JWT, or pg_cron via x-cron-secret.
import { authenticate, handle, HttpError, json, mapWithConcurrency, serviceClient } from "../_shared/http.ts";
import { AD_CHANNELS, fetchDaySpend } from "../_shared/triplewhale.ts";

const pktDay = (offsetDays = 0) => new Date(Date.now() + 5 * 3600_000 + offsetDays * 86400_000).toISOString().slice(0, 10);

Deno.serve(handle(async (req) => {
  const started = Date.now();
  const db = serviceClient();
  const caller = await authenticate(req, db, "finance");
  const body = await req.json().catch(() => ({})) as { from?: string; to?: string };

  const { data: integ } = await db.from("integrations").select("config, enabled").eq("provider", "triplewhale").single();
  const { data: secret } = await db.rpc("integration_get_secret", { p_provider: "triplewhale" });
  if (!integ?.enabled || !secret?.api_key || !integ.config?.shop_domain) {
    if (caller.kind === "cron") return json(req, { skipped: "Triple Whale not connected" });
    throw new HttpError(400, "Triple Whale is not connected. Open Settings → Integrations.");
  }

  const today = pktDay();
  const to = body.to && /^\d{4}-\d{2}-\d{2}$/.test(body.to) ? body.to : today;
  let from = body.from && /^\d{4}-\d{2}-\d{2}$/.test(body.from) ? body.from : pktDay(-2);
  const minFrom = new Date(Date.parse(to) - 400 * 86400_000).toISOString().slice(0, 10);
  if (from < minFrom) from = minFrom;
  const days: string[] = [];
  for (let d = Date.parse(from); d <= Date.parse(to); d += 86400_000) days.push(new Date(d).toISOString().slice(0, 10));

  const { data: run } = await db.from("sync_runs")
    .insert({ kind: "adspend", trigger: caller.kind === "cron" ? "cron" : "manual" })
    .select("id").single();

  const rows: { day: string; channel: string; amount: number }[] = [];
  const failed: string[] = [];
  let lastError: string | null = null;
  const done = new Set<string>();
  await mapWithConcurrency(days, 3, async (day) => {
    if (Date.now() - started > 120_000) return; // time budget; the rest is picked up next run
    try {
      const spend = await fetchDaySpend(integ.config.shop_domain, secret, day, today);
      for (const ch of AD_CHANNELS) rows.push({ day, channel: ch, amount: spend[ch] ?? 0 });
      done.add(day);
    } catch (e) {
      failed.push(day);
      lastError = e instanceof Error ? e.message : String(e);
    }
  });

  let applied: unknown = null;
  if (rows.length) {
    const { data, error } = await db.rpc("apply_ad_spend", { p_rows: rows });
    if (error) throw new Error(`Saving ad spend failed: ${error.message}`);
    applied = data;
    await db.from("integrations").update({ last_sync_at: new Date().toISOString() }).eq("provider", "triplewhale");
  }

  const total = rows.reduce((a, r) => a + r.amount, 0);
  const stats = { from, to, days: days.length, synced_days: done.size, failed_days: failed.length, total_spend: Math.round(total), applied };
  await db.from("sync_runs").update({
    finished_at: new Date().toISOString(),
    status: failed.length === 0 && done.size === days.length ? "ok" : (done.size > 0 ? "partial" : "error"),
    stats,
    error: lastError,
  }).eq("id", run?.id);
  if (done.size === 0 && lastError) throw new HttpError(502, lastError);
  return json(req, stats);
}));
