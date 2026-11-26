import { join, resolve } from 'node:path';
import { loadConfig } from './config.ts';
import { readKeyPassword } from './credentials.ts';
import { createOsascriptNotifier } from './notify.ts';
import { run } from './run.ts';

const USAGE = 'Usage: node src/main.ts [--dry-run | --test-notification]';
const EXIT_CODES = { complete: 0, partial: 2, failed: 1 } as const;

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
      try {
        await notify('KSeF: błąd pobierania faktur', message);
      } catch (notifyErr) {
        console.error(`could not show the notification: ${errorMessage(notifyErr)}`);
      }
    }
    return 1;
  }

  const summary = await run({
    config,
    keyPassword,
    fetch,
    sleep: (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms)),
    now: () => new Date(),
    notify,
    log: (line) => console.log(`${new Date().toISOString()} ${line}`),
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
