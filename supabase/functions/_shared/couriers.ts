// Courier detection, status normalisation and tracking API clients.
// Pure helpers (detectCourier, normalizeStatus, parseCourierDate) are unit
// tested in couriers_test.ts.
import { chunk, mapWithConcurrency, sleep } from "./http.ts";

export type ShipmentStatus =
  | "booked" | "in_transit" | "out_for_delivery" | "delivery_failed" | "delivered"
  | "return_in_transit" | "returned" | "cancelled" | "lost" | "unknown";

export const FINAL_STATUSES: ShipmentStatus[] = ["delivered", "returned", "cancelled", "lost"];

export interface TrackEvent {
  status: ShipmentStatus;
  raw: string;
  at: string | null;
}

export type TrackResult =
  | { ok: true; status: ShipmentStatus; raw: string; at: string | null; events: TrackEvent[] }
  | { ok: false; error: string };

export type Courier = "postex" | "blueex" | "mnp" | "tranzo" | "xps" | "unknown";

/** Detect courier from Shopify's tracking company first, then tracking number shape. */
export function detectCourier(trackingNumber: string, company?: string | null): Courier {
  const c = (company ?? "").toLowerCase();
  if (c) {
    if (c.includes("postex") || c.includes("post ex")) return "postex";
    if (c.includes("blue")) return "blueex";
    if (c.includes("m&p") || c.includes("mnp") || c.includes("m & p") || c.includes("mulphilog") || c.includes("muller")) return "mnp";
    if (c.includes("tranzo")) return "tranzo";
    if (c.includes("xps")) return "xps";
  }
  const tn = trackingNumber.trim().replace(/\s+/g, "").toUpperCase();
  if (tn.startsWith("503")) return "blueex";
  if (tn.startsWith("559")) return "mnp";
  if (tn.startsWith("T00")) return "tranzo";
  if (/^2\d{13}$/.test(tn)) return "postex";
  if (/^KI/.test(tn) || (/^12\d+$/.test(tn) && tn.length !== 14)) return "xps";
  return "unknown";
}

/** Map any courier status text to our status set. Returns null when the text is an error, not a status. */
export function normalizeStatus(text: string | null | undefined): ShipmentStatus | null {
  const t = (text ?? "").toLowerCase().replace(/\s+/g, " ").trim();
  if (!t) return null;
  if (/(not found|invalid|error|no record|unauthori[sz]ed|credentials)/.test(t)) return null;

  if (/(return|\brto\b|reversed)/.test(t)) {
    if (/(returned to (shipper|origin|vendor|merchant|seller|client)|return(ed)? delivered|rto delivered|delivered to (shipper|origin|vendor|merchant|seller)|received at origin|return received|returned$|^returned to)/.test(t)) {
      return "returned";
    }
    return "return_in_transit";
  }
  if (/cancel/.test(t)) return "cancelled";
  if (/\blost\b|missing|damaged/.test(t)) return "lost";
  if (/(refused|rejected|not accepted|undelivered|un-delivered|consignee not available|not available|wrong address|incomplete address|attempt|under review|shipper request|on hold|\bhold\b|no response|failed)/.test(t)) {
    return "delivery_failed";
  }
  if (/(out for delivery|out-for-delivery|\bofd\b|on route for delivery|with rider)/.test(t)) return "out_for_delivery";
  if (/deliver/.test(t)) return "delivered";
  if (/(unbooked|booked|order created|^created|pending pickup|ready for pickup|label printed|at merchant)/.test(t)) return "booked";
  if (/(transit|warehouse|dispatch|arrived|departed|received at|picked|hub|on the way|shipped|forwarded|sorting|on route|package on route)/.test(t)) {
    return "in_transit";
  }
  return "unknown";
}

/** Parse courier date strings (ISO, "dd/mm/yyyy hh:mm", "yyyy-mm-dd hh:mm:ss"). Assumes PKT when no zone. */
export function parseCourierDate(value: string | null | undefined): string | null {
  if (!value) return null;
  const v = String(value).trim();
  if (!v) return null;
  // ISO with zone
  if (/^\d{4}-\d{2}-\d{2}T.*(Z|[+-]\d{2}:?\d{2})$/.test(v)) {
    const d = new Date(v);
    return isNaN(d.getTime()) ? null : d.toISOString();
  }
  // yyyy-mm-dd[ T]hh:mm[:ss]
  let m = v.match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
  if (m) return pkt(+m[1], +m[2], +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0));
  // dd/mm/yyyy or dd-mm-yyyy [hh:mm[:ss] [AM|PM]]
  m = v.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?)?/i);
  if (m) {
    let h = +(m[4] ?? 0);
    const ap = (m[7] ?? "").toLowerCase();
    if (ap === "pm" && h < 12) h += 12;
    if (ap === "am" && h === 12) h = 0;
    return pkt(+m[3], +m[2], +m[1], h, +(m[5] ?? 0), +(m[6] ?? 0));
  }
  // "03 Oct 2026 14:20" etc. — only accept text that contains a 4-digit year
  if (!/\b(19|20)\d{2}\b/.test(v)) return null;
  const d = new Date(v + (/(gmt|utc|[+-]\d{2}:?\d{2})/i.test(v) ? "" : " GMT+0500"));
  if (isNaN(d.getTime())) return null;
  const y = d.getUTCFullYear();
  return y >= 2000 && y <= 2100 ? d.toISOString() : null;
}

function pkt(y: number, mo: number, d: number, h: number, mi: number, s: number): string | null {
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const ms = Date.UTC(y, mo - 1, d, h - 5, mi, s);
  return isNaN(ms) ? null : new Date(ms).toISOString();
}

function latest(events: TrackEvent[]): TrackEvent | null {
  if (events.length === 0) return null;
  const dated = events.filter((e) => e.at);
  if (dated.length === 0) return events[events.length - 1];
  return dated.reduce((a, b) => (b.at! >= a.at! ? b : a));
}

function result(events: TrackEvent[], fallbackRaw?: string | null): TrackResult {
  const last = latest(events);
  if (last) return { ok: true, status: last.status, raw: last.raw, at: last.at, events };
  const s = normalizeStatus(fallbackRaw);
  if (s) return { ok: true, status: s, raw: fallbackRaw!, at: null, events: [] };
  return { ok: false, error: fallbackRaw || "No status returned" };
}

function ev(raw: string | null | undefined, at: string | null | undefined, override?: ShipmentStatus | null): TrackEvent | null {
  const status = override ?? normalizeStatus(raw);
  if (!status || !raw) return null;
  return { status, raw: String(raw).trim(), at: parseCourierDate(at ?? null) };
}

async function fetchJson(url: string, init: RequestInit, timeoutMs = 20000): Promise<{ status: number; body: any; text: string }> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...init, signal: ctrl.signal });
    const text = await res.text();
    let body: any = null;
    try { body = JSON.parse(text); } catch { /* not json */ }
    return { status: res.status, body, text };
  } finally {
    clearTimeout(timer);
  }
}

// ----------------------------------------------------------------------------
// PostEx — bulk endpoint, newest history entry by date (fixes the legacy bug
// that used the oldest entry and the wrong date field)
// ----------------------------------------------------------------------------
const POSTEX_CODES: Record<string, ShipmentStatus> = {
  "0001": "booked", "0002": "returned", "0003": "in_transit", "0004": "out_for_delivery",
  "0005": "delivered", "0006": "returned", "0007": "returned", "0008": "delivery_failed",
  "0013": "delivery_failed",
};

function postexResult(dist: any): TrackResult {
  const history: any[] = Array.isArray(dist?.transactionStatusHistory) ? dist.transactionStatusHistory : [];
  const events = history
    .map((h) => {
      const raw = h.transactionStatusMessage ?? h.transactionStatus ?? "";
      let code = POSTEX_CODES[String(h.transactionStatusMessageCode ?? "")] ?? null;
      if (code === "returned" && /transit|route/i.test(raw)) code = "return_in_transit";
      // "Un-Assigned By Me" = merchant cancelled the booking: no shipment, no charge
      if (/un-?assigned|cancel/i.test(raw)) code = "cancelled";
      return ev(raw || code, h.updatedAt ?? h.transactionDateTime ?? h.createdAt, code);
    })
    .filter((e): e is TrackEvent => !!e);
  return result(events, dist?.transactionStatus);
}

export async function trackPostEx(numbers: string[], creds: { token: string }): Promise<Map<string, TrackResult>> {
  const out = new Map<string, TrackResult>();
  const headers = { "Content-Type": "application/json", token: creds.token };
  await mapWithConcurrency(chunk(numbers, 50), 3, async (batch) => {
    try {
      const url = `https://api.postex.pk/services/integration/api/order/v1/track-bulk-order?TrackingNumbers=${encodeURIComponent(batch.join(","))}`;
      const { status, body } = await fetchJson(url, { headers });
      if (status === 401 || status === 403) {
        batch.forEach((n) => out.set(n, { ok: false, error: `PostEx auth failed (${status})` }));
        return;
      }
      const items: any[] = Array.isArray(body?.dist) ? body.dist : [];
      for (const item of items) {
        const dist = item?.trackingResponse ?? item;
        const tn = String(dist?.trackingNumber ?? "").toUpperCase();
        if (tn) out.set(tn, postexResult(dist));
      }
    } catch (e) {
      console.error("PostEx bulk failed", e);
    }
  });
  const missing = numbers.filter((n) => !out.has(n));
  await mapWithConcurrency(missing, 6, async (n) => {
    try {
      const { status, body } = await fetchJson(`https://api.postex.pk/services/integration/api/order/v1/track-order/${encodeURIComponent(n)}`, { headers });
      out.set(n, status === 200 && body?.dist ? postexResult(body.dist) : { ok: false, error: body?.statusMessage ?? `PostEx HTTP ${status}` });
    } catch (e) {
      out.set(n, { ok: false, error: `PostEx request failed: ${e instanceof Error ? e.message : e}` });
    }
  });
  return out;
}

export async function testPostEx(creds: { token: string }): Promise<string> {
  const { status, body } = await fetchJson("https://api.postex.pk/services/integration/api/order/v2/get-operational-city", {
    headers: { token: creds.token },
  });
  if (status === 401 || status === 403) throw new Error("PostEx rejected the API token");
  if (status >= 400) throw new Error(`PostEx returned HTTP ${status}: ${body?.statusMessage ?? ""}`);
  const n = Array.isArray(body?.dist) ? body.dist.length : 0;
  return `PostEx token valid (${n} operational cities)`;
}

// ----------------------------------------------------------------------------
// BlueEx — batched V4 tracking, falls back to single lookups
// ----------------------------------------------------------------------------
function blueexResult(s: any): TrackResult {
  const history: any[] = Array.isArray(s?.cnDetail) ? s.cnDetail : [];
  const events = history
    .map((h) => ev(h.statusmessage, [h.statusdate, h.statustime].filter(Boolean).join(" ")))
    .filter((e): e is TrackEvent => !!e);
  return result(events, s?.Details?.desc);
}

export async function trackBlueEx(numbers: string[], creds: { username: string; password: string }): Promise<Map<string, TrackResult>> {
  const out = new Map<string, TrackResult>();
  const headers = { "Content-Type": "application/json", Authorization: `Basic ${btoa(`${creds.username}:${creds.password}`)}` };
  const url = "https://apis.blue-ex.com/api/V4/GetTracking";
  const single = async (n: string) => {
    try {
      const { body, status } = await fetchJson(url, { method: "POST", headers, body: JSON.stringify({ ShipmentNumbers: [n] }) });
      const match = (body?.processed_shipments ?? []).find((s: any) => String(s.shipmentnumber).toUpperCase() === n);
      out.set(n, match ? blueexResult(match) : { ok: false, error: body?.message ?? `BlueEx HTTP ${status}` });
    } catch (e) {
      out.set(n, { ok: false, error: `BlueEx request failed: ${e instanceof Error ? e.message : e}` });
    }
  };
  for (const batch of chunk(numbers, 25)) {
    try {
      const { status, body } = await fetchJson(url, { method: "POST", headers, body: JSON.stringify({ ShipmentNumbers: batch }) });
      if (status === 200 && Array.isArray(body?.processed_shipments)) {
        for (const s of body.processed_shipments) {
          const tn = String(s.shipmentnumber ?? "").toUpperCase();
          if (tn) out.set(tn, blueexResult(s));
        }
      } else if (status === 401 && !String(body?.message ?? "").toLowerCase().includes("shipment")) {
        batch.forEach((n) => out.set(n, { ok: false, error: `BlueEx auth failed: ${body?.message ?? status}` }));
        continue;
      }
      const missing = batch.filter((n) => !out.has(n));
      if (missing.length) await mapWithConcurrency(missing, 4, single);
      await sleep(150);
    } catch (e) {
      console.error("BlueEx batch failed", e);
      await mapWithConcurrency(batch, 4, single);
    }
  }
  return out;
}

// ----------------------------------------------------------------------------
// M&P — public tracking endpoint, one parcel per call
// ----------------------------------------------------------------------------
export async function trackMnp(numbers: string[]): Promise<Map<string, TrackResult>> {
  const out = new Map<string, TrackResult>();
  await mapWithConcurrency(numbers, 8, async (n) => {
    try {
      const url = `https://tracking.mulphilog.com.pk/api/CNTracking?consignment=${encodeURIComponent(n)}&id=4`;
      const { status, body } = await fetchJson(url, {});
      const first = Array.isArray(body) ? body[0] : null;
      if (status !== 200 || !first || String(first.isSuccess) !== "true") {
        out.set(n, { ok: false, error: first?.message ?? `M&P HTTP ${status}` });
        return;
      }
      const details: any[] = first.tracking_Details?.[0]?.CNTrackingDetail ?? [];
      const events = details
        .map((d) => ev(d.TrackingStatus, d.TransDate))
        .filter((e): e is TrackEvent => !!e);
      out.set(n, result(events));
    } catch (e) {
      out.set(n, { ok: false, error: `M&P request failed: ${e instanceof Error ? e.message : e}` });
    }
  });
  return out;
}

// ----------------------------------------------------------------------------
// Tranzo
// ----------------------------------------------------------------------------
export async function trackTranzo(numbers: string[], creds: { api_token: string }): Promise<Map<string, TrackResult>> {
  const out = new Map<string, TrackResult>();
  await mapWithConcurrency(numbers, 8, async (n) => {
    try {
      const url = `https://api-integration.tranzo.pk/api/custom/v1/track-order/?tracking_numbers=${encodeURIComponent(n)}`;
      const { status, body } = await fetchJson(url, { headers: { "Api-Token": creds.api_token } });
      if (status === 401 || status === 403) {
        out.set(n, { ok: false, error: `Tranzo auth failed (${status})` });
        return;
      }
      const row = Array.isArray(body) ? body[0] : null;
      const history: any[] = Array.isArray(row?.order_status_history) ? row.order_status_history : [];
      const events = history
        .map((h) => ev(h.status ?? h.order_status, h.created_at ?? h.date ?? h.updated_at))
        .filter((e): e is TrackEvent => !!e);
      out.set(n, row ? result(events, row.order_status) : { ok: false, error: `Tranzo: tracking not found (HTTP ${status})` });
    } catch (e) {
      out.set(n, { ok: false, error: `Tranzo request failed: ${e instanceof Error ? e.message : e}` });
    }
  });
  return out;
}

// ----------------------------------------------------------------------------
// XPS
// ----------------------------------------------------------------------------
export async function trackXps(numbers: string[], creds: { auth_key: string }): Promise<Map<string, TrackResult>> {
  const out = new Map<string, TrackResult>();
  await mapWithConcurrency(numbers, 8, async (n) => {
    try {
      const { status, body } = await fetchJson("https://portal.xpsworldwideexpress.pk/API/CurrentStatus.php", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ auth_key: creds.auth_key, tracking_no: n }),
      });
      const row = Array.isArray(body) ? body[0] : body;
      out.set(n, row?.status ? result([], row.status) : { ok: false, error: row?.message ?? `XPS HTTP ${status}` });
    } catch (e) {
      out.set(n, { ok: false, error: `XPS request failed: ${e instanceof Error ? e.message : e}` });
    }
  });
  return out;
}

export type CourierCreds = Record<string, string>;

export async function trackMany(courier: Courier, numbers: string[], creds: CourierCreds | null): Promise<Map<string, TrackResult>> {
  if (numbers.length === 0) return new Map();
  const need = (keys: string[]) => {
    if (!creds || keys.some((k) => !creds[k])) throw new Error(`${courier} is not configured in Integrations`);
  };
  switch (courier) {
    case "postex": need(["token"]); return trackPostEx(numbers, creds as { token: string });
    case "blueex": need(["username", "password"]); return trackBlueEx(numbers, creds as { username: string; password: string });
    case "mnp": return trackMnp(numbers);
    case "tranzo": need(["api_token"]); return trackTranzo(numbers, creds as { api_token: string });
    case "xps": need(["auth_key"]); return trackXps(numbers, creds as { auth_key: string });
    default: return new Map(numbers.map((n) => [n, { ok: false, error: "Unknown courier — set the tracking company in Shopify" }]));
  }
}

/** Connection test used by the Integrations page. Uses a sample tracking number when given. */
export async function testCourier(courier: Courier, creds: CourierCreds, sample?: string | null): Promise<string> {
  if (courier === "postex" && !sample) return testPostEx(creds as { token: string });
  const probe = (sample ?? "").trim().toUpperCase() || "0000000000";
  const res = (await trackMany(courier, [probe], creds)).get(probe);
  if (res?.ok) return `Connected — ${probe}: ${res.raw}`;
  const err = res && !res.ok ? res.error : "no response";
  if (/auth|credential|unauthori|token|key|401|403/i.test(err)) throw new Error(err);
  if (sample) throw new Error(`Credentials accepted but tracking ${probe} failed: ${err}`);
  return `Credentials accepted (no sample tracking number given; API said: ${err})`;
}
