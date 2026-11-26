import { appendFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { InvoiceMetadata } from './ksef.ts';

export interface Store {
  readonly checkpoint: string | null;
  has(ksefNumber: string): boolean;
  saveInvoice(invoice: InvoiceMetadata, xml: Buffer): Promise<void>;
  writeCheckpoint(value: string): Promise<void>;
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

async function writeAtomic(target: string, data: string | Buffer): Promise<void> {
  await mkdir(dirname(target), { recursive: true });
  const temp = `${target}.tmp`;
  await writeFile(temp, data);
  await rename(temp, target);
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

  const saved = new Set<string>();
  const index = await readIfExists(join(dataDir, 'index.jsonl'));
  if (index !== null) {
    index.split('\n').forEach((line, i) => {
      if (line === '') return;
      try {
        const ksefNumber = (JSON.parse(line) as { ksefNumber?: unknown }).ksefNumber;
        if (typeof ksefNumber !== 'string') throw new Error('missing ksefNumber');
        saved.add(ksefNumber);
      } catch {
        throw new Error(`Uszkodzony plik index.jsonl, linia ${i + 1}`);
      }
    });
  }

  return {
    get checkpoint() {
      return checkpoint;
    },
    has: (ksefNumber) => saved.has(ksefNumber),
    async saveInvoice(invoice, xml) {
      const [year, month] = invoice.issueDate.split('-');
      const file = `invoices/${year}/${month}/${invoice.ksefNumber}.xml`;
      await writeAtomic(join(dataDir, file), xml);
      const line = {
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
