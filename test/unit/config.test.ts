import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { isValidNip, parseConfig } from '../../src/config.ts';

const REPO_ROOT = '/repo';
const TODAY = new Date('2026-11-26T12:00:00Z');

const base = {
  nip: '5265877635',
  environment: 'prod',
  certificatePath: '/Users/test/ksef-auth.crt',
  keyPath: '/Users/test/ksef-auth.key',
  startDate: '2026-02-01',
  dataDir: 'data',
};

function parse(overrides: Record<string, unknown>) {
  return parseConfig({ ...base, ...overrides }, REPO_ROOT, TODAY);
}

describe('parseConfig', () => {
  it('accepts a valid config and resolves dataDir', () => {
    assert.deepEqual(parse({}), { ...base, dataDir: '/repo/data' });
    const { dataDir: _omitted, ...withoutDataDir } = base;
    assert.equal(parseConfig(withoutDataDir, REPO_ROOT, TODAY).dataDir, '/repo/data');
    assert.equal(parse({ dataDir: '/tmp/x' }).dataDir, '/tmp/x');
  });

  it('accepts a startDate equal to today', () => {
    assert.equal(parse({ startDate: '2026-11-26' }).startDate, '2026-11-26');
  });

  const invalid: Array<[string, Record<string, unknown>, string]> = [
    ['nip checksum', { nip: '5265877636' }, 'config.json: nip musi mieć 10 cyfr i poprawną sumę kontrolną'],
    ['nip type', { nip: 5265877635 }, 'config.json: nip musi mieć 10 cyfr i poprawną sumę kontrolną'],
    ['environment', { environment: 'production' }, 'config.json: environment musi być jednym z: test, demo, prod'],
    ['relative certificatePath', { certificatePath: 'cert.crt' }, 'config.json: certificatePath musi być ścieżką bezwzględną'],
    ['tilde certificatePath', { certificatePath: '~/x.crt' }, 'config.json: certificatePath musi być ścieżką bezwzględną'],
    ['relative keyPath', { keyPath: 'key.key' }, 'config.json: keyPath musi być ścieżką bezwzględną'],
    ['tilde keyPath', { keyPath: '~/x.key' }, 'config.json: keyPath musi być ścieżką bezwzględną'],
    ['startDate month', { startDate: '2026-13-01' }, 'config.json: startDate musi mieć format RRRR-MM-DD i nie może być z przyszłości'],
    ['startDate format', { startDate: '1.02.2026' }, 'config.json: startDate musi mieć format RRRR-MM-DD i nie może być z przyszłości'],
    ['startDate future', { startDate: '2026-11-27' }, 'config.json: startDate musi mieć format RRRR-MM-DD i nie może być z przyszłości'],
    ['dataDir type', { dataDir: 42 }, 'config.json: dataDir musi być tekstem'],
  ];
  for (const [name, overrides, message] of invalid) {
    it(`rejects invalid ${name}`, () => {
      assert.throws(() => parse(overrides), { message });
    });
  }

  it('rejects a config that is not an object', () => {
    for (const raw of [null, 'x', 42, [], undefined]) {
      assert.throws(() => parseConfig(raw, REPO_ROOT, TODAY), { message: 'config.json: oczekiwano obiektu JSON' });
    }
  });
});

describe('isValidNip', () => {
  it('checks length, leading zero and checksum', () => {
    assert.equal(isValidNip('5265877635'), true);
    assert.equal(isValidNip('5265877636'), false);
    assert.equal(isValidNip('526587763'), false);
    assert.equal(isValidNip('0265877635'), false);
  });
});
