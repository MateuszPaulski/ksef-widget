import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import type { IndexEntry } from '../../src/store.ts';
import { buildSnapshot, readPreviousFailure, widgetInvoice, writeSnapshot } from '../../src/snapshot.ts';

function entry(n: number, savedAt: string, sellerName: string | null = `Sprzedawca ${n}`): IndexEntry {
  return {
    ksefNumber: `K${n}`,
    invoiceNumber: `FV/${n}`,
    issueDate: '2026-11-20',
    sellerNip: '1111111111',
    sellerName,
    grossAmount: 1230,
    currency: 'PLN',
    permanentStorageDate: '2026-11-20T09:00:00.1234567+00:00',
    invoiceHash: 'UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE=',
    file: `invoices/2026/11/K${n}.xml`,
    savedAt,
  };
}

describe('snapshot', () => {
  let root: string;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'ksef-snapshot-'));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it('widgetInvoice maps an index entry for display', () => {
    assert.deepEqual(widgetInvoice(entry(1, '2026-11-26T13:00:39.000Z'), 'prod'), {
      ksefNumber: 'K1',
      seller: 'Sprzedawca 1',
      invoiceNumber: 'FV/1',
      amount: '1230,00 PLN',
      issueDate: '2026-11-20',
      savedAt: '2026-11-26T13:00:39.000Z',
      viewUrl: 'https://qr.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE',
    });
  });

  it('widgetInvoice falls back to the NIP', () => {
    assert.equal(widgetInvoice(entry(1, '2026-11-26T13:00:39.000Z', null), 'prod').seller, 'NIP 1111111111');
  });

  it('keeps the newest 8, newest first', () => {
    const invoices = Array.from({ length: 10 }, (_, i) => widgetInvoice(entry(i + 1, '2026-11-26T12:00:00.000Z'), 'prod'));
    const snapshot = buildSnapshot({ status: 'complete' }, invoices, new Date('2026-11-26T13:00:00.000Z'));
    assert.deepEqual(
      snapshot.invoices.map((i) => i.ksefNumber),
      ['K10', 'K9', 'K8', 'K7', 'K6', 'K5', 'K4', 'K3'],
    );
  });

  it("counts today's saves over the whole index", () => {
    const invoices = Array.from({ length: 10 }, (_, i) => widgetInvoice(entry(i + 1, '2026-11-26T12:00:00.000Z'), 'prod'));
    const snapshot = buildSnapshot({ status: 'complete' }, invoices, new Date('2026-11-26T13:00:00.000Z'));
    assert.equal(snapshot.savedToday, 10);
    assert.equal(snapshot.invoices.length, 8);
  });

  it('uses the Warsaw day', () => {
    const invoices = [
      widgetInvoice(entry(1, '2026-11-26T22:50:00.000Z'), 'prod'),
      widgetInvoice(entry(2, '2026-11-26T23:10:00.000Z'), 'prod'),
    ];
    const snapshot = buildSnapshot({ status: 'complete' }, invoices, new Date('2026-11-26T23:30:00.000Z'));
    assert.equal(snapshot.today, '2026-11-27');
    assert.equal(snapshot.savedToday, 1);
  });

  it('carries status and reason', () => {
    const now = new Date('2026-11-26T13:00:00.000Z');
    const failed = buildSnapshot({ status: 'failed', reason: 'Brak połączenia z KSeF: fetch failed' }, [], now);
    assert.equal(failed.status, 'failed');
    assert.equal(failed.reason, 'Brak połączenia z KSeF: fetch failed');
    assert.equal(failed.updatedAt, now.toISOString());
    assert.equal('reason' in buildSnapshot({ status: 'complete' }, [], now), false);
  });

  it('writeSnapshot writes pretty JSON atomically', async () => {
    const path = join(root, 'a', 'b', 'widget.json');
    const snapshot = buildSnapshot({ status: 'partial', reason: 'x' }, [widgetInvoice(entry(1, '2026-11-26T12:00:00.000Z'), 'prod')], new Date('2026-11-26T13:00:00.000Z'));

    await writeSnapshot(path, snapshot);

    assert.equal(await readFile(path, 'utf8'), `${JSON.stringify(snapshot, null, 2)}\n`);
    assert.deepEqual(await readdir(join(root, 'a', 'b')), ['widget.json']);
  });

  it('buildSnapshot writes failureKey only when given', () => {
    const now = new Date('2026-11-26T13:00:00.000Z');
    assert.equal(buildSnapshot({ status: 'failed', reason: 'long text', failureKey: 'KSeF 500' }, [], now).failureKey, 'KSeF 500');
    assert.equal('failureKey' in buildSnapshot({ status: 'partial', reason: 'x' }, [], now), false);
  });

  it('readPreviousFailure returns the failure key and day of a failed snapshot', async () => {
    const path = join(root, 'failed.json');
    await writeSnapshot(path, buildSnapshot({ status: 'failed', reason: 'long text', failureKey: 'KSeF 500' }, [], new Date('2026-11-26T13:00:00.000Z')));
    assert.deepEqual(await readPreviousFailure(path), { failureKey: 'KSeF 500', today: '2026-11-26' });
  });

  it('readPreviousFailure is null unless the file is a failed snapshot', async () => {
    const path = join(root, 'other.json');
    assert.equal(await readPreviousFailure(path), null);
    await writeSnapshot(path, buildSnapshot({ status: 'partial', reason: 'x' }, [], new Date('2026-11-26T13:00:00.000Z')));
    assert.equal(await readPreviousFailure(path), null);
    for (const text of ['{"status":"failed"', 'null', '"failed"', '{"status":"failed","today":"2026-11-26"}', '{"status":"failed","failureKey":"x"}', '{"status":"failed","reason":"x","today":"2026-11-26"}']) {
      await writeFile(path, text);
      assert.equal(await readPreviousFailure(path), null, text);
    }
  });
});
