# ADR-0003 — Incremental sync by PermanentStorage HWM via the metadata query, with file-based state

Date: 2026-11-26
Status: accepted

## Context

KSeF offers two ways to pull invoices: the synchronous metadata query (`POST /invoices/query/metadata`) plus single downloads (`GET /invoices/ksef/{ksefNumber}`), or the asynchronous export (`POST /invoices/exports`) that builds AES-encrypted, split ZIP packages. Both support the `PermanentStorage` date with a high-water mark (`permanentStorageHwmDate`) below which KSeF guarantees the invoice set is complete and will never change. MF recommends the metadata query and single downloads for low-volume taxpayers, synchronising about once a day. Rate limits are tight: metadata 20/h, downloads 64/h per context and IP. The owner receives a few dozen purchase invoices a month.

## Decision

- Query metadata with `subjectType=Subject2`, `dateType=PermanentStorage`, `sortOrder=Asc`, `restrictToPermanentStorageHwmDate=true`, in windows of at most 90 days; handle `hasMore` / `isTruncated` as documented; download each new invoice singly.
- Keep state in plain files under a configurable data directory: `state.json` with the checkpoint (the last fully processed window's HWM as the exact server string, or the window's own `to` when KSeF reports an HWM beyond it), an append-only `index.jsonl` of saved invoices keyed by KSeF number that doubles as the dedup set, the XMLs under `invoices/YYYY/MM/<ksefNumber>.xml`, and daily Markdown reports.
- The checkpoint advances only when every invoice of a window is on disk. A run cut short leaves it unchanged; the next run re-lists the window and the index skips saved invoices.

## Consequences

- No database, no ZIP or AES handling, two read endpoints in total.
- Invoices stored after the current HWM appear on the next run, typically minutes to a day later; acceptable for a daily digest.
- A first backfill larger than about 60 invoices completes over several runs because of the 64/h download limit.
- The state is human-readable and repairable by hand; a corrupt index line fails the run loudly rather than being skipped.
- If volume ever grows to hundreds of invoices a day, switching to the export API is a new decision; the HWM checkpoint semantics carry over.
