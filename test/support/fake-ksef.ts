import { createHash } from 'node:crypto';
import { ENVIRONMENTS } from '../../src/environments.ts';
import type { InvoiceMetadata } from '../../src/ksef.ts';

const API = ENVIRONMENTS.test.apiBase;
const AUTH_REFERENCE = '20261126-AU-0000000000-0000000000-00';

export interface FakeInvoice {
  metadata: InvoiceMetadata;
  xml: Buffer;
}

/** A purchase invoice whose metadata hash is the real SHA-256 of its XML bytes. */
export function fakeInvoice(n: number): FakeInvoice {
  const xml = Buffer.from(`<Faktura><P_2>FV/${n}</P_2></Faktura>`, 'utf8');
  return {
    xml,
    metadata: {
      ksefNumber: `5265877635-20261120-${n.toString(16).toUpperCase().padStart(6, '0')}123456-AB`,
      invoiceNumber: `FV/${n}`,
      issueDate: '2026-11-20',
      permanentStorageDate: `2026-11-20T09:0${n}:00.1234567+00:00`,
      seller: { nip: '1111111111', name: `Sprzedawca ${n}` },
      grossAmount: 100 * n + 0.5,
      currency: 'PLN',
      invoiceHash: createHash('sha256').update(xml).digest('base64'),
    },
  };
}

export interface FakeKsefOptions {
  invoices: FakeInvoice[];
  hwm: string;
  now: () => Date; // the test's fake clock; token validUntil is derived from it
  authStatus?: { code: number; description: string; details?: string[] };
  downloadStatus?: (ksefNumber: string) => { status: number; headers?: Record<string, string>; body?: string } | undefined;
  fetchError?: Error; // every request throws this
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

/** In-memory stand-in for the KSeF endpoints used by run(). It does not validate the signature. */
export function createFakeKsef(options: FakeKsefOptions): {
  fetch: typeof fetch;
  requests: Array<{ method: string; path: string }>;
} {
  const requests: Array<{ method: string; path: string }> = [];

  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    if (options.fetchError !== undefined) throw options.fetchError;
    const path = String(input).slice(API.length);
    const method = init?.method ?? 'GET';
    requests.push({ method, path });
    const iso = (offsetMs: number) => new Date(options.now().getTime() + offsetMs).toISOString();

    if (method === 'POST' && path === '/auth/challenge') {
      return json(200, {
        challenge: '20261126-CR-0123456789-ABCDEF0123-AB',
        timestamp: iso(0),
        timestampMs: options.now().getTime(),
        clientIp: '203.0.113.1',
      });
    }
    if (method === 'POST' && path.startsWith('/auth/xades-signature')) {
      return json(202, {
        referenceNumber: AUTH_REFERENCE,
        authenticationToken: { token: 'auth', validUntil: iso(10 * 60_000) },
      });
    }
    if (method === 'GET' && path === `/auth/${AUTH_REFERENCE}`) {
      return json(200, { status: options.authStatus ?? { code: 200, description: 'ok' } });
    }
    if (method === 'POST' && path === '/auth/token/redeem') {
      return json(200, {
        accessToken: { token: 'acc', validUntil: iso(15 * 60_000) },
        refreshToken: { token: 'ref', validUntil: iso(24 * 3_600_000) },
      });
    }
    if (method === 'POST' && path.startsWith('/invoices/query/metadata')) {
      return json(200, {
        hasMore: false,
        isTruncated: false,
        permanentStorageHwmDate: options.hwm,
        invoices: options.invoices.map((invoice) => invoice.metadata),
      });
    }
    if (method === 'GET' && path.startsWith('/invoices/ksef/')) {
      const ksefNumber = path.slice('/invoices/ksef/'.length);
      const override = options.downloadStatus?.(ksefNumber);
      if (override !== undefined) return new Response(override.body ?? '', { status: override.status, headers: override.headers });
      const invoice = options.invoices.find((candidate) => candidate.metadata.ksefNumber === ksefNumber);
      if (invoice === undefined) return new Response('', { status: 404 });
      return new Response(new Uint8Array(invoice.xml), { status: 200, headers: { 'content-type': 'application/xml' } });
    }
    return new Response('', { status: 404 });
  }) as typeof fetch;

  return { fetch: fakeFetch, requests };
}
