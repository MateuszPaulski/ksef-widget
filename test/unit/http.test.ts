import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { KsefApiError, RateLimitError, createHttp } from '../../src/http.ts';

const API = 'https://ksef.example.test/v2';

type Step = Response | Error;

function setup(steps: Step[]) {
  const inits: Array<RequestInit | undefined> = [];
  const sleeps: number[] = [];
  const fetchFn = (async (_input: string | URL | Request, init?: RequestInit) => {
    inits.push(init);
    const step = steps.shift();
    if (step === undefined) throw new Error('unexpected extra fetch call');
    if (step instanceof Error) throw step;
    return step;
  }) as typeof fetch;
  const http = createHttp(API, {
    fetch: fetchFn,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
  });
  return { http, inits, sleeps };
}

function rateLimited(retryAfter?: string): Response {
  return new Response('', { status: 429, headers: retryAfter === undefined ? {} : { 'Retry-After': retryAfter } });
}

describe('createHttp resilience', () => {
  it('waits out a short Retry-After', async () => {
    const { http, sleeps } = setup([rateLimited('5'), new Response('ok', { status: 200 })]);
    const response = await http('GET', '/x');
    assert.equal(await response.text(), 'ok');
    assert.deepEqual(sleeps, [5000]);
  });

  it('counts a missing Retry-After as 60 s', async () => {
    const { http, sleeps } = setup([rateLimited(), new Response('ok', { status: 200 })]);
    await http('GET', '/x');
    assert.deepEqual(sleeps, [60_000]);
  });

  it('ends with RateLimitError on a long Retry-After', async () => {
    const { http, sleeps } = setup([rateLimited('600')]);
    await assert.rejects(http('GET', '/x'), (err: unknown) => {
      assert.ok(err instanceof RateLimitError);
      assert.equal(err.retryAfterSeconds, 600);
      assert.equal(err.message, 'Limit zapytań KSeF — trzeba odczekać 600 s.');
      return true;
    });
    assert.deepEqual(sleeps, []);
  });

  it('treats a non-numeric Retry-After as longer than the threshold', async () => {
    const { http, sleeps } = setup([rateLimited('soon')]);
    await assert.rejects(http('GET', '/x'), RateLimitError);
    assert.deepEqual(sleeps, []);
  });

  it('gives up after three rate-limit retries', async () => {
    const { http, inits, sleeps } = setup([rateLimited('1'), rateLimited('1'), rateLimited('1'), rateLimited('1')]);
    await assert.rejects(http('GET', '/x'), RateLimitError);
    assert.equal(inits.length, 4);
    assert.deepEqual(sleeps, [1000, 1000, 1000]);
  });

  it('retries network errors', async () => {
    const { http, sleeps } = setup([
      new TypeError('fetch failed'),
      new TypeError('fetch failed'),
      new Response('ok', { status: 200 }),
    ]);
    const response = await http('GET', '/x');
    assert.equal(await response.text(), 'ok');
    assert.deepEqual(sleeps, [30_000, 30_000]);
  });

  it('fails after the network retries are used up', async () => {
    const { http, inits } = setup([
      new TypeError('fetch failed'),
      new TypeError('fetch failed'),
      new TypeError('fetch failed'),
      new TypeError('fetch failed'),
    ]);
    await assert.rejects(http('GET', '/x'), { message: 'Brak połączenia z KSeF: fetch failed' });
    assert.equal(inits.length, 4);
  });

  it('keeps the two retry budgets independent', async () => {
    const { http, inits } = setup([
      rateLimited('1'),
      rateLimited('1'),
      rateLimited('1'),
      new TypeError('fetch failed'),
      new TypeError('fetch failed'),
      new TypeError('fetch failed'),
      new Response('ok', { status: 200 }),
    ]);
    await http('GET', '/x');
    assert.equal(inits.length, 7);
  });

  it('does not retry server errors', async () => {
    const { http, inits, sleeps } = setup([new Response('{"x":1}', { status: 500 })]);
    await assert.rejects(http('GET', '/x'), (err: unknown) => err instanceof KsefApiError && err.status === 500);
    assert.equal(inits.length, 1);
    assert.deepEqual(sleeps, []);
  });

  it('passes a fresh timeout signal on every attempt', async () => {
    const { http, inits } = setup([new TypeError('fetch failed'), new Response('ok', { status: 200 })]);
    await http('GET', '/x');
    assert.ok(inits[0]?.signal instanceof AbortSignal);
    assert.ok(inits[1]?.signal instanceof AbortSignal);
    assert.notEqual(inits[0]?.signal, inits[1]?.signal);
  });
});
