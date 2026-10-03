// Triple Whale API (summary page). Docs: https://triplewhale.readme.io/reference/get-summary-page-data
// Response: { metrics: [{ id, title, values: { current, previous }, ... }] }
import { sleep } from "./http.ts";

export const AD_CHANNELS = ["facebookAds", "googleAds", "tiktokAds", "snapchatAds", "pinterestAds", "amazonAds"] as const;

export interface TripleWhaleCreds {
  api_key: string;
}

/** Spend per ad channel for one day (shop's currency). */
export async function fetchDaySpend(shopDomain: string, creds: TripleWhaleCreds, day: string, todayPkt: string): Promise<Record<string, number>> {
  // todayHour: hours elapsed today (1–25); 25 = full day for past dates
  const hour = day === todayPkt ? Math.min(24, new Date(Date.now() + 5 * 3600_000).getUTCHours() + 1) : 25;
  const body = JSON.stringify({ shopDomain, period: { start: day, end: day }, todayHour: hour });
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch("https://api.triplewhale.com/api/v2/summary-page/get-data", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": creds.api_key },
      body,
    });
    if (res.status === 429) {
      await sleep(Number(res.headers.get("retry-after") ?? 2) * 1000);
      continue;
    }
    const text = await res.text();
    if (res.status === 401 || res.status === 403) throw new Error(`Triple Whale rejected the API key (${res.status}). It needs the summary-page:read scope.`);
    if (!res.ok) throw new Error(`Triple Whale HTTP ${res.status}: ${text.slice(0, 200)}`);
    const data = JSON.parse(text);
    return parseSpend(data);
  }
  throw new Error("Triple Whale kept rate-limiting; try again later");
}

/** Extracts per-channel spend from a summary-page response. Exported for tests. */
export function parseSpend(data: any): Record<string, number> {
  const metrics: any[] = Array.isArray(data?.metrics) ? data.metrics : [];
  const out: Record<string, number> = {};
  for (const m of metrics) {
    const id = String(m?.id ?? m?.metricId ?? m?.metricName ?? "");
    if (!(AD_CHANNELS as readonly string[]).includes(id)) continue;
    const raw = m?.values?.current ?? m?.value ?? 0;
    const v = typeof raw === "number" ? raw : parseFloat(String(raw));
    out[id] = Number.isFinite(v) ? Math.round(v * 100) / 100 : 0;
  }
  return out;
}

export async function testTripleWhale(shopDomain: string, creds: TripleWhaleCreds): Promise<string> {
  const today = new Date(Date.now() + 5 * 3600_000).toISOString().slice(0, 10);
  const yesterday = new Date(Date.now() + 5 * 3600_000 - 86400_000).toISOString().slice(0, 10);
  const spend = await fetchDaySpend(shopDomain, creds, yesterday, today);
  const total = Object.values(spend).reduce((a, b) => a + b, 0);
  const parts = Object.entries(spend).filter(([, v]) => v > 0).map(([k, v]) => `${k.replace("Ads", "")} ${Math.round(v)}`);
  return `Connected — yesterday's ad spend ${Math.round(total)}${parts.length ? ` (${parts.join(", ")})` : ""}`;
}
