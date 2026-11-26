import type { Credentials } from './credentials.ts';
import type { Environment } from './environments.ts';
import type { Http } from './http.ts';
import { buildAuthTokenRequest, signXades } from './xades.ts';

export interface AccessToken {
  token: string;
  validUntil: string;
}

const AUTH_POLL_INTERVAL_MS = 1000;
const AUTH_MAX_POLLS = 120;
const STATUS_IN_PROGRESS = 100;
const STATUS_SUCCESS = 200;

interface AuthStatus {
  status: { code: number; description: string; details?: string[] | null };
}

export async function authenticate(
  http: Http,
  credentials: Credentials,
  nip: string,
  environment: Environment,
  deps: { sleep: (ms: number) => Promise<void> },
): Promise<AccessToken> {
  const { challenge } = (await (await http('POST', '/auth/challenge')).json()) as { challenge: string };

  const signedXml = signXades(buildAuthTokenRequest(challenge, nip), credentials, new Date());
  // Self-signed certificates are accepted on TEST only when KSeF is told not to verify the chain.
  const uploadPath = environment === 'test' ? '/auth/xades-signature?verifyCertificateChain=false' : '/auth/xades-signature';
  const accepted = (await (await http('POST', uploadPath, { xml: signedXml })).json()) as {
    referenceNumber: string;
    authenticationToken: { token: string };
  };
  const authToken = accepted.authenticationToken.token;

  for (let poll = 0; poll < AUTH_MAX_POLLS; poll++) {
    if (poll > 0) await deps.sleep(AUTH_POLL_INTERVAL_MS);
    const { status } = (await (
      await http('GET', `/auth/${accepted.referenceNumber}`, { token: authToken })
    ).json()) as AuthStatus;
    if (status.code === STATUS_SUCCESS) {
      const redeemed = (await (await http('POST', '/auth/token/redeem', { token: authToken })).json()) as {
        accessToken: AccessToken;
      };
      return { token: redeemed.accessToken.token, validUntil: redeemed.accessToken.validUntil };
    }
    if (status.code !== STATUS_IN_PROGRESS) {
      const details = status.details?.length ? ` — ${status.details.join(', ')}` : '';
      throw new Error(`Uwierzytelnienie w KSeF nieudane (kod ${status.code}: ${status.description}${details})`);
    }
  }
  throw new Error(`Uwierzytelnienie w KSeF nie zakończyło się w ${(AUTH_MAX_POLLS * AUTH_POLL_INTERVAL_MS) / 1000} s`);
}
