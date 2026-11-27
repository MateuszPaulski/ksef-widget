# ADR-0013 — The app also syncs sales-invoice metadata into a year ledger in the invoice folder

Date: 2026-11-27
Status: accepted

## Context

The owner asked for a current-year summary on the widget: net expenses (purchase invoices, the owner as `Subject2`) and net incomes (sales invoices, the owner as `Subject1`), by issue date, PLN plus separate sums for other currencies. The app has only ever fetched purchase invoices (ADR-0003), and `index.jsonl` holds gross amounts only, from the owner's chosen start date; real data already uses that format. KSeF metadata carries `netAmount`, `grossAmount`, `vatAmount`, `currency`, `invoiceType` and `issueDate` for both subject types; the metadata query is limited to 20 per hour per context and IP; KSeF recommends keeping one continuation point per subject type and doing reporting on locally synchronised data. Design: `docs/superpowers/specs/2026-11-27-ksef-year-summary-and-fallback-removal-design.md` (6, 7.2–7.5).

## Decision

- After a complete invoice download, each run syncs metadata for `Subject2` and then `Subject1` with the HWM window rules of ADR-0003 (one shared implementation), starting at the later of each subject's checkpoint and Warsaw midnight on 1 January of the current year. Nothing is downloaded for sales invoices; nothing about them is notified or reported.
- Two new files in the invoice folder form a new on-disk contract: `ledger.jsonl` (append-only; one line per invoice and subject: `ksefNumber`, `subjectType`, `issueDate`, `invoiceType`, `currency`, `netAmount`, `grossAmount`, `vatAmount`; deduplicated by subject and KSeF number) and `ledger-state.json` (one checkpoint per subject and `completeAt`, the last run that brought both up to date). Existing files and formats are unchanged; `identity.json` guards the ledger like the rest of the folder.
- Sums are exact (integer grosze); amounts are not converted between currencies; correcting invoices count with the sign KSeF reports.
- The widget snapshot (ADR-0006) gains an optional, display-ready `yearSummary` (`text`, `warning`); a snapshot without it renders as before.
- A ledger that hits a limit or fails never changes the run's outcome; the summary line says whether it is current, not yet ready or unreadable.

## Consequences

- An idle run spends 3 metadata queries instead of 1; the first run after the update spends up to 11; a manual fetch spends 3. A rate limit stops the ledger, which continues next hour; the download always goes first.
- The sales side exists only as summary data; downloading sales XML, reporting it or other subject types would be a new decision.
- Old ledger lines are kept across years; only the current year is summed. Deleting both ledger files rebuilds them from 1 January.
- How KSeF derives `netAmount` for corrections, simplified and advance/settlement invoices is not documented; the ledger keeps `invoiceType` and all three amounts so a changed rule needs no refetch.
- Extends ADR-0003 (a second subject type, separate checkpoints) and ADR-0006 (an optional snapshot field); supersedes neither.
