import { ENVIRONMENTS, type Environment } from './environments.ts';
import type { InvoiceMetadata } from './ksef.ts';

export interface RunSummary {
  startedAt: Date;
  status: 'complete' | 'partial' | 'failed';
  reason?: string;
  saved: InvoiceMetadata[];
}

const NOTIFICATION_MAX_CHARS = 240;
const NOTIFICATION_LISTED_INVOICES = 3;

const amountFormat = new Intl.NumberFormat('pl-PL', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const dayFormat = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Warsaw' });
const timeFormat = new Intl.DateTimeFormat('sv-SE', {
  timeZone: 'Europe/Warsaw',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23',
});

export function formatAmount(amount: number, currency: string): string {
  return `${amountFormat.format(amount)} ${currency}`;
}

function reverseDate(issueDate: string, separator: string): string {
  return issueDate.split('-').reverse().join(separator);
}

export function invoiceViewUrl(environment: Environment, invoice: InvoiceMetadata): string {
  const hash = invoice.invoiceHash.replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
  return `${ENVIRONMENTS[environment].qrBase}/invoice/${invoice.seller.nip}/${reverseDate(invoice.issueDate, '-')}/${hash}`;
}

export function invoiceCountLabel(n: number): string {
  if (n === 1) return '1 nowa faktura';
  const lastTwo = n % 100;
  const isFew = n % 10 >= 2 && n % 10 <= 4 && (lastTwo < 12 || lastTwo > 14);
  return isFew ? `${n} nowe faktury` : `${n} nowych faktur`;
}

export function escapeMarkdown(text: string): string {
  return text.replace(/[\r\n]+/g, ' ').replace(/[\\`*_[\]<>#|]/g, '\\$&');
}

export function warsawDay(date: Date): string {
  return dayFormat.format(date);
}

function sellerLabel(invoice: InvoiceMetadata): string {
  return invoice.seller.name ? invoice.seller.name : `NIP ${invoice.seller.nip}`;
}

export function formatReportSection(summary: RunSummary, environment: Environment): string {
  const reason = escapeMarkdown(summary.reason ?? '');
  const status =
    summary.status === 'complete' ? 'zakończone' : summary.status === 'partial' ? `częściowe — ${reason}` : `BŁĄD — ${reason}`;
  const lines = [
    `## Uruchomienie ${timeFormat.format(summary.startedAt)}`,
    '',
    `Status: ${status}`,
    `Nowe faktury: ${summary.saved.length}`,
  ];
  if (summary.saved.length > 0) lines.push('');
  for (const invoice of summary.saved) {
    lines.push(
      `- **${escapeMarkdown(sellerLabel(invoice))}** (NIP ${invoice.seller.nip})` +
        ` — nr ${escapeMarkdown(invoice.invoiceNumber)}, ${formatAmount(invoice.grossAmount, invoice.currency)}` +
        `, wystawiona ${reverseDate(invoice.issueDate, '.')}` +
        ` — [podgląd w KSeF](${invoiceViewUrl(environment, invoice)}) — \`${invoice.ksefNumber}\``,
    );
  }
  return lines.join('\n');
}

export function formatNotification(summary: RunSummary): { title: string; message: string } | null {
  const n = summary.saved.length;
  const reason = summary.reason ?? '';
  if (summary.status === 'partial') {
    return { title: `KSeF: pobrano częściowo (${n})`, message: `${reason} Reszta przy następnym uruchomieniu.` };
  }
  if (summary.status === 'failed') {
    const message = `${reason}${n > 0 ? ` Zapisano wcześniej: ${n}.` : ''}`;
    return {
      title: 'KSeF: błąd pobierania faktur',
      message: message.length > NOTIFICATION_MAX_CHARS ? `${message.slice(0, NOTIFICATION_MAX_CHARS - 1)}…` : message,
    };
  }
  if (n === 0) return null;
  const listed = summary.saved
    .slice(0, NOTIFICATION_LISTED_INVOICES)
    .map((invoice) => `${sellerLabel(invoice)}: ${formatAmount(invoice.grossAmount, invoice.currency)}`);
  if (n > NOTIFICATION_LISTED_INVOICES) listed.push(`i ${n - NOTIFICATION_LISTED_INVOICES} więcej`);
  return { title: `KSeF: ${invoiceCountLabel(n)}`, message: listed.join('; ') };
}
