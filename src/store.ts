import { appendFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { InvoiceMetadata } from './ksef.ts';

export interface Store {
  readonly checkpoint: string | null;
  has(ksefNumber: string): boolean;
  savedSince(instant: Date): number;
  saveInvoice(invoice: InvoiceMetadata, xml: Buffer): Promise<void>;
  writeCheckpoint(value: string): Promise<void>;
}

export interface IndexEntry {
  ksefNumber: string;
  invoiceNumber: string;
  issueDate: string;
  sellerNip: string;
  sellerName: string | null;
  grossAmount: number;
  currency: string;
  permanentStorageDate: string;
  invoiceHash: string;
  file: string;
  savedAt: string;
}

function hasCode(err: unknown, code: string): boolean {
  return err instanceof Error && 'code' in err && err.code === code;
}

async function readIfExists(path: string): Promise<string | null> {
  try {
    return await readFile(path, 'utf8');
  } catch (err) {
    if (hasCode(err, 'ENOENT')) return null;
    throw err;
  }
}

export async function writeAtomic(target: string, data: string | Buffer): Promise<void> {
  await mkdir(dirname(target), { recursive: true });
  const temp = `${target}.tmp`;
  await writeFile(temp, data);
  await rename(temp, target);
}

export async function readIndex(dataDir: string): Promise<IndexEntry[]> {
  const index = await readIfExists(join(dataDir, 'index.jsonl'));
  const entries: IndexEntry[] = [];
  if (index !== null) {
    index.split('\n').forEach((line, i) => {
      if (line === '') return;
      try {
        const entry = JSON.parse(line) as IndexEntry;
        if (typeof entry.ksefNumber !== 'string') throw new Error('missing ksefNumber');
        entries.push(entry);
      } catch {
        throw new Error(`Uszkodzony plik index.jsonl, linia ${i + 1}`);
      }
    });
  }
  return entries;
}

export async function openStore(dataDir: string, now: () => Date): Promise<Store> {
  let checkpoint: string | null = null;
  const state = await readIfExists(join(dataDir, 'state.json'));
  if (state !== null) {
    const parsed: unknown = JSON.parse(state);
    const value = typeof parsed === 'object' && parsed !== null ? (parsed as { checkpoint?: unknown }).checkpoint : undefined;
    if (typeof value !== 'string') throw new Error('Uszkodzony plik state.json');
    checkpoint = value;
  }

  const entries = await readIndex(dataDir);
  const saved = new Set(entries.map((entry) => entry.ksefNumber));
  const savedAt = entries.map((entry) => Date.parse(entry.savedAt));

  return {
    get checkpoint() {
      return checkpoint;
    },
    has: (ksefNumber) => saved.has(ksefNumber),
    savedSince: (instant) => savedAt.filter((t) => t > instant.getTime()).length,
    async saveInvoice(invoice, xml) {
      const [year, month] = invoice.issueDate.split('-');
      const file = `invoices/${year}/${month}/${invoice.ksefNumber}.xml`;
      await writeAtomic(join(dataDir, file), xml);
      const line: IndexEntry = {
        ksefNumber: invoice.ksefNumber,
        invoiceNumber: invoice.invoiceNumber,
        issueDate: invoice.issueDate,
        sellerNip: invoice.seller.nip,
        sellerName: invoice.seller.name ?? null,
        grossAmount: invoice.grossAmount,
        currency: invoice.currency,
        permanentStorageDate: invoice.permanentStorageDate,
        invoiceHash: invoice.invoiceHash,
        file,
        savedAt: now().toISOString(),
      };
      await appendFile(join(dataDir, 'index.jsonl'), `${JSON.stringify(line)}\n`);
      saved.add(invoice.ksefNumber);
      savedAt.push(Date.parse(line.savedAt));
    },
    async writeCheckpoint(value) {
      await writeAtomic(join(dataDir, 'state.json'), `${JSON.stringify({ checkpoint: value })}\n`);
      checkpoint = value;
    },
  };
}

export async function appendReport(dataDir: string, day: string, section: string): Promise<void> {
  const path = join(dataDir, 'reports', `${day}.md`);
  await mkdir(dirname(path), { recursive: true });
  try {
    // 'wx' fails if the file exists, so the header is written only for a new file.
    await writeFile(path, `# Faktury z KSeF — ${day}\n\n${section}\n`, { flag: 'wx' });
  } catch (err) {
    if (!hasCode(err, 'EEXIST')) throw err;
    await appendFile(path, `${section}\n`);
  }
}
