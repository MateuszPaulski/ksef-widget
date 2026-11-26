import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

export type Notifier = (title: string, message: string) => Promise<void>;

export function createOsascriptNotifier(
  exec: (file: string, args: string[]) => Promise<unknown> = promisify(execFile),
): Notifier {
  return async (title, message) => {
    // Text goes in as argv, never into the AppleScript source: seller names are attacker-controlled.
    await exec('osascript', [
      '-e',
      'on run argv',
      '-e',
      'display notification (item 2 of argv) with title (item 1 of argv)',
      '-e',
      'end run',
      title,
      message,
    ]);
  };
}
