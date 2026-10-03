// Shopify Admin GraphQL client. Supports a static Admin API access token
// (legacy custom app, shpat_…) or Dev Dashboard client credentials
// (client_id + client_secret → short-lived token).
import { sleep } from "./http.ts";

export interface ShopifyConfig {
  shop_domain: string;
  api_version?: string;
}
export interface ShopifySecret {
  access_token?: string;
  client_id?: string;
  client_secret?: string;
}

export function normalizeDomain(input: string): string {
  return input.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
}

export class ShopifyClient {
  private token: string | null;
  private readonly endpoint: string;
  private readonly domain: string;

  constructor(private config: ShopifyConfig, private secret: ShopifySecret) {
    this.domain = normalizeDomain(config.shop_domain);
    if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(this.domain)) {
      throw new Error("Shop domain must look like your-store.myshopify.com");
    }
    this.endpoint = `https://${this.domain}/admin/api/${config.api_version || "2026-07"}/graphql.json`;
    this.token = secret.access_token ?? null;
  }

  private async getToken(): Promise<string> {
    if (this.token) return this.token;
    if (!this.secret.client_id || !this.secret.client_secret) {
      throw new Error("Shopify credentials missing: provide an Admin API access token or client ID + secret");
    }
    const res = await fetch(`https://${this.domain}/admin/oauth/access_token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: this.secret.client_id,
        client_secret: this.secret.client_secret,
      }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || !body.access_token) {
      throw new Error(`Shopify token exchange failed (${res.status}): ${body.error_description ?? body.error ?? "check client ID/secret"}`);
    }
    this.token = body.access_token as string;
    return this.token;
  }

  async query<T = any>(query: string, variables: Record<string, unknown> = {}): Promise<T> {
    for (let attempt = 0; attempt < 6; attempt++) {
      const res = await fetch(this.endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": await this.getToken() },
        body: JSON.stringify({ query, variables }),
      });
      if (res.status === 429 || res.status >= 500) {
        await sleep(1000 * (attempt + 1));
        continue;
      }
      if (res.status === 401 || res.status === 403) {
        throw new Error(`Shopify rejected the credentials (HTTP ${res.status}). Check the token and its read_orders scope.`);
      }
      const body = await res.json();
      if (body.errors) {
        const throttled = body.errors.some((e: any) => e.extensions?.code === "THROTTLED");
        if (throttled) {
          await sleep(2000);
          continue;
        }
        throw new Error(`Shopify GraphQL error: ${JSON.stringify(body.errors).slice(0, 500)}`);
      }
      // Respect the cost-based throttle bucket
      const cost = body.extensions?.cost;
      if (cost?.throttleStatus && cost.throttleStatus.currentlyAvailable < (cost.requestedQueryCost ?? 0) * 1.5) {
        await sleep(1000);
      }
      return body.data as T;
    }
    throw new Error("Shopify API kept throttling; try again shortly");
  }

  async testConnection(): Promise<string> {
    const data = await this.query<{ shop: { name: string; currencyCode: string } }>(
      "{ shop { name currencyCode } orders(first: 1) { edges { node { id } } } }",
    );
    return `Connected to ${data.shop.name} (${data.shop.currencyCode})`;
  }
}

// Kept under Shopify's 1000-point query cost limit: 25 orders × (≈30 line cost).
export const ORDERS_QUERY = `
query Orders($cursor: String, $query: String!) {
  orders(first: 25, after: $cursor, query: $query, sortKey: UPDATED_AT) {
    pageInfo { hasNextPage endCursor }
    nodes {
      legacyResourceId
      name
      createdAt
      updatedAt
      processedAt
      cancelledAt
      cancelReason
      displayFinancialStatus
      displayFulfillmentStatus
      paymentGatewayNames
      currencyCode
      tags
      note
      subtotalPriceSet { shopMoney { amount } }
      totalDiscountsSet { shopMoney { amount } }
      totalShippingPriceSet { shopMoney { amount } }
      totalTaxSet { shopMoney { amount } }
      totalPriceSet { shopMoney { amount } }
      totalRefundedSet { shopMoney { amount } }
      currentTotalPriceSet { shopMoney { amount } }
      totalOutstandingSet { shopMoney { amount } }
      shippingAddress { name phone city province }
      lineItems(first: 30) {
        nodes {
          id
          title
          variantTitle
          sku
          quantity
          currentQuantity
          originalUnitPriceSet { shopMoney { amount } }
          product { legacyResourceId }
          variant { legacyResourceId inventoryItem { unitCost { amount } } }
        }
      }
      fulfillments(first: 5) {
        legacyResourceId
        createdAt
        status
        trackingInfo(first: 3) { number company }
      }
    }
  }
}`;

// Same query without customer PII (for stores whose app lacks protected customer data access)
export const ORDERS_QUERY_NO_PII = ORDERS_QUERY.replace("shippingAddress { name phone city province }", "shippingAddress { city province }");

const money = (m: any): number => {
  const v = parseFloat(m?.shopMoney?.amount ?? "0");
  return isNaN(v) ? 0 : Math.round(v * 100) / 100;
};
const gidNum = (v: string | null | undefined): number | null => {
  if (!v) return null;
  const n = Number(String(v).split("/").pop());
  return Number.isFinite(n) ? n : null;
};

export function isCodOrder(gateways: string[], financialStatus: string | null): boolean {
  const g = gateways.map((x) => x.toLowerCase());
  if (g.some((x) => x.includes("cash on delivery") || x.includes("cod") || x === "manual")) return true;
  if (g.length === 0) return (financialStatus ?? "").toUpperCase() !== "PAID";
  return false;
}

export interface MappedOrder {
  order: Record<string, unknown>;
  lines: Record<string, unknown>[];
  shipments: { tracking_number: string; company: string | null; fulfillment_id: number | null; fulfilled_at: string | null }[];
}

export function mapOrder(n: any): MappedOrder {
  const gateways: string[] = n.paymentGatewayNames ?? [];
  const id = Number(n.legacyResourceId);
  const order = {
    id,
    name: n.name,
    created_at_shop: n.createdAt,
    updated_at_shop: n.updatedAt,
    processed_at: n.processedAt,
    cancelled_at: n.cancelledAt,
    cancel_reason: n.cancelReason,
    financial_status: n.displayFinancialStatus,
    fulfillment_status: n.displayFulfillmentStatus,
    payment_gateways: gateways,
    is_cod: isCodOrder(gateways, n.displayFinancialStatus),
    currency: n.currencyCode ?? "PKR",
    subtotal: money(n.subtotalPriceSet),
    total_discounts: money(n.totalDiscountsSet),
    shipping_charged: money(n.totalShippingPriceSet),
    total_tax: money(n.totalTaxSet),
    total_price: money(n.totalPriceSet),
    total_refunded: money(n.totalRefundedSet),
    current_total: money(n.currentTotalPriceSet),
    outstanding: money(n.totalOutstandingSet),
    customer_name: n.shippingAddress?.name ?? null,
    phone: n.shippingAddress?.phone ?? null,
    city: n.shippingAddress?.city ? String(n.shippingAddress.city).trim() : null,
    province: n.shippingAddress?.province ?? null,
    tags: n.tags ?? [],
    note: n.note ?? null,
    synced_at: new Date().toISOString(),
  };
  const lines = (n.lineItems?.nodes ?? []).map((l: any) => {
    const cost = l.variant?.inventoryItem?.unitCost?.amount;
    return {
      id: gidNum(l.id),
      order_id: id,
      title: l.title,
      variant_title: l.variantTitle,
      sku: l.sku || null,
      product_id: l.product?.legacyResourceId ? Number(l.product.legacyResourceId) : null,
      variant_id: l.variant?.legacyResourceId ? Number(l.variant.legacyResourceId) : null,
      quantity: l.quantity,
      current_quantity: l.currentQuantity ?? l.quantity,
      unit_price: money(l.originalUnitPriceSet),
      unit_cost: cost != null && cost !== "" ? Math.round(parseFloat(cost) * 100) / 100 : null,
    };
  });
  const shipments: MappedOrder["shipments"] = [];
  const seen = new Set<string>();
  for (const f of n.fulfillments ?? []) {
    if (f.status === "CANCELLED") continue;
    for (const t of f.trackingInfo ?? []) {
      const tn = String(t.number ?? "").replace(/[\s'"]+/g, "").toUpperCase();
      if (!tn || seen.has(tn)) continue;
      seen.add(tn);
      shipments.push({
        tracking_number: tn,
        company: t.company ?? null,
        fulfillment_id: f.legacyResourceId ? Number(f.legacyResourceId) : null,
        fulfilled_at: f.createdAt ?? null,
      });
    }
  }
  return { order, lines, shipments };
}
