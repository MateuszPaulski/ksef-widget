import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createOsascriptNotifier } from '../../src/notify.ts';

describe('createOsascriptNotifier', () => {
  it('passes the text as argv, never inside the script', async () => {
    const calls: Array<[string, string[]]> = [];
    const notify = createOsascriptNotifier(async (file, args) => {
      calls.push([file, args]);
    });
    const message = 'A "quoted" \\ name"; do shell script "rm -rf ~"';

    await notify('KSeF: 1 nowa faktura', message);

    assert.equal(calls.length, 1);
    const [file, args] = calls[0]!;
    assert.equal(file, 'osascript');
    assert.deepEqual(args, [
      '-e',
      'on run argv',
      '-e',
      'display notification (item 2 of argv) with title (item 1 of argv)',
      '-e',
      'end run',
      'KSeF: 1 nowa faktura',
      message,
    ]);
    assert.equal(args.at(-1), message);
  });
});
