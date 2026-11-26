import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface TestCredentialFiles {
  certificatePath: string;
  keyPath: string;
  password: string;
}

/** Self-signed certificate + encrypted PKCS#8 key, as /usr/bin/openssl produces them. */
export async function makeTestCredentials(options: {
  nip: string;
  keyType: 'rsa' | 'ec';
  dir: string;
}): Promise<TestCredentialFiles> {
  const { nip, keyType, dir } = options;
  const password = randomBytes(12).toString('hex');
  const certificatePath = join(dir, `${nip}.crt`);
  const keyPath = join(dir, `${nip}.key`);
  const keyArgs =
    keyType === 'rsa'
      ? ['-newkey', 'rsa:2048']
      : ['-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-pkeyopt', 'ec_param_enc:named_curve'];
  await execFileAsync('/usr/bin/openssl', [
    'req',
    '-x509',
    ...keyArgs,
    '-keyout', keyPath,
    '-out', certificatePath,
    '-days', '30',
    '-passout', `pass:${password}`,
    '-subj', `/GN=Jan/SN=Testowy/serialNumber=TINPL-${nip}/CN=Jan Testowy/C=PL`,
  ]);
  return { certificatePath, keyPath, password };
}
