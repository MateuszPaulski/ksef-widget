# KSeF year summary and fallback removal — design

Date: 2026-11-27
Status: approved scope (owner), technical calls by the orchestrator (O), details by the spec author (S)

## 1. Intent

Two changes to `KSeF.app`, which the owner has installed and confirmed against production (saving settings and **Sprawdź połączenie** work with their real certificate; real invoices now exist in their invoice folder).

1. **Remove the TypeScript fallback.** It was to stay "until the owner confirms the app against production" (ADR-0008); they have, and asked for its removal. The Swift app becomes the only implementation.
2. **Current-year summary at the bottom of the widget.** The owner asked for "current year summary at the bottom — expenses, incomes" and approved this layout ("all fine, looks good"):

```
KSeF · zaktualizowano 14:00              2 nowe dziś
Acme Sp. z o.o.          1230,00 PLN    26.11
Orange Polska              89,99 PLN    25.11
────────────────────────────────────────────────
2026 · wydatki 48 210,55 PLN · przychody 182 400,00 PLN
```

Approved rules: expenses = purchase invoices (the owner is the buyer, `Subject2`); incomes = sales invoices (the owner is the seller, `Subject1`), which the app has never fetched, so it adds an hourly metadata query for them and keeps only summary data (no XML, no notification, no report entry); net amounts in the summary, invoice rows stay gross; year by issue date, current calendar year in Europe/Warsaw; correcting invoices count with their sign; PLN in the total and other currencies as separate sums (`+ 1 200,00 EUR`), never converted; the medium widget shows two invoice rows instead of three, the large widget keeps its rows. Accepted limits: totals cover only what is in KSeF; the TypeScript code does not get this.

## 2. Goals

1. The repository holds one implementation: no `src/`, no Node tooling, no launchd scripts, no LaunchAgent detection in the app; README and AGENTS.md describe only the app; the owner learns which leftovers of the old setup they may delete.
2. The app keeps an independent **ledger** of the current year's purchase and sales invoice metadata in the invoice folder, synced hourly by the proven HWM rules, and writes a display-ready year summary into the widget snapshot.
3. The widget shows the summary line under the invoice rows, says when it is not current, and renders a snapshot without the summary exactly as today.
4. Every Swift suite stays green after each commit; the TEST E2E proves income and expense on both sides of one sent invoice.

## 3. Non-goals

- No XML download, notification, report line or index entry for sales invoices; no `Subject3` or `SubjectAuthorized`.
- No currency conversion, no gross or VAT totals, no per-month breakdown, no previous years in the widget, no new settings, no new UI besides the footer.
- No change to `index.jsonl`, `state.json`, `invoices/`, `reports/`, `identity.json` or their formats; no migration of the owner's folder.
- No edit of the historical specs and plans in `docs/superpowers/` or of ADR-0001…0007.
- No change to the widget extension's entitlements, the snapshot path or the probe.

## 4. Anti-goals

- **A summary that fails silently.** A ledger that is behind, has never finished, or cannot be read says so in the footer line itself. A sum covering only part of the year never appears as the year's total.
- **A summary that breaks the fetch.** The ledger never makes a run partial or failed, never notifies, never writes the report, and never starts before the invoice download has completed in that run.
- **Money in binary floating point.** Sums are exact.
- **Silent double counting.** A re-listed window never adds a line twice.

## 5. Constraints and recon facts

Sources: the TEST OpenAPI (`https://api-test.ksef.mf.gov.pl/docs/v2/openapi.json`, fetched 2026-11-27, "OpenAPI" below), the official docs repo `CIRFMF/ksef-api` ("docs"), and the official client `CIRFMF/ksef-client-csharp` ("C# client"), both at their default branch on 2026-11-27.

### 5.1 Metadata

- `POST /invoices/query/metadata` takes `subjectType`: `Subject1` = "Podmiot 1 - sprzedawca", `Subject2` = "Podmiot 2 - nabywca" (OpenAPI `InvoiceQuerySubjectType`). The docs' incremental-sync guide says invoices "powinny być pobierane oddzielnie dla każdego typu podmiotu" and keeps one continuation point per subject type (`pobieranie-faktur/przyrostowe-pobieranie-faktur.md`).
- Every `InvoiceMetadata` item has, as required fields, `netAmount`, `grossAmount`, `vatAmount` (all `number`, `format: double`), `currency` (3 letters), `invoiceType`, `issueDate` (`format: date`), `ksefNumber`, `permanentStorageDate`, `seller`, `buyer` (OpenAPI). Descriptions: `netAmount` "Łączna kwota netto", `grossAmount` "Łączna kwota brutto", `vatAmount` "Łączna kwota VAT **wyrażona w PLN**".
- `invoiceType` values: `Vat`, `Zal`, `Kor`, `Roz`, `Upr`, `KorZal`, `KorRoz` (FA), `VatPef`, `VatPefSp`, `KorPef` (PEF), `VatRr`, `KorVatRr` (FA_RR) (OpenAPI `InvoiceType`).
- The C# client's E2E (`KSeF.Client.Tests.Core/E2E/Invoice/InvoiceDataVerificationTests.cs`) queries `Subject1` as the seller for the FA(3) template with `P_13_1` 43.60, `P_14_1` 10.03, `P_15` 53.63 and asserts `NetAmount` 43.6, `VatAmount` 10.03, `GrossAmount` 53.63. Our TEST template has the same three amounts.
- Amounts in FA(3) are `TKwotowy`: `xsd:decimal`, `fractionDigits` 2, pattern `-?([1-9]\d{0,15}|0)(\.\d{1,2})?` (`faktury/schemy/FA/schemat_FA(3)_v1-0E.xsd`), so signed with at most two decimals.
- Rate limits for the metadata query: 8/s, 16/min, 20/h (`x-rate-limits` in the OpenAPI, `limity/limity-api.md`), counted per context (NIP) and IP. The docs say TEST defaults are ten times PROD; AGENTS.md treats TEST as 20/h. This design keeps 20/h as binding for TEST.
- The date range may span at most 100 days (OpenAPI, changelog 2.x); the app keeps its 90-day windows.
- `P_1` (issue date) "nie może być późniejsza niż data przyjęcia dokumentu do systemu KSeF" (`faktury/weryfikacja-faktury.md`). So every invoice issued in a year is stored at or after that year's 1 January, 00:00 Warsaw time, which is 23:00 UTC on 31 December (1 January is always CET, UTC+1).
- The docs' local-data principle: business operations such as reporting "były wykonywane na danych przechowywanych lokalnie, które zostały wcześniej zsynchronizowane z KSeF" (`limity/limity-api.md`).

### 5.2 Correcting, advance and settlement invoices

- FA(3) `P_13_x` (net per rate): "W przypadku faktur korygujących - kwota różnicy, o której mowa w art. 106j ust. 2 pkt 5 ustawy"; `P_15`: "W przypadku faktur korygujących - korekta kwoty wynikającej z faktury korygowanej" (XSD). The changelog of API 2.3.0 allowed negative values in the `amount` filter ("Umożliwiono wyszukiwanie faktur po ujemnych kwotach"). Together: a correction that lowers a sale carries negative amounts. Confirmed on TEST 2026-11-27 (FA(3) only; nothing is claimed about PROD): the metadata of a `KOR` with `P_13_1` -43.60, `P_14_1` -10.03 and `P_15` -53.63 came back as `invoiceType` `Kor`, `netAmount` -43.6, `grossAmount` -53.63, `vatAmount` -10.03, so all three amounts carry the sign of the invoice. The docs still never say how `netAmount` is derived.
- `Zal` (advance): `P_13_x` "W przypadku faktur zaliczkowych - wartość zaliczki netto" (XSD). `Roz` (settlement after advances, art. 106f ust. 3): the XSD says only that `P_15` holds "kwota pozostała do zapłaty"; it says nothing special for `P_13_x`. If issuers put only the remainder in `P_13_x` of a `Roz`, `Zal` + `Roz` add up to the sale; if they put the full value, the sale counts twice. **UNCONFIRMED**; it depends on the issuer. The summary counts every invoice type; the ledger keeps `invoiceType`, so a later rule (for example excluding `Zal`) needs no refetch.
- `Upr` (simplified invoice) may lack `P_13_x`; what `netAmount` then holds is **UNCONFIRMED** (small amounts by definition, at most 450 PLN).

### 5.3 Currency

`currency` is the invoice's `KodWaluty`. Confirmed on TEST 2026-11-27 (nothing is claimed about PROD): a `Vat` invoice with `KodWaluty` EUR, `P_13_1` 100.00, `P_14_1` 23.00, `P_14_1W` 98.42 and `P_15` 123.00 came back as `currency` `EUR`, `netAmount` 100, `grossAmount` 123, `vatAmount` 98.42, so net and gross are in the invoice currency and `vatAmount` is the PLN value of the VAT (`P_14_1W`). The summary uses only `netAmount` with `currency`.

### 5.4 The app today

- `syncInvoices` (`widget/Core/Sync.swift`) walks 90-day windows from a checkpoint, pages and narrows on truncation (`listWindow`), downloads and saves each new invoice, writes the checkpoint after each window (the HWM, or the window's `to` when the HWM is beyond it), stops on an open window, and turns a `RateLimitError` into a partial outcome. `queryMetadata` (`widget/Core/KsefClient.swift`) always sends `Subject2`.
- `InvoiceMetadata` decodes `grossAmount` as `Double`. It is also decoded from the frozen `widget/CoreTests/Fixtures/formats.json` (no `netAmount` there) and encoded by `FakeKsef`.
- Amount text comes from `formatAmount` (`widget/Core/Report.swift`): `pl_PL`, two decimals, round half away from zero; grouping with U+00A0 only from 10 000 (`12 345,67 PLN`, `1230,00 PLN`), pinned by the frozen `amounts` goldens.
- The widget snapshot (ADR-0006) carries display-ready strings; the widget decodes it with `JSONDecoder` (`widget/Shared/Snapshot.swift`). The medium widget shows 3 rows, or 2 under a banner; the large one 8.
- `identity.json` is checked at the start of every run, before anything else in the folder is read.
- The TypeScript fallback: `src/` (13 files), `test/` (unit, e2e, support, golden generator, the FA(3) template the Swift E2E also reads), `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig.json`, `config.example.json`, `scripts/launchagent.sh`, `scripts/run-daily.sh`, `.gitignore` entry `node_modules/`. The app pauses while `~/Library/LaunchAgents/local.ksef-daily-fetch.plist` exists (menu state, settings banner, tests). No LaunchAgent was ever installed on the owner's Mac.

## 6. Approaches considered for the summary's data source

### 6.1 Derive from the purchase index — rejected
`index.jsonl` holds gross amounts only, starts at the owner's chosen start date (perhaps later than 1 January) and has no sales at all. Adding net amounts would change a format that real data already uses, and sales would still need a second source.

### 6.2 On-demand yearly query — rejected
Re-listing the whole year for both subjects every hour costs up to 11 metadata queries per run against a 20/h limit, competes with the invoice download, and goes against the docs' rule that reporting runs on locally synchronised data.

### 6.3 Independent ledger by HWM sync — chosen (O)
One incremental metadata sync per subject, on the same window, paging and checkpoint code as the download, starting at the beginning of the current year, appending one summary line per invoice to a new file. Idle cost: one query per subject per run. Additive files only; the owner's folder needs no migration.

## 7. Decisions

### 7.1 Fallback removal
- (O) Delete everything that exists only for the TypeScript fetcher: `src/`, `test/unit/`, `test/e2e/`, `test/support/`, `test/golden/make-vectors.ts`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig.json`, `config.example.json`, `scripts/launchagent.sh`, `scripts/run-daily.sh`.
- (O) Move `test/fixtures/fa3-invoice.xml` to `widget/E2ETests/Fixtures/fa3-invoice.xml` (`git mv`, attribution unchanged) and point `FetchE2ETests` at it; `KsefE2ETests` excludes `Fixtures/**` from its sources, as `KsefCoreTests` does.
- (O) `widget/CoreTests/Fixtures/*.json` stay as frozen artefacts; a short `widget/CoreTests/Fixtures/README.md` says where they came from (the removed TypeScript generator, recoverable from git history), that they are never regenerated or edited, and what each pins.
- (O) Remove the LaunchAgent detection from the app: `AppPaths.legacyLaunchAgent`, `LegacyLaunchAgent`, `MenuState.legacyAgent` and its line, the settings banner and its form field, the tick and menu branches, the launch log field, `LegacyLaunchAgentTests` and the related assertions and render.
- (S) `.gitignore`: drop `node_modules/`. **Keep `config.json` and `data/`** (overrules "entries that only served them"): the repository is public and the owner's main checkout probably still holds a real `config.json` (NIP, paths) and possibly a `data/` folder with invoices from their PROD dry run; the README tells them to delete these, and until they do, the ignore lines keep them out of a commit.
- (S) Comments: only `widget/Core/Report.swift` "so the Swift and TypeScript URLs stay identical" is reworded (the URLs must match those already in the owner's reports, pinned by `formats.json`). Comments that explain a byte contract by JavaScript behaviour (`JSON.stringify`, `Date.parse`, `Intl.NumberFormat`, `AbortSignal.timeout`, Node's issuer string) stay: they say why the frozen formats look as they do. Test names that say "TypeScript" stay: they name the fixtures' provenance.
- (S) README and AGENTS.md describe only the app; the snapshot path lives in three places (`widget/Core/AppPaths.swift`, `widget/Extension/Extension.entitlements`, `widget/Shared/Snapshot.swift`). The README lists the leftovers the owner may delete, as commands for them (7.7).
- (S) ADR-0008 and ADR-0010 are new in this unmerged branch and are corrected where they describe the fallback or the LaunchAgent check in the present tense. No new ADR: the removal completes ADR-0008's plan.

### 7.2 The ledger (on-disk contract, ADR-0013)
- (S) Files in the invoice folder, next to the existing ones:
  - `ledger.jsonl`, append-only, one line per invoice and subject, keys in this order: `{"ksefNumber","subjectType","issueDate","invoiceType","currency","netAmount","grossAmount","vatAmount"}`; `subjectType` is `Subject2` (expense) or `Subject1` (income); amounts are JSON numbers exactly as KSeF sent them. Example: `{"ksefNumber":"5265877635-20261120-0123456789AB-CD","subjectType":"Subject2","issueDate":"2026-11-20","invoiceType":"Vat","currency":"PLN","netAmount":43.6,"grossAmount":53.63,"vatAmount":10.03}`.
  - `ledger-state.json`, rewritten atomically: `{"Subject2":"<checkpoint>","Subject1":"<checkpoint>","completeAt":"<ISO instant>"}`; each key appears once it has been written, always in this order. Checkpoints are kept verbatim as in `state.json`. `completeAt` is the instant of the last run in which both subjects reached the open window.
- (S) Dedup key: subject + `ksefNumber`, held in memory from the file; a re-listed window adds nothing. A line is appended before its window's checkpoint is written, exactly like `index.jsonl`.
- (S) A line is written only for metadata with `netAmount`, `grossAmount`, `vatAmount` (each a whole number of grosze, 7.4), `invoiceType` and an `issueDate` matching `YYYY-MM-DD`; anything else stops the ledger for this run with `Nieprawidłowe metadane faktury <ksefNumber> do podsumowania roku` (log only; shown as "behind", 7.5).
- (O) The new metadata fields are decoded as optional on the shared `InvoiceMetadata`, so the invoice download never fails because of a ledger-only field and the frozen `formats.json` still decodes.
- (S) Start: per subject, the later of its checkpoint and the current year's start `"<year>-01-01T00:00:00+01:00"` (Warsaw midnight; overrules the orchestrator's "UTC midnight": an invoice issued on 1 January and sent between 00:00 and 01:00 Warsaw time is stored at 23:xx UTC on 31 December and would be missed, 5.1). The year is the Warsaw year of the run. Independent of the settings' start date.
- (S) Year rollover: nothing is reset. On the first run of a new year the start moves to the new year's start (any checkpoint before it is skipped, which skips only invoices stored before the new year began, so issued in the old year); old lines stay in `ledger.jsonl` and are simply not summed. After a long pause the ledger resumes at the current year's start, not at an old checkpoint.
- (S) Identity: the ledger lives in the invoice folder, so the existing `identity.json` check at the start of `run()` covers it; the summary is computed only after that check passed in the same run, so a folder of another NIP or environment is never summed.
- (O) Reuse: the window loop of `syncInvoices` (next window, list, process, closed-window HWM rule, checkpoint, stop, rate-limit → partial) moves into one function both syncs call; `queryMetadata` takes the subject. `SyncTests` stay unchanged and prove the refactor.

### 7.3 Order, stop rule, query counts
- (O, S) In `run()`, after the invoice download: only if the download outcome is **complete**, sync `Subject2`, then `Subject1`, with the same login and inside the same run gate. The first subject that ends partial (rate limit) or throws stops the ledger for this run; the next run continues from the checkpoints. If both end complete, `completeAt` is written. Ledger results never change the run's status, reason, report or notification; a stopped ledger writes one log line `ledger <subjectType> stopped: <reason>`, a complete one writes nothing.
- (S) The ledger also runs after a manual **Pobierz teraz**; **Sprawdź połączenie** (dry run) never touches it.
- (S) Metadata queries per run (one page per window, at most 250 invoices per 90 days):
  - idle hourly run: 1 (download) + 1 + 1 = **3** (was 1);
  - first run after the update, today (27.11): 1 + 4 + 4 = **9**; on 27–31 December: 1 + 5 + 5 = **11**; a fresh folder adds the download's own backfill windows first;
  - the ledger pauses 500 ms before each of its queries (the first included), because the first run's 9 to 11 queries otherwise go out within about two seconds and drew a per-second 429 on TEST;
  - a 429 with `Retry-After` over 120 s, or a fourth 429, ends the ledger as partial; the download never waits for the ledger.
  - A manual press costs 3 queries; about six presses within an hour of a scheduled run reach 20/h, and then the next download is partial with KSeF's rate-limit reason (notified, resumes next hour). Accepted.

### 7.4 Money
- (S) Amounts are decoded from JSON as `Double` (as `grossAmount` is today), then converted once to integer grosze (`Int64`) by `(amount × 100).rounded()`; a value more than 0.001 grosz away from a whole number of grosze, not finite, or at least 10¹⁰ PLN in magnitude is rejected (7.2). For any value with at most two decimals below that bound this conversion is exact (the Double's error times 100 stays far below 0.001 grosz; around 10¹¹ PLN it no longer would, and valid amounts would be rejected). Sums are `Int64` grosze per currency.
- (S) Formatting reuses `formatAmount(Double(grosze) / 100, currency)`, so the summary looks exactly like invoice rows (`48 210,55 PLN`, U+00A0 grouping from 10 000, `1230,00 PLN` below). So an amount below 10 000 is not grouped: the approved example's `+ 1 200,00 EUR` is written `+ 1200,00 EUR`, as invoice rows already write `1230,00 PLN`. A side is `<PLN total> PLN` (always, `0,00 PLN` when empty), then ` + <sum> <CODE>` for every other currency with a non-zero sum, codes in ascending order.

### 7.5 Summary and snapshot
- (S) Computed at the end of every run whose identity check passed, from `ledger.jsonl` and `ledger-state.json` on disk, for the Warsaw year of the run end: expenses = `Subject2` lines, incomes = `Subject1` lines, both filtered by `issueDate` starting with `<year>-`, summing `netAmount`.
- (S) The snapshot gains an optional object after `invoices`, display-ready (ADR-0006): `"yearSummary": {"text": "<line>", "warning": <bool>}`. A snapshot without it (written by the installed app, or by a setup failure) decodes and renders exactly as today, and the frozen `snapshotJson` golden stays byte-identical. The line, pinned:

  | State | `text` | `warning` |
  |---|---|---|
  | this run completed both subjects | `2026 · wydatki 48 210,55 PLN · przychody 182 400,00 PLN` | false |
  | not completed this run, `completeAt` exists | `2026 (stan na 26.11 11:00) · wydatki … · przychody …` (`completeAt` in Warsaw, `DD.MM HH:mm`) | true |
  | never completed (no `completeAt`) | `2026 · podsumowanie w przygotowaniu` | true |
  | `ledger.jsonl` or `ledger-state.json` unreadable | `2026 · podsumowanie niedostępne: Uszkodzony plik ledger.jsonl, linia 3` (or `Uszkodzony plik ledger-state.json`) | true |

  The "stan na" part comes right after the year, so a truncated line still shows it. A partial backfill never shows a total until both subjects completed once.
- (S) Setup failures (`reportSetupFailure`: no settings, unreadable credential files, missing Keychain item) write no summary: they happen before the folder's identity is checked, and their failed banner already explains the state. The footer returns with the next run.
- (S) Until the first run after Warsaw midnight on 1 January the footer keeps showing the previous year's line, labelled with that year; that run switches it.

### 7.6 Widget
- (S) `WidgetModel` gains a footer (text, warning) from `yearSummary`; the view draws a `Divider` and the line in `.caption`, `.monospacedDigit()`, `.secondary` (or `.orange` when warning), at most two lines, tail truncation, at the bottom below `Spacer`. `Text(verbatim:)` as everywhere.
- (S) Rows: large 8; medium 3, minus 1 under a banner, minus 1 with a footer (so 2 with a footer, 1 with banner and footer).
- (S) The extension's entitlements, data path and timeline are unchanged (the app reloads timelines after every run).

### 7.7 Leftovers the owner may delete (README, commands for the owner only)
In their main checkout: `config.json`, `node_modules/`, and `data/` only after checking it holds nothing they want. `~/.config/ksef-daily-fetch/` (after making sure the original `.crt` and `.key` are kept somewhere safe; the app has its own copies). The old Keychain item: `security delete-generic-password -s ksef-daily-fetch`. If it exists: `~/Library/Logs/ksef-daily-fetch.log`. And, as a check only (none was ever installed): `ls ~/Library/LaunchAgents | grep ksef`.

## 8. Risks and open points

- Correction sign, foreign-currency net and `vatAmount` in PLN were confirmed on TEST on 2026-11-27 for FA(3) (5.2, 5.3); production behaviour is not verified and the owner can compare the totals with their bookkeeping.
- `Zal` + `Roz` double counting depends on the issuer (5.2); `Upr` net may be zero (5.2).
- An idle run now spends 3 metadata queries instead of 1; manual presses spend 3 each (7.3).
- `completeAt` lags by at most the run interval; the "stan na" suffix appears whenever a run does not complete the ledger, including runs whose download was partial (cap, token), until the next complete run.
- A crash between appending a ledger line and writing the checkpoint re-lists the window; dedup prevents double lines. A torn last line makes the ledger unreadable; the footer says so and the README explains the fix (remove the line, or delete both ledger files to rebuild from 1 January at the cost of up to 10 queries).
- The TEST E2E budget is tight against 20/h per context: 19 queries worst case for the buyer (Task 8).
- Building the app registers a second copy with macOS and may make the owner's live widget flicker; the plan builds it once, at the end.

## 9. Left to the builder

Names of private helpers; the order of tests inside a file; the exact wording of log lines beyond those pinned here.

## 10. Only the owner can verify (after reinstalling with `scripts/build-app.sh --install`)

1. The footer appears in the real medium and large widget after the first run, in light and dark appearance; medium shows two rows.
2. The first run after the update completes the ledger (footer without "stan na"); `ledger.jsonl` and `ledger-state.json` appear in the invoice folder; existing files are untouched.
3. Expenses and incomes match their own records for the year (net, by issue date), including any correction, advance/settlement or foreign-currency invoice they have.
4. After a run that hits a limit or fails, the footer shows `(stan na …)` in orange and clears at the next complete run.
5. On 1 January the footer switches to the new year at the first run.
6. They delete the leftovers of 7.7 they no longer need.
