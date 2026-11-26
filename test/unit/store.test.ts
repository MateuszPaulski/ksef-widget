import assert from 'node:assert/strict';
import { access, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { InvoiceMetadata } from '../../src/ksef.ts';
import { appendReport, openStore } from '../../src/store.ts';

const NOW = new Date('2026-11-26T08:00:12.345Z');
const KSEF_NUMBER = '5265877635-20261120-0123456789AB-CD';

const invoice: InvoiceMetadata = {
  ksefNumber: KSEF_NUMBER,
  invoiceNumber: 'FV/1/2026',
  issueDate: '2026-11-20',
  permanentStorageDate: '2026-11-20T09:00:00.1234567+00:00',
  seller: { nip: '1111111111', name: 'Sprzedawca' },
  grossAmount: 123.45,
  currency: 'PLN',
  invoiceHash: 'aGFzaA==',
};

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

describe('store', () => {
  let root: string;
  let dataDir: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'ksef-store-'));
    dataDir = join(root, 'data');
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it('opening a missing dataDir creates nothing', async () => {
    const store = await openStore(dataDir, () => NOW);
    assert.equal(store.checkpoint, null);
    assert.equal(store.has('x'), false);
    assert.equal(await exists(dataDir), false);
  });

  it('saves invoice bytes and indexes them', async () => {
    const store = await openStore(dataDir, () => NOW);
    const xml = Buffer.from('<Faktura>\r\nł</Faktura>', 'utf8');

    await store.saveInvoice(invoice, xml);

    const file = `invoices/2026/11/${KSEF_NUMBER}.xml`;
    assert.ok((await readFile(join(dataDir, file))).equals(xml));
    const lines = (await readFile(join(dataDir, 'index.jsonl'), 'utf8')).split('\n');
    assert.equal(lines.length, 2);
    assert.equal(lines[1], '');
    assert.deepEqual(JSON.parse(lines[0] ?? ''), {
      ksefNumber: KSEF_NUMBER,
      invoiceNumber: 'FV/1/2026',
      issueDate: '2026-11-20',
      sellerNip: '1111111111',
      sellerName: 'Sprzedawca',
      grossAmount: 123.45,
      currency: 'PLN',
      permanentStorageDate: '2026-11-20T09:00:00.1234567+00:00',
      invoiceHash: 'aGFzaA==',
      file,
      savedAt: NOW.toISOString(),
    });
    assert.equal(store.has(KSEF_NUMBER), true);
    assert.deepEqual(await readdir(join(dataDir, 'invoices/2026/11')), [`${KSEF_NUMBER}.xml`]);
  });

  it('writes a null sellerName when KSeF gives none', async () => {
    const store = await openStore(dataDir, () => NOW);
    await store.saveInvoice({ ...invoice, seller: { nip: '1111111111', name: null } }, Buffer.from('x'));
    const line = JSON.parse((await readFile(join(dataDir, 'index.jsonl'), 'utf8')).trim());
    assert.equal(line.sellerName, null);
  });

  it('reopening keeps the dedup set', async () => {
    const store = await openStore(dataDir, () => NOW);
    await store.saveInvoice(invoice, Buffer.from('x'));
    const reopened = await openStore(dataDir, () => NOW);
    assert.equal(reopened.has(KSEF_NUMBER), true);
    assert.equal(reopened.has('other'), false);
  });

  it('stores the checkpoint verbatim', async () => {
    const store = await openStore(dataDir, () => NOW);
    await store.writeCheckpoint('2026-11-26T07:00:00.1234567+00:00');
    assert.equal(store.checkpoint, '2026-11-26T07:00:00.1234567+00:00');
    const reopened = await openStore(dataDir, () => NOW);
    assert.equal(reopened.checkpoint, '2026-11-26T07:00:00.1234567+00:00');
    assert.deepEqual(await readdir(dataDir), ['state.json']);
  });

  it('a corrupt index line fails loudly', async () => {
    await mkdir(dataDir, { recursive: true });
    await writeFile(join(dataDir, 'index.jsonl'), `{"ksefNumber":"${KSEF_NUMBER}"}\n{"ksefNumber":\n`);
    await assert.rejects(openStore(dataDir, () => NOW), { message: 'Uszkodzony plik index.jsonl, linia 2' });
  });

  it('appendReport appends, never overwrites', async () => {
    await appendReport(dataDir, '2026-11-26', 'section one');
    await appendReport(dataDir, '2026-11-26', 'section two');
    assert.equal(
      await readFile(join(dataDir, 'reports', '2026-11-26.md'), 'utf8'),
      '# Faktury z KSeF — 2026-11-26\n\nsection one\nsection two\n',
    );
  });
});
