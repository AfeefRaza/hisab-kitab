// Reads a bank statement PDF and returns its transactions for the import preview.
// Nothing is stored here — the app shows the preview and imports through
// import_bank_statement. The full account number is never returned (last 4 only).
// POST { pdf_base64 }  →  { header, rows, warnings, balance_check }
// Auth: finance+ user JWT.
import { getDocumentProxy } from "npm:unpdf@1.6.2";
import { authenticate, handle, HttpError, json, resolveStore, storeClient } from "../_shared/http.ts";
import { parseStatementItems, type TextItem } from "../_shared/bank_pdf.ts";

const MAX_BYTES = 10 * 1024 * 1024;

function fromBase64(b64: string): Uint8Array {
  const bin = atob(b64.replace(/^data:[^,]*,/, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

Deno.serve(handle(async (req) => {
  const body = await req.json().catch(() => ({})) as { pdf_base64?: string; store_id?: string };
  const storeId = await resolveStore(req, body);
  await authenticate(req, storeClient(storeId), "finance");
  if (!body.pdf_base64) throw new HttpError(400, "No PDF received");

  const bytes = fromBase64(body.pdf_base64);
  if (bytes.length > MAX_BYTES) throw new HttpError(413, "PDF is larger than 10 MB");
  if (new TextDecoder().decode(bytes.slice(0, 5)) !== "%PDF-") throw new HttpError(400, "That file is not a PDF");

  let pdf;
  try {
    pdf = await getDocumentProxy(bytes);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    throw new HttpError(422, /password/i.test(msg) ? "This PDF is password-protected. Download it again without a password." : `Could not read the PDF: ${msg}`);
  }
  const pages: TextItem[][] = [];
  for (let p = 1; p <= pdf.numPages; p++) {
    const tc = await (await pdf.getPage(p)).getTextContent();
    pages.push(
      (tc.items as any[])
        .filter((i) => typeof i.str === "string" && i.str.trim())
        .map((i) => ({ str: i.str, x: i.transform[4], y: i.transform[5] })),
    );
  }
  if (!pages.some((p) => p.length)) {
    throw new HttpError(422, "This PDF has no text (it is probably a scan). Download the statement from internet banking instead.");
  }
  return json(req, parseStatementItems(pages));
}));
