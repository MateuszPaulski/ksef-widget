import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { loadConfig } from './config.ts';
import { readKeyPassword } from './credentials.ts';
import { createOsascriptNotifier } from './notify.ts';
import { warsawDay } from './report.ts';
import { run } from './run.ts';
import { buildSnapshot, readPreviousFailure, writeSnapshot } from './snapshot.ts';

const SNAPSHOT_PATH = join(homedir(), 'Library', 'Application Support', 'ksef-daily-fetch', 'widget.json');
const USAGE = 'Usage: node src/main.ts [--dry-run | --test-notification]';
// 3 = main.ts handled a failure itself; 1 is left to usage errors and to Node dying before main runs,
// which scripts/run-daily.sh reports.
const EXIT_CODES = { complete: 0, partial: 2, failed: 3 } as const;

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

async function main(args: string[]): Promise<number> {
  const flag = args[0];
  if (args.length > 1 || (flag !== undefined && flag !== '--dry-run' && flag !== '--test-notification')) {
    console.error(USAGE);
    return 1;
  }

  const notify = createOsascriptNotifier();
  if (flag === '--test-notification') {
    await notify('KSeF: test powiadomienia', 'Powiadomienia działają.');
    return 0;
  }
  const dryRun = flag === '--dry-run';

  const repoRoot = resolve(import.meta.dirname, '..');
  let config;
  let keyPassword;
  try {
    config = await loadConfig(join(repoRoot, 'config.json'), repoRoot);
    keyPassword = await readKeyPassword(config.nip);
  } catch (err) {
    const message = errorMessage(err);
    console.error(message);
    if (!dryRun) {
      // Same rule as in run(): do not repeat a failure notification that was already shown today.
      const previous = await readPreviousFailure(SNAPSHOT_PATH);
      if (previous !== null && previous.reason === message && previous.today === warsawDay(new Date())) {
        console.error('repeated failure, notification skipped');
      } else {
        try {
          await notify('KSeF: błąd pobierania faktur', message);
        } catch (notifyErr) {
          console.error(`could not show the notification: ${errorMessage(notifyErr)}`);
        }
      }
      try {
        await writeSnapshot(SNAPSHOT_PATH, buildSnapshot({ status: 'failed', reason: message }, [], new Date()));
      } catch (snapshotErr) {
        console.error(`could not write the widget snapshot: ${errorMessage(snapshotErr)}`);
      }
    }
    return EXIT_CODES.failed;
  }

  const summary = await run({
    config,
    keyPassword,
    fetch,
    sleep: (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms)),
    now: () => new Date(),
    notify,
    log: (line) => console.log(`${new Date().toISOString()} ${line}`),
    snapshotPath: SNAPSHOT_PATH,
    dryRun,
  });
  if (dryRun && summary.status === 'failed') console.error(summary.reason);
  return EXIT_CODES[summary.status];
}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (err) => {
    console.error(errorMessage(err));
    process.exitCode = 1;
  },
);
