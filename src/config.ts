import { isAbsolute, resolve } from 'node:path';
import { readFile } from 'node:fs/promises';
import { ENVIRONMENTS, type Environment } from './environments.ts';

export interface Config {
  nip: string;
  environment: Environment;
  certificatePath: string;
  keyPath: string;
  startDate: string;
  dataDir: string;
}

const NIP_WEIGHTS = [6, 5, 7, 2, 3, 4, 5, 6, 7];
// The OpenAPI NIP pattern: first digit 1-9, digits 2-3 not both 0.
const NIP_PATTERN = /^[1-9]((\d[1-9])|([1-9]\d))\d{7}$/;

export function isValidNip(nip: string): boolean {
  if (!NIP_PATTERN.test(nip)) return false;
  const sum = NIP_WEIGHTS.reduce((acc, weight, i) => acc + weight * Number(nip[i]), 0);
  return sum % 11 === Number(nip[9]);
}

function isValidStartDate(value: string, today: Date): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value && value <= today.toISOString().slice(0, 10);
}

function requireAbsolutePath(raw: Record<string, unknown>, field: 'certificatePath' | 'keyPath'): string {
  const value = raw[field];
  if (typeof value !== 'string' || !isAbsolute(value)) {
    throw new Error(`config.json: ${field} musi być ścieżką bezwzględną`);
  }
  return value;
}

export function parseConfig(raw: unknown, repoRoot: string, today: Date): Config {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new Error('config.json: oczekiwano obiektu JSON');
  }
  const fields = raw as Record<string, unknown>;

  const nip = fields['nip'];
  if (typeof nip !== 'string' || !isValidNip(nip)) {
    throw new Error('config.json: nip musi mieć 10 cyfr i poprawną sumę kontrolną');
  }

  const environment = fields['environment'];
  if (typeof environment !== 'string' || !Object.hasOwn(ENVIRONMENTS, environment)) {
    throw new Error(`config.json: environment musi być jednym z: ${Object.keys(ENVIRONMENTS).join(', ')}`);
  }

  const certificatePath = requireAbsolutePath(fields, 'certificatePath');
  const keyPath = requireAbsolutePath(fields, 'keyPath');

  const startDate = fields['startDate'];
  if (typeof startDate !== 'string' || !isValidStartDate(startDate, today)) {
    throw new Error('config.json: startDate musi mieć format RRRR-MM-DD i nie może być z przyszłości');
  }

  const dataDir = fields['dataDir'] ?? 'data';
  if (typeof dataDir !== 'string') {
    throw new Error('config.json: dataDir musi być tekstem');
  }

  return {
    nip,
    environment: environment as Environment,
    certificatePath,
    keyPath,
    startDate,
    dataDir: resolve(repoRoot, dataDir),
  };
}

export async function loadConfig(path: string, repoRoot: string): Promise<Config> {
  let raw: unknown;
  try {
    raw = JSON.parse(await readFile(path, 'utf8'));
  } catch (err) {
    throw new Error(`Nie można wczytać config.json: ${err instanceof Error ? err.message : String(err)}`);
  }
  return parseConfig(raw, repoRoot, new Date());
}
