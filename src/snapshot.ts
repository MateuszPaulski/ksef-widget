import { readFile } from 'node:fs/promises';
import type { Environment } from './environments.ts';
import { formatAmount, invoiceViewUrl, sellerLabel, warsawDay, type RunSummary } from './report.ts';
import { writeAtomic, type IndexEntry } from './store.ts';

export const SNAPSHOT_INVOICES = 8;

export interface WidgetInvoice {
  ksefNumber: string;
  seller: string;
  invoiceNumber: string;
  amount: string;
  issueDate: string;
  savedAt: string;
  viewUrl: string;
}

export interface WidgetSnapshot {
  updatedAt: string;
  status: 'complete' | 'partial' | 'failed';
  reason?: string;
  today: string;
  savedToday: number;
  invoices: WidgetInvoice[];
}

export function widgetInvoice(entry: IndexEntry, environment: Environment): WidgetInvoice {
  return {
    ksefNumber: entry.ksefNumber,
    seller: sellerLabel({ seller: { nip: entry.sellerNip, name: entry.sellerName } }),
    invoiceNumber: entry.invoiceNumber,
    amount: formatAmount(entry.grossAmount, entry.currency),
    issueDate: entry.issueDate,
    savedAt: entry.savedAt,
    viewUrl: invoiceViewUrl(environment, {
      seller: { nip: entry.sellerNip },
      issueDate: entry.issueDate,
      invoiceHash: entry.invoiceHash,
    }),
  };
}

// `invoices` are in index order, oldest first.
export function buildSnapshot(summary: Pick<RunSummary, 'status' | 'reason'>, invoices: WidgetInvoice[], now: Date): WidgetSnapshot {
  const today = warsawDay(now);
  return {
    updatedAt: now.toISOString(),
    status: summary.status,
    ...(summary.reason === undefined ? {} : { reason: summary.reason }),
    today,
    savedToday: invoices.filter((invoice) => warsawDay(new Date(invoice.savedAt)) === today).length,
    invoices: invoices.slice(-SNAPSHOT_INVOICES).reverse(),
  };
}

export async function writeSnapshot(path: string, snapshot: WidgetSnapshot): Promise<void> {
  await writeAtomic(path, `${JSON.stringify(snapshot, null, 2)}\n`);
}

// A missing, unreadable or malformed file counts as "no previous failure".
export async function readPreviousFailure(path: string): Promise<{ reason: string; today: string } | null> {
  try {
    const parsed: unknown = JSON.parse(await readFile(path, 'utf8'));
    if (typeof parsed !== 'object' || parsed === null) return null;
    const { status, reason, today } = parsed as Record<string, unknown>;
    return status === 'failed' && typeof reason === 'string' && typeof today === 'string' ? { reason, today } : null;
  } catch {
    return null;
  }
}
