// TEST-only online-session sender: puts an invoice into the KSeF TEST environment so the fetch path
// can be verified. Never imported by src/.
// test/fixtures/fa3-invoice.xml is adapted from invoice-template-fa-3-with-custom-Subject2.xml in
// https://github.com/CIRFMF/ksef-client-csharp (MIT, (c) 2025 Ministerstwo Finansów).
import { X509Certificate, constants, createCipheriv, createHash, publicEncrypt, randomBytes } from 'node:crypto';
import type { Http } from '../../src/http.ts';

const POLL_INTERVAL_MS = 2_000;
const MAX_POLLS = 90;
const INVOICE_REJECTED_FROM = 400;

interface PublicKeyCertificate {
  certificate: string;
  publicKeyId: string;
  validFrom: string;
  validTo: string;
  usage: string[];
}

interface InvoiceStatus {
  ksefNumber?: string | null;
  permanentStorageDate?: string | null;
  status: { code: number; description: string; details?: string[] | null };
}

const sha256Base64 = (data: Buffer) => createHash('sha256').update(data).digest('base64');

export async function sendTestInvoice(
  http: Http,
  accessToken: string,
  xml: Buffer,
  sleep: (ms: number) => Promise<void>,
): Promise<{ ksefNumber: string; permanentStorageDate: string }> {
  const certificates = (await (await http('GET', '/security/public-key-certificates')).json()) as PublicKeyCertificate[];
  const now = Date.now();
  const mf = certificates.find(
    (c) => c.usage.includes('SymmetricKeyEncryption') && Date.parse(c.validFrom) <= now && now <= Date.parse(c.validTo),
  );
  if (mf === undefined) throw new Error('KSeF TEST did not offer a valid SymmetricKeyEncryption certificate');
  const publicKey = new X509Certificate(Buffer.from(mf.certificate, 'base64')).publicKey;

  const key = randomBytes(32);
  const iv = randomBytes(16);
  const encryptedSymmetricKey = publicEncrypt(
    { key: publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    key,
  );

  const session = (await (
    await http('POST', '/sessions/online', {
      token: accessToken,
      json: {
        formCode: { systemCode: 'FA (3)', schemaVersion: '1-0E', value: 'FA' },
        encryption: {
          encryptedSymmetricKey: encryptedSymmetricKey.toString('base64'),
          initializationVector: iv.toString('base64'),
          publicKeyId: mf.publicKeyId,
        },
      },
    })
  ).json()) as { referenceNumber: string };

  const cipher = createCipheriv('aes-256-cbc', key, iv);
  const encrypted = Buffer.concat([cipher.update(xml), cipher.final()]);
  const sent = (await (
    await http('POST', `/sessions/online/${session.referenceNumber}/invoices`, {
      token: accessToken,
      json: {
        invoiceHash: sha256Base64(xml),
        invoiceSize: xml.length,
        encryptedInvoiceHash: sha256Base64(encrypted),
        encryptedInvoiceSize: encrypted.length,
        encryptedInvoiceContent: encrypted.toString('base64'),
      },
    })
  ).json()) as { referenceNumber: string };

  for (let poll = 0; poll < MAX_POLLS; poll++) {
    if (poll > 0) await sleep(POLL_INTERVAL_MS);
    const invoice = (await (
      await http('GET', `/sessions/${session.referenceNumber}/invoices/${sent.referenceNumber}`, { token: accessToken })
    ).json()) as InvoiceStatus;
    const { code, description, details } = invoice.status;
    if (code >= INVOICE_REJECTED_FROM) {
      throw new Error(`KSeF TEST rejected the invoice (${code}: ${description}${details?.length ? ` — ${details.join(', ')}` : ''})`);
    }
    if (code === 200 && invoice.ksefNumber && invoice.permanentStorageDate) {
      await http('POST', `/sessions/online/${session.referenceNumber}/close`, { token: accessToken });
      return { ksefNumber: invoice.ksefNumber, permanentStorageDate: invoice.permanentStorageDate };
    }
  }
  throw new Error(`KSeF TEST did not settle the invoice within ${(MAX_POLLS * POLL_INTERVAL_MS) / 1000} s`);
}
