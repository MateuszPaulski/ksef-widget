import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { describe, it } from 'node:test';
import { KsefApiError, RateLimitError } from '../../src/http.ts';
import type { InvoiceMetadata, MetadataPage, Window } from '../../src/ksef.ts';
import type { Store } from '../../src/store.ts';
import {
  KSEF_NUMBER_PATTERN,
  MAX_DOWNLOADS_PER_RUN,
  listWindow,
  nextWindow,
  syncInvoices,
  type Query,
  type SyncDeps,
} from '../../src/sync.ts';

const NOW = new Date('2026-11-26T08:00:00Z');
const HWM = '2026-11-26T07:00:00.1234567+00:00';

function sha256(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('base64');
}

function makeInvoice(n: number, overrides: Partial<InvoiceMetadata> = {}): { metadata: InvoiceMetadata; xml: Buffer } {
  const xml = Buffer.from(`<Faktura>${n}</Faktura>`);
  const hex = n.toString(16).toUpperCase().padStart(6, '0');
  const metadata: InvoiceMetadata = {
    ksefNumber: `5265877635-20261120-${hex}123456-AB`,
    invoiceNumber: `FV/${n}`,
    issueDate: '2026-11-20',
    permanentStorageDate: `2026-11-20T09:${String(n % 60).padStart(2, '0')}:00.1234567+00:00`,
    seller: { nip: '1111111111', name: 'Sprzedawca' },
    grossAmount: 100 + n,
    currency: 'PLN',
    invoiceHash: sha256(xml),
    ...overrides,
  };
  return { metadata, xml };
}

function page(invoices: InvoiceMetadata[], extra: Partial<MetadataPage> = {}): MetadataPage {
  return { hasMore: false, isTruncated: false, permanentStorageHwmDate: HWM, invoices, ...extra };
}

function fakeStore(initiallySaved: string[] = []) {
  const saved = new Set(initiallySaved);
  const saves: string[] = [];
  const checkpoints: string[] = [];
  const store: Store = {
    checkpoint: null,
    has: (ksefNumber) => saved.has(ksefNumber),
    async saveInvoice(invoice) {
      saves.push(invoice.ksefNumber);
      saved.add(invoice.ksefNumber);
    },
    async writeCheckpoint(value) {
      checkpoints.push(value);
    },
  };
  return { store, saves, checkpoints };
}

function fakeClock(start: Date = NOW) {
  let current = start.getTime();
  const sleeps: number[] = [];
  return {
    now: () => new Date(current),
    sleep: async (ms: number) => {
      sleeps.push(ms);
      current += ms;
    },
    sleeps,
  };
}

interface Harness {
  deps: SyncDeps;
  saves: string[];
  checkpoints: string[];
  downloads: string[];
  onSaved: string[];
  queries: Array<{ window: Window; pageOffset: number }>;
  sleeps: number[];
}

function harness(options: {
  query: Query;
  invoices?: Array<{ metadata: InvoiceMetadata; xml: Buffer }>;
  alreadySaved?: string[];
  from?: string;
  tokenValidUntil?: (now: Date) => string;
  download?: (ksefNumber: string) => Promise<Buffer>;
}): Harness {
  const clock = fakeClock();
  const { store, saves, checkpoints } = fakeStore(options.alreadySaved);
  const xmlByNumber = new Map((options.invoices ?? []).map(({ metadata, xml }) => [metadata.ksefNumber, xml]));
  const downloads: string[] = [];
  const onSaved: string[] = [];
  const queries: Harness['queries'] = [];
  const deps: SyncDeps = {
    from: options.from ?? '2026-11-25T08:00:00.1234567+00:00',
    store,
    query: async (window, pageOffset) => {
      queries.push({ window, pageOffset });
      return options.query(window, pageOffset);
    },
    download: async (ksefNumber) => {
      downloads.push(ksefNumber);
      if (options.download !== undefined) return options.download(ksefNumber);
      const xml = xmlByNumber.get(ksefNumber);
      if (xml === undefined) throw new Error(`no xml for ${ksefNumber}`);
      return xml;
    },
    tokenValidUntil: (options.tokenValidUntil ?? ((now) => new Date(now.getTime() + 15 * 60_000).toISOString()))(NOW),
    now: clock.now,
    sleep: clock.sleep,
    onSaved: (invoice) => onSaved.push(invoice.ksefNumber),
  };
  return { deps, saves, checkpoints, downloads, onSaved, queries, sleeps: clock.sleeps };
}

describe('KSEF_NUMBER_PATTERN', () => {
  it('accepts a real-looking number and rejects path traversal', () => {
    assert.ok(KSEF_NUMBER_PATTERN.test('5265877635-20261126-0123456789AB-CD'));
    assert.ok(!KSEF_NUMBER_PATTERN.test('../../etc/passwd'));
  });
});

describe('nextWindow', () => {
  it('closes the window 90 days after from when that is in the past', () => {
    assert.deepEqual(nextWindow('2026-01-01T00:00:00Z', NOW), {
      from: '2026-01-01T00:00:00Z',
      to: '2026-04-01T00:00:00.000Z',
    });
  });

  it('leaves the window open otherwise and keeps from verbatim', () => {
    assert.deepEqual(nextWindow('2026-11-01T00:00:00.1234567+00:00', NOW), {
      from: '2026-11-01T00:00:00.1234567+00:00',
    });
  });

  it('parses KSeF 7-digit fractions with an offset', () => {
    assert.deepEqual(nextWindow('2026-01-01T00:00:00.1234567+00:00', NOW), {
      from: '2026-01-01T00:00:00.1234567+00:00',
      to: '2026-04-01T00:00:00.123Z',
    });
  });
});

describe('listWindow', () => {
  const window: Window = { from: '2026-11-25T08:00:00.1234567+00:00' };
  const [a, b, c] = [1, 2, 3].map((n) => makeInvoice(n).metadata) as [InvoiceMetadata, InvoiceMetadata, InvoiceMetadata];

  it('pages until hasMore is false', async () => {
    const calls: Array<[Window, number]> = [];
    const pages = [page([a, b], { hasMore: true, permanentStorageHwmDate: 'first' }), page([c], { permanentStorageHwmDate: 'last' })];
    const result = await listWindow(async (w, offset) => {
      calls.push([w, offset]);
      return pages.shift()!;
    }, window);
    assert.deepEqual(calls, [[window, 0], [window, 1]]);
    assert.deepEqual(result.invoices, [a, b, c]);
    assert.equal(result.hwm, 'last');
  });

  it('narrows from on truncation and dedupes', async () => {
    const closed: Window = { ...window, to: '2026-11-26T00:00:00.000Z' };
    const calls: Array<[Window, number]> = [];
    const pages = [page([a, b], { hasMore: true, isTruncated: true }), page([b, c])];
    const result = await listWindow(async (w, offset) => {
      calls.push([w, offset]);
      return pages.shift()!;
    }, closed);
    assert.deepEqual(calls, [[closed, 0], [{ from: b.permanentStorageDate, to: closed.to }, 0]]);
    assert.deepEqual(result.invoices, [a, b, c]);
  });

  it('treats 21183 as nothing settled yet', async () => {
    const result = await listWindow(async () => {
      throw new KsefApiError(400, 'POST', '/invoices/query/metadata', '{"exception":{"exceptionCode":21183}}');
    }, window);
    assert.deepEqual(result, { invoices: [], hwm: null });
    await assert.rejects(
      listWindow(async () => {
        throw new KsefApiError(400, 'POST', '/invoices/query/metadata', '{"exception":{"exceptionCode":21111}}');
      }, window),
      KsefApiError,
    );
  });

  it('reports a missing HWM as null', async () => {
    const result = await listWindow(async () => page([a], { permanentStorageHwmDate: null }), window);
    assert.equal(result.hwm, null);
  });
});

describe('syncInvoices', () => {
  it('saves new invoices in order and advances the checkpoint to the HWM', async () => {
    const [a, b, c] = [1, 2, 3].map((n) => makeInvoice(n)) as [ReturnType<typeof makeInvoice>, ReturnType<typeof makeInvoice>, ReturnType<typeof makeInvoice>];
    const h = harness({
      query: async () => page([a.metadata, b.metadata, c.metadata]),
      invoices: [a, b, c],
      alreadySaved: [b.metadata.ksefNumber],
    });

    const outcome = await syncInvoices(h.deps);

    assert.deepEqual(outcome, { status: 'complete' });
    assert.deepEqual(h.downloads, [a.metadata.ksefNumber, c.metadata.ksefNumber]);
    assert.deepEqual(h.saves, [a.metadata.ksefNumber, c.metadata.ksefNumber]);
    assert.deepEqual(h.onSaved, [a.metadata.ksefNumber, c.metadata.ksefNumber]);
    assert.deepEqual(h.checkpoints, [HWM]);
  });

  it('walks a closed window then the open one', async () => {
    const hwm2 = '2026-11-26T07:30:00.7654321+00:00';
    const from = new Date(NOW.getTime() - 100 * 86_400_000).toISOString();
    const h = harness({
      from,
      query: async (w) => page([], { permanentStorageHwmDate: w.to ?? hwm2 }),
    });

    const outcome = await syncInvoices(h.deps);

    assert.deepEqual(outcome, { status: 'complete' });
    assert.equal(h.queries.length, 2);
    const first = h.queries[0]!.window;
    assert.equal(first.from, from);
    assert.ok(first.to !== undefined);
    assert.deepEqual(h.queries[1]!.window, { from: first.to });
    assert.deepEqual(h.checkpoints, [first.to, hwm2]);
  });

  it('a closed window with an HWM past its end settles up to its end and continues', async () => {
    const hwm2 = '2026-11-26T07:30:00.7654321+00:00';
    const from = new Date(NOW.getTime() - 100 * 86_400_000).toISOString();
    const h = harness({
      from,
      query: async (w) =>
        page([], {
          permanentStorageHwmDate: w.to === undefined ? hwm2 : new Date(Date.parse(w.to) + 86_400_000).toISOString(),
        }),
    });

    const outcome = await syncInvoices(h.deps);

    assert.deepEqual(outcome, { status: 'complete' });
    const first = h.queries[0]!.window;
    assert.deepEqual(h.queries[1]!.window, { from: first.to });
    assert.deepEqual(h.checkpoints, [first.to, hwm2]);
  });

  it('stops when the HWM did not move past from', async () => {
    const h = harness({ query: async () => page([], { permanentStorageHwmDate: '2026-11-25T08:00:00.1234567+00:00' }) });
    const outcome = await syncInvoices(h.deps);
    assert.deepEqual(outcome, { status: 'complete' });
    assert.equal(h.queries.length, 1);
  });

  it('a rate limit mid-window is partial and keeps the checkpoint', async () => {
    const [a, b] = [1, 2].map((n) => makeInvoice(n)) as [ReturnType<typeof makeInvoice>, ReturnType<typeof makeInvoice>];
    const h = harness({
      query: async () => page([a.metadata, b.metadata]),
      invoices: [a, b],
      download: async (ksefNumber) => {
        if (ksefNumber === b.metadata.ksefNumber) throw new RateLimitError(600);
        return a.xml;
      },
    });

    const outcome = await syncInvoices(h.deps);

    assert.deepEqual(outcome, { status: 'partial', reason: 'Limit zapytań KSeF — trzeba odczekać 600 s.' });
    assert.deepEqual(h.saves, [a.metadata.ksefNumber]);
    assert.deepEqual(h.checkpoints, []);
  });

  it('a rate limit while listing is partial too', async () => {
    const h = harness({
      query: async () => {
        throw new RateLimitError(900);
      },
    });
    const outcome = await syncInvoices(h.deps);
    assert.deepEqual(outcome, { status: 'partial', reason: 'Limit zapytań KSeF — trzeba odczekać 900 s.' });
  });

  it('stops at the per-run download cap', async () => {
    const all = Array.from({ length: MAX_DOWNLOADS_PER_RUN + 1 }, (_, i) => makeInvoice(i + 1));
    const h = harness({ query: async () => page(all.map((i) => i.metadata)), invoices: all });

    const outcome = await syncInvoices(h.deps);

    assert.deepEqual(outcome, { status: 'partial', reason: 'Limit 60 pobrań na jedno uruchomienie.' });
    assert.equal(h.saves.length, 60);
    assert.deepEqual(h.checkpoints, []);
  });

  it('paces downloads', async () => {
    const all = [1, 2, 3].map((n) => makeInvoice(n));
    const h = harness({ query: async () => page(all.map((i) => i.metadata)), invoices: all });
    await syncInvoices(h.deps);
    assert.deepEqual(h.sleeps, [4000, 4000]);
  });

  it('a token about to expire ends the run', async () => {
    const a = makeInvoice(1);
    const h = harness({
      query: async () => page([a.metadata]),
      invoices: [a],
      tokenValidUntil: (now) => new Date(now.getTime() + 30_000).toISOString(),
    });

    const outcome = await syncInvoices(h.deps);

    assert.deepEqual(outcome, { status: 'partial', reason: 'Token dostępu wkrótce wygaśnie.' });
    assert.deepEqual(h.downloads, []);
    assert.deepEqual(h.checkpoints, []);
  });

  it('fails on a hash mismatch', async () => {
    const a = makeInvoice(1, { invoiceHash: sha256(Buffer.from('other')) });
    const h = harness({ query: async () => page([a.metadata]), invoices: [a] });

    await assert.rejects(syncInvoices(h.deps), {
      message: `Skrót pobranej faktury ${a.metadata.ksefNumber} nie zgadza się z metadanymi KSeF`,
    });
    assert.deepEqual(h.saves, []);
  });

  it('rejects a hostile ksefNumber before download', async () => {
    const a = makeInvoice(1, { ksefNumber: '../../etc/passwd' });
    const h = harness({ query: async () => page([a.metadata]), invoices: [a] });

    await assert.rejects(syncInvoices(h.deps), {
      message: 'Nieprawidłowy numer KSeF w odpowiedzi API: "../../etc/passwd"',
    });
    assert.deepEqual(h.downloads, []);
    assert.deepEqual(h.saves, []);
    assert.deepEqual(h.checkpoints, []);
  });

  it('rejects a hostile issueDate before download', async () => {
    const a = makeInvoice(1, { issueDate: '../../x' });
    const h = harness({ query: async () => page([a.metadata]), invoices: [a] });

    await assert.rejects(syncInvoices(h.deps), {
      message: 'Nieprawidłowa data wystawienia w odpowiedzi API: "../../x"',
    });
    assert.deepEqual(h.downloads, []);
    assert.deepEqual(h.saves, []);
  });

  it('keeps the checkpoint on a null HWM of the open window', async () => {
    const h = harness({ query: async () => page([], { permanentStorageHwmDate: null }) });
    const outcome = await syncInvoices(h.deps);
    assert.deepEqual(outcome, { status: 'complete' });
    assert.deepEqual(h.checkpoints, []);
  });

  it('a closed window must report an HWM', async () => {
    const from = new Date(NOW.getTime() - 100 * 86_400_000).toISOString();
    const h = harness({ from, query: async () => page([], { permanentStorageHwmDate: null }) });

    await assert.rejects(syncInvoices(h.deps), (err: Error) => {
      const window = h.queries[0]!.window;
      assert.equal(err.message, `Nieoczekiwany permanentStorageHwmDate (null) dla okna ${window.from} – ${window.to}`);
      return true;
    });
    assert.deepEqual(h.checkpoints, []);
  });
});
