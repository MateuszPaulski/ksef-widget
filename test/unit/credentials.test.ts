import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { loadCredentials, readKeyPassword } from '../../src/credentials.ts';
import { makeTestCredentials, type TestCredentialFiles } from '../support/certs.ts';
import { randomNip } from '../support/nip.ts';

describe('loadCredentials', () => {
  let dir: string;
  const nipA = randomNip();
  const nipB = randomNip();
  let rsa: TestCredentialFiles;
  let ec: TestCredentialFiles;

  before(async () => {
    dir = await mkdtemp(join(tmpdir(), 'ksef-cred-'));
    rsa = await makeTestCredentials({ nip: nipA, keyType: 'rsa', dir });
    ec = await makeTestCredentials({ nip: nipB, keyType: 'ec', dir });
  });

  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('loads an encrypted RSA key and its certificate', async () => {
    const credentials = await loadCredentials(rsa.certificatePath, rsa.keyPath, rsa.password);
    assert.equal(credentials.privateKey.asymmetricKeyType, 'rsa');
    assert.ok(credentials.certificate.subject.includes(`serialNumber=TINPL-${nipA}`));
    assert.match(credentials.certificatePem, /^-----BEGIN CERTIFICATE-----/);
  });

  it('loads an encrypted EC P-256 key', async () => {
    const credentials = await loadCredentials(ec.certificatePath, ec.keyPath, ec.password);
    assert.equal(credentials.privateKey.asymmetricKeyType, 'ec');
    assert.equal(credentials.privateKey.asymmetricKeyDetails?.namedCurve, 'prime256v1');
  });

  it('rejects a wrong password', async () => {
    await assert.rejects(
      loadCredentials(rsa.certificatePath, rsa.keyPath, 'wrong'),
      (err: Error) => err.message.startsWith('Nie można odczytać klucza prywatnego (złe hasło lub format)'),
    );
  });

  it('rejects a key that does not match the certificate', async () => {
    await assert.rejects(
      loadCredentials(rsa.certificatePath, ec.keyPath, ec.password),
      { message: 'Klucz prywatny nie pasuje do certyfikatu' },
    );
  });
});

describe('readKeyPassword', () => {
  it('calls security with the service and NIP', async () => {
    const calls: Array<[string, string[]]> = [];
    const password = await readKeyPassword('5265877635', async (file, args) => {
      calls.push([file, args]);
      return { stdout: 'secret\n' };
    });
    assert.equal(password, 'secret');
    assert.deepEqual(calls, [
      ['security', ['find-generic-password', '-s', 'ksef-daily-fetch', '-a', '5265877635', '-w']],
    ]);
  });

  it('explains a missing Keychain item', async () => {
    await assert.rejects(
      readKeyPassword('5265877635', async () => {
        throw new Error('The specified item could not be found in the keychain.');
      }),
      { message: 'Brak hasła klucza w Pęku kluczy (usługa ksef-daily-fetch, konto 5265877635)' },
    );
  });
});
