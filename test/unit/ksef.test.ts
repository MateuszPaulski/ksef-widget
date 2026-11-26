import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createHttp } from '../../src/http.ts';
import { downloadInvoice, queryMetadata, type MetadataPage } from '../../src/ksef.ts';

const API = 'https://ksef.example.test/v2';

interface Recorded {
  url: string;
  method: string;
  headers: Headers;
  body: string | undefined;
}

function setup(response: Response) {
  const requests: Recorded[] = [];
  const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
    requests.push({
      url: String(input),
      method: init?.method ?? 'GET',
      headers: new Headers(init?.headers),
      body: typeof init?.body === 'string' ? init.body : undefined,
    });
    return response;
  }) as typeof fetch;
  return { http: createHttp(API, { fetch: fetchFn, sleep: async () => {} }), requests };
}

describe('queryMetadata', () => {
  const page: MetadataPage = {
    hasMore: false,
    isTruncated: false,
    permanentStorageHwmDate: '2026-11-26T06:59:00.1234567+00:00',
    invoices: [],
  };

  it('queries purchase invoices by PermanentStorage', async () => {
    const from = '2026-11-25T08:00:00.1234567+00:00';
    const { http, requests } = setup(new Response(JSON.stringify(page), { status: 200 }));

    const result = await queryMetadata(http, 'tok', { from }, 2);

    assert.deepEqual(result, page);
    assert.equal(requests.length, 1);
    const [request] = requests;
    assert.equal(request?.method, 'POST');
    assert.equal(request?.url, `${API}/invoices/query/metadata?sortOrder=Asc&pageOffset=2&pageSize=250`);
    assert.equal(request?.headers.get('Authorization'), 'Bearer tok');
    assert.deepEqual(JSON.parse(request?.body ?? ''), {
      subjectType: 'Subject2',
      dateRange: { dateType: 'PermanentStorage', from, restrictToPermanentStorageHwmDate: true },
    });
  });

  it('sends `to` verbatim when the window has one', async () => {
    const { http, requests } = setup(new Response(JSON.stringify(page), { status: 200 }));
    const window = { from: '2026-01-01T00:00:00Z', to: '2026-04-01T00:00:00.000Z' };

    await queryMetadata(http, 'tok', window, 0);

    assert.deepEqual(JSON.parse(requests[0]?.body ?? ''), {
      subjectType: 'Subject2',
      dateRange: { dateType: 'PermanentStorage', ...window, restrictToPermanentStorageHwmDate: true },
    });
  });
});

describe('downloadInvoice', () => {
  it('downloads raw invoice bytes', async () => {
    const bytes = Buffer.from('<Faktura>\r\n<Nazwa>Spółka ł</Nazwa>\r\n</Faktura>', 'utf8');
    const { http, requests } = setup(new Response(bytes, { status: 200, headers: { 'content-type': 'application/xml' } }));

    const result = await downloadInvoice(http, 'tok', '5265877635-20261126-0123456789AB-CD');

    assert.ok(Buffer.isBuffer(result));
    assert.ok(result.equals(bytes));
    const [request] = requests;
    assert.equal(request?.method, 'GET');
    assert.equal(request?.url, `${API}/invoices/ksef/5265877635-20261126-0123456789AB-CD`);
    assert.equal(request?.headers.get('Accept'), 'application/xml');
    assert.equal(request?.headers.get('Authorization'), 'Bearer tok');
  });
});
