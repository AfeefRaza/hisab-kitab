import { assertEquals } from "jsr:@std/assert@1";
import { detectCourier, normalizeStatus, parseCourierDate } from "./couriers.ts";
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
