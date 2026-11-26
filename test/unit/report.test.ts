import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import type { InvoiceMetadata } from '../../src/ksef.ts';
import {
  escapeMarkdown,
  formatAmount,
  formatNotification,
  formatReportSection,
  invoiceCountLabel,
  invoiceViewUrl,
  warsawDay,
  type RunSummary,
} from '../../src/report.ts';

const NBSP = ' ';

function invoice(overrides: Partial<InvoiceMetadata> = {}, name: string | null | undefined = 'Acme Sp. z o.o.'): InvoiceMetadata {
  return {
    ksefNumber: '1111111111-20260201-0123456789AB-CD',
    invoiceNumber: 'FV/1/2026',
    issueDate: '2026-02-01',
    permanentStorageDate: '2026-02-01T09:00:00.1234567+00:00',
    seller: { nip: '1111111111', name },
    grossAmount: 12345.67,
    currency: 'PLN',
    invoiceHash: 'UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE=',
    ...overrides,
  };
}

const startedAt = new Date('2026-11-26T07:00:12Z'); // 08:00:12 in Warsaw (CET)

describe('formatAmount', () => {
  it('formats with Polish grouping and two decimals', () => {
    assert.equal(formatAmount(12345.67, 'PLN'), `12${NBSP}345,67 PLN`);
    assert.equal(formatAmount(53.63, 'EUR'), '53,63 EUR');
    assert.equal(formatAmount(10, 'PLN'), '10,00 PLN');
  });
});

describe('invoiceViewUrl', () => {
  it('builds the KOD I link with a Base64URL hash', () => {
    assert.equal(
      invoiceViewUrl('prod', invoice()),
      'https://qr.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE',
    );
    assert.ok(invoiceViewUrl('test', invoice()).startsWith('https://qr-test.ksef.mf.gov.pl/invoice/'));
  });
});

describe('invoiceCountLabel', () => {
  it('inflects like Polish', () => {
    assert.equal(invoiceCountLabel(1), '1 nowa faktura');
    for (const n of [2, 3, 4, 22, 104]) assert.equal(invoiceCountLabel(n), `${n} nowe faktury`);
    for (const n of [5, 11, 12, 13, 14, 21, 112]) assert.equal(invoiceCountLabel(n), `${n} nowych faktur`);
  });
});

describe('escapeMarkdown', () => {
  it('escapes Markdown characters and collapses newlines', () => {
    assert.equal(escapeMarkdown('\\ ` * _ [ ] < > # |'), '\\\\ \\` \\* \\_ \\[ \\] \\< \\> \\# \\|');
    assert.equal(escapeMarkdown('a\r\n\nb\rc'), 'a b c');
  });
});

describe('warsawDay', () => {
  it('uses the Europe/Warsaw calendar day', () => {
    assert.equal(warsawDay(new Date('2026-11-26T23:30:00Z')), '2026-11-27');
    assert.equal(warsawDay(new Date('2026-07-01T21:59:00Z')), '2026-07-01');
    assert.equal(warsawDay(new Date('2026-07-01T22:00:00Z')), '2026-07-02');
  });
});

describe('formatReportSection', () => {
  it('lists saved invoices', () => {
    const summary: RunSummary = { startedAt, status: 'complete', saved: [invoice(), invoice({ invoiceNumber: 'FV/2' }, null)] };
    assert.equal(
      formatReportSection(summary, 'prod'),
      [
        '## Uruchomienie 08:00:12',
        '',
        'Status: zakończone',
        'Nowe faktury: 2',
        '',
        `- **Acme Sp. z o.o.** (NIP 1111111111) — nr FV/1/2026, 12${NBSP}345,67 PLN, wystawiona 01.02.2026 — [podgląd w KSeF](https://qr.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE) — \`1111111111-20260201-0123456789AB-CD\``,
        `- **NIP 1111111111** (NIP 1111111111) — nr FV/2, 12${NBSP}345,67 PLN, wystawiona 01.02.2026 — [podgląd w KSeF](https://qr.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE) — \`1111111111-20260201-0123456789AB-CD\``,
      ].join('\n'),
    );
  });

  it('omits the list when nothing was saved and shows partial and failed reasons', () => {
    assert.equal(
      formatReportSection({ startedAt, status: 'partial', reason: 'Limit 60 pobrań na godzinę.', saved: [] }, 'prod'),
      '## Uruchomienie 08:00:12\n\nStatus: częściowe — Limit 60 pobrań na godzinę.\nNowe faktury: 0',
    );
    assert.equal(
      formatReportSection({ startedAt, status: 'failed', reason: 'Brak połączenia z KSeF: fetch failed', saved: [] }, 'prod'),
      '## Uruchomienie 08:00:12\n\nStatus: BŁĄD — Brak połączenia z KSeF: fetch failed\nNowe faktury: 0',
    );
  });

  it('escapes a hostile seller onto a single line', () => {
    const hostile = invoice({ invoiceNumber: 'FV|1\n# x' }, 'Evil*Corp [x](http://e) | # <b>\nline2');
    const section = formatReportSection({ startedAt, status: 'complete', saved: [hostile] }, 'prod');
    const bullets = section.split('\n').filter((line) => line.startsWith('- '));
    assert.equal(bullets.length, 1);
    assert.ok(bullets[0]?.includes('Evil\\*Corp \\[x\\](http://e) \\| \\# \\<b\\> line2'));
    assert.ok(bullets[0]?.includes('nr FV\\|1 \\# x'));
    assert.ok(!section.split('\n').some((line) => line.startsWith('# ')));
  });
});

describe('formatNotification', () => {
  const many = (n: number) => Array.from({ length: n }, (_, i) => invoice({ grossAmount: 10 + i }, `Sprzedawca ${i + 1}`));

  it('is null for a complete run with nothing new', () => {
    assert.equal(formatNotification({ startedAt, status: 'complete', saved: [] }), null);
  });

  it('summarises new invoices', () => {
    assert.deepEqual(formatNotification({ startedAt, status: 'complete', saved: many(2) }), {
      title: 'KSeF: 2 nowe faktury',
      message: 'Sprzedawca 1: 10,00 PLN; Sprzedawca 2: 11,00 PLN',
    });
    assert.deepEqual(formatNotification({ startedAt, status: 'complete', saved: many(5) }), {
      title: 'KSeF: 5 nowych faktur',
      message: 'Sprzedawca 1: 10,00 PLN; Sprzedawca 2: 11,00 PLN; Sprzedawca 3: 12,00 PLN; i 2 więcej',
    });
  });

  it('falls back to the NIP when the seller has no name', () => {
    assert.deepEqual(formatNotification({ startedAt, status: 'complete', saved: [invoice({}, '')] }), {
      title: 'KSeF: 1 nowa faktura',
      message: `NIP 1111111111: 12${NBSP}345,67 PLN`,
    });
  });

  it('describes a partial run', () => {
    assert.deepEqual(
      formatNotification({ startedAt, status: 'partial', reason: 'Limit 60 pobrań na godzinę.', saved: many(1) }),
      {
        title: 'KSeF: pobrano częściowo (1)',
        message: 'Limit 60 pobrań na godzinę. Reszta przy następnym uruchomieniu.',
      },
    );
  });

  it('describes a failed run', () => {
    assert.deepEqual(formatNotification({ startedAt, status: 'failed', reason: 'Brak połączenia z KSeF: x', saved: [] }), {
      title: 'KSeF: błąd pobierania faktur',
      message: 'Brak połączenia z KSeF: x',
    });
    assert.equal(
      formatNotification({ startedAt, status: 'failed', reason: 'Błąd.', saved: many(2) })?.message,
      'Błąd. Zapisano wcześniej: 2.',
    );
  });

  it('truncates a failed message to 240 characters', () => {
    const message = formatNotification({ startedAt, status: 'failed', reason: 'x'.repeat(500), saved: [] })?.message;
    assert.equal(message?.length, 240);
    assert.ok(message?.endsWith('…'));
  });
});
