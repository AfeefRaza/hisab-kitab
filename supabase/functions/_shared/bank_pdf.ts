// Bank statement PDF → transactions. Works on positioned text items (x, y per page) so
// multi-line descriptions and separate Credit / Debit / Balance columns are read the
// way a person reads the table. Built for Meezan Bank statements; any statement with a
// header row naming Date / Description / Credit / Debit / Balance columns works the same.
// The running balance is checked row by row, so a missed or misread row is reported.

export interface TextItem { str: string; x: number; y: number }
export interface StatementRow {
  date: string; // YYYY-MM-DD
  description: string;
  credit: number;
  debit: number;
  balance: number | null;
}
export interface StatementHeader {
  account_title: string | null;
  account_last4: string | null; // never the full number
  bank: string | null;
  currency: string | null;
  from: string | null;
  to: string | null;
  opening_balance: number | null;
  closing_balance: number | null;
}
export interface ParsedStatement {
  header: StatementHeader;
  rows: StatementRow[];
  warnings: string[];
  balance_check: { checked: number; breaks: number; ok: boolean };
}

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
};

/** "12 Oct 2026", "12-Oct-2026", "12/10/2026" → "2026-10-12" */
export function parseStatementDate(s: string): string | null {
  const t = s.trim();
  let m = t.match(/^(\d{1,2})[\s\-\/]([A-Za-z]{3,4})[\s\-\/,]+(\d{4})$/);
  if (m) {
    const mo = MONTHS[m[2].toLowerCase()];
    if (!mo) return null;
    return `${m[3]}-${String(mo).padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  }
  m = t.match(/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  return null;
}

/** "- PKR13,000.00" → {sign:-1, value:13000}; "PKR770,840.88" → {sign:0, value:770840.88} */
export function parseMoney(s: string): { sign: number; value: number } | null {
  const t = s.replace(/\s+/g, "");
  const m = t.match(/^([+-]?)(?:PKR|Rs\.?|RS\.?)?(-?)([\d,]+(?:\.\d{1,2})?)(CR|DR|Cr|Dr)?$/);
  if (!m) return null;
  const value = parseFloat(m[3].replace(/,/g, ""));
  if (!Number.isFinite(value)) return null;
  let sign = m[1] === "+" ? 1 : m[1] === "-" ? -1 : 0;
  if (m[2] === "-") sign = -1;
  if (m[4]) sign = /cr/i.test(m[4]) ? 1 : -1;
  return { sign, value };
}

const round2 = (n: number) => Math.round(n * 100) / 100;

interface Columns { date: number; desc: number; credit: number; debit: number; balance: number; headerY: number }

function findColumns(items: TextItem[]): Columns | null {
  // The header row is the line that names both a credit and a debit column
  const byY = new Map<number, TextItem[]>();
  for (const it of items) {
    const key = Math.round(it.y);
    const list = byY.get(key) ?? [];
    list.push(it);
    byY.set(key, list);
  }
  for (const [y, line] of byY) {
    const find = (re: RegExp) => line.find((i) => re.test(i.str.trim()));
    const credit = find(/^(credit|credits|deposits?|cr\.?)$/i);
    const debit = find(/^(debit|debits|withdrawals?|dr\.?)$/i);
    if (!credit || !debit) continue;
    const date = find(/date/i);
    const desc = find(/description|narration|particulars|details|transaction/i);
    const balance = find(/balance/i);
    if (!date || !balance) continue;
    return { date: date.x, desc: desc?.x ?? (date.x + credit.x) / 2, credit: credit.x, debit: debit.x, balance: balance.x, headerY: y };
  }
  return null;
}

function headerValue(items: TextItem[], label: RegExp): string | null {
  const l = items.find((i) => label.test(i.str.trim()));
  if (!l) return null;
  // value printed just below the label, same column
  const below = items
    .filter((i) => i.str.trim() && Math.abs(i.x - l.x) < 4 && i.y < l.y && l.y - i.y < 14)
    .sort((a, b) => b.y - a.y);
  return below[0]?.str.trim() ?? null;
}

export function parseStatementItems(pages: TextItem[][]): ParsedStatement {
  const warnings: string[] = [];
  const first = pages[0] ?? [];
  const accountNo = headerValue(first, /^account number$/i);
  const opening = headerValue(first, /^opening balance$/i);
  const closing = headerValue(first, /^closing balance$/i);
  const iban = headerValue(first, /^iban$/i);
  const header: StatementHeader = {
    account_title: headerValue(first, /^account title$/i),
    account_last4: accountNo ? accountNo.replace(/\D/g, "").slice(-4) || null : null,
    bank: iban && /^PK\d\d([A-Z]{4})/.test(iban) ? bankFromIban(iban) : null,
    currency: headerValue(first, /^currency$/i),
    from: parseStatementDate(headerValue(first, /^from date$/i) ?? ""),
    to: parseStatementDate(headerValue(first, /^to date$/i) ?? ""),
    opening_balance: opening ? parseMoney(opening)?.value ?? null : null,
    closing_balance: closing ? parseMoney(closing)?.value ?? null : null,
  };

  const rows: StatementRow[] = [];
  let cols: Columns | null = null;
  for (const [pi, page] of pages.entries()) {
    cols = findColumns(page) ?? cols;
    if (!cols) {
      warnings.push(`Page ${pi + 1}: no Date/Credit/Debit/Balance header row found`);
      continue;
    }
    const c = cols;
    const top = findColumns(page)?.headerY ?? Infinity; // rows sit below the header row
    const descLeft = (c.date + c.desc) / 2 - 20;
    const moneyLeft = Math.min(c.credit, c.debit) - 40;
    const inTable = page.filter((i) => i.y < top - 2 && i.str.trim());

    // A row starts with a date in the date column
    const anchors = inTable
      .filter((i) => i.x < descLeft + 30 && parseStatementDate(i.str) !== null)
      .sort((a, b) => b.y - a.y);
    for (const [ai, a] of anchors.entries()) {
      const nextY = anchors[ai + 1]?.y ?? -Infinity;
      const own = inTable.filter((i) => i !== a && i.y <= a.y + 2 && i.y > nextY + 2);
      const desc = own
        .filter((i) => i.x >= descLeft && i.x < moneyLeft && !parseMoney(i.str))
        .sort((p, q) => (Math.abs(p.y - q.y) > 2 ? q.y - p.y : p.x - q.x))
        .map((i) => i.str.trim())
        .join(" ")
        .replace(/\s+/g, " ")
        .replace(/(\S)- (?=XXXX|xxxx|\d)/g, "$1-") // "AWAIS-" + "XXXXCASH" wrapped onto two lines
        .trim();
      let credit = 0, debit = 0, balance: number | null = null;
      for (const i of own.filter((i) => i.x >= moneyLeft)) {
        const m = parseMoney(i.str);
        if (!m) continue;
        const nearest = [["credit", c.credit], ["debit", c.debit], ["balance", c.balance]]
          .sort((p, q) => Math.abs((p[1] as number) - i.x) - Math.abs((q[1] as number) - i.x))[0][0];
        if (nearest === "balance" && m.sign === 0) balance = m.value;
        else if (m.sign > 0 || (m.sign === 0 && nearest === "credit")) credit = m.value;
        else debit = m.value;
      }
      if (credit === 0 && debit === 0) continue; // opening/closing lines
      rows.push({ date: parseStatementDate(a.str)!, description: desc, credit, debit, balance });
    }
  }

  // Running-balance check: every row must equal previous balance + credit − debit
  let prev = header.opening_balance;
  let checked = 0, breaks = 0;
  for (const [i, r] of rows.entries()) {
    if (prev !== null && r.balance !== null) {
      checked++;
      if (Math.abs(round2(prev + r.credit - r.debit) - r.balance) > 0.01) {
        breaks++;
        if (breaks <= 5) warnings.push(`Row ${i + 1} (${r.date}): balance ${r.balance} does not follow from the previous balance ${prev} — a row may be missing or misread`);
      }
    }
    if (r.balance !== null) prev = r.balance;
  }
  if (header.closing_balance !== null && rows.length && rows[rows.length - 1].balance !== null &&
      Math.abs(rows[rows.length - 1].balance! - header.closing_balance) > 0.01) {
    warnings.push(`Last row balance ${rows[rows.length - 1].balance} differs from the statement's closing balance ${header.closing_balance}`);
    breaks++;
  }
  if (!rows.length) warnings.push("No transactions found in this PDF");
  return { header, rows, warnings, balance_check: { checked, breaks, ok: breaks === 0 && checked > 0 } };
}

const IBAN_BANKS: Record<string, string> = {
  MEZN: "Meezan Bank", HABB: "HBL", MUCB: "MCB", UNIL: "UBL", ABPA: "Allied Bank", BAHL: "Bank Al Habib",
  ALFH: "Bank Alfalah", FAYS: "Faysal Bank", ASCM: "Askari Bank", SCBL: "Standard Chartered", BKIP: "BankIslami",
  DUIB: "Dubai Islamic", JSBL: "JS Bank", SONE: "Soneri Bank", NBPA: "National Bank",
};
function bankFromIban(iban: string): string | null {
  const code = iban.replace(/\s/g, "").slice(4, 8).toUpperCase();
  return IBAN_BANKS[code] ?? null;
}
