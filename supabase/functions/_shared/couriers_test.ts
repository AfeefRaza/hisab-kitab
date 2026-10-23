import { assertEquals } from "jsr:@std/assert@1";
import { detectCourier, normalizeStatus, parseCourierDate, postexResult, postexStatus } from "./couriers.ts";
import { isCodOrder, mapOrder } from "./shopify.ts";

Deno.test("detectCourier: tracking number shapes", () => {
  assertEquals(detectCourier("50312345678"), "blueex");
  assertEquals(detectCourier("559 1234 5678"), "mnp");
  assertEquals(detectCourier("t00123456"), "tranzo");
  assertEquals(detectCourier("22085990000463"), "postex");
  assertEquals(detectCourier("KI123456"), "xps");
  assertEquals(detectCourier("1234567"), "xps");
  assertEquals(detectCourier("12345678901234"), "unknown"); // 14 digits starting 1x is not PostEx or XPS
  assertEquals(detectCourier("ABC"), "unknown");
});

Deno.test("detectCourier: Shopify tracking company wins over number shape", () => {
  assertEquals(detectCourier("50312345678", "PostEx"), "postex");
  assertEquals(detectCourier("999", "M&P Courier"), "mnp");
});

Deno.test("normalizeStatus: delivery", () => {
  assertEquals(normalizeStatus("Delivered"), "delivered");
  assertEquals(normalizeStatus("Shipment Delivered to Consignee"), "delivered");
  assertEquals(normalizeStatus("Out For Delivery"), "out_for_delivery");
  assertEquals(normalizeStatus("Delivery Under Review"), "delivery_failed");
  assertEquals(normalizeStatus("Undelivered - Consignee not available"), "delivery_failed");
  assertEquals(normalizeStatus("Attempt Made"), "delivery_failed");
  assertEquals(normalizeStatus("Refused by customer"), "delivery_failed");
});

Deno.test("normalizeStatus: returns are split into in-transit vs back with us", () => {
  assertEquals(normalizeStatus("Return in transit"), "return_in_transit");
  assertEquals(normalizeStatus("RTO Initiated"), "return_in_transit");
  assertEquals(normalizeStatus("Returned"), "returned");
  assertEquals(normalizeStatus("Returned to Shipper"), "returned");
  assertEquals(normalizeStatus("Return Delivered"), "returned");
  assertEquals(normalizeStatus("RTO Delivered"), "returned");
});

Deno.test("normalizeStatus: cancelled is NOT a return (legacy bug)", () => {
  assertEquals(normalizeStatus("Cancelled"), "cancelled");
  assertEquals(normalizeStatus("Un-Assigned By Me"), "unknown"); // PostEx code mapping turns this into cancelled
});

Deno.test("normalizeStatus: errors are not statuses (legacy bug counted them in transit)", () => {
  assertEquals(normalizeStatus("Tracking Details Not Found"), null);
  assertEquals(normalizeStatus("Invalid credentials"), null);
  assertEquals(normalizeStatus(""), null);
  assertEquals(normalizeStatus(null), null);
});

Deno.test("normalizeStatus: in transit / booked", () => {
  assertEquals(normalizeStatus("Booked"), "booked");
  assertEquals(normalizeStatus("Unbooked"), "booked");
  assertEquals(normalizeStatus("At PostEx Warehouse"), "in_transit");
  assertEquals(normalizeStatus("Arrived at Lahore Hub"), "in_transit");
  assertEquals(normalizeStatus("Something new"), "unknown");
});

Deno.test("audit C1: waiting / pending delivery is never delivered", () => {
  assertEquals(normalizeStatus("Waiting for Delivery"), "in_transit");
  assertEquals(normalizeStatus("Awaiting delivery"), "in_transit");
  assertEquals(normalizeStatus("Enroute for Delivery"), "out_for_delivery");
  assertEquals(normalizeStatus("Delivered to Customer"), "delivered");
  assertEquals(normalizeStatus("Not delivered"), "delivery_failed");
  assertEquals(postexStatus("Waiting for Delivery", "0005"), "in_transit"); // even with a 'delivered' code
  assertEquals(postexStatus("Delivered to Customer", "0005"), "delivered");
  assertEquals(postexStatus("Booking Cancelled by Merchant", "0002"), "cancelled");
  assertEquals(postexStatus("En Route to Merchant Warehouse", "0003"), "return_in_transit");
  assertEquals(postexStatus("Returned at Merchant Warehouse", "0002"), "returned");
});

Deno.test("audit F6: a label still at the merchant is booked, not in transit", () => {
  assertEquals(postexStatus("At HavenWear Warehouse", "0001"), "booked");
  assertEquals(postexStatus("At PostEx Warehouse"), "in_transit");
  assertEquals(postexStatus("Received at KHI Warehouse"), "in_transit");
});

// Real PostEx event sequences from the audit (#haven33776 / #haven33684 refused & returned, #haven33633 returning)
const seq = (...steps: [string, string][]) => ({
  transactionStatusHistory: steps.map(([msg, at]) => ({ transactionStatusMessage: msg, updatedAt: at })),
});

Deno.test("audit C2: refused parcel ends returned, never delivered on the way", () => {
  const r = postexResult(seq(
    ["At HavenWear Warehouse", "2026-10-01T10:00:00+05:00"],
    ["Received at KHI Warehouse", "2026-10-02T09:00:00+05:00"],
    ["Waiting for Delivery", "2026-10-04T08:00:00+05:00"],
    ["Enroute for Delivery", "2026-10-04T10:00:00+05:00"],
    ["Attempt Made: RFD(REFUSED TO RECEIVE)", "2026-10-04T16:00:00+05:00"],
    ["Waiting for Return", "2026-10-06T09:00:00+05:00"],
    ["Return Process Initiated", "2026-10-07T09:00:00+05:00"],
    ["Return to KARACHI", "2026-10-09T09:00:00+05:00"],
    ["En Route to Merchant Warehouse", "2026-10-14T12:00:00+05:00"],
    ["Returned at Merchant Warehouse", "2026-10-14T22:12:00+05:00"],
  ));
  if (!r.ok) throw new Error("expected ok");
  assertEquals(r.status, "returned");
  assertEquals(r.events.some((e) => e.status === "delivered"), false);
});

Deno.test("audit C2: parcel heading back is returning, not delivered", () => {
  const r = postexResult(seq(
    ["Waiting for Delivery", "2026-10-04T08:00:00+05:00"],
    ["Attempt Made: CNA(CUSTOMER NOT AVAILABLE)", "2026-10-05T15:00:00+05:00"],
    ["Return Process Initiated", "2026-10-08T09:00:00+05:00"],
    ["En Route to Merchant Warehouse", "2026-10-15T11:00:00+05:00"],
  ));
  if (!r.ok) throw new Error("expected ok");
  assertEquals(r.status, "return_in_transit");
});

Deno.test("audit C1: waiting parcel stays undelivered until the courier confirms", () => {
  const waiting = postexResult(seq(["Waiting for Delivery", "2026-10-16T13:32:00+05:00"]));
  if (!waiting.ok) throw new Error("expected ok");
  assertEquals(waiting.status, "in_transit");
  const done = postexResult(seq(["Waiting for Delivery", "2026-10-16T13:32:00+05:00"], ["Delivered to Customer", "2026-10-17T12:00:00+05:00"]));
  if (!done.ok) throw new Error("expected ok");
  assertEquals(done.status, "delivered");
});

Deno.test("parseCourierDate: formats default to PKT", () => {
  assertEquals(parseCourierDate("2026-09-05T10:00:00Z"), "2026-09-05T10:00:00.000Z");
  assertEquals(parseCourierDate("2026-09-05 10:00:00"), "2026-09-05T05:00:00.000Z");
  assertEquals(parseCourierDate("05/09/2026 10:00"), "2026-09-05T05:00:00.000Z");
  assertEquals(parseCourierDate("05-09-2026 02:30 PM"), "2026-09-05T09:30:00.000Z");
  assertEquals(parseCourierDate("2026-09-05"), "2026-09-04T19:00:00.000Z");
  assertEquals(parseCourierDate("garbage"), null);
  assertEquals(parseCourierDate(null), null);
});

Deno.test("isCodOrder", () => {
  assertEquals(isCodOrder(["Cash on Delivery (COD)"], "PENDING"), true);
  assertEquals(isCodOrder(["shopify_payments"], "PAID"), false);
  assertEquals(isCodOrder([], "PENDING"), true);
  assertEquals(isCodOrder([], "PAID"), false);
});

Deno.test("mapOrder: money, lines, all tracking numbers, cancelled fulfilments skipped", () => {
  const m = mapOrder({
    legacyResourceId: "5001", name: "#1001", createdAt: "2026-09-01T10:00:00Z", updatedAt: "2026-09-02T10:00:00Z",
    paymentGatewayNames: ["Cash on Delivery (COD)"], displayFinancialStatus: "PENDING",
    totalPriceSet: { shopMoney: { amount: "2999.50" } }, currentTotalPriceSet: { shopMoney: { amount: "2499.5" } },
    totalShippingPriceSet: { shopMoney: { amount: "200" } },
    shippingAddress: { city: " Lahore ", name: "Ali", phone: "0300" },
    lineItems: { nodes: [{ id: "gid://shopify/LineItem/77", title: "Hoodie", quantity: 2, currentQuantity: 1,
      originalUnitPriceSet: { shopMoney: { amount: "1499.75" } }, variant: { legacyResourceId: "9", inventoryItem: { unitCost: { amount: "800" } } } }] },
    fulfillments: [
      { legacyResourceId: "1", createdAt: "2026-09-01T12:00:00Z", status: "SUCCESS", trackingInfo: [{ number: "22 0859 9000 0463", company: "PostEx" }] },
      { legacyResourceId: "2", createdAt: "2026-09-01T13:00:00Z", status: "CANCELLED", trackingInfo: [{ number: "503999" }] },
    ],
  });
  assertEquals(m.order.id, 5001);
  assertEquals(m.order.is_cod, true);
  assertEquals(m.order.total_price, 2999.5);
  assertEquals(m.order.current_total, 2499.5);
  assertEquals(m.order.city, "Lahore");
  assertEquals(m.lines[0].id, 77);
  assertEquals(m.lines[0].current_quantity, 1);
  assertEquals(m.lines[0].unit_cost, 800);
  assertEquals(m.shipments.length, 1);
  assertEquals(m.shipments[0].tracking_number, "22085990000463");
  assertEquals(m.cancelledTracking, ["503999"]);
});

import { parseSpend } from "./triplewhale.ts";

Deno.test("Triple Whale: per-channel spend from summary-page metrics", () => {
  const spend = parseSpend({
    metrics: [
      { id: "facebookAds", title: "Facebook Ads", values: { current: 10543.219, previous: 9000 } },
      { id: "tiktokAds", values: { current: "2500" } },
      { id: "blendedAds", values: { current: 13043.22 } }, // total — not a channel
      { id: "sales", values: { current: 99999 } },
      { metricName: "googleAds", value: 300 }, // documented alternative shape
    ],
  });
  assertEquals(spend, { facebookAds: 10543.22, tiktokAds: 2500, googleAds: 300 });
  assertEquals(parseSpend({}), {});
});
