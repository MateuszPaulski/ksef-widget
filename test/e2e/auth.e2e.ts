import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { after, before, describe, it } from 'node:test';
import { loadCredentials } from '../../src/credentials.ts';
import { ENVIRONMENTS } from '../../src/environments.ts';
import { createHttp } from '../../src/http.ts';
import { authenticate } from '../../src/ksef.ts';
import { makeTestCredentials } from '../support/certs.ts';
import { randomNip } from '../support/nip.ts';

describe('XAdES authentication against KSeF TEST', () => {
  let dir: string;

  before(async () => {
    dir = await mkdtemp(join(tmpdir(), 'ksef-e2e-auth-'));
  });

  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  for (const keyType of ['rsa', 'ec'] as const) {
    it(`authenticates a random NIP with a self-signed ${keyType} certificate`, async () => {
      const nip = randomNip();
      const files = await makeTestCredentials({ nip, keyType, dir });
      const credentials = await loadCredentials(files.certificatePath, files.keyPath, files.password);
      const http = createHttp(ENVIRONMENTS.test.apiBase, { fetch, sleep });

      const accessToken = await authenticate(http, credentials, nip, 'test', { sleep });

      assert.ok(accessToken.token.length > 0);
      assert.ok(Date.parse(accessToken.validUntil) > Date.now());
    });
  }
});
