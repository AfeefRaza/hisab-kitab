import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

// Auth is via bearer token (not cookies), so a permissive CORS origin does not
// enable CSRF. Restrict further with ALLOWED_ORIGINS if desired.
const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "*").split(",").map((s) => s.trim());

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  const allowOrigin = allowed.includes("*") ? "*" : (allowed.includes(origin) ? origin : allowed[0]);
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

export function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), "Content-Type": "application/json" },
  });
}

export function serviceClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export type Caller =
  | { kind: "user"; userId: string; email: string | null; role: string }
  | { kind: "cron" };

const ROLE_RANK: Record<string, number> = { pending: 0, viewer: 1, finance: 2, admin: 3 };

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/**
 * Accepts either a signed-in user's JWT (role checked against profiles) or the
 * pg_cron shared secret (header x-cron-secret, stored in Vault).
 */
export async function authenticate(req: Request, db: SupabaseClient, minRole: "viewer" | "finance" | "admin"): Promise<Caller> {
  const cronSecret = req.headers.get("x-cron-secret");
  if (cronSecret) {
    const { data, error } = await db.rpc("cron_secret_matches", { p_secret: cronSecret });
    if (error || data !== true) throw new HttpError(401, "Invalid cron secret");
    return { kind: "cron" };
  }

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) throw new HttpError(401, "Missing authorization");
  const { data: userData, error: userErr } = await db.auth.getUser(token);
  if (userErr || !userData?.user) throw new HttpError(401, "Invalid or expired session");

  const { data: profile } = await db.from("profiles").select("role").eq("id", userData.user.id).single();
  const role = profile?.role ?? "pending";
  if ((ROLE_RANK[role] ?? 0) < ROLE_RANK[minRole]) throw new HttpError(403, `Requires ${minRole} role`);
  return { kind: "user", userId: userData.user.id, email: userData.user.email ?? null, role };
}

export function handle(fn: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders(req) });
    try {
      return await fn(req);
    } catch (err) {
      if (err instanceof HttpError) return json(req, { error: err.message }, err.status);
      console.error(err);
      return json(req, { error: err instanceof Error ? err.message : "Unexpected error" }, 500);
    }
  };
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function mapWithConcurrency<T, R>(items: T[], concurrency: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await worker(items[i]);
    }
  });
  await Promise.all(runners);
  return results;
}

export function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/** Mask a secret for display: keep last 4 chars. */
export function mask(value: string | undefined | null): string | null {
  if (!value) return null;
  const v = String(value);
  return v.length <= 4 ? "••••" : "••••" + v.slice(-4);
}
