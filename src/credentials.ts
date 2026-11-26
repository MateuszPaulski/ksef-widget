import { X509Certificate, createPrivateKey, type KeyObject } from 'node:crypto';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { promisify } from 'node:util';

const KEYCHAIN_SERVICE = 'ksef-daily-fetch';

type Exec = (file: string, args: string[]) => Promise<{ stdout: string }>;

export async function readKeyPassword(
  nip: string,
  exec: Exec = promisify(execFile) as Exec,
): Promise<string> {
  try {
    const { stdout } = await exec('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', nip, '-w']);
    return stdout.replace(/\r?\n$/, '');
  } catch {
    throw new Error(`Brak hasła klucza w Pęku kluczy (usługa ${KEYCHAIN_SERVICE}, konto ${nip})`);
  }
}

export interface Credentials {
  certificatePem: string;
  certificate: X509Certificate;
  privateKey: KeyObject;
}

export async function loadCredentials(
  certificatePath: string,
  keyPath: string,
  password: string,
): Promise<Credentials> {
  const [certificatePem, keyPem] = await Promise.all([
    readFile(certificatePath, 'utf8'),
    readFile(keyPath, 'utf8'),
  ]);

  let privateKey: KeyObject;
  try {
    privateKey = createPrivateKey({ key: keyPem, format: 'pem', passphrase: password });
  } catch (err) {
    throw new Error(
      `Nie można odczytać klucza prywatnego (złe hasło lub format): ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  const certificate = new X509Certificate(certificatePem);
  if (!certificate.checkPrivateKey(privateKey)) {
    throw new Error('Klucz prywatny nie pasuje do certyfikatu');
  }

  const type = privateKey.asymmetricKeyType;
  const details = privateKey.asymmetricKeyDetails;
  const supported =
    (type === 'rsa' && (details?.modulusLength ?? 0) >= 2048) ||
    (type === 'ec' && details?.namedCurve === 'prime256v1');
  if (!supported) {
    throw new Error(`Nieobsługiwany typ klucza: ${type}; wymagany RSA 2048+ lub EC P-256`);
  }

  return { certificatePem, certificate, privateKey };
}
