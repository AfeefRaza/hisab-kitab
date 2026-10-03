// Admin-only integration management. Credentials are tested server-side,
// stored in Supabase Vault, and never returned to the client — only masked hints.
//
// POST { action: "test" | "save" | "disconnect", provider, config?, credentials?, sample_tracking? }
//  - test:       tests given credentials (or the saved ones when omitted); saves nothing
//  - save:       tests, then stores; refuses to activate credentials that fail the test
//  - disconnect: deletes the stored secret and disables the integration
import { authenticate, handle, HttpError, json, mask, serviceClient } from "../_shared/http.ts";
import { type Courier, testCourier } from "../_shared/couriers.ts";
import { normalizeDomain, ShopifyClient } from "../_shared/shopify.ts";

const SECRET_FIELDS: Record<string, string[]> = {
  shopify: ["access_token", "client_id", "client_secret"],
  postex: ["token"],
  blueex: ["username", "password"],
  mnp: [],
  tranzo: ["api_token"],
  xps: ["auth_key"],
};
const CONFIG_FIELDS: Record<string, string[]> = {
  shopify: ["shop_domain", "api_version"],
  postex: ["account_id", "pickup_address_code"],
  blueex: ["account_no"],
  mnp: ["account_no"],
  tranzo: ["account_id"],
  xps: ["account_id"],
};

function pick(obj: Record<string, unknown> | undefined, keys: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of keys) {
    const v = obj?.[k];
    if (typeof v === "string" && v.trim() !== "") out[k] = v.trim();
  }
  return out;
}

async function runTest(provider: string, config: Record<string, string>, secret: Record<string, string>, sample?: string): Promise<string> {
  if (provider === "shopify") {
    if (!config.shop_domain) throw new Error("Shop domain is required");
    if (!secret.access_token && !(secret.client_id && secret.client_secret)) {
      throw new Error("Provide an Admin API access token, or a client ID and client secret");
    }
    return await new ShopifyClient({ shop_domain: config.shop_domain, api_version: config.api_version }, secret).testConnection();
  }
  const required = SECRET_FIELDS[provider];
  const missing = required.filter((k) => !secret[k]);
  if (missing.length) throw new Error(`Missing: ${missing.join(", ")}`);
  return await testCourier(provider as Courier, secret, sample);
}

Deno.serve(handle(async (req) => {
  const db = serviceClient();
  const caller = await authenticate(req, db, "admin");
  if (caller.kind !== "user") throw new HttpError(403, "Admin user required");

  const body = await req.json().catch(() => ({}));
  const { action, provider } = body as { action: string; provider: string };
  if (!(provider in SECRET_FIELDS)) throw new HttpError(400, "Unknown provider");

  const { data: row } = await db.from("integrations").select("config").eq("provider", provider).single();
  const { data: saved } = await db.rpc("integration_get_secret", { p_provider: provider });

  if (action === "disconnect") {
    const { error } = await db.rpc("integration_disconnect", { p_provider: provider, p_actor: caller.userId });
    if (error) throw new Error(error.message);
    return json(req, { ok: true, message: "Disconnected" });
  }

  const newConfig = { ...(row?.config ?? {}), ...pick(body.config, CONFIG_FIELDS[provider]) };
  if (newConfig.shop_domain) newConfig.shop_domain = normalizeDomain(newConfig.shop_domain);
  const newSecretFields = pick(body.credentials, SECRET_FIELDS[provider]);
  // Replacing credentials: any field given replaces the saved one; missing fields keep saved values
  const effectiveSecret: Record<string, string> = { ...(saved ?? {}), ...newSecretFields };
  if (provider === "shopify" && newSecretFields.access_token) {
    delete effectiveSecret.client_id;
    delete effectiveSecret.client_secret;
  } else if (provider === "shopify" && (newSecretFields.client_id || newSecretFields.client_secret)) {
    delete effectiveSecret.access_token;
  }

  let ok = true;
  let message: string;
  try {
    message = await runTest(provider, newConfig, effectiveSecret, body.sample_tracking);
  } catch (e) {
    ok = false;
    message = e instanceof Error ? e.message : String(e);
  }

  if (action === "test") return json(req, { ok, message });

  if (action !== "save") throw new HttpError(400, "Unknown action");
  if (!ok) return json(req, { ok: false, message: `Not saved — connection test failed: ${message}` }, 422);

  const hint: Record<string, string | null> = {};
  for (const k of Object.keys(effectiveSecret)) {
    hint[k] = k === "username" || k === "client_id" ? effectiveSecret[k] : mask(effectiveSecret[k]);
  }
  const { error } = await db.rpc("integration_save", {
    p_provider: provider,
    p_secret: Object.keys(newSecretFields).length || !saved ? effectiveSecret : null,
    p_secret_hint: hint,
    p_config: newConfig,
    p_actor: caller.userId,
    p_status: "connected",
    p_message: message,
  });
  if (error) throw new Error(error.message);
  return json(req, { ok: true, message });
}));
