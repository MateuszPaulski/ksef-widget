import { createHash } from 'node:crypto';
import { KsefApiError, RateLimitError } from './http.ts';
import type { InvoiceMetadata, MetadataPage, Window } from './ksef.ts';
import type { Store } from './store.ts';

export const MAX_WINDOW_DAYS = 90;
export const MAX_DOWNLOADS_PER_HOUR = 60;
const HOUR_MS = 3_600_000;
export const MIN_DOWNLOAD_INTERVAL_MS = 4_000;
export const TOKEN_MARGIN_MS = 60_000;
export const KSEF_NUMBER_PATTERN =
  /^([1-9](\d[1-9]|[1-9]\d)\d{7})-(20[2-9][0-9]|2[1-9]\d{2}|[3-9]\d{3})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])-([0-9A-F]{6})-?([0-9A-F]{6})-([0-9A-F]{2})$/;

// KSeF error code: `from` is later than the HWM, i.e. nothing has been settled yet.
const FROM_AFTER_HWM_CODE = '21183';

export type Query = (window: Window, pageOffset: number) => Promise<MetadataPage>;

export function nextWindow(from: string, now: Date): Window {
  const to = Date.parse(from) + MAX_WINDOW_DAYS * 86_400_000;
  return to < now.getTime() ? { from, to: new Date(to).toISOString() } : { from };
}

export async function listWindow(
  query: Query,
  window: Window,
): Promise<{ invoices: InvoiceMetadata[]; hwm: string | null }> {
  const invoices = new Map<string, InvoiceMetadata>();
  let from = window.from;
  let pageOffset = 0;
  for (;;) {
    let page: MetadataPage;
    try {
      page = await query({ ...window, from }, pageOffset);
    } catch (err) {
      if (err instanceof KsefApiError && err.status === 400 && err.body.includes(FROM_AFTER_HWM_CODE)) {
        return { invoices: [], hwm: null };
      }
      throw err;
    }
    for (const invoice of page.invoices) {
      if (!invoices.has(invoice.ksefNumber)) invoices.set(invoice.ksefNumber, invoice);
    }
    if (!page.hasMore) return { invoices: [...invoices.values()], hwm: page.permanentStorageHwmDate ?? null };
    if (page.isTruncated) {
      from = page.invoices[page.invoices.length - 1]!.permanentStorageDate;
      pageOffset = 0;
    } else {
      pageOffset++;
    }
  }
}

export interface SyncDeps {
  from: string;
  store: Store;
  query: Query;
  download: (ksefNumber: string) => Promise<Buffer>;
  tokenValidUntil: string;
  now: () => Date;
  sleep: (ms: number) => Promise<void>;
  onSaved: (invoice: InvoiceMetadata) => void;
}

export type SyncOutcome = { status: 'complete' } | { status: 'partial'; reason: string };

function partial(reason: string): SyncOutcome {
  return { status: 'partial', reason };
}

export async function syncInvoices(deps: SyncDeps): Promise<SyncOutcome> {
  const { store, now, sleep } = deps;
  let from = deps.from;
  let lastDownloadAt: number | null = null;

  try {
    for (;;) {
      const window = nextWindow(from, now());
      const { invoices, hwm } = await listWindow(deps.query, window);

      for (const invoice of invoices) {
        if (store.has(invoice.ksefNumber)) continue;
        // Both values become part of a path: reject anything unexpected before using them.
        if (!KSEF_NUMBER_PATTERN.test(invoice.ksefNumber)) {
          throw new Error(
            `Nieprawidłowy numer KSeF w odpowiedzi API: ${JSON.stringify(invoice.ksefNumber).slice(0, 60)}`,
          );
        }
        if (!/^\d{4}-\d{2}-\d{2}$/.test(invoice.issueDate)) {
          throw new Error(
            `Nieprawidłowa data wystawienia w odpowiedzi API: ${JSON.stringify(invoice.issueDate).slice(0, 60)}`,
          );
        }
        if (Date.parse(deps.tokenValidUntil) - now().getTime() < TOKEN_MARGIN_MS) {
          return partial('Token dostępu wkrótce wygaśnie.');
        }
        if (lastDownloadAt !== null) {
          const wait = MIN_DOWNLOAD_INTERVAL_MS - (now().getTime() - lastDownloadAt);
          if (wait > 0) await sleep(wait);
        }
        // Counted after the pause, against the current time: KSeF's limit is a rolling hour across runs.
        if (store.savedSince(new Date(now().getTime() - HOUR_MS)) >= MAX_DOWNLOADS_PER_HOUR) {
          return partial(`Limit ${MAX_DOWNLOADS_PER_HOUR} pobrań na godzinę.`);
        }
        lastDownloadAt = now().getTime();
        const bytes = await deps.download(invoice.ksefNumber);
        if (createHash('sha256').update(bytes).digest('base64') !== invoice.invoiceHash) {
          throw new Error(`Skrót pobranej faktury ${invoice.ksefNumber} nie zgadza się z metadanymi KSeF`);
        }
        await store.saveInvoice(invoice, bytes);
        deps.onSaved(invoice);
      }

      // A closed window (backfill) must report an HWM; an open one may not have one yet.
      if (window.to !== undefined && hwm === null) {
        throw new Error(`Nieoczekiwany permanentStorageHwmDate (${hwm}) dla okna ${window.from} – ${window.to}`);
      }
      if (hwm === null) return { status: 'complete' };
      // Everything up to a closed window's `to` is settled even if KSeF reports a later HWM.
      const next = window.to !== undefined && Date.parse(hwm) > Date.parse(window.to) ? window.to : hwm;
      await store.writeCheckpoint(next);
      if (window.to === undefined || next === from) return { status: 'complete' };
      from = next;
    }
  } catch (err) {
    if (err instanceof RateLimitError) return partial(err.message);
    throw err;
  }
}
