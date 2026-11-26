const REQUEST_TIMEOUT_MS = 60_000;
const BODY_EXCERPT_CHARS = 300;

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
    const response = await deps.fetch(apiBase + path, {
      method,
      headers,
      body,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) {
      throw new KsefApiError(response.status, method, path, await response.text());
    }
    return response;
  };
}
