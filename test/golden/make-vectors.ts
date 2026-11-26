import { execFile } from 'node:child_process';
import { createPrivateKey, randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { loadCredentials } from '../../src/credentials.ts';
import type { InvoiceMetadata } from '../../src/ksef.ts';
import { appendReport, openStore, readIndex } from '../../src/store.ts';
import { buildSnapshot, widgetInvoice, writeSnapshot } from '../../src/snapshot.ts';
import { formatAmount, formatNotification, formatReportSection } from '../../src/report.ts';
import { buildAuthTokenRequest, signXades } from '../../src/xades.ts';
import { randomNip } from '../support/nip.ts';

// Oracle for the Swift port: runs the existing TypeScript code and writes widget/CoreTests/Fixtures/*.json.
// Usage: node test/golden/make-vectors.ts <outDir>

const execFileAsync = promisify(execFile);
const OPENSSL = '/usr/bin/openssl';

const CHALLENGE = '20261126-CR-0123456789-ABCDEF0123-AB';
const CONTEXT_NIP = '5265877635';
const SIGNING_TIME = '2026-11-26T08:00:00.000Z';
const NOW = '2026-11-26T13:00:39.123Z';

const EC_KEY_ARGS = ['-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-pkeyopt', 'ec_param_enc:named_curve'];

interface Generated {
  certificatePem: string;
  keyPem: string;
  password: string;
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

async function generate(dir: string, name: string, keyArgs: string[], subjectArgs: string[]): Promise<Generated> {
  const password = randomBytes(12).toString('hex');
  const certificatePath = join(dir, `${name}.crt`);
  const keyPath = join(dir, `${name}.key`);
  await execFileAsync(OPENSSL, [
    'req', '-x509', ...keyArgs,
    '-keyout', keyPath, '-out', certificatePath,
    '-days', '30', '-passout', `pass:${password}`,
    ...subjectArgs,
  ]);
  return {
    certificatePem: await readFile(certificatePath, 'utf8'),
    keyPem: await readFile(keyPath, 'utf8'),
    password,
  };
}

function testSubject(nip: string): string[] {
  return ['-subj', `/GN=Jan/SN=Testowy/serialNumber=TINPL-${nip}/CN=Jan Testowy/C=PL`];
}

async function signedVector(dir: string, name: string, generated: Generated): Promise<unknown> {
  const certificatePath = join(dir, `${name}.crt`);
  const keyPath = join(dir, `${name}.key`);
  const credentials = await loadCredentials(certificatePath, keyPath, generated.password);
  const certificate = credentials.certificate;
  return {
    certificatePem: generated.certificatePem,
    keyPem: generated.keyPem,
    password: generated.password,
    contextNip: CONTEXT_NIP,
    challenge: CHALLENGE,
    signingTime: SIGNING_TIME,
    issuer: certificate.issuer.split('\n').reverse().join(', '),
    serial: BigInt(`0x${certificate.serialNumber}`).toString(),
    signedXml: signXades(buildAuthTokenRequest(CHALLENGE, CONTEXT_NIP), credentials, new Date(SIGNING_TIME)),
  };
}

async function xadesVectors(dir: string, outDir: string): Promise<void> {
  const awkwardSubject =
    '/C=PL/O=Ministerstwo Finansów & "Spółka" <x>, a+b; c\\\\d/OU=KSeF/L=Warszawa/ST=mazowieckie/CN=Test CA ł';
  const configPath = join(dir, 'organization-identifier.cnf');
  await writeFile(
    configPath,
    [
      'oid_section = new_oids',
      '[ new_oids ]',
      'orgId = 2.5.4.97',
      '[ req ]',
      'distinguished_name = dn',
      'prompt = no',
      'string_mask = utf8only',
      '[ dn ]',
      'C = PL',
      'orgId = VATPL-5260250274',
      'O = Ministerstwo Finansów',
      'CN = Test CA',
      '',
    ].join('\n'),
  );

  const definitions: Array<[string, string[], string[]]> = [
    ['xades-rsa', ['-newkey', 'rsa:2048'], testSubject(randomNip())],
    ['xades-ec', EC_KEY_ARGS, testSubject(randomNip())],
    ['xades-awkward-issuer', ['-newkey', 'rsa:2048'], ['-utf8', '-subj', `${awkwardSubject}/serialNumber=TINPL-${randomNip()}`]],
    ['xades-organization-identifier', EC_KEY_ARGS, ['-utf8', '-config', configPath]],
  ];
  for (const [name, keyArgs, subjectArgs] of definitions) {
    const generated = await generate(dir, name, keyArgs, subjectArgs);
    await writeFile(join(outDir, `${name}.json`), json(await signedVector(dir, name, generated)));
  }
}

async function keyVectors(dir: string, outDir: string): Promise<void> {
  const rsa = await generate(dir, 'keys-rsa', ['-newkey', 'rsa:2048'], testSubject(randomNip()));
  const ec = await generate(dir, 'keys-ec', EC_KEY_ARGS, testSubject(randomNip()));
  const base = { rsa, ec };

  const nodeExport = (kind: 'rsa' | 'ec', cipher: string, password: string): string =>
    createPrivateKey({ key: base[kind].keyPem, format: 'pem', passphrase: base[kind].password }).export({
      type: 'pkcs8',
      format: 'pem',
      cipher,
      passphrase: password,
    }) as string;

  for (const kind of ['rsa', 'ec'] as const) {
    await writeFile(join(dir, `${kind}.in.key`), base[kind].keyPem);
  }
  const newPassword = (): string => randomBytes(12).toString('hex');
  const keys: unknown[] = [
    { name: 'libressl-sha1-aes256-rsa', certificate: 'rsa', keyPem: rsa.keyPem, password: rsa.password, expect: 'ok' },
    { name: 'libressl-sha1-aes256-ec', certificate: 'ec', keyPem: ec.keyPem, password: ec.password, expect: 'ok' },
  ];

  const aes128Password = newPassword();
  keys.push({
    name: 'libressl-sha1-aes128-ec',
    certificate: 'ec',
    keyPem: await opensslPkcs8(dir, 'ec', ['-v2', 'aes-128-cbc'], ec.password, aes128Password),
    password: aes128Password,
    expect: 'ok',
  });

  const nodeVariants: Array<[string, 'rsa' | 'ec', string]> = [
    ['node-sha256-aes128-rsa', 'rsa', 'aes-128-cbc'],
    ['node-sha256-aes192-ec', 'ec', 'aes-192-cbc'],
    ['node-sha256-aes256-ec', 'ec', 'aes-256-cbc'],
  ];
  for (const [name, kind, cipher] of nodeVariants) {
    const password = newPassword();
    keys.push({ name, certificate: kind, keyPem: nodeExport(kind, cipher, password), password, expect: 'ok' });
  }

  const pbes1Password = newPassword();
  keys.push({
    name: 'pbes1-3des-ec',
    certificate: 'ec',
    keyPem: await opensslPkcs8(dir, 'ec', ['-v1', 'PBE-SHA1-3DES'], ec.password, pbes1Password),
    password: pbes1Password,
    expect: 'unsupported',
    oid: '1.2.840.113549.1.12.1.3',
  });

  await writeFile(
    join(outDir, 'keys.json'),
    json({ certificates: { rsa: rsa.certificatePem, ec: ec.certificatePem }, keys }),
  );
}

async function opensslPkcs8(dir: string, kind: string, args: string[], passin: string, passout: string): Promise<string> {
  const outPath = join(dir, `${kind}.${randomBytes(4).toString('hex')}.pkcs8`);
  await execFileAsync(OPENSSL, [
    'pkcs8', '-topk8', ...args,
    '-in', join(dir, `${kind}.in.key`), '-out', outPath,
    '-passin', `pass:${passin}`, '-passout', `pass:${passout}`,
  ]);
  return readFile(outPath, 'utf8');
}

async function formatVectors(dir: string, outDir: string): Promise<void> {
  const a: InvoiceMetadata = {
    ksefNumber: '5265877635-20261120-0123456789AB-CD',
    invoiceNumber: 'FV/1/2026',
    issueDate: '2026-11-20',
    permanentStorageDate: '2026-11-20T09:00:00.1234567+00:00',
    seller: { nip: '1111111111', name: 'Acme Sp. z o.o.' },
    grossAmount: 1230,
    currency: 'PLN',
    invoiceHash: 'UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE=',
  };
  const b: InvoiceMetadata = {
    ...a,
    ksefNumber: '5265877635-20261120-0123456789AC-CD',
    seller: { nip: '1111111111', name: null },
    grossAmount: 12345.675,
    currency: 'EUR',
    issueDate: '2026-10-31',
  };
  const c: InvoiceMetadata = {
    ...a,
    ksefNumber: '5265877635-20261120-0123456789AD-CD',
    seller: {
      nip: "1/2 (3)!*'ł",
      name: 'Zakład "Ł/ódź" \\ <b>*x*</b>\n\ttab\u0001  ✓ https://evil.example WwW.evil.example www.www.x',
    },
    invoiceNumber: 'FV|1\n# x',
    grossAmount: -0.5,
    currency: 'P_N',
  };
  const invoices = [a, b, c];

  const dataDir = join(dir, 'data');
  const store = await openStore(dataDir, () => new Date(NOW));
  for (const invoice of invoices) await store.saveInvoice(invoice, Buffer.from('<Faktura/>'));
  const indexText = await readFile(join(dataDir, 'index.jsonl'), 'utf8');
  const indexLines = indexText.split(/(?<=\n)/).filter((line) => line !== '');

  await store.writeCheckpoint('2026-11-26T07:00:00.1234567+00:00');
  const stateJson = await readFile(join(dataDir, 'state.json'), 'utf8');

  const startedAt = new Date(NOW);
  await appendReport(dataDir, '2026-11-26', formatReportSection({ startedAt, status: 'complete', saved: invoices }, 'prod'));
  await appendReport(
    dataDir,
    '2026-11-26',
    formatReportSection({ startedAt, status: 'failed', reason: 'Brak połączenia z KSeF: fetch failed', saved: [a] }, 'test'),
  );
  const reportFile = await readFile(join(dataDir, 'reports', '2026-11-26.md'), 'utf8');

  const notifications = [
    formatNotification({ startedAt, status: 'complete', saved: invoices }),
    formatNotification({ startedAt, status: 'partial', reason: 'Limit 60 pobrań na godzinę.', saved: [a] }),
    formatNotification({ startedAt, status: 'failed', reason: 'x'.repeat(300), saved: [a, b] }),
  ];

  const snapshotPath = join(dir, 'widget.json');
  await writeSnapshot(
    snapshotPath,
    buildSnapshot(
      { status: 'failed', reason: 'Uwierzytelnienie w KSeF nieudane (kod 460: Błąd)', failureKey: 'KSeF 500' },
      (await readIndex(dataDir)).map((entry) => widgetInvoice(entry, 'prod')),
      new Date(NOW),
    ),
  );
  const snapshotJson = await readFile(snapshotPath, 'utf8');

  const amounts = [1230, 12345.67, 1234567.891, 0.125, 1.005, 2.675, -12345.675, 0, -0.001, 10].map((v) => [
    v,
    formatAmount(v, 'PLN'),
  ]);

  await writeFile(
    join(outDir, 'formats.json'),
    json({ now: NOW, invoices, indexLines, stateJson, reportFile, notifications, snapshotJson, amounts }),
  );
}

if (process.argv[2] === undefined) throw new Error('Usage: node test/golden/make-vectors.ts <outDir>');
const outDir = resolve(process.argv[2]);
await mkdir(outDir, { recursive: true });
const dir = await mkdtemp(join(tmpdir(), 'ksef-golden-'));
try {
  await xadesVectors(dir, outDir);
  await keyVectors(dir, outDir);
  await formatVectors(dir, outDir);
} finally {
  await rm(dir, { recursive: true, force: true });
}
