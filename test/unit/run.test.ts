import assert from 'node:assert/strict';
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import type { Config } from '../../src/config.ts';
import { warsawDay } from '../../src/report.ts';
import { run, type RunOptions } from '../../src/run.ts';
import { makeTestCredentials, type TestCredentialFiles } from '../support/certs.ts';
import { createFakeKsef, fakeInvoice, type FakeKsefOptions } from '../support/fake-ksef.ts';
import { randomNip } from '../support/nip.ts';

const START = new Date('2026-11-26T07:00:00Z');
const HWM = '2026-11-26T06:59:00.1234567+00:00';

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

describe('run', () => {
  let root: string;
  let credentials: TestCredentialFiles;
  let nip: string;
  let counter = 0;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'ksef-run-'));
    nip = randomNip();
    credentials = await makeTestCredentials({ nip, keyType: 'rsa', dir: root });
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  function setup(fakeOptions: Omit<FakeKsefOptions, 'now' | 'hwm'>, overrides: Partial<RunOptions> = {}) {
    let current = START.getTime();
    const now = () => new Date(current);
    const sleeps: number[] = [];
    const notifications: Array<{ title: string; message: string }> = [];
    const logs: string[] = [];
    const n = counter++;
    const dataDir = join(root, `data-${n}`);
    const snapshotPath = join(root, `widget-${n}.json`);
    const config: Config = {
      nip,
      environment: 'test',
      certificatePath: credentials.certificatePath,
      keyPath: credentials.keyPath,
      startDate: '2026-11-01',
      dataDir,
    };
    const fake = createFakeKsef({ ...fakeOptions, hwm: HWM, now });
    const options: RunOptions = {
      config,
      keyPassword: credentials.password,
      fetch: fake.fetch,
      sleep: async (ms) => {
        sleeps.push(ms);
        current += ms;
      },
      now,
      notify: async (title, message) => {
        notifications.push({ title, message });
      },
      log: (line) => logs.push(line),
      snapshotPath,
      ...overrides,
    };
    return { options, fake, dataDir, snapshotPath, sleeps, notifications, logs };
  }

  const ksefRequests = (requests: Array<{ path: string }>) => requests.filter((r) => r.path.startsWith('/invoices/ksef/'));
  const reportPath = (dataDir: string) => join(dataDir, 'reports', `${warsawDay(START)}.md`);
  const readSnapshot = async (snapshotPath: string) => JSON.parse(await readFile(snapshotPath, 'utf8'));
  const indexLines = async (dataDir: string) => (await readFile(join(dataDir, 'index.jsonl'), 'utf8')).trim().split('\n');

  it('saves new invoices, reports and notifies once', async () => {
    const invoices = [fakeInvoice(1), fakeInvoice(2)];
    const { options, dataDir, notifications, logs } = setup({ invoices });

    const summary = await run(options);

    assert.equal(summary.status, 'complete');
    assert.equal(summary.saved.length, 2);
    for (const { metadata, xml } of invoices) {
      const saved = await readFile(join(dataDir, 'invoices/2026/11', `${metadata.ksefNumber}.xml`));
      assert.ok(saved.equals(xml));
    }
    assert.equal((await indexLines(dataDir)).length, 2);
    assert.deepEqual(JSON.parse(await readFile(join(dataDir, 'state.json'), 'utf8')), { checkpoint: HWM });
    const report = await readFile(reportPath(dataDir), 'utf8');
    assert.ok(report.includes('FV/1') && report.includes('FV/2'));
    assert.ok(report.includes('https://qr-test.ksef.mf.gov.pl/invoice/'));
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0]?.title, 'KSeF: 2 nowe faktury');
    assert.equal(logs.length, 1);
    assert.ok(logs[0]?.includes('complete'));
  });

  it('a second run finds nothing and stays quiet', async () => {
    const { options, fake, dataDir, notifications } = setup({ invoices: [fakeInvoice(1), fakeInvoice(2)] });
    await run(options);
    const reportBefore = await readFile(reportPath(dataDir), 'utf8');
    const requestsBefore = fake.requests.length;

    const summary = await run(options);

    assert.equal(summary.status, 'complete');
    assert.equal(summary.saved.length, 0);
    assert.equal(notifications.length, 1);
    assert.equal(await readFile(reportPath(dataDir), 'utf8'), reportBefore);
    assert.equal((await indexLines(dataDir)).length, 2);
    assert.deepEqual(ksefRequests(fake.requests.slice(requestsBefore)), []);
  });

  it('a long rate limit is partial and resumable', async () => {
    const invoices = [fakeInvoice(1), fakeInvoice(2)];
    let limited = true;
    const { options, dataDir, notifications } = setup({
      invoices,
      downloadStatus: (ksefNumber) =>
        limited && ksefNumber === invoices[1]?.metadata.ksefNumber
          ? { status: 429, headers: { 'Retry-After': '900' } }
          : undefined,
    });

    const first = await run(options);

    assert.equal(first.status, 'partial');
    assert.equal(first.saved.length, 1);
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0]?.title, 'KSeF: pobrano częściowo (1)');
    assert.ok((await readFile(reportPath(dataDir), 'utf8')).includes('Status: częściowe — Limit zapytań KSeF — trzeba odczekać 900 s.'));
    assert.equal(await exists(join(dataDir, 'state.json')), false);

    limited = false;
    const second = await run(options);

    assert.equal(second.status, 'complete');
    assert.equal(second.saved.length, 1);
    assert.equal((await indexLines(dataDir)).length, 2);
    assert.deepEqual(JSON.parse(await readFile(join(dataDir, 'state.json'), 'utf8')), { checkpoint: HWM });
  });

  it('an authentication failure notifies with the reason', async () => {
    const { options, dataDir, notifications } = setup({
      invoices: [],
      authStatus: {
        code: 460,
        description: 'Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu',
        details: ['Certyfikat odwołany'],
      },
    });

    const summary = await run(options);

    assert.equal(summary.status, 'failed');
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0]?.title, 'KSeF: błąd pobierania faktur');
    assert.ok(notifications[0]?.message.startsWith('Uwierzytelnienie w KSeF nieudane (kod 460'));
    assert.ok((await readFile(reportPath(dataDir), 'utf8')).includes('BŁĄD — '));
  });

  it('a wrong key password fails before any request', async () => {
    const { options, fake, notifications } = setup({ invoices: [] }, { keyPassword: 'wrong' });

    const summary = await run(options);

    assert.equal(summary.status, 'failed');
    assert.ok(summary.reason?.startsWith('Nie można odczytać klucza prywatnego'));
    assert.equal(fake.requests.length, 0);
    assert.equal(notifications.length, 1);
  });

  it('an offline Mac fails after retries', async () => {
    const { options, sleeps, notifications } = setup({ invoices: [], fetchError: new TypeError('fetch failed') });

    const summary = await run(options);

    assert.equal(summary.status, 'failed');
    assert.equal(summary.reason, 'Brak połączenia z KSeF: fetch failed');
    assert.deepEqual(sleeps, [30_000, 30_000, 30_000]);
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0]?.message, 'Brak połączenia z KSeF: fetch failed');
  });

  it('a failure after some invoices were saved mentions them', async () => {
    const invoices = [fakeInvoice(1), fakeInvoice(2)];
    const { options, dataDir, notifications } = setup({
      invoices,
      downloadStatus: (ksefNumber) => (ksefNumber === invoices[1]?.metadata.ksefNumber ? { status: 500 } : undefined),
    });

    const summary = await run(options);

    assert.equal(summary.status, 'failed');
    assert.equal(summary.saved.length, 1);
    assert.ok(notifications[0]?.message.endsWith(' Zapisano wcześniej: 1.'));
    assert.ok((await readFile(reportPath(dataDir), 'utf8')).includes('FV/1'));
  });

  it('a dry run writes and notifies nothing', async () => {
    const { options, fake, dataDir, snapshotPath, notifications, logs } = setup(
      { invoices: [fakeInvoice(1), fakeInvoice(2)] },
      { dryRun: true },
    );

    const summary = await run(options);

    assert.equal(summary.status, 'complete');
    assert.deepEqual(summary.saved, []);
    assert.equal(await exists(dataDir), false);
    assert.equal(await exists(snapshotPath), false);
    assert.equal(notifications.length, 0);
    assert.deepEqual(ksefRequests(fake.requests), []);
    assert.equal(logs.length, 1);
    assert.ok(logs[0]?.startsWith('dry run: 2 invoices'));
  });

  it('a failed dry run stays quiet', async () => {
    const { options, dataDir, snapshotPath, notifications } = setup(
      { invoices: [], authStatus: { code: 460, description: 'Błąd certyfikatu' } },
      { dryRun: true },
    );

    const summary = await run(options);

    assert.equal(summary.status, 'failed');
    assert.ok(summary.reason?.startsWith('Uwierzytelnienie w KSeF nieudane (kod 460'));
    assert.equal(await exists(dataDir), false);
    assert.equal(await exists(snapshotPath), false);
    assert.equal(notifications.length, 0);
  });

  it('writes the widget snapshot after saving invoices', async () => {
    const { options, snapshotPath } = setup({ invoices: [fakeInvoice(1), fakeInvoice(2)] });

    await run(options);

    const snapshot = await readSnapshot(snapshotPath);
    assert.equal(snapshot.status, 'complete');
    assert.equal('reason' in snapshot, false);
    assert.equal(snapshot.today, warsawDay(START));
    assert.equal(snapshot.savedToday, 2);
    assert.deepEqual(
      snapshot.invoices.map((i: { invoiceNumber: string }) => i.invoiceNumber),
      ['FV/2', 'FV/1'],
    );
    assert.equal(snapshot.invoices[0].seller, 'Sprzedawca 2');
    assert.equal(snapshot.invoices[0].amount, '200,50 PLN');
    assert.ok(snapshot.invoices[0].viewUrl.startsWith('https://qr-test.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/'));
  });

  it('a quiet run still writes the snapshot', async () => {
    const { options, snapshotPath } = setup({ invoices: [fakeInvoice(1), fakeInvoice(2)] });
    await run(options);
    await rm(snapshotPath);

    await run(options);

    const snapshot = await readSnapshot(snapshotPath);
    assert.equal(snapshot.status, 'complete');
    assert.equal(snapshot.invoices.length, 2);
  });

  it('a failed run records the failure in the snapshot', async () => {
    const { options, snapshotPath } = setup({
      invoices: [],
      authStatus: { code: 460, description: 'Błąd certyfikatu' },
    });

    await run(options);

    const snapshot = await readSnapshot(snapshotPath);
    assert.equal(snapshot.status, 'failed');
    assert.ok(snapshot.reason.startsWith('Uwierzytelnienie w KSeF nieudane (kod 460'));
    assert.deepEqual(snapshot.invoices, []);
    assert.equal(snapshot.savedToday, 0);
  });

  it('a corrupt index still gives a failed snapshot', async () => {
    const { options, dataDir, snapshotPath, logs } = setup({ invoices: [] });
    await mkdir(dataDir, { recursive: true });
    await writeFile(join(dataDir, 'index.jsonl'), '{"ksefNumber":');

    const summary = await run(options);

    assert.equal(summary.status, 'failed');
    assert.equal(summary.reason, 'Uszkodzony plik index.jsonl, linia 1');
    const snapshot = await readSnapshot(snapshotPath);
    assert.equal(snapshot.status, 'failed');
    assert.equal(snapshot.reason, 'Uszkodzony plik index.jsonl, linia 1');
    assert.deepEqual(snapshot.invoices, []);
    assert.ok(logs.some((line) => line.includes('could not read the index for the widget')));
  });

  it('survives a failing notifier', async () => {
    const { options, logs } = setup(
      { invoices: [fakeInvoice(1)] },
      {
        notify: async () => {
          throw new Error('osascript missing');
        },
      },
    );

    const summary = await run(options);

    assert.equal(summary.status, 'complete');
    assert.ok(logs.some((line) => line.includes('osascript missing')));
  });
});
