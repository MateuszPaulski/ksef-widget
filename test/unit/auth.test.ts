import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { loadCredentials, type Credentials } from '../../src/credentials.ts';
import type { Environment } from '../../src/environments.ts';
import { KsefApiError, createHttp } from '../../src/http.ts';
import { authenticate } from '../../src/ksef.ts';
import { makeTestCredentials } from '../support/certs.ts';
import { randomNip } from '../support/nip.ts';

const API = 'https://ksef.example.test/v2';
const NIP = '5265877635';
const REFERENCE = 'a1b2c3d4-0000-4000-8000-000000000000';

interface RecordedRequest {
  method: string;
  path: string;
  headers: Headers;
  body: string | undefined;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

/** Fake fetch answering by "METHOD /path" (query included); each answer may be a single response or a queue. */
function fakeKsef(answers: Record<string, Response | Response[] | (() => Response)>) {
  const requests: RecordedRequest[] = [];
  const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
    const path = String(input).slice(API.length);
    const method = init?.method ?? 'GET';
    requests.push({
      method,
      path,
      headers: new Headers(init?.headers),
      body: typeof init?.body === 'string' ? init.body : undefined,
    });
    const answer = answers[`${method} ${path}`];
    if (answer === undefined) throw new Error(`unexpected request ${method} ${path}`);
    if (typeof answer === 'function') return answer();
    return Array.isArray(answer) ? answer.shift()! : answer;
  }) as typeof fetch;
  return { fetch: fetchFn, requests };
}

function setup(answers: Record<string, Response | Response[] | (() => Response)>) {
  const fake = fakeKsef(answers);
  const sleeps: number[] = [];
  const sleep = async (ms: number) => {
    sleeps.push(ms);
  };
  const http = createHttp(API, { fetch: fake.fetch, sleep });
  return { ...fake, sleeps, sleep, http };
}

const challenge = () => json(200, { challenge: '20261126-CR-0123456789-ABCDEF0123-AB', timestamp: '2026-11-26T08:00:00+00:00', timestampMs: 1, clientIp: '127.0.0.1' });
const accepted = () => json(202, { referenceNumber: REFERENCE, authenticationToken: { token: 'auth-token', validUntil: '2026-11-26T08:10:00+00:00' } });
const status = (code: number, extra: object = {}) => json(200, { status: { code, description: 'x', ...extra } });
const redeemed = () => json(200, { accessToken: { token: 'acc', validUntil: '2026-11-26T08:15:00+00:00' }, refreshToken: { token: 'ref', validUntil: '2026-11-27T08:00:00+00:00' } });

describe('authenticate', () => {
  let dir: string;
  let credentials: Credentials;

  before(async () => {
    dir = await mkdtemp(join(tmpdir(), 'ksef-auth-'));
    const files = await makeTestCredentials({ nip: randomNip(), keyType: 'rsa', dir });
    credentials = await loadCredentials(files.certificatePath, files.keyPath, files.password);
  });

  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('authenticates: challenge, signed XML, polls until 200, redeems', async () => {
    const t = setup({
      'POST /auth/challenge': challenge,
      'POST /auth/xades-signature?verifyCertificateChain=false': accepted,
      [`GET /auth/${REFERENCE}`]: [status(100), status(100), status(200)],
      'POST /auth/token/redeem': redeemed,
    });

    const token = await authenticate(t.http, credentials, NIP, 'test', { sleep: t.sleep });

    assert.deepEqual(token, { token: 'acc', validUntil: '2026-11-26T08:15:00+00:00' });
    assert.deepEqual(
      t.requests.map((r) => `${r.method} ${r.path}`),
      [
        'POST /auth/challenge',
        'POST /auth/xades-signature?verifyCertificateChain=false',
        `GET /auth/${REFERENCE}`,
        `GET /auth/${REFERENCE}`,
        `GET /auth/${REFERENCE}`,
        'POST /auth/token/redeem',
      ],
    );
    assert.deepEqual(t.sleeps, [1000, 1000]);
    const upload = t.requests[1]!;
    assert.equal(upload.headers.get('content-type'), 'application/xml');
    assert.ok(upload.body?.includes('<ds:Signature'));
    assert.ok(upload.body?.includes('<Challenge>20261126-CR-0123456789-ABCDEF0123-AB</Challenge>'));
    for (const request of t.requests.slice(2)) {
      assert.equal(request.headers.get('authorization'), 'Bearer auth-token');
    }
  });

  it('omits verifyCertificateChain outside test', async () => {
    const environment: Environment = 'prod';
    const t = setup({
      'POST /auth/challenge': challenge,
      'POST /auth/xades-signature': accepted,
      [`GET /auth/${REFERENCE}`]: status(200),
      'POST /auth/token/redeem': redeemed,
    });

    await authenticate(t.http, credentials, NIP, environment, { sleep: t.sleep });

    assert.equal(t.requests[1]!.path, '/auth/xades-signature');
  });

  it('fails with KSeF status details', async () => {
    const t = setup({
      'POST /auth/challenge': challenge,
      'POST /auth/xades-signature?verifyCertificateChain=false': accepted,
      [`GET /auth/${REFERENCE}`]: status(460, {
        description: 'Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu',
        details: ['Certyfikat odwołany'],
      }),
    });

    await assert.rejects(authenticate(t.http, credentials, NIP, 'test', { sleep: t.sleep }), {
      message:
        'Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)',
    });
  });

  it('gives up after 120 polls', async () => {
    const t = setup({
      'POST /auth/challenge': challenge,
      'POST /auth/xades-signature?verifyCertificateChain=false': accepted,
      [`GET /auth/${REFERENCE}`]: () => status(100),
    });

    await assert.rejects(authenticate(t.http, credentials, NIP, 'test', { sleep: t.sleep }), {
      message: 'Uwierzytelnienie w KSeF nie zakończyło się w 120 s',
    });
    assert.equal(t.requests.filter((r) => r.path === `/auth/${REFERENCE}`).length, 120);
  });

  it('turns a non-2xx answer into KsefApiError', async () => {
    const t = setup({ 'POST /auth/challenge': json(500, { x: 1 }) });

    await assert.rejects(
      authenticate(t.http, credentials, NIP, 'test', { sleep: t.sleep }),
      (err: unknown) => {
        assert.ok(err instanceof KsefApiError);
        assert.equal(err.status, 500);
        assert.equal(err.message, 'KSeF odpowiedział 500 na POST /auth/challenge: {"x":1}');
        return true;
      },
    );
  });
});
