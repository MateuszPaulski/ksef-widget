import type { Config } from './config.ts';
import { loadCredentials } from './credentials.ts';
import { ENVIRONMENTS } from './environments.ts';
import { createHttp } from './http.ts';
import { authenticate, downloadInvoice, queryMetadata, type InvoiceMetadata } from './ksef.ts';
import type { Notifier } from './notify.ts';
import { formatNotification, formatReportSection, warsawDay, type RunSummary } from './report.ts';
import { buildSnapshot, readPreviousFailure, widgetInvoice, writeSnapshot, type WidgetInvoice } from './snapshot.ts';
import { appendReport, openStore, readIndex } from './store.ts';
import { listWindow, nextWindow, syncInvoices, type Query } from './sync.ts';

export interface RunOptions {
  config: Config;
  keyPassword: string;
  fetch: typeof fetch;
  sleep: (ms: number) => Promise<void>;
  now: () => Date;
  notify: Notifier;
  log: (line: string) => void;
  snapshotPath: string;
  dryRun?: boolean;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export async function run(options: RunOptions): Promise<RunSummary> {
  const { config, now, log } = options;
  const startedAt = now();
  const saved: InvoiceMetadata[] = [];
  let summary: RunSummary;

  try {
    const credentials = await loadCredentials(config.certificatePath, config.keyPath, options.keyPassword);
    const store = await openStore(config.dataDir, now);
    const http = createHttp(ENVIRONMENTS[config.environment].apiBase, { fetch: options.fetch, sleep: options.sleep });
    const accessToken = await authenticate(http, credentials, config.nip, config.environment, { sleep: options.sleep });
    const query: Query = (window, pageOffset) => queryMetadata(http, accessToken.token, window, pageOffset);
    const from = store.checkpoint ?? `${config.startDate}T00:00:00Z`;

    if (options.dryRun) {
      const { invoices } = await listWindow(query, nextWindow(from, now()));
      const notSaved = invoices.filter((invoice) => !store.has(invoice.ksefNumber)).length;
      log(`dry run: ${invoices.length} invoices in the first window, ${notSaved} not yet saved`);
      return { startedAt, status: 'complete', saved: [] };
    }

    const outcome = await syncInvoices({
      from,
      store,
      query,
      download: (ksefNumber) => downloadInvoice(http, accessToken.token, ksefNumber),
      tokenValidUntil: accessToken.validUntil,
      now,
      sleep: options.sleep,
      onSaved: (invoice) => saved.push(invoice),
    });
    summary =
      outcome.status === 'complete'
        ? { startedAt, status: 'complete', saved }
        : { startedAt, status: 'partial', reason: outcome.reason, saved };
  } catch (err) {
    summary = { startedAt, status: 'failed', reason: errorMessage(err), saved };
  }

  if (options.dryRun) return summary;

  // A lasting failure would otherwise notify at every hourly run: stay quiet when the snapshot on disk already
  // holds the same failure from today. New invoices saved by this run are always announced.
  const finishedAt = now();
  let repeatedFailure = false;
  if (summary.status === 'failed' && summary.saved.length === 0) {
    const previous = await readPreviousFailure(options.snapshotPath);
    repeatedFailure = previous !== null && previous.reason === summary.reason && previous.today === warsawDay(finishedAt);
  }

  if (summary.status !== 'complete' || summary.saved.length > 0) {
    try {
      await appendReport(config.dataDir, warsawDay(startedAt), formatReportSection(summary, config.environment));
    } catch (err) {
      log(`could not write the report: ${errorMessage(err)}`);
    }
    const notification = repeatedFailure ? null : formatNotification(summary);
    if (repeatedFailure) log('repeated failure, notification skipped');
    if (notification !== null) {
      try {
        await options.notify(notification.title, notification.message);
      } catch (err) {
        log(`could not show the notification: ${errorMessage(err)}`);
      }
    }
  }

  let invoices: WidgetInvoice[] = [];
  try {
    invoices = (await readIndex(config.dataDir)).map((entry) => widgetInvoice(entry, config.environment));
  } catch (err) {
    log(`could not read the index for the widget: ${errorMessage(err)}`);
  }
  try {
    await writeSnapshot(options.snapshotPath, buildSnapshot(summary, invoices, finishedAt));
  } catch (err) {
    log(`could not write the widget snapshot: ${errorMessage(err)}`);
  }
  log(`status=${summary.status} saved=${summary.saved.length}${summary.reason === undefined ? '' : ` reason=${summary.reason}`}`);
  return summary;
}
