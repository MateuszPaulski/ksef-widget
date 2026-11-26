export const MAX_RETRY_AFTER_SECONDS = 120;
export const MAX_RATE_LIMIT_RETRIES = 3;
export const NETWORK_RETRIES = 3;
export const NETWORK_RETRY_DELAY_MS = 30_000;
export const REQUEST_TIMEOUT_MS = 60_000;
const DEFAULT_RETRY_AFTER_SECONDS = 60;
// A Retry-After we cannot parse is treated as a long wait (the hourly limits are the usual cause).
const UNPARSEABLE_RETRY_AFTER_SECONDS = 3600;
const BODY_EXCERPT_CHARS = 300;

export class RateLimitError extends Error {
  readonly retryAfterSeconds: number;

  constructor(retryAfterSeconds: number) {
    super(`Limit zapytań KSeF — trzeba odczekać ${retryAfterSeconds} s.`);
    this.name = 'RateLimitError';
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function retryAfterSeconds(response: Response): number {
  const header = response.headers.get('Retry-After');
  if (header === null) return DEFAULT_RETRY_AFTER_SECONDS;
  return /^\d+$/.test(header.trim()) ? Number(header) : UNPARSEABLE_RETRY_AFTER_SECONDS;
}

export class KsefApiError extends Error {
  readonly status: number;
  readonly method: string;
  readonly path: string;
  readonly body: string;

  constructor(status: number, method: string, path: string, body: string) {
    super(`KSeF odpowiedział ${status} na ${method} ${path}: ${body.slice(0, BODY_EXCERPT_CHARS)}`);
    this.name = 'KsefApiError';
    this.status = status;
    this.method = method;
    this.path = path;
    this.body = body;
  }
}

export interface HttpDeps {
  fetch: typeof fetch;
  sleep: (ms: number) => Promise<void>;
}

export interface RequestOptions {
  token?: string;
  json?: unknown;
  xml?: string;
  accept?: string;
}

export type Http = (method: 'GET' | 'POST', path: string, options?: RequestOptions) => Promise<Response>;

export function createHttp(apiBase: string, deps: HttpDeps): Http {
  return async (method, path, options = {}) => {
    const headers: Record<string, string> = { Accept: options.accept ?? 'application/json' };
    if (options.token !== undefined) headers['Authorization'] = `Bearer ${options.token}`;
    let body: string | undefined;
    if (options.json !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(options.json);
    } else if (options.xml !== undefined) {
      headers['Content-Type'] = 'application/xml';
      body = options.xml;
    }
    let rateLimitRetries = 0;
    let networkRetries = 0;
    for (;;) {
      let response: Response;
      try {
        response = await deps.fetch(apiBase + path, {
          method,
          headers,
          body,
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
      } catch (err) {
        if (networkRetries === NETWORK_RETRIES) {
          throw new Error(`Brak połączenia z KSeF: ${err instanceof Error ? err.message : String(err)}`);
        }
        networkRetries++;
        await deps.sleep(NETWORK_RETRY_DELAY_MS);
        continue;
      }
      if (response.status === 429) {
        const seconds = retryAfterSeconds(response);
        if (seconds > MAX_RETRY_AFTER_SECONDS || rateLimitRetries === MAX_RATE_LIMIT_RETRIES) {
          throw new RateLimitError(seconds);
        }
        rateLimitRetries++;
        await deps.sleep(seconds * 1000);
        continue;
      }
      if (!response.ok) {
        throw new KsefApiError(response.status, method, path, await response.text());
      }
      return response;
    }
  };
}
