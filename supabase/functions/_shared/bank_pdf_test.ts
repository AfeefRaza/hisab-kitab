import { assertEquals } from "jsr:@std/assert@1";
import { parseMoney, parseStatementDate, parseStatementItems, type TextItem } from "./bank_pdf.ts";

Deno.test("statement dates and money", () => {
  assertEquals(parseStatementDate("12 Oct 2026"), "2026-10-12");
  assertEquals(parseStatementDate("3-Sep-2026"), "2026-09-03");
  assertEquals(parseStatementDate("05/09/2026"), "2026-09-05");
  assertEquals(parseStatementDate("26 Oct 2026, 16:42"), null); // page footer, not a row
  assertEquals(parseMoney("- PKR13,000.00"), { sign: -1, value: 13000 });
  assertEquals(parseMoney("+ PKR3,450.00"), { sign: 1, value: 3450 });
  assertEquals(parseMoney("PKR770,840.88"), { sign: 0, value: 770840.88 });
  assertEquals(parseMoney("Money Received from"), null);
});

// Synthetic statement in the Meezan layout (names are made up)
const it = (str: string, x: number, y: number): TextItem => ({ str, x, y });
const page1: TextItem[] = [
  it("Account Statement", 425, 789),
  it("Account Title", 28, 750), it("TEST TRADER", 28, 742),
  it("Account Number", 156, 750), it("01170100001234", 156, 742),
  it("IBAN", 283, 750), it("PK88MEZN0001170100001234", 283, 742),
  it("From Date", 156, 716), it("11 Oct 2026", 156, 708),
  it("To Date", 283, 716), it("10 Nov 2026", 283, 708),
  it("Opening Balance", 28, 682), it("PKR1,000.00", 28, 674),
  it("Closing Balance", 156, 682), it("PKR5,987.00", 156, 674),
  it("Booking Date", 45, 556), it("Description", 169, 556), it("Credit", 307, 556), it("Debit", 408, 556), it("Available Balance", 483, 556),
  // fee row
  it("12 Oct 2026", 50, 531), it("Charges Taxes Plus", 145, 531), it("FED - STAN(111111)", 143, 511),
  it("- PKR13.00", 392, 531), it("PKR987.00", 484, 531),
  // transfer whose name wraps after a hyphen
  it("12 Oct 2026", 50, 480), it("Money Transferred to ALI-", 126, 480), it("XXXXCASH STAN(111111)", 132, 460),
  it("- PKR500.00", 385, 480), it("PKR487.00", 484, 480),
  // courier credit
  it("13 Oct 2026", 50, 429), it("Money Received from", 142, 429), it("XXXX9545 - STAN(222222)", 133, 409),
  it("+ PKR5,500.00", 287, 429), it("PKR5,987.00", 484, 429),
  it("1 26 Oct 2026, 16:42", 28, 20), // footer
];

Deno.test("Meezan-style PDF rows: multi-line descriptions, signs, balance check", () => {
  const r = parseStatementItems([page1]);
  assertEquals(r.header.account_title, "TEST TRADER");
  assertEquals(r.header.account_last4, "1234");
  assertEquals(r.header.bank, "Meezan Bank");
  assertEquals(r.header.from, "2026-10-11");
  assertEquals(r.header.opening_balance, 1000);
  assertEquals(r.rows.length, 3);
  assertEquals(r.rows[0], { date: "2026-10-12", description: "Charges Taxes Plus FED - STAN(111111)", credit: 0, debit: 13, balance: 987 });
  assertEquals(r.rows[1].description, "Money Transferred to ALI-XXXXCASH STAN(111111)");
  assertEquals(r.rows[2].credit, 5500);
  assertEquals(r.balance_check, { checked: 3, breaks: 0, ok: true });
  assertEquals(r.warnings, []);
});

Deno.test("a missing row breaks the running balance and is reported", () => {
  const broken = page1.filter((i) => !(i.y === 480 || i.y === 460)); // drop the transfer
  const r = parseStatementItems([broken]);
  assertEquals(r.rows.length, 2);
  assertEquals(r.balance_check.ok, false);
});
