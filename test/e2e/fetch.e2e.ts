import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it, type TestContext } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import type { Config } from '../../src/config.ts';
import { loadCredentials } from '../../src/credentials.ts';
import { ENVIRONMENTS } from '../../src/environments.ts';
import { createHttp } from '../../src/http.ts';
import { authenticate } from '../../src/ksef.ts';
import { warsawDay, type RunSummary } from '../../src/report.ts';
import { run } from '../../src/run.ts';
import { makeTestCredentials } from '../support/certs.ts';
import { randomNip } from '../support/nip.ts';
import { sendTestInvoice } from '../support/send-invoice.ts';

const HWM_LAG_MS = 120_000;
const MAX_ATTEMPTS = 4;
const ATTEMPT_INTERVAL_MS = 60_000;
const BACKFILL_DAYS = 100;

describe('fetch against KSeF TEST', () => {
  let dir: string;

  before(async () => {
    dir = await mkdtemp(join(tmpdir(), 'ksef-e2e-fetch-'));
  });

  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('fetches an invoice sent by another NIP, then finds nothing new', { timeout: 20 * 60_000 }, async (t: TestContext) => {
    const sellerNip = randomNip();
    const buyerNip = randomNip();
    const seller = await makeTestCredentials({ nip: sellerNip, keyType: 'rsa', dir });
    const buyer = await makeTestCredentials({ nip: buyerNip, keyType: 'ec', dir });
    const http = createHttp(ENVIRONMENTS.test.apiBase, { fetch, sleep });

    const sellerToken = await authenticate(
      http,
      await loadCredentials(seller.certificatePath, seller.keyPath, seller.password),
      sellerNip,
      'test',
      { sleep },
    );
    const invoiceNumber = `E2E/${randomBytes(4).toString('hex')}`;
    const template = await readFile(join(import.meta.dirname, '..', 'fixtures', 'fa3-invoice.xml'), 'utf8');
    const xml = Buffer.from(
      template
        .replaceAll('{{SELLER_NIP}}', sellerNip)
        .replaceAll('{{BUYER_NIP}}', buyerNip)
        .replaceAll('{{INVOICE_NUMBER}}', invoiceNumber)
        .replaceAll('{{ISSUE_DATE}}', warsawDay(new Date()))
        .replaceAll('{{CREATED_AT}}', new Date(Date.now() - 60_000).toISOString()),
      'utf8',
    );
    const { ksefNumber } = await sendTestInvoice(http, sellerToken.token, xml, sleep);
    t.diagnostic(`sent invoice ${ksefNumber}`);

    await sleep(HWM_LAG_MS);

    const dataDir = join(dir, 'data');
    const config: Config = {
      nip: buyerNip,
      environment: 'test',
      certificatePath: buyer.certificatePath,
      keyPath: buyer.keyPath,
      // 100 days back: the first run walks one closed window (explicit `to`) and then the open one.
      startDate: warsawDay(new Date(Date.now() - BACKFILL_DAYS * 86_400_000)),
      dataDir,
    };
    const notifications: Array<{ title: string; message: string }> = [];
    const logs: string[] = [];
    const recordMetadata = (async (input, init) => {
      const response = await fetch(input, init);
      if (String(input).includes('/invoices/query/metadata')) {
        const { from, to } = JSON.parse(String(init?.body)).dateRange;
        const text = await response.clone().text();
        const { hasMore, isTruncated, permanentStorageHwmDate, invoices } = response.ok ? JSON.parse(text) : ({} as never);
        t.diagnostic(
          `metadata ${response.status} from=${from} to=${to ?? '(none)'} ` +
            (response.ok
              ? `hasMore=${hasMore} isTruncated=${isTruncated} hwm=${permanentStorageHwmDate} invoices=${invoices.length}`
              : text.slice(0, 200)),
        );
      }
      return response;
    }) as typeof fetch;
    const runOnce = (): Promise<RunSummary> =>
      run({
        config,
        keyPassword: buyer.password,
        fetch: recordMetadata,
        sleep,
        now: () => new Date(),
        notify: async (title, message) => {
          notifications.push({ title, message });
        },
        log: (line) => logs.push(line),
        snapshotPath: join(dir, 'widget.json'),
      });

    let summary: RunSummary | undefined;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      if (attempt > 1) await sleep(ATTEMPT_INTERVAL_MS);
      summary = await runOnce();
      assert.equal(summary.status, 'complete', `attempt ${attempt}: ${summary.status} ${summary.reason ?? ''}\n${logs.join('\n')}`);
      if (attempt === 1) await stat(join(dataDir, 'state.json')); // the closed window advanced the checkpoint
      if (summary.saved.some((invoice) => invoice.ksefNumber === ksefNumber)) break;
    }
    assert.ok(
      summary?.saved.some((invoice) => invoice.ksefNumber === ksefNumber),
      `invoice ${ksefNumber} not fetched after ${MAX_ATTEMPTS} attempts`,
    );

    const [year, month] = warsawDay(new Date()).split('-');
    const saved = await readFile(join(dataDir, 'invoices', year!, month!, `${ksefNumber}.xml`));
    assert.ok(saved.equals(xml), 'saved XML differs from the XML that was sent');

    const indexLines = (await readFile(join(dataDir, 'index.jsonl'), 'utf8')).trim().split('\n');
    assert.equal(indexLines.length, 1);
    const entry = JSON.parse(indexLines[0]!);
    assert.equal(entry.ksefNumber, ksefNumber);
    assert.equal(entry.sellerNip, sellerNip);

    const report = await readFile(join(dataDir, 'reports', `${warsawDay(new Date())}.md`), 'utf8');
    assert.ok(report.includes(invoiceNumber));
    assert.ok(report.includes(`https://qr-test.ksef.mf.gov.pl/invoice/${sellerNip}/`));
    assert.equal(notifications.at(-1)?.title, 'KSeF: 1 nowa faktura');

    const notificationsBefore = notifications.length;
    const second = await runOnce();
    assert.equal(second.status, 'complete', `${second.reason ?? ''}\n${logs.join('\n')}`);
    assert.equal(second.saved.length, 0);
    assert.equal(notifications.length, notificationsBefore);
    assert.equal((await readFile(join(dataDir, 'index.jsonl'), 'utf8')).trim().split('\n').length, 1);
  });
});
