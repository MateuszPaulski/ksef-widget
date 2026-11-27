# KSeF Year Summary and Fallback Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the TypeScript fallback so the Swift app is the only implementation, and add a current-year summary (net expenses and incomes) to the widget, backed by a ledger of purchase and sales invoice metadata in the invoice folder.

**Architecture:** First the removal, in two commits that keep every Swift suite green. Then, in `KsefCore` and test-first: the HWM window loop is split out of `syncInvoices` so a second sync can reuse it; a `Ledger` store and `syncLedger` keep `ledger.jsonl` and `ledger-state.json`; a pure summary function turns them into one display-ready line in the widget snapshot; `run()` calls the ledger after a complete download. Then the widget shows the line as a footer, the TEST E2E proves both sides of one invoice, and the docs and a single final app build close the change.

**Tech Stack:** Swift 6 (language mode 6.0), Xcode `xcodebuild`, XcodeGen (`/opt/homebrew/bin/xcodegen`), XCTest, Foundation, SwiftUI, WidgetKit; macOS 14.0 deployment target on Apple Silicon.

**Spec:** `docs/superpowers/specs/2026-11-27-ksef-year-summary-and-fallback-removal-design.md` (read it first; section numbers below refer to it). ADRs: ADR-0013 (ledger), ADR-0003 (HWM sync), ADR-0006 (snapshot), ADR-0008 (removal), in `ADR.md`.

## Global Constraints

**Safety — the owner's app is installed, configured and running with real credentials and real invoice data (orchestrator's hard rules):**
- Never read, list or touch: `~/Applications/KSeF.app`, `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/`, `~/Library/Application Support/ksef-daily-fetch/`, the owner's invoice folder (default `~/Documents/KSeF`), `~/.config/ksef-daily-fetch/`, the Keychain (never run `security`; never instantiate `KeychainSecretStore`; never set `KSEF_KEYCHAIN_TEST`), or `config.json` in the main checkout. Never run anything from the main checkout; work only in this worktree.
- Never launch, quit, kill or signal the app (no unconfigured smoke launch: the owner's app folder exists). Never run `open`, `pkill`, `killall`, `osascript`, `launchctl`, or `scripts/build-app.sh --install`; never pass a signing identity or `DEVELOPMENT_TEAM`.
- Building: the test bundles (`KsefCoreTests`, `KsefWidgetTests`, `KsefAppTests`, `KsefE2ETests`) may be built and run freely; none of them builds the app. **Build the app exactly once**, in Task 9, Step 4, with `scripts/build-app.sh` and no arguments; never run `-scheme KsefWidget` or `-scheme SnapshotProbe` builds anywhere else.
- Network only to `https://api-test.ksef.mf.gov.pl/v2`, only from `KsefE2ETests`, with self-signed certificates and random NIPs; never between 16:00 and 18:00 Europe/Warsaw (check `TZ=Europe/Warsaw date` first); the full fetch E2E and the probe each at most twice an hour (TEST is treated as 20 metadata queries per hour per NIP). Never DEMO or PROD.
- After Task 9's build: `pluginkit -m -v -p com.apple.widgetkit-extension | grep -c "/widget/build/"` must print `0` (it filters out the owner's installed copy; do not print the unfiltered list).

**Repository and git:**
- Work only in this worktree on branch `ksef-swift-app`. Never push, never touch `main`. One `git` command per shell call, run from the worktree directory; no heredocs or `&&` chains with git; commit with `git commit -F <message file>`, the file outside the worktree (e.g. `$TMPDIR`). Every commit message ends with the attribution lines your harness provides.
- The repository is public: no real name, e-mail, NIP of the owner, Team ID, signing identity, home-directory path or names of other apps or projects in tracked files or commit messages; write home paths as `~/…`. Before each commit run `git grep -n <your login name>` (type the name literally) → no output.
- Do not edit `docs/superpowers/specs/2026-11-26-*`, `docs/superpowers/plans/2026-11-26-*`, `docs/adr/000[1-7]*`.

**Coding guidelines (follow them in every task):**
1. Think first — state assumptions; push back if something simpler exists.
2. Simplicity — minimum code; no unrequested features, single-use abstractions, speculative flexibility, or handling for impossible cases.
3. Surgical changes — every changed line traces to the request; match existing style; don't touch adjacent code; remove what your change orphaned.
4. Goal-driven — every task ends in a verifiable check.
5. Comments — write code that needs none. A comment is either a directive a tool reads, or one or two lines saying what the code cannot show: why this and not the obvious alternative, a constraint, a unit, a gotcha. What the code does belongs in names and types; what changed and why belongs in the commit message; future work is one `TODO` line. A doc block carries only what the signature lacks.

**Swift and build:**
- No third-party packages, no Swift Package Manager. `KsefCore` imports only `Foundation`, `Security`, `CryptoKit`, `CommonCrypto`: `grep -rhoE "^import [A-Za-z0-9]+" widget/Core | sort -u` prints only those four.
- Regenerate after adding or removing a file or editing `widget/project.yml`: `xcodegen generate --spec widget/project.yml --project widget`.
- Commands used below (all with `-project widget/KsefWidget.xcodeproj -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build`):
  - `CORE_TESTS` = `xcodebuild … -scheme KsefCoreTests test`
  - `WIDGET_TESTS` = `xcodebuild … -scheme KsefWidgetTests test` (prefix `TEST_RUNNER_WIDGET_RENDER_DIR=<dir>` for PNGs)
  - `APP_TESTS` = `xcodebuild … -scheme KsefAppTests test`
  - `E2E_BUILD` = `xcodebuild … -scheme KsefE2ETests build-for-testing` (compiles, no network)
  - `GREEN` = `CORE_TESTS`, `WIDGET_TESTS`, `APP_TESTS` all print `** TEST SUCCEEDED **` and `E2E_BUILD` prints `** TEST BUILD SUCCEEDED **`. Every commit in this plan is preceded by `GREEN`.
- Test counts today (`grep -c "func test"`): `KsefCoreTests` 219, `KsefWidgetTests` 31, `KsefAppTests` 8, `KsefE2ETests` 3. Each task states the count after it; report the counts `xcodebuild` prints.

**Copy:** Polish for every user-facing string, exactly as pinned here; English for code, comments, docs, log lines. Seller names, invoice numbers and reasons are attacker-controlled: in SwiftUI always `Text(verbatim:)`. Log lines never carry tokens, passwords, key material or full widget URLs.

**Pinned values (spec 7.2–7.6):**
- Files in the invoice folder: `ledger.jsonl`, `ledger-state.json`.
- Ledger line key order: `ksefNumber, subjectType, issueDate, invoiceType, currency, netAmount, grossAmount, vatAmount`; state key order: `Subject2, Subject1, completeAt` (absent keys omitted).
- Year start: `"<year>-01-01T00:00:00+01:00"`.
- Errors: `Uszkodzony plik ledger.jsonl, linia <N>`, `Uszkodzony plik ledger-state.json`, `Nieprawidłowe metadane faktury <quoted ksefNumber> do podsumowania roku` (`quoted` = the existing helper in `Sync.swift`: JSON-quoted, first 60 characters).
- Footer lines: `<year> · wydatki <side> · przychody <side>`; `<year> (stan na DD.MM HH:mm) · wydatki <side> · przychody <side>`; `<year> · podsumowanie w przygotowaniu`; `<year> · podsumowanie niedostępne: <error>`. Side: `formatAmount(PLN)` then ` + <formatAmount>` per other non-zero currency, codes ascending.
- Log line when the ledger stops: `ledger <Subject1|Subject2> stopped: <reason>`; nothing when it completes.

## Review Focus

1. **The owner's existing folder** (written by the installed app: `identity.json`, `state.json`, `index.jsonl`, invoices) must keep every existing file byte-identical except the checkpoint the download already rewrites, and only gain the two ledger files. Test in Task 6 (`testAnExistingFolderKeepsItsFilesAndGainsTheLedger`).
2. **A snapshot written by the currently installed app** (no `yearSummary`) must decode and render exactly as today, and a run without a summary must write the frozen golden bytes. Tests in Task 5 (`testWritesTheTypeScriptBytes`, unchanged) and Task 7 (`testTheContractWithoutAYearSummaryHasNoFooter`, the six existing renders).
3. **Corrections that zero or invert a sum**: a currency whose sum is 0 disappears, a negative sum is shown with its sign, PLN is always shown. Test in Task 5 (`testFormatsTotals`).
4. **A rate-limited or failing ledger** must leave the run complete, notify and report exactly as without the ledger, and show the state in the footer. Test in Task 6 (`testALedgerRateLimitLeavesTheRunCompleteAndSaysSoInTheFooter`).
5. **The Warsaw new year**: an invoice issued on 1 January and stored at 23:30 UTC on 31 December is in the new year's ledger window; one issued in the old year and stored in the new one is not summed. Tests in Task 4 (`testStartsAtWarsawNewYearWithoutACheckpoint`) and Task 5 (`testSumsTheWarsawYearByIssueDate`).

---

## File structure

```
.gitignore                                  # T2: drop node_modules/ (keep config.json, data/: spec 7.1)
README.md, AGENTS.md                        # T2: fallback removed; T9: year summary, ledger files
src/ test/ package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.json config.example.json
scripts/launchagent.sh scripts/run-daily.sh # T2: DELETED (test/fixtures/fa3-invoice.xml moved, see below)
widget/
  project.yml                               # T2: KsefE2ETests excludes Fixtures/**
  Core/
    AppPaths.swift Schedule.swift StatusLine.swift          # T1: LaunchAgent detection removed; T5: warsawStamp internal
    Report.swift                                            # T2: one comment reworded
    KsefClient.swift Sync.swift                             # T3: Subject, optional metadata fields, walkWindows
    Store.swift                                             # T4: append(_:to:) internal
    Ledger.swift                                            # T4 NEW: LedgerEntry, grosze, Ledger, yearStart, syncLedger; T6: updateLedger
    YearSummary.swift                                       # T5 NEW: formatTotals, yearSummary
    WidgetSnapshot.swift                                    # T5: yearSummary field
    Run.swift                                               # T6: ledger after the download, summary into the snapshot
  App/AppDelegate.swift SettingsView.swift SettingsWindow.swift   # T1
  CoreTests/
    Fixtures/README.md                      # T2 NEW: provenance of the frozen fixtures
    LegacyLaunchAgentTests.swift            # T1 DELETED
    SettingsTests.swift StatusLineTests.swift               # T1
    KsefClientTests.swift                   # T3
    LedgerTests.swift                       # T4 NEW
    YearSummaryTests.swift WidgetSnapshotTests.swift        # T5
    RunTests.swift Support/FakeKsef.swift   # T6
  AppTests/SettingsRenderTests.swift        # T1
  Shared/Snapshot.swift WidgetModel.swift InvoiceListView.swift   # T7
  Tests/Fixtures.swift SnapshotTests.swift WidgetModelTests.swift RenderTests.swift   # T7
  E2ETests/
    Fixtures/fa3-invoice.xml                # T2 MOVED from test/fixtures/
    Fixtures/fa3-correction.xml Fixtures/fa3-invoice-eur.xml   # T8 NEW
    SendInvoice.swift FetchE2ETests.swift   # T2 path; T8 template helper, both sides
    SummaryProbeE2ETests.swift              # T8 NEW
```

Unchanged: `widget/Extension/`, `widget/Probe/`, `scripts/build-app.sh`, `widget/CoreTests/Fixtures/*.json`.

---

### Task 1: Remove the LaunchAgent detection from the app

Spec 7.1. Size: small.

**Files:**
- Modify: `widget/Core/AppPaths.swift` (field `legacyLaunchAgent` and its assignment), `widget/Core/Schedule.swift` (`enum LegacyLaunchAgent`), `widget/Core/StatusLine.swift` (`MenuState.legacyAgent` and its line), `widget/App/AppDelegate.swift` (launch log `legacyAgent=…`; the `if LegacyLaunchAgent.isInstalled` block in `tick`; `legacy` in `menuContent`: `canFetch = settings.verified && !model.gate.isRunning`, `displayed = model.gate.isRunning ? .running : menuState`, `showsWarningIcon: snapshot?.status == .failed`), `widget/App/SettingsView.swift` (`SettingsForm.legacyAgent`, the banner and `legacyBanner`), `widget/App/SettingsWindow.swift` (`legacyAgent:` in `makeForm`), `widget/CoreTests/SettingsTests.swift` (the `legacyLaunchAgent` assertion), `widget/CoreTests/StatusLineTests.swift` (the `.legacyAgent` assertion), `widget/AppTests/SettingsRenderTests.swift` (`legacyAgent` parameter and `testRenderLegacyAgent`)
- Delete: `widget/CoreTests/LegacyLaunchAgentTests.swift`

**Interfaces:**
- Produces: `public enum MenuState { case running, notConfigured, notVerified; case idle(SnapshotStatus?) }`; `SettingsForm` without `legacyAgent`.

- [ ] **Step 1: Remove the tests first:** delete `LegacyLaunchAgentTests.swift`, the two assertions and the render test with its parameter; regenerate the project.
- [ ] **Step 2: Remove the production code** listed above. Nothing else changes; the tick still requires verified settings and the hourly due rule.
- [ ] **Step 3: Verify.** `grep -rn -E "legacy|LaunchAgent|launchd" widget --include=*.swift` → no output. `GREEN`; `KsefCoreTests` 218, `KsefAppTests` 7, `KsefWidgetTests` 31.
- [ ] **Step 4: Commit** `refactor(app): drop the old LaunchAgent check` (body: the TypeScript fallback is being removed; no LaunchAgent was ever installed by the app's owner).

---

### Task 2: Remove the TypeScript fallback

Spec 7.1, 7.7. Size: medium.

**Files:**
- Move: `test/fixtures/fa3-invoice.xml` → `widget/E2ETests/Fixtures/fa3-invoice.xml` (`git mv`, content unchanged)
- Delete (`git rm -r`): `src/`, `test/`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig.json`, `config.example.json`, `scripts/launchagent.sh`, `scripts/run-daily.sh`
- Create: `widget/CoreTests/Fixtures/README.md`
- Modify: `widget/project.yml`, `widget/E2ETests/FetchE2ETests.swift:57-60`, `widget/Core/Report.swift:38`, `.gitignore`, `README.md`, `AGENTS.md`

- [ ] **Step 1: Move the template.** `git mv test/fixtures/fa3-invoice.xml widget/E2ETests/Fixtures/fa3-invoice.xml`. In `FetchE2ETests`, replace `repositoryRoot` with the fixtures folder next to the test file: `URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fa3-invoice.xml")`. In `widget/project.yml`, `KsefE2ETests` sources become `- path: E2ETests` with `excludes: ["Fixtures/**"]` (as `KsefCoreTests`), the four `CoreTests/Support/…` entries unchanged. Regenerate; `E2E_BUILD` → `** TEST BUILD SUCCEEDED **`.
- [ ] **Step 2: Delete the TypeScript code** with `git rm -r` (one call per path). Locally, remove the untracked `node_modules/` folder of this worktree (`rm -rf node_modules`, worktree only). `.gitignore`: delete the `node_modules/` line only; keep `data/`, `config.json` and the key/certificate lines (spec 7.1).
- [ ] **Step 3: Freeze the fixtures.** `widget/CoreTests/Fixtures/README.md`, about eight lines: the six JSON files were generated by the TypeScript implementation (`test/golden/make-vectors.ts`, removed on 2026-11-27, recoverable from git history) with throwaway self-signed TEST keys; they are frozen: never regenerate or hand-edit them; `xades-*.json` pin the XAdES signer (RSA byte-identical), `keys.json` the key reader, `formats.json` the on-disk and display formats the owner's existing data uses (index lines, `state.json`, report, notifications, snapshot, amounts).
- [ ] **Step 4: Reword one comment.** `Report.swift:38` → `/// Everything outside the RFC 3986 unreserved set, byte by byte, so links match those already in the owner's reports (pinned by formats.json).` Leave the other JavaScript/Node comments and the "TypeScript" test names (spec 7.1).
- [ ] **Step 5: README without the fallback.** Delete: the last sentence of the first section's third paragraph ("The TypeScript fetcher it replaces…"); in "Set up › Where things live", "The formats are the same as the TypeScript fetcher's." and change "(new, or written by the TypeScript fetcher)" to "(new, or written by an earlier version)"; in "Running", "are those of the TypeScript fetcher" (→ "Notification rules:") and the whole paragraph about the old LaunchAgent; the whole "Fallback: the TypeScript fetcher" section; checklist item 10; in "Development", the `# the TypeScript fallback` lines, and "and `pnpm test`" in "What was verified". Replace the fixtures paragraph with: the fixtures in `widget/CoreTests/Fixtures/` are frozen outputs of the removed TypeScript implementation (see their README); the RSA signature must stay byte-identical to `xades-rsa.json`. Add a section **Leftovers of the old setup** after "Desktop widget" with the spec 7.7 list as commands for the owner, prefaced: "Only the owner runs these; nothing in the app needs them." Commands, verbatim:
  ```sh
  # in the main checkout of this repository
  rm config.json
  rm -rf node_modules
  ls data   # delete data/ only if it holds nothing you want
  # the old credential copies: first make sure the original .crt and .key are kept somewhere safe
  rm -r ~/.config/ksef-daily-fetch
  security delete-generic-password -s ksef-daily-fetch
  rm -f ~/Library/Logs/ksef-daily-fetch.log
  ls ~/Library/LaunchAgents | grep ksef   # expected: nothing (no LaunchAgent was installed)
  ```
- [ ] **Step 6: AGENTS.md without the fallback.** First paragraph: drop the fallback sentences and the "only one of the two may run" rule; keep the design links. Commands: drop the golden regeneration and the four `pnpm` lines. Rules: drop "Fixtures … come from `test/golden/make-vectors.ts`" and replace with "Fixtures in `widget/CoreTests/Fixtures/` are frozen (their README); never regenerate or hand-edit them; the RSA XAdES signature must stay byte-identical (`XadesTests`) and the on-disk formats byte-compatible (`formats.json`)"; drop the whole "Fallback (TypeScript, `src/`)" rule and "Never install or load the LaunchAgent …"; network rule: only `widget/E2ETests/`; snapshot path rule: "lives in three places that change together: `widget/Core/AppPaths.swift`, `widget/Extension/Extension.entitlements` and `widget/Shared/Snapshot.swift`". Replace the launch and registration rules with the safety block of this plan's Global Constraints (the owner's app is installed: never read or touch `~/Applications/KSeF.app`, the app folder, the snapshot folder, the invoice folder; never launch, quit, kill or signal the app; build the app only through `scripts/build-app.sh` without arguments, at most once per change; the filtered `pluginkit … | grep -c "/widget/build/"` check). Known follow-ups: `/auth/rev2` is now one path string in `widget/Core/KsefClient.swift`; drop the "Remove the TypeScript fetcher" item.
- [ ] **Step 7: Verify.** `git ls-files | grep -E "^(src|test)/|package.json|pnpm|tsconfig|config.example|launchagent|run-daily"` → no output. `grep -rn -E "pnpm|src/|test/fixtures|make-vectors|launchagent|run-daily|fallback" README.md AGENTS.md widget --include=*.md --include=*.swift --include=*.yml` → only the fixtures README's mention of `test/golden/make-vectors.ts`. `GREEN` (counts as after Task 1).
- [ ] **Step 8: Commit** `chore: remove the TypeScript fallback` (body: the owner confirmed the app against production; what was deleted, what moved, why `config.json`/`data/` stay ignored).

---

### Task 3: One window walk for every sync; the subject in the query

Spec 7.2 (reuse, optional fields). Size: small.

**Files:**
- Modify: `widget/Core/Sync.swift`, `widget/Core/KsefClient.swift`, `widget/Core/Run.swift:55-57`, `widget/CoreTests/KsefClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // KsefClient.swift
  enum Subject: String, Decodable, Sendable { case seller = "Subject1", buyer = "Subject2" }
  public struct InvoiceMetadata {  // existing fields unchanged, plus (var, so the memberwise init defaults them to nil):
      var netAmount: Double?
      var vatAmount: Double?
      var invoiceType: String?
  }
  func queryMetadata(http: KsefHTTP, token: String, subject: Subject, window: Window, pageOffset: Int) async throws -> MetadataPage
  // Sync.swift
  /// Lists windows from `from`; `process` sees each window's invoices before its checkpoint is written,
  /// and a non-nil result ends the walk without writing it.
  func walkWindows(
      from: String, query: Query, now: @Sendable () -> Date,
      process: ([InvoiceMetadata]) async throws -> SyncOutcome?,
      writeCheckpoint: (String) throws -> Void
  ) async throws -> SyncOutcome
  func quoted(_ value: String) -> String   // was private
  ```

- [ ] **Step 1: Write the failing tests** in `KsefClientTests`. Existing calls gain `subject: .buyer` (their expected `Subject2` bodies stay).
  - `testQueriesSalesInvoicesAsSubject1`: as `testQueriesPurchaseInvoicesByPermanentStorage` with `subject: .seller`; body `subjectType` is `"Subject1"`.
  - `testDecodesTheSummaryFieldsWhenPresentAndNilWhenAbsent`: decode `MetadataPage` from a JSON page with two invoices, one with `"netAmount":43.6,"vatAmount":10.03,"invoiceType":"Kor"`, one without those keys → `43.6`, `10.03`, `"Kor"`; then `nil`, `nil`, `nil`.
  Run `CORE_TESTS` → compile failure (no `subject:` parameter).
- [ ] **Step 2: Implement.** `queryMetadata` writes `("subjectType", .string(subject.rawValue))`. The three optional fields on `InvoiceMetadata` (declared `var` after `invoiceHash`). `walkWindows` holds the loop of today's `syncInvoices` verbatim (next window, `listWindow`, then `process`, then the closed-window null-HWM error, HWM-beyond-`to` rule, `writeCheckpoint`, stop on open window or unmoved `from`, `RateLimitError` → `.partial(errorMessage(error))` around the whole loop). `syncInvoices` keeps its signature and passes its per-invoice body (validation, token margin, pacing, cap, download, hash, save; its two `return .partial(…)` become the closure's return values) as `process`, and `store.writeCheckpoint` as `writeCheckpoint`; its `lastDownloadAt` stays a local captured by the closure. `Run.swift` passes `subject: .buyer`.
- [ ] **Step 3: Verify.** `SyncTests.swift` and `RunTests.swift` untouched (`git diff --stat -- widget/CoreTests/SyncTests.swift widget/CoreTests/RunTests.swift` → empty) and `GREEN`; `KsefCoreTests` 220.
- [ ] **Step 4: Commit** `refactor(core): share the HWM window walk; query by subject`.

---

### Task 4: The ledger store and its sync

Spec 7.2, 7.4. Size: medium.

**Files:**
- Create: `widget/Core/Ledger.swift`, `widget/CoreTests/LedgerTests.swift`
- Modify: `widget/Core/Store.swift` (`append(_:to:)` private → internal)

**Interfaces:**
- Consumes: `Subject`, `InvoiceMetadata`, `walkWindows`, `Query`, `SyncOutcome`, `quoted` (Task 3); `readIfExists`, `writeAtomic`, `append(_:to:)`, `JSONValue`, `KsefTime`, `KsefError`.
- Produces:
  ```swift
  struct LedgerEntry: Decodable, Equatable {
      let ksefNumber: String; let subjectType: Subject; let issueDate: String; let invoiceType: String
      let currency: String; let netAmount: Double; let grossAmount: Double; let vatAmount: Double
  }
  /// Whole grosze, or nil for a value with more than two decimals, not finite, or ≥ 10¹³ PLN in magnitude.
  func grosze(_ amount: Double) -> Int64?
  /// Throws `Nieprawidłowe metadane faktury <quoted> do podsumowania roku` unless the three amounts are whole grosze,
  /// invoiceType is present and issueDate is YYYY-MM-DD.
  func ledgerEntry(_ invoice: InvoiceMetadata, subject: Subject) throws -> LedgerEntry
  /// Used by one run at a time.
  final class Ledger {
      static func open(dataDir: URL) throws -> Ledger
      private(set) var entries: [LedgerEntry]
      private(set) var completeAt: String?
      func checkpoint(_ subject: Subject) -> String?
      func has(_ subject: Subject, _ ksefNumber: String) -> Bool
      func add(_ entry: LedgerEntry) throws   // not `append`: a method of that base name would shadow the free append(_:to:)
      func writeCheckpoint(_ subject: Subject, _ value: String) throws
      func writeCompleteAt(_ instant: Date) throws   // KsefTime.iso
  }
  func yearStart(_ year: Int) -> String   // "2026-01-01T00:00:00+01:00"
  func syncLedger(_ subject: Subject, ledger: Ledger, query: Query, year: Int, now: @Sendable () -> Date) async throws -> SyncOutcome
  ```

- [ ] **Step 1: Write the failing tests** (`LedgerTests`, temp folders via `temporaryDirectory()`, a fake `Query` closure recording windows like `SyncTests`' harness; `NOW = instant("2026-11-26T08:00:00Z")`, `HWM = "2026-11-26T07:00:00.1234567+00:00"`; metadata built with `InvoiceMetadata(…, netAmount:, vatAmount:, invoiceType:)`):
  1. `testGroszeAreExact`: `grosze(43.6) == 4360`, `grosze(-43.6) == -4360`, `grosze(1234567.89) == 123456789`, `grosze(99_999_999_999.99) == 9_999_999_999_999`, `grosze(0.1)! + grosze(0.2)! == 30`, `grosze(0) == 0`; `nil` for `1.005`, `.nan`, `.infinity`, `1e13`, `-1e13`.
  2. `testWritesTheLinePinnedInTheSpec`: `add(ledgerEntry(<5265877635-20261120-0123456789AB-CD, 2026-11-20, Vat, PLN, net 43.6, gross 53.63, vat 10.03>, subject: .buyer))` → file text exactly `{"ksefNumber":"5265877635-20261120-0123456789AB-CD","subjectType":"Subject2","issueDate":"2026-11-20","invoiceType":"Vat","currency":"PLN","netAmount":43.6,"grossAmount":53.63,"vatAmount":10.03}\n`.
  3. `testStateKeepsItsKeyOrder`: `writeCheckpoint(.seller, "b")`, `writeCheckpoint(.buyer, "a")`, `writeCompleteAt(instant("2026-11-26T13:00:41.123Z"))` → `ledger-state.json` text exactly `{"Subject2":"a","Subject1":"b","completeAt":"2026-11-26T13:00:41.123Z"}\n`; `Ledger.open` again → same checkpoints, `completeAt`, entries and `has` answers.
  4. `testUnreadableFilesFailLoudly`: line 2 of `ledger.jsonl` is `{"ksefNumber":` → `Uszkodzony plik ledger.jsonl, linia 2`; a line with `"subjectType":"Subject3"` → the same message with its line; `ledger-state.json` = `[]` → `Uszkodzony plik ledger-state.json`. Missing files → empty ledger, no checkpoints, `completeAt == nil`, nothing created.
  5. `testRejectsMetadataItCannotSum`: `ledgerEntry` throws the pinned message for each of: `netAmount` nil, `vatAmount` nil, `invoiceType` nil, `grossAmount` 1.005, `issueDate` `"2026-1-1"`; the message for ksefNumber `"x"` is exactly `Nieprawidłowe metadane faktury "x" do podsumowania roku`.
  6. `testStartsAtWarsawNewYearWithoutACheckpoint`: `syncLedger(.buyer, …, year: 2026)` → first window `from == "2026-01-01T00:00:00+01:00"`; an invoice with `permanentStorageDate` `2025-12-31T23:30:00.0000000+00:00` and `issueDate` `2026-01-01` returned by the fake is written; result `.complete`; `checkpoint(.buyer) == HWM`; 4 queries (three closed 90-day windows, then the open one).
  7. `testResumesFromALaterCheckpointAndSkipsAnEarlierOne`: checkpoint `2026-11-20T00:00:00.000Z` → first `from` is that; checkpoint `2025-06-01T00:00:00.000Z` → first `from` is `2026-01-01T00:00:00+01:00`.
  8. `testAppendsEachInvoiceOnceAcrossReListedWindows`: the fake returns the same invoice for every window → one line; a second `syncLedger` run → still one line.
  9. `testKeepsSubjectsApart`: the same ksefNumber synced as `.buyer` and `.seller` → two lines, `Subject2` then `Subject1`; each subject's checkpoint written under its own key.
  10. `testARateLimitIsPartialAndKeepsTheCheckpoint`: the fake throws `RateLimitError(retryAfterSeconds: 900)` on the second window → `.partial("Limit zapytań KSeF — trzeba odczekać 900 s.")`; checkpoint = the first window's `to`; lines of the first window kept.
  11. `testInvalidMetadataStopsBeforeTheCheckpoint`: one invoice without `netAmount` → throws the pinned message; no line, no checkpoint.
  Run `CORE_TESTS` → compile failure.
- [ ] **Step 2: Implement `Ledger.swift`.** Lines written with `JSONValue.object` in the pinned order (`.number` for amounts) via `append(_:to:)`; read like `readIndex` (split on the newline byte, decode each non-empty line with `JSONDecoder`, error with the 1-based line number). State decoded as an optional-keyed `Decodable`, rewritten whole with `writeAtomic`. Dedup set keyed by `"\(subject.rawValue) \(ksefNumber)"`. `syncLedger`: `from` = the checkpoint when `KsefTime.millis` of it exceeds that of `yearStart(year)`, else `yearStart(year)`; then `walkWindows` with a `process` that `add`s `ledgerEntry` for every invoice `has` does not know and returns `nil`, and `writeCheckpoint` for the subject.
- [ ] **Step 3: Verify.** `GREEN`; `KsefCoreTests` 231.
- [ ] **Step 4: Commit** `feat(core): year ledger of purchase and sales metadata`.

---

### Task 5: The year summary line and the snapshot field

Spec 7.4, 7.5. Size: medium.

**Files:**
- Create: `widget/Core/YearSummary.swift`, `widget/CoreTests/YearSummaryTests.swift`
- Modify: `widget/Core/WidgetSnapshot.swift`, `widget/Core/StatusLine.swift` (`warsawStamp` private → internal), `widget/CoreTests/WidgetSnapshotTests.swift`

**Interfaces:**
- Consumes: `Ledger`, `LedgerEntry`, `grosze` (Task 4); `formatAmount`, `warsawDay`, `warsawStamp` (`DD.MM HH:mm`).
- Produces:
  ```swift
  struct YearSummaryLine: Equatable { let text: String; let warning: Bool }
  func formatTotals(_ grosze: [String: Int64]) -> String
  /// For the Warsaw year of `now`; `ledgerCompleted` = this run brought both subjects up to date.
  func yearSummary(dataDir: URL, ledgerCompleted: Bool, now: Date) -> YearSummaryLine
  struct WidgetSnapshot { …; let yearSummary: YearSummaryLine? }   // new last field
  func buildSnapshot(status:reason:failureKey:invoices:now:yearSummary: YearSummaryLine? = nil) -> WidgetSnapshot
  ```
  Snapshot JSON: `"yearSummary": {"text": …, "warning": …}` after `"invoices"`, omitted when nil.

- [ ] **Step 1: Write the failing tests** (`nbsp = "\u{a0}"`; ledger folders written through `Ledger.add`/`writeCheckpoint`/`writeCompleteAt`):
  1. `testFormatsTotals`: `formatTotals([:]) == "0,00 PLN"`; `formatTotals(["PLN": 4821055]) == "48\(nbsp)210,55 PLN"`; `formatTotals(["EUR": 120000, "PLN": 18240000, "USD": 0, "CHF": -500]) == "182\(nbsp)400,00 PLN + \(formatAmount(-5, "CHF")) + 1200,00 EUR"`; `formatTotals(["EUR": 1]) == "0,00 PLN + 0,01 EUR"`.
  2. `testTheLineWhenTheLedgerIsCurrent`: lines (Subject2: Vat 2026 net 43.6 PLN, Kor 2026 net -10 PLN, Vat 2025-12-30 net 999 PLN; Subject1: Vat 2026 net 182400 PLN, Vat 2026 net 1200 EUR), `completeAt` set, `ledgerCompleted: true`, `now = instant("2026-11-26T13:00:00Z")` → `YearSummaryLine(text: "2026 · wydatki 33,60 PLN · przychody 182\(nbsp)400,00 PLN + 1200,00 EUR", warning: false)`.
  3. `testBehindShowsStanNaRightAfterTheYear`: same files, `completeAt` = `2026-11-26T10:00:00.000Z`, `ledgerCompleted: false` → text `"2026 (stan na 26.11 11:00) · wydatki 33,60 PLN · przychody 182\(nbsp)400,00 PLN + 1200,00 EUR"`, warning true.
  4. `testNeverCompletedShowsNoTotal`: lines present, no `completeAt`, `ledgerCompleted: false` → `("2026 · podsumowanie w przygotowaniu", true)`; an empty folder gives the same.
  5. `testAnUnreadableLedgerSaysSo`: line 3 corrupt → `("2026 · podsumowanie niedostępne: Uszkodzony plik ledger.jsonl, linia 3", true)`.
  6. `testSumsTheWarsawYearByIssueDate`: `now = instant("2026-12-31T23:30:00Z")` (Warsaw 2027), `ledgerCompleted: true`, a 2026 line and a `2027-01-01` line of net 5 → `"2027 · wydatki 5,00 PLN · przychody 0,00 PLN"`.
  7. `WidgetSnapshotTests.testWritesTheYearSummaryAfterTheInvoices`: `writeSnapshot(buildSnapshot(status: .complete, reason: nil, failureKey: nil, invoices: [], now: instant("2026-11-26T13:00:00Z"), yearSummary: YearSummaryLine(text: "2026 · wydatki 43,60 PLN · przychody 0,00 PLN", warning: false)))` → file text ends exactly with
     ```
       "invoices": [],
       "yearSummary": {
         "text": "2026 · wydatki 43,60 PLN · przychody 0,00 PLN",
         "warning": false
       }
     }
     ```
     followed by one newline. The existing `testWritesTheTypeScriptBytes` stays as it is (no summary → golden bytes).
  Run `CORE_TESTS` → compile failure.
- [ ] **Step 2: Implement.** `formatTotals`: `formatAmount(Double(pln) / 100, "PLN")`, then for each other code in ascending order with a non-zero sum ` + ` and `formatAmount(Double(sum) / 100, code)`. `yearSummary`: year = `Int(warsawDay(now).prefix(4))`; `Ledger.open` failure → `podsumowanie niedostępne: <errorMessage>`; no `completeAt` → `podsumowanie w przygotowaniu`; otherwise sum `grosze(netAmount)` of lines whose `issueDate` has prefix `"<year>-"` by `subjectType` and currency, and add ` (stan na <warsawStamp(completeAt)>)` after the year unless `ledgerCompleted`. Snapshot JSON as pinned.
- [ ] **Step 3: Verify.** `GREEN`; `KsefCoreTests` 238.
- [ ] **Step 4: Commit** `feat(core): year summary line in the widget snapshot`.

---

### Task 6: The ledger in every run

Spec 7.2, 7.3, 7.5. Size: medium.

**Files:**
- Modify: `widget/Core/Run.swift`, `widget/Core/Ledger.swift`, `widget/CoreTests/Support/FakeKsef.swift`, `widget/CoreTests/RunTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:
  ```swift
  // Ledger.swift
  /// Never throws; true when both subjects reached the open window and completeAt was written.
  func updateLedger(dataDir: URL, query: (Subject) -> Query, now: @escaping @Sendable () -> Date, log: @Sendable (String) -> Void) async -> Bool
  // FakeKsef.swift
  struct FakeKsefOptions { …; var salesInvoices: [FakeInvoice] = []; var metadataAnswer: (@Sendable (String) -> FakeDownloadAnswer?)? = nil }  // called with the request's subjectType
  ```
  `fakeInvoice(n)` gains `netAmount: Double(100 * n)`, `vatAmount: 0.5`, `invoiceType: "Vat"`.

- [ ] **Step 1: Extend the fakes.** `FakeKsef` reads `subjectType` from the metadata request body: `Subject1` answers `salesInvoices`, `Subject2` answers `invoices`; when `metadataAnswer` returns an answer for that subject, reply with it instead. `RunTests.rig` gains `salesInvoices:` and `metadataAnswer:` (defaults `[]`, `nil`). Add a helper `metadataQueries(_ r: Rig) async -> Int` counting requests whose path starts with `/invoices/query/metadata`.
- [ ] **Step 2: Write the failing tests** in `RunTests` (`START` = `2026-11-26T07:00:00Z`, Warsaw 08:00; `"yearSummary"` read from the snapshot with `jsonObject`):
  1. `testTheLedgerFollowsACompleteDownloadForBothSubjects`: `invoices: [fakeInvoice(1)]`, `salesInvoices: [fakeInvoice(7)]` → status complete; `ledger.jsonl` lines: one `Subject2` (fakeInvoice 1), one `Subject1` (fakeInvoice 7); `ledger-state.json` has `Subject2 == HWM`, `Subject1 == HWM` and a `completeAt`; snapshot `yearSummary == ["text": "2026 · wydatki 100,00 PLN · przychody 700,00 PLN", "warning": false]`; logs still exactly 1 line.
  2. `testTheLedgerCostsOneQueryPerSubjectWhenIdle`: first run → `metadataQueries == 9` (1 download window from `2026-11-01`, 4 + 4 ledger windows from `2026-01-01T00:00:00+01:00`); second run → 3 more (total 12).
  3. `testAPartialDownloadSkipsTheLedger`: the long download rate limit of `testALongRateLimitIsPartialAndResumable` → `metadataQueries == 1`; no `ledger.jsonl`; `yearSummary == ["text": "2026 · podsumowanie w przygotowaniu", "warning": true]`.
  4. `testALedgerRateLimitLeavesTheRunCompleteAndSaysSoInTheFooter`: run 1, `metadataAnswer` gives `429` with `Retry-After: 900` for `Subject1` → status complete, saved 1, notifications exactly `["KSeF: 1 nowa faktura"]`, report has no word `ledger`, logs contain `ledger Subject1 stopped: Limit zapytań KSeF — trzeba odczekać 900 s.`, state has `Subject2` but no `completeAt`, footer `2026 · podsumowanie w przygotowaniu` (warning). Run 2 without the limit → footer `2026 · wydatki 100,00 PLN · przychody 0,00 PLN` (no warning). Run 3 with the limit again → footer starts with `2026 (stan na 26.11 08:0` and has warning true; status complete; no new notification.
  5. `testNoSummaryFromAFolderOfAnotherIdentity`: identity of another NIP and a `ledger.jsonl` in the folder → status failed as today; the snapshot has no `yearSummary` key; `ledger.jsonl` unchanged.
  6. `testAFailedLoginStillWritesTheSummaryFromDisk`: `authStatus` 460 → snapshot `yearSummary == ["text": "2026 · podsumowanie w przygotowaniu", "warning": true]`.
  7. `testADryRunNeverTouchesTheLedger`: `dryRun: true` → `metadataQueries == 1`, no `ledger.jsonl`, no `ledger-state.json`.
  8. `testAnExistingFolderKeepsItsFilesAndGainsTheLedger`: a folder with matching `identity.json`, `state.json` `{"checkpoint":"2026-11-26T05:00:00.0000000+00:00"}` and `index.jsonl` = the frozen `FormatsFixture.load().indexLines` joined; `invoices: []` → `index.jsonl` and `identity.json` byte-identical, `state.json` = `{"checkpoint":HWM}` as today, and the folder's top-level entries are exactly `identity.json`, `index.jsonl`, `ledger-state.json`, `ledger.jsonl`, `state.json`.
  Run `CORE_TESTS` → failures (no ledger in `run()`).
- [ ] **Step 3: Implement.** `updateLedger`: `Ledger.open`, then `.buyer`, then `.seller` through `syncLedger` with year `Int(warsawDay(now()).prefix(4))`; the first `.partial(reason)` or thrown error logs `ledger <rawValue> stopped: <reason or errorMessage>` and returns false; after both complete, `writeCompleteAt(now())` (failure → log, false) and return true. In `run()`: a `folderChecked` flag set right after `checkDataFolder` succeeds; the query closure becomes `(Subject) -> Query`; after `syncInvoices`, only when the outcome is `.complete`, `ledgerCompleted = await updateLedger(…)`; after the `do/catch`, `buildSnapshot(…, yearSummary: folderChecked ? yearSummary(dataDir:ledgerCompleted:now: finishedAt) : nil)`. The dry run path and `reportSetupFailure` are unchanged.
- [ ] **Step 4: Verify.** All earlier `RunTests` pass unchanged. `GREEN`; `KsefCoreTests` 246.
- [ ] **Step 5: Commit** `feat(core): sync the year ledger after a complete download`.

---

### Task 7: The widget footer

Spec 7.5, 7.6. Size: medium.

**Files:**
- Modify: `widget/Shared/Snapshot.swift`, `widget/Shared/WidgetModel.swift`, `widget/Shared/InvoiceListView.swift`, `widget/Tests/Fixtures.swift`, `widget/Tests/SnapshotTests.swift`, `widget/Tests/WidgetModelTests.swift`, `widget/Tests/RenderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct Snapshot { …; struct YearSummary: Decodable, Equatable, Sendable { let text: String; let warning: Bool }
                    var yearSummary: YearSummary? }   // var: memberwise init defaults it to nil; Decodable still decodes it (a `let` with a default would not be decoded)
  struct WidgetModel { …; struct Footer: Equatable { let text: String; let warning: Bool }; let footer: Footer? }
  func rowLimit(isLarge: Bool) -> Int   // large 8; medium 3 - (banner ? 1 : 0) - (footer ? 1 : 0)
  enum Fixtures { static func snapshot(…, yearSummary: Snapshot.YearSummary? = nil) -> Snapshot }
  ```

- [ ] **Step 1: Write the failing tests.**
  - `SnapshotTests.testDecodesTheYearSummary`: `contractJSON` with `,\n  "yearSummary": {"text": "2026 · wydatki 43,60 PLN · przychody 0,00 PLN", "warning": false}` inserted after the `invoices` array → decoded `YearSummary(text: "2026 · wydatki 43,60 PLN · przychody 0,00 PLN", warning: false)`.
  - `SnapshotTests.testTheContractWithoutAYearSummaryHasNoFooter`: `contractJSON` as is → `yearSummary == nil` and `WidgetModel.make(.success(…), now: Fixtures.now).footer == nil`.
  - `WidgetModelTests.testFooterCopiesTheSummary`: summary `("2026 (stan na 26.11 11:00) · wydatki …", true)` → `footer == Footer(text: same, warning: true)`; also present on a failed and on a stale snapshot; `nil` for `.failure(.missing)`.
  - `WidgetModelTests.testRowLimitWithAFooter`: with a summary: medium 2; with a summary and `status: .partial` (banner) 1; large 8.
  - `WidgetModelTests.testHostileFooterStaysVerbatim`: footer text `"**x** [y](https://e.example)"` unchanged.
  - `RenderTests` (new, each with `Fixtures.snapshot(invoiceCount: 3 or 8 for large, yearSummary: …)`): `medium-summary`, `medium-summary-dark`, `large-summary`, `large-summary-dark` with `("2026 · wydatki 48\u{a0}210,55 PLN · przychody 182\u{a0}400,00 PLN", false)`; `medium-summary-stale` with `("2026 (stan na 26.11 11:00) · wydatki 48\u{a0}210,55 PLN · przychody 182\u{a0}400,00 PLN", true)`; `medium-summary-currency` with the worst case `("2026 (stan na 26.11 11:00) · wydatki 1\u{a0}234\u{a0}567,89 PLN + 12\u{a0}345,67 EUR · przychody 2\u{a0}345\u{a0}678,90 PLN + 1200,00 USD", true)`; `medium-summary-failed` (`status: .failed` with the long reason of `testRenderMediumFailed`, plain summary); `medium-summary-pending` with `("2026 · podsumowanie w przygotowaniu", true)`.
  Run `WIDGET_TESTS` → compile failure.
- [ ] **Step 2: Implement.** `make` maps `snapshot.yearSummary` to `footer` (nil for load failures). View: after `Spacer(minLength: 0)`, if a footer: `Divider()` and `Text(verbatim: footer.text)` with `.font(.caption)`, `.monospacedDigit()`, `.foregroundStyle(footer.warning ? Color.orange : Color.secondary)`, `.lineLimit(2)`, `.truncationMode(.tail)`. Nothing else in the view changes; the extension, its entitlements and the timeline are untouched.
- [ ] **Step 3: Verify and render.** `mkdir -p widget/build/renders` then `TEST_RUNNER_WIDGET_RENDER_DIR="$PWD/widget/build/renders"` + `WIDGET_TESTS` → `** TEST SUCCEEDED **`, `KsefWidgetTests` 44. Open every PNG (14 files). Check: medium with a summary shows 2 rows, with banner and summary 1 row; no row or footer overlaps or is clipped at the bottom edge; the worst-case line wraps to at most two lines and its start (`2026 (stan na 26.11 11:00) · wydatki`) is visible; the six earlier renders look as before (no footer). If the worst case or `medium-summary-failed` does not fit, report it with the PNG instead of shrinking fonts. `GREEN`.
- [ ] **Step 4: Commit** `feat(widget): year summary footer`. In the report to the orchestrator, list the PNG paths.

---

### Task 8: Both sides on KSeF TEST, and the sign/currency probe

Spec 5.2, 5.3, 8. Size: medium. Network; check the time window and the hourly limits (Global Constraints) before each run.

**Files:**
- Create: `widget/E2ETests/Fixtures/fa3-correction.xml`, `widget/E2ETests/Fixtures/fa3-invoice-eur.xml`, `widget/E2ETests/SummaryProbeE2ETests.swift`
- Modify: `widget/E2ETests/SendInvoice.swift`, `widget/E2ETests/FetchE2ETests.swift`

**Interfaces:**
- Produces (SendInvoice.swift): `func invoiceTemplate(_ name: String, replacing values: [String: String]) throws -> Data` — reads `E2ETests/Fixtures/<name>` via `#filePath`, replaces each `{{KEY}}`; `FetchE2ETests` uses it instead of its inline replacement.

- [ ] **Step 1: Extend `FetchE2ETests`.** Constants `maxAttempts = 3`, `hwmLagMs = 180_000` (query budget for the buyer's NIP: attempt 1 = 2 download + 4 + 4 ledger = 10, later attempts and the second run 3 each, worst case 19 ≤ 20; one comment line says so). After the attempt loop, for the buyer: `ledger.jsonl` has exactly one line, `subjectType` `Subject2`, `ksefNumber` the sent one, `netAmount` 43.6, `grossAmount` 53.63, `vatAmount` 10.03, `currency` `PLN`, `invoiceType` `Vat`; the snapshot's `yearSummary` is `["text": "<year> · wydatki 43,60 PLN · przychody 0,00 PLN", "warning": false]` (`<year>` = `warsawDay(Date()).prefix(4)`). Keep the second-run assertions. Then one `run()` for the seller (its own data folder and snapshot, `startDate` = today, seller credentials): status complete, saved 0, its `ledger.jsonl` has one `Subject1` line with the same number and amounts, its footer `"<year> · wydatki 0,00 PLN · przychody 43,60 PLN"` (seller budget: 1 + 4 + 4 = 9).
- [ ] **Step 2: Write the probe templates.** Both are `fa3-invoice.xml` with these differences (same placeholders plus `{{CORRECTED_NUMBER}}`, `{{CORRECTED_ISSUE_DATE}}`, `{{CORRECTED_KSEF_NUMBER}}` in the correction):
  - `fa3-correction.xml`: `<P_13_1>-43.60</P_13_1><P_14_1>-10.03</P_14_1>`, `<P_15>-53.63</P_15>`, `<RodzajFaktury>KOR</RodzajFaktury>` followed by `<DaneFaKorygowanej><DataWystFaKorygowanej>{{CORRECTED_ISSUE_DATE}}</DataWystFaKorygowanej><NrFaKorygowanej>{{CORRECTED_NUMBER}}</NrFaKorygowanej><NrKSeF>1</NrKSeF><NrKSeFFaKorygowanej>{{CORRECTED_KSEF_NUMBER}}</NrKSeFFaKorygowanej></DaneFaKorygowanej>`, rows `P_11` `-18.00` and `-25.60`.
  - `fa3-invoice-eur.xml`: `<KodWaluty>EUR</KodWaluty>`, `<P_13_1>100.00</P_13_1><P_14_1>23.00</P_14_1><P_14_1W>98.42</P_14_1W>`, `<P_15>123.00</P_15>`, one row `P_11` `100.00`, `P_12` `23`.
- [ ] **Step 3: Write `SummaryProbeE2ETests.testACorrectionIsNegativeAndAForeignInvoiceKeepsItsCurrency`.** Random seller and buyer NIPs; the seller sends `fa3-invoice.xml`, then `fa3-correction.xml` referencing it (its number, issue date, KSeF number), then `fa3-invoice-eur.xml`; wait 180 s; `run()` for the seller (`startDate` today), at most 2 attempts 60 s apart until its `ledger.jsonl` has 3 `Subject1` lines (budget 9 + 3). Print every ledger line. Assert: the correction line has `invoiceType` `Kor`, `netAmount` -43.6, `grossAmount` -53.63; the EUR line has `currency` `EUR`, `netAmount` 100, `grossAmount` 123; footer `"<year> · wydatki 0,00 PLN · przychody 0,00 PLN + 100,00 EUR"`. Print, do not assert, the EUR line's `vatAmount` (98.42 means PLN).
- [ ] **Step 4: Run on TEST**, each command once: `E2E_BUILD`, then `xcodebuild … -scheme KsefE2ETests test -only-testing:KsefE2ETests/FetchE2ETests` → `** TEST SUCCEEDED **`, then `… -only-testing:KsefE2ETests/SummaryProbeE2ETests` → `** TEST SUCCEEDED **`. If KSeF TEST rejects the correction or the EUR invoice, fix the template once from the rejection text and rerun once (not within the same hour as two earlier runs); if it still fails, do not commit the probe, and report KSeF's exact rejection. If the correction's amounts come back positive, do not change the summary code: stop and report the printed lines (the sign rule is the orchestrator's call).
- [ ] **Step 5: Commit** `test(e2e): year ledger on both sides of a TEST invoice; sign and currency probe`. Report the printed ledger lines and the EUR `vatAmount` to the orchestrator; they settle spec 5.2/5.3.

---

### Task 9: Docs and the single app build

Spec 7.5–7.7, 10. Size: small.

**Files:**
- Modify: `README.md`, `AGENTS.md`

- [ ] **Step 1: README.** "What it does": one paragraph on the summary line (net, by issue date, current Warsaw year, PLN plus other currencies, corrections with their sign, only what is in KSeF; sales invoices are read as metadata only, never downloaded, notified or reported). "Desktop widget": the footer and its four states with the exact Polish copy of spec 7.5, and that the medium widget then shows two rows. "Where things live": `ledger.jsonl` and `ledger-state.json` (one sentence each). "Running": an idle run uses 3 of KSeF's 20 metadata queries per hour, the first run after the update up to 11, each **Pobierz teraz** 3; a limit stops only the summary update, which continues next hour. "Troubleshooting": `podsumowanie niedostępne: Uszkodzony plik ledger.jsonl, linia N` → delete that line, or delete both ledger files to rebuild from 1 January (up to 11 queries). Replace the first-run checklist with spec section 10 (items 1–6) under a heading "After updating to the year summary". Add the new spec to the design links.
- [ ] **Step 2: AGENTS.md.** First paragraph: one sentence on the year ledger and summary; add the new spec to the design list. "State": the two ledger files under the invoice folder.
- [ ] **Step 3: Pre-build checks.** `git status --short` → only `README.md`, `AGENTS.md`. `git grep -n <your login name>` → nothing; `git grep -nE "DEVELOPMENT_TEAM|Developer ID Application:"` → nothing. Import check → the four modules. `GREEN`.
- [ ] **Step 4: Build the app, once.** `scripts/build-app.sh` (no arguments) → prints `hardened runtime present and no get-task-allow in the app and the extension`, a designated requirement containing `cdhash`, and `built … (not installed)`. Then `pluginkit -m -v -p com.apple.widgetkit-extension | grep -c "/widget/build/"` → `0`. Do not open, launch or copy the built app.
- [ ] **Step 5: Commit** `docs: year summary, ledger files and owner checks`.

---

## Done when

- `KsefCoreTests` 246, `KsefWidgetTests` 44, `KsefAppTests` 7 pass offline; `FetchE2ETests` and the probe passed once on TEST (or the probe's rejection is reported).
- `git ls-files` shows no TypeScript, Node or launchd file; `widget/CoreTests/Fixtures/*.json` unchanged (`git diff --stat <first commit of this plan>^ -- widget/CoreTests/Fixtures` lists only `README.md`).
- The 14 widget PNGs were looked at and their paths reported.
- The app was built exactly once (Task 9), not installed, not launched; the filtered `pluginkit` check prints `0`; nothing personal is tracked; `git status` is clean.

## Verifiable headlessly vs left for the owner

| Task | Implementer verifies | Owner verifies after `scripts/build-app.sh --install` (spec 10) |
|---|---|---|
| 1–2 | builds, tests, no leftovers in the repository | deletes the leftovers on their Mac (README) |
| 3–6 | ledger, summary, snapshot and run behaviour, offline | the first run creates the ledger files; existing files untouched (item 2) |
| 7 | model rules, PNG renders | the footer in the real widget, light and dark, medium and large (item 1) |
| 8 | both sides and the sign/currency behaviour on TEST | totals match their records, including corrections, advances and foreign invoices (item 3) |
| 9 | docs, one ad-hoc build, no registration left | behind/limit display (item 4), new-year switch (item 5) |
