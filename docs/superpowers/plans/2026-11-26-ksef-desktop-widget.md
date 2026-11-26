# KSeF Desktop Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS desktop widget (medium and large) that lists the newest saved KSeF purchase invoices from a snapshot file the fetcher writes after every run, with the fetcher switched from daily to hourly.

**Architecture:** The TypeScript fetcher gains `src/snapshot.ts` and writes `~/Library/Application Support/ksef-daily-fetch/widget.json` after every run. A small Swift app in `widget/` (XcodeGen project, ad-hoc signed) embeds a WidgetKit extension that runs in the App Sandbox with a read-only temporary exception for that one directory, renders the snapshot, and links each row to its KSeF view URL; the host app forwards those clicks to the browser. The LaunchAgent fires every hour at minute 0.

**Tech Stack:** Node v22.23.4 (native TS), pnpm 10.17.0, `node:test`; Swift 6.4 (language mode 6.0), SwiftUI, WidgetKit, AppKit, XCTest; Xcode 27.1 (`xcodebuild`), XcodeGen 2.46.0 (`/opt/homebrew/bin/xcodegen`); macOS 27 on Apple Silicon.

**Spec:** `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md` (read it first; section numbers below refer to it). ADRs: `ADR.md` (ADR-0005, 0006, 0007). Fetcher spec for context: `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md`.

## Global Constraints

- Work only in this worktree. Never push, never add a remote. Run each `git` command on its own. The harness may refuse compound shell commands (`&&`, `;`, pipes mixing tools); if it does, split the command into separate calls with the same effect.
- Coding guidelines: think first and state assumptions; minimum code; no unrequested features, no single-use abstractions, no speculative flexibility, no handling for impossible cases; surgical changes to existing files (match their style, do not refactor adjacent code); every task ends with a verifiable check.
- TypeScript: run with `node <file>.ts`, erasable syntax only, relative imports end in `.ts`, type-only imports use `import type`. No new npm packages.
- Swift: no third-party packages, no Swift Package Manager dependencies. `SWIFT_VERSION` 6.0, deployment target macOS 14.0. All `xcodebuild` calls use `-destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build`.
- Signing: ad hoc only (`CODE_SIGN_IDENTITY = "-"`, committed in `widget/project.yml`). Never use a Developer ID or Apple Development identity, never pass `DEVELOPMENT_TEAM`, never run `security`, never touch the Keychain. `codesign -s -` (ad hoc) is allowed.
- The repository is public: no real name, e-mail, NIP, Team ID, signing identity, hash, or absolute path containing a home-directory name in tracked files. Write home paths as `~/…` or `$HOME/…`.
- Polish for user-facing strings (widget text, app alert, notification), exactly as pinned here; English for code, comments, docs, log lines.
- Never run `scripts/launchagent.sh install` or `uninstall`, never `launchctl bootstrap`/`bootout`. Never copy the app into `/Applications` or `~/Applications`. Never trigger a real notification: do not run `node src/main.ts` except with `--bogus`. Never open a KSeF URL in a browser. Never run `pnpm test:e2e` or `pnpm test:e2e:auth` (no network needed for this feature).
- The only files written outside the worktree: the Task 1 spike file under `~/Library/Application Support/ksef-daily-fetch/` (created and removed in the same task), the sandbox containers macOS creates for the probe, app and extension, and LaunchServices registrations that Task 6 removes.
- Snapshot path contract, identical in three places: `src/main.ts` (`join(homedir(), 'Library', 'Application Support', 'ksef-daily-fetch', 'widget.json')`), `widget/Extension/Extension.entitlements` (`/Library/Application Support/ksef-daily-fetch/`), `widget/Shared/Snapshot.swift` (`Library/Application Support/ksef-daily-fetch/widget.json` under the real home from `getpwuid(getuid())`).
- Every commit message ends with the attribution lines your harness provides.

## Review Focus

1. **Seller text is attacker-controlled** (anyone can invoice this NIP): a seller name with newlines, Markdown (`**x**`, `[a](https://e)`), or 200 characters must appear verbatim on one truncated line in the widget, never interpreted. `Text(verbatim:)` + `lineLimit(1)`; test in Task 5 (model keeps it verbatim) and the large render in Task 6 includes such a seller.
2. **A crafted or malformed view URL** (`javascript:`, `file:`, `http:`, `https://qr.ksef.mf.gov.pl.evil.com/…`, userinfo tricks) must neither become a row link nor be opened by the host app. Tests in Task 5 (`KsefLink`), command-line check in Task 6.
3. **No snapshot, a half-garbled one, or one with an unknown status** (fetcher never ran, file edited by hand): the widget shows the pinned banner, never an empty or crashed widget. Tests in Task 5.
4. **The Mac slept all night or the LaunchAgent is not installed**: the widget must turn to "Dane nieaktualne" after three hours and drop yesterday's "dziś" count after Warsaw midnight even when macOS does not reload it. Tests in Task 5 (`timelineDates`, stale threshold, today check).
5. **A run that fails before or during sync** (wrong key password, corrupt `index.jsonl`, config missing): a snapshot with `status: "failed"` and the Polish reason is still written; a dry run writes nothing. Tests in Task 3.

---

## File structure

```
.gitignore                         # + widget/*.xcodeproj/, widget/build/
AGENTS.md, README.md               # Task 7
scripts/launchagent.sh             # hourly schedule (Task 4)
src/
  store.ts                         # + IndexEntry, readIndex, export writeAtomic (Task 2)
  report.ts                        # export sellerLabel; Pick<> parameter types (Task 2)
  snapshot.ts                      # NEW: widgetInvoice, buildSnapshot, writeSnapshot (Task 2)
  run.ts                           # writes the snapshot after every non-dry run (Task 3)
  main.ts                          # snapshot path; failed snapshot before run() (Task 3)
test/unit/
  snapshot.test.ts                 # NEW (Task 2)
  store.test.ts, run.test.ts       # extended (Tasks 2, 3)
test/e2e/fetch.e2e.ts              # passes snapshotPath (Task 3; not run)
widget/
  project.yml                      # XcodeGen spec (Tasks 1, 5, 6)
  Extension/Extension.entitlements # sandbox + read-only exception (Task 1)
  Extension/Info.plist             # NSExtension only (Task 6)
  Extension/KsefWidget.swift       # @main bundle, Widget, TimelineProvider (Task 6)
  Shared/Snapshot.swift            # path, Decodable model, load (Tasks 1, 5)
  Shared/WidgetModel.swift         # pure view model + Polish copy (Task 5)
  Shared/KsefLink.swift            # URL allow-list (Task 5)
  Shared/InvoiceListView.swift     # SwiftUI content view (Task 6)
  App/main.swift                   # host app delegate (Task 6)
  App/App.entitlements             # sandbox only (Task 6)
  Probe/main.swift                 # SnapshotProbe CLI (Tasks 1, 5)
  Tests/Fixtures.swift             # shared fixtures (Task 5)
  Tests/SnapshotTests.swift, Tests/WidgetModelTests.swift, Tests/KsefLinkTests.swift (Task 5)
  Tests/RenderTests.swift          # PNG renders (Task 6)
```

Snapshot contract (spec 7.2), shared by both halves:

```ts
// src/snapshot.ts
export interface WidgetInvoice {
  ksefNumber: string; seller: string; invoiceNumber: string; amount: string;
  issueDate: string; savedAt: string; viewUrl: string;
}
export interface WidgetSnapshot {
  updatedAt: string; status: 'complete' | 'partial' | 'failed'; reason?: string;
  today: string; savedToday: number; invoices: WidgetInvoice[];
}
```

---

### Task 1: Sandbox-read spike

Prove, before any UI exists, that a sandboxed, ad-hoc-signed process with the widget extension's exact entitlements file can read a file at the real snapshot path, and that the same binary without the exception cannot (spec 5, 6.2, 7.7).

**Files:**
- Create: `widget/project.yml`, `widget/Extension/Extension.entitlements`, `widget/Shared/Snapshot.swift`, `widget/Probe/main.swift`
- Modify: `.gitignore` (append `widget/*.xcodeproj/` and `widget/build/`)

**Interfaces:**
- Produces: `enum SnapshotFile { static let relativePath: String; static var url: URL }` in `widget/Shared/Snapshot.swift` (Task 5 adds decoding to this file); the `SnapshotProbe` scheme; the entitlements file the extension will use.

- [ ] **Step 1: Write the entitlements file** `widget/Extension/Extension.entitlements` — a plist dict with exactly two keys: `com.apple.security.app-sandbox` = `true`; `com.apple.security.temporary-exception.files.home-relative-path.read-only` = array with one string `/Library/Application Support/ksef-daily-fetch/`. Nothing else (no network).

- [ ] **Step 2: Write `widget/project.yml`**

```yaml
name: KsefWidget
options:
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
    GENERATE_INFOPLIST_FILE: YES
targets:
  SnapshotProbe:
    type: tool
    platform: macOS
    sources: [Probe, Shared/Snapshot.swift]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.ksef-daily-fetch.SnapshotProbe
        CREATE_INFOPLIST_SECTION_IN_BINARY: YES   # a sandboxed CLI without an embedded CFBundleIdentifier dies with SIGTRAP
        CODE_SIGN_ENTITLEMENTS: Extension/Extension.entitlements
```

- [ ] **Step 3: Write `SnapshotFile` and the probe**

`SnapshotFile.relativePath = "Library/Application Support/ksef-daily-fetch/widget.json"`; `SnapshotFile.url` = the real home from `String(cString: getpwuid(getuid())!.pointee.pw_dir)` + `relativePath`. Comment why: inside the sandbox `NSHomeDirectory()` and `homeDirectoryForCurrentUser` return the container.

`widget/Probe/main.swift` (spike version): `Data(contentsOf: SnapshotFile.url)`; success → print `OK <count> bytes`, exit 0; error → print `FAILED <error>` (include the underlying POSIX error), exit 1.

- [ ] **Step 4: Generate and build**

Run: `xcodegen generate --spec widget/project.yml --project widget`
Run: `xcodebuild -project widget/KsefWidget.xcodeproj -scheme SnapshotProbe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build -quiet build`
Expected: no errors; `widget/build/Build/Products/Release/SnapshotProbe` exists.
Run: `codesign -d --entitlements - --xml widget/build/Build/Products/Release/SnapshotProbe | plutil -p -`
Expected: `com.apple.security.app-sandbox => true` and the exception array with `/Library/Application Support/ksef-daily-fetch/` (Xcode may add `com.apple.security.get-task-allow`; nothing else).

- [ ] **Step 5: Prove the read through the sandbox**

Run: `test -e "$HOME/Library/Application Support/ksef-daily-fetch"; echo "exists=$?"`. If it prints `exists=0`, the directory belongs to the owner: do NOT create, change or delete anything in it; skip to Step 6 and report the positive check as not run.
Otherwise:
Run: `mkdir -p "$HOME/Library/Application Support/ksef-daily-fetch" && printf '{"spike":true}\n' > "$HOME/Library/Application Support/ksef-daily-fetch/widget.json"`
Run: `widget/build/Build/Products/Release/SnapshotProbe; echo "exit=$?"`
Expected: `OK 15 bytes`, `exit=0`.

- [ ] **Step 6: Prove the sandbox denies without the exception**

Write `widget/build/sandbox-only.entitlements` (plist dict: `com.apple.security.app-sandbox` = `true` only).
Run: `cp widget/build/Build/Products/Release/SnapshotProbe widget/build/SnapshotProbe-denied && codesign -f -s - --entitlements widget/build/sandbox-only.entitlements widget/build/SnapshotProbe-denied`
Run: `widget/build/SnapshotProbe-denied; echo "exit=$?"`
Expected (when Step 5 created the file): `FAILED …` mentioning `Operation not permitted` (Cocoa code 257), `exit=1`. A `No such file` error does not count: the sandbox reports a missing file the same way with or without the exception.

- [ ] **Step 7: Clean up** (only if Step 5 created the directory)

Run: `rm -rf "$HOME/Library/Application Support/ksef-daily-fetch"` → then `test -e "$HOME/Library/Application Support/ksef-daily-fetch"; echo "exists=$?"` prints `exists=1`.
If Step 5 or 6 did not give the expected result, stop and report; do not build further tasks on a failed spike. Record both outputs in the commit message.

- [ ] **Step 8: Commit**

```bash
git add .gitignore widget/project.yml widget/Extension/Extension.entitlements widget/Shared/Snapshot.swift widget/Probe/main.swift
git commit -m "feat(widget): spike proving sandboxed read of the snapshot path"
```
Check `git status --short` shows nothing under `widget/build` or `widget/KsefWidget.xcodeproj`.

---

### Task 2: Snapshot builder in the fetcher

**Files:**
- Create: `src/snapshot.ts`, `test/unit/snapshot.test.ts`
- Modify: `src/store.ts`, `src/report.ts`, `test/unit/store.test.ts`

**Interfaces:**
- Consumes: `formatAmount`, `invoiceViewUrl`, `warsawDay`, `RunSummary` (`src/report.ts`); `Environment`.
- Produces:
  ```ts
  // src/store.ts
  export interface IndexEntry {
    ksefNumber: string; invoiceNumber: string; issueDate: string; sellerNip: string; sellerName: string | null;
    grossAmount: number; currency: string; permanentStorageDate: string; invoiceHash: string; file: string; savedAt: string;
  }
  export function readIndex(dataDir: string): Promise<IndexEntry[]>;           // file order; missing file → []
  export function writeAtomic(target: string, data: string | Buffer): Promise<void>; // existing, now exported
  // src/report.ts (types widened, behaviour unchanged)
  export function sellerLabel(invoice: Pick<InvoiceMetadata, 'seller'>): string;
  export function invoiceViewUrl(environment: Environment, invoice: Pick<InvoiceMetadata, 'seller' | 'issueDate' | 'invoiceHash'>): string;
  // src/snapshot.ts
  export const SNAPSHOT_INVOICES = 8;
  export function widgetInvoice(entry: IndexEntry, environment: Environment): WidgetInvoice;
  export function buildSnapshot(summary: Pick<RunSummary, 'status' | 'reason'>, invoices: WidgetInvoice[], now: Date): WidgetSnapshot;
  export function writeSnapshot(path: string, snapshot: WidgetSnapshot): Promise<void>;
  ```
  `buildSnapshot` takes all invoices in index order (oldest first): `updatedAt = now.toISOString()`; `today = warsawDay(now)`; `savedToday` = count over **all** given invoices with `warsawDay(new Date(savedAt)) === today`; `invoices` = the last `SNAPSHOT_INVOICES`, reversed; `reason` key present only when `summary.reason !== undefined`. `writeSnapshot` = `writeAtomic(path, JSON.stringify(snapshot, null, 2) + '\n')`.

- [ ] **Step 1: Write failing tests**

`test/unit/store.test.ts` additions:
- `readIndex returns entries in file order`: save two invoices via `openStore(...).saveInvoice`, then `readIndex(dataDir)` → two entries, `[0].ksefNumber` is the first saved, `[0].savedAt === NOW.toISOString()`.
- `readIndex of a missing index is empty`: → `[]`, data dir still absent.
- `readIndex fails loudly on a corrupt line`: valid line then `{"ksefNumber":` → rejects `Uszkodzony plik index.jsonl, linia 2`.
(The existing store tests stay unchanged and must still pass.)

`test/unit/snapshot.test.ts` with a helper `entry(n: number, savedAt: string, sellerName: string | null = \`Sprzedawca ${n}\`): IndexEntry` (`ksefNumber: \`K${n}\``, `invoiceNumber: \`FV/${n}\``, `issueDate: '2026-11-20'`, `sellerNip: '1111111111'`, `grossAmount: 1230`, `currency: 'PLN'`, `invoiceHash: 'UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE='`, other fields any string):
- `widgetInvoice maps an index entry for display`: `widgetInvoice(entry(1, '2026-11-26T13:00:39.000Z'), 'prod')` deep-equals `{ ksefNumber: 'K1', seller: 'Sprzedawca 1', invoiceNumber: 'FV/1', amount: '1230,00 PLN', issueDate: '2026-11-20', savedAt: '2026-11-26T13:00:39.000Z', viewUrl: 'https://qr.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE' }`.
- `widgetInvoice falls back to the NIP`: `sellerName: null` → `seller === 'NIP 1111111111'`.
- `keeps the newest 8, newest first`: entries K1…K10 → `invoices.map((i) => i.ksefNumber)` equals `['K10','K9','K8','K7','K6','K5','K4','K3']`.
- `counts today's saves over the whole index`: 10 entries saved `2026-11-26T12:00:00.000Z`, `now = 2026-11-26T13:00:00.000Z` → `savedToday === 10`, `invoices.length === 8`.
- `uses the Warsaw day`: `now = 2026-11-26T23:30:00.000Z`; entries saved `2026-11-26T22:50:00.000Z` and `2026-11-26T23:10:00.000Z` → `today === '2026-11-27'`, `savedToday === 1`.
- `carries status and reason`: `{ status: 'failed', reason: 'Brak połączenia z KSeF: fetch failed' }` → `status`, `reason` copied, `updatedAt === now.toISOString()`; `{ status: 'complete' }` → `'reason' in snapshot === false`.
- `writeSnapshot writes pretty JSON atomically`: path `<tmp>/a/b/widget.json` → file text equals `JSON.stringify(snapshot, null, 2) + '\n'`; `readdir(<tmp>/a/b)` equals `['widget.json']`.

Run: `pnpm test` → FAIL (missing exports / module).

- [ ] **Step 2: Implement**

`store.ts`: add `IndexEntry` and `readIndex` (same parsing and error message as today); `openStore` builds its dedup set from `readIndex`; type the `line` object in `saveInvoice` as `IndexEntry`; add `export` to `writeAtomic`. `report.ts`: export `sellerLabel`, widen both parameter types as above, no other change. `src/snapshot.ts`: as in Interfaces; `widgetInvoice` uses `sellerLabel({ seller: { nip: entry.sellerNip, name: entry.sellerName } })`, `formatAmount(entry.grossAmount, entry.currency)` and `invoiceViewUrl(environment, { seller: { nip: entry.sellerNip }, issueDate: entry.issueDate, invoiceHash: entry.invoiceHash })`.

- [ ] **Step 3: Verify** `pnpm test && pnpm typecheck` → all pass (non-zero test count), no type errors.

- [ ] **Step 4: Commit** `git add src/store.ts src/report.ts src/snapshot.ts test/unit/store.test.ts test/unit/snapshot.test.ts` then `git commit -m "feat: build the widget snapshot from the invoice index"`.

---

### Task 3: Write the snapshot after every run

**Files:**
- Modify: `src/run.ts`, `src/main.ts`, `test/unit/run.test.ts`, `test/e2e/fetch.e2e.ts`

**Interfaces:**
- Consumes: `readIndex` (Task 2), `widgetInvoice`, `buildSnapshot`, `writeSnapshot`, `type WidgetInvoice` (Task 2).
- Produces: `RunOptions.snapshotPath: string` (required). Dry runs never write it.

`run.ts`: after the existing report/notification block and before the final `log(...)`, for every non-dry run:
```ts
let invoices: WidgetInvoice[] = [];
try {
  invoices = (await readIndex(config.dataDir)).map((entry) => widgetInvoice(entry, config.environment));
} catch (err) {
  log(`could not read the index for the widget: ${errorMessage(err)}`);
}
try {
  await writeSnapshot(options.snapshotPath, buildSnapshot(summary, invoices, now()));
} catch (err) {
  log(`could not write the widget snapshot: ${errorMessage(err)}`);
}
```
`main.ts`: `const SNAPSHOT_PATH = join(homedir(), 'Library', 'Application Support', 'ksef-daily-fetch', 'widget.json');` passed as `snapshotPath` to `run`. In the existing pre-config `catch`, inside `if (!dryRun)` after the notification attempt: `writeSnapshot(SNAPSHOT_PATH, buildSnapshot({ status: 'failed', reason: message }, [], new Date()))` in its own try/catch that prints `could not write the widget snapshot: <message>` to stderr. `fetch.e2e.ts`: add `snapshotPath: join(dir, 'widget.json'),` to the `run({...})` call (do not run the E2E).

- [ ] **Step 1: Write failing tests** in `test/unit/run.test.ts`. In `setup`, take `const n = counter++` once and use it for both `dataDir` (`data-${n}`, as today) and `snapshotPath = join(root, \`widget-${n}.json\`)`; put `snapshotPath` in `options` and return it. Read it with `JSON.parse(await readFile(snapshotPath, 'utf8'))`.
- `writes the widget snapshot after saving invoices`: `[fakeInvoice(1), fakeInvoice(2)]` → `status === 'complete'`; `'reason' in snapshot === false`; `today === warsawDay(START)`; `savedToday === 2`; `invoices.map((i) => i.invoiceNumber)` equals `['FV/2', 'FV/1']`; `invoices[0].seller === 'Sprzedawca 2'`; `invoices[0].amount === '200,50 PLN'`; `invoices[0].viewUrl.startsWith('https://qr-test.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/')`.
- `a quiet run still writes the snapshot`: run, `rm(snapshotPath)`, run again → file exists, `status === 'complete'`, `invoices.length === 2`.
- `a failed run records the failure in the snapshot`: `authStatus` 460 → `status === 'failed'`, `reason` starts with `Uwierzytelnienie w KSeF nieudane (kod 460`, `invoices` `[]`, `savedToday === 0`.
- `a corrupt index still gives a failed snapshot`: before the run `mkdir(dataDir, { recursive: true })` and write `index.jsonl` = `{"ksefNumber":` → summary `failed` with reason `Uszkodzony plik index.jsonl, linia 1`; snapshot `status === 'failed'`, same reason, `invoices` `[]`; some log line contains `could not read the index for the widget`.
- In both existing dry-run tests add `assert.equal(await exists(snapshotPath), false)`.
- The existing `saves new invoices, reports and notifies once` keeps `logs.length === 1` (a successful snapshot write logs nothing).

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement** as above. Run `pnpm test && pnpm typecheck` → PASS.

- [ ] **Step 3: Smoke-test without side effects**

Run: `node src/main.ts --bogus; echo "exit=$?"` → usage line, `exit=1`.
Run: `test -e "$HOME/Library/Application Support/ksef-daily-fetch/widget.json"; echo "exists=$?"` → `exists=1` (nothing written by the usage path; if the owner's file exists, just report it and do not touch it).

- [ ] **Step 4: Commit** `git add src/run.ts src/main.ts test/unit/run.test.ts test/e2e/fetch.e2e.ts` then `git commit -m "feat: write the widget snapshot after every run"`.

---

### Task 4: Hourly LaunchAgent

**Files:**
- Modify: `scripts/launchagent.sh`

**Interfaces:**
- Consumes: nothing new. Label, script names and log path stay (spec 7.3).

- [ ] **Step 1: Change the schedule.** In `print_plist`, `StartCalendarInterval` becomes a dict with only `<key>Minute</key><integer>0</integer>` (drop `Hour`). Header comment: "the hourly LaunchAgent". Install message: `Installed $LABEL: runs every hour at minute 0, and once at wake after sleep.` Nothing else changes.

- [ ] **Step 2: Verify without loading anything**

Run: `zsh -n scripts/launchagent.sh` → no output.
Run: `scripts/launchagent.sh print > "$TMPDIR/ksef.plist" && plutil -lint "$TMPDIR/ksef.plist" && plutil -p "$TMPDIR/ksef.plist"` → `OK`; `"StartCalendarInterval" => { "Minute" => 0 }`, no `Hour`; label still `local.ksef-daily-fetch`.
Do NOT run `install` or `uninstall`.

- [ ] **Step 3: Commit** `git add scripts/launchagent.sh` then `git commit -m "feat: run the fetch every hour"`.

---

### Task 5: Snapshot decoding, view model and link allow-list (Swift, test-first)

**Files:**
- Modify: `widget/project.yml` (add the test target), `widget/Shared/Snapshot.swift`, `widget/Probe/main.swift`
- Create: `widget/Shared/WidgetModel.swift`, `widget/Shared/KsefLink.swift`, `widget/Tests/Fixtures.swift`, `widget/Tests/SnapshotTests.swift`, `widget/Tests/WidgetModelTests.swift`, `widget/Tests/KsefLinkTests.swift`

**Interfaces:**
- Consumes: `SnapshotFile.url` (Task 1); the JSON contract (spec 7.2).
- Produces:
  ```swift
  // Shared/Snapshot.swift (added)
  struct Snapshot: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable { case complete, partial, failed }
    struct Invoice: Decodable, Equatable, Sendable { let ksefNumber: String; let seller: String; let amount: String; let issueDate: String; let viewUrl: String }
    let updatedAt: Date; let status: Status; let reason: String?; let today: String; let savedToday: Int; let invoices: [Invoice]
  }
  enum SnapshotLoadError: Error, Equatable, Sendable { case missing; case unreadable(String) }
  extension SnapshotFile {
    static func decode(_ data: Data) throws -> Snapshot
    static func load(from url: URL = SnapshotFile.url) -> Result<Snapshot, SnapshotLoadError>
  }
  // Shared/KsefLink.swift
  enum KsefLink { static let hosts: Set<String>; static func isAllowed(_ url: URL) -> Bool }
  // Shared/WidgetModel.swift
  struct WidgetModel: Equatable {
    enum Tone: Equatable { case warning, error }
    struct Banner: Equatable { let text: String; let tone: Tone }
    struct Row: Equatable, Identifiable { let id: String; let seller: String; let amount: String; let date: String; let url: URL? }
    let title: String; let newToday: String?; let banner: Banner?; let rows: [Row]; let emptyText: String?
    func rowLimit(isLarge: Bool) -> Int
    static let staleAfter: TimeInterval   // 3 h
    static func make(_ result: Result<Snapshot, SnapshotLoadError>, now: Date) -> WidgetModel
    static func timelineDates(_ result: Result<Snapshot, SnapshotLoadError>, now: Date) -> [Date]
  }
  func newTodayLabel(_ count: Int) -> String
  ```

Rules (spec 7.4, 7.5), all times in Europe/Warsaw (`Calendar(identifier: .gregorian)` with `TimeZone(identifier: "Europe/Warsaw")`):
- `decode`: `JSONDecoder` with a `.custom` date strategy using `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` (accepts `…41.123Z` and `…41Z`); a bad date throws `DecodingError.dataCorrupted`. `load`: a `CocoaError(.fileReadNoSuchFile)` → `.missing`; any other read or decode error → `.unreadable(error.localizedDescription)`.
- `KsefLink.hosts = ["qr.ksef.mf.gov.pl", "qr-test.ksef.mf.gov.pl", "qr-demo.ksef.mf.gov.pl"]`; `isAllowed` = scheme `https` and `url.host` (exact) in `hosts` and no user/password.
- `title`: `KSeF · zaktualizowano HH:mm` from `updatedAt`; `KSeF` on `.failure`.
- `newToday`: `newTodayLabel(savedToday)` when `savedToday > 0` and `snapshot.today` equals the Warsaw date of `now` (`yyyy-MM-dd`); else `nil`. `newTodayLabel`: 1 → `1 nowa dziś`; `n % 10` in 2…4 and `n % 100` not in 12…14 → `N nowe dziś`; otherwise `N nowych dziś`.
- `banner` (first match): `.missing` → `Brak danych — pobieranie jeszcze nie zapisało stanu widżetu.` (error); `.unreadable(m)` → `Nie można odczytać danych widżetu: m` (error); `now − updatedAt >= staleAfter` → `Dane nieaktualne — ostatnia aktualizacja DD.MM HH:mm` (error); `failed` → `Błąd pobierania: <reason ?? "">` (error); `partial` → `Pobrano częściowo — reszta przy następnym uruchomieniu.` (warning); else `nil`.
- `rows`: every snapshot invoice in order; `id = ksefNumber`; `date` = `DD.MM` from `issueDate` (`2026-11-26` → `26.11`, string split, no locale); `url` = `URL(string: viewUrl)` only if `KsefLink.isAllowed`. `rows` is `[]` on `.failure`.
- `emptyText`: `Brak zapisanych faktur.` when the snapshot was read, has no invoices and `status != .failed`; else `nil` (after a failure an empty list means "unknown").
- `rowLimit(isLarge:)`: large → 8; medium → 3, or 2 when `banner != nil`.
- `timelineDates`: `[now]` + `updatedAt + staleAfter` (only on `.success` and if later than `now`) + the next Warsaw midnight after `now`; ascending.
- Swift 6 mode rejects shared mutable `static let` `DateFormatter`s; format with `Calendar.dateComponents` and `String(format: "%02d", …)` (or create formatters inside the function).

- [ ] **Step 1: Add the test target to `widget/project.yml`**

```yaml
  KsefWidgetTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests, Shared]
```
(no host app). Regenerate: `xcodegen generate --spec widget/project.yml --project widget`.

- [ ] **Step 2: Write `Tests/Fixtures.swift` and the failing tests**

`Fixtures`: `updatedAt = Date(timeIntervalSince1970: 1795698041.123)` (2026-11-26T13:00:41.123Z, 14:00 Warsaw); `now = Date(timeIntervalSince1970: 1795699200)` (13:20Z); `contractJSON` = the spec 7.2 example verbatim (one invoice, Acme, `1230,00 PLN`); `snapshot(status: Snapshot.Status = .complete, reason: String? = nil, invoiceCount: Int = 3, today: String = "2026-11-26", savedToday: Int = 2, updatedAt: Date = updatedAt) -> Snapshot` whose invoices, in order, are: `Acme Sp. z o.o.` / `1230,00 PLN` / `2026-11-26`; `Orange Polska` / `89,99 PLN` / `2026-11-25`; `Hetzner Online` / `153,75 EUR` / `2026-11-24`; `**Evil** [x](https://e.example)\nline2` / `12 345,67 PLN` / `2026-11-23`; `Bardzo Długa Nazwa Sprzedawcy Spółka z ograniczoną odpowiedzialnością Oddział w Polsce` / `1,00 PLN` / `2026-11-22`; `NIP 1111111111` / `99,00 USD` / `2026-11-21`; then `Sprzedawca 7` and `Sprzedawca 8` (`10,00 PLN`, `2026-11-20`, `2026-11-19`); ids `K1…K8`; each `viewUrl` `https://qr.ksef.mf.gov.pl/invoice/1111111111/<DD-MM-YYYY>/hash<n>`.

`SnapshotTests`:
- `testDecodesTheContract`: `decode(contractJSON)` → `updatedAt == Fixtures.updatedAt` (accuracy 0.001), `status == .complete`, `reason == nil`, `today == "2026-11-26"`, `savedToday == 2`, `invoices[0].amount == "1230,00 PLN"`, `invoices[0].seller == "Acme Sp. z o.o."`.
- `testDecodesWithoutMilliseconds`: `updatedAt` `2026-11-26T13:00:41Z` decodes.
- `testUnknownStatusIsAnError`, `testMissingFieldIsAnError` (no `savedToday`) → `XCTAssertThrowsError`.
- `testLoadMissingFile` → `.failure(.missing)` for a path in a fresh temp directory.
- `testLoadGarbage` → `.failure(.unreadable(_))` for a file containing `{"updatedAt":`.
- `testURLIsUnderTheRealHome`: `SnapshotFile.url.path` has suffix `/Library/Application Support/ksef-daily-fetch/widget.json` and does not contain `/Library/Containers/`.

`KsefLinkTests`: allowed: `https://qr.ksef.mf.gov.pl/invoice/x`, `https://qr-test.ksef.mf.gov.pl/x`, `https://qr-demo.ksef.mf.gov.pl/x`. Rejected: `http://qr.ksef.mf.gov.pl/x`, `https://qr.ksef.mf.gov.pl.evil.example/x`, `https://evil.example/qr.ksef.mf.gov.pl`, `https://user@qr.ksef.mf.gov.pl/x`, `javascript:alert(1)`, `file:///etc/passwd`.

`WidgetModelTests` (`now = Fixtures.now` unless stated):
- `testNormalSnapshot`: `title == "KSeF · zaktualizowano 14:00"`, `newToday == "2 nowe dziś"`, `banner == nil`, `rows.count == 3`, `rows[0] == Row(id: "K1", seller: "Acme Sp. z o.o.", amount: "1230,00 PLN", date: "26.11", url: URL(string: "https://qr.ksef.mf.gov.pl/invoice/1111111111/26-11-2026/hash1"))`, `emptyText == nil`.
- `testPluralTable`: `newTodayLabel(1) == "1 nowa dziś"`; 2, 3, 4, 22, 104 → `"<n> nowe dziś"`; 5, 11, 12, 13, 14, 21, 112 → `"<n> nowych dziś"`.
- `testNoCountWhenZeroOrNotToday`: `savedToday: 0` → `newToday == nil`; `today: "2026-11-25"` → `nil`; `now` = 2026-11-26T23:00:00Z (`1795734000`, Warsaw midnight) with `today: "2026-11-26"` → `nil`.
- `testStaleFromThreeHours`: `now = updatedAt + 3 h − 1 s` → `banner == nil`; `now = updatedAt + 3 h` → `Banner(text: "Dane nieaktualne — ostatnia aktualizacja 26.11 14:00", tone: .error)` (the timeline entry scheduled at exactly `updatedAt + 3 h` must already show it).
- `testFailed`: `reason: "Brak połączenia z KSeF: fetch failed"` → `Banner(text: "Błąd pobierania: Brak połączenia z KSeF: fetch failed", tone: .error)`; `rows.count == 3`.
- `testPartial` → `Banner(text: "Pobrano częściowo — reszta przy następnym uruchomieniu.", tone: .warning)`.
- `testStaleBeatsFailed`: failed snapshot, `now = updatedAt + 4 h` → the stale banner.
- `testMissing`: `.failure(.missing)` → `title == "KSeF"`, `newToday == nil`, `Banner(text: "Brak danych — pobieranie jeszcze nie zapisało stanu widżetu.", tone: .error)`, `rows == []`, `emptyText == nil`.
- `testUnreadable`: `.failure(.unreadable("x"))` → `Banner(text: "Nie można odczytać danych widżetu: x", tone: .error)`.
- `testEmptyList`: `invoiceCount: 0` → `rows == []`, `emptyText == "Brak zapisanych faktur."`.
- `testFailedEmptyListHasNoEmptyText`: `status: .failed, reason: "Uszkodzony plik index.jsonl, linia 1", invoiceCount: 0` → `emptyText == nil`, failed banner shown.
- `testHostileSellerStaysVerbatim`: `invoiceCount: 8` → `rows[3].seller == "**Evil** [x](https://e.example)\nline2"`.
- `testDisallowedURLHasNoLink`: a snapshot whose first `viewUrl` is `https://evil.example/x` → `rows[0].url == nil`.
- `testRowLimit`: large → 8; medium without banner → 3; medium with the partial banner → 2.
- `testTimelineDates` (let `midnight = Date(timeIntervalSince1970: 1795734000)`, 2026-11-26T23:00:00Z = Warsaw midnight; build the other expected dates from `Fixtures.updatedAt.addingTimeInterval(…)`, not from literal doubles): `.success` → `[now, Fixtures.updatedAt.addingTimeInterval(WidgetModel.staleAfter), midnight]`; `.failure(.missing)` → `[now, midnight]`; `now = Fixtures.updatedAt.addingTimeInterval(4 * 3600)` → `[now, midnight]`.

Run: `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test` → FAIL (types missing).

- [ ] **Step 3: Implement** `Snapshot.swift` additions, `KsefLink.swift`, `WidgetModel.swift` per the rules above. Update `Probe/main.swift`: `SnapshotFile.load()` → `.success(s)`: print `OK status=<s.status.rawValue> invoices=<s.invoices.count> savedToday=<s.savedToday> updatedAt=<ISO8601>`, exit 0; `.failure(.missing)`: print `MISSING`, exit 2; `.failure(.unreadable(m))`: print `UNREADABLE <m>`, exit 1.

- [ ] **Step 4: Verify**

Run the test command above → `** TEST SUCCEEDED **`, `Executed <n> tests, with 0 failures` (n ≥ 20).
Run: `xcodebuild -project widget/KsefWidget.xcodeproj -scheme SnapshotProbe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build -quiet build && widget/build/Build/Products/Release/SnapshotProbe; echo "exit=$?"` → `MISSING`, `exit=2` (unless the owner's real file exists; then `OK status=…`, `exit=0`).

- [ ] **Step 5: Commit** `git add widget/project.yml widget/Shared widget/Probe widget/Tests` then `git commit -m "feat(widget): snapshot decoding, view model and link allow-list"`.

---

### Task 6: Widget extension, content view and host app

**Files:**
- Modify: `widget/project.yml` (add `KsefWidget` and `KsefWidgetExtension`)
- Create: `widget/Extension/Info.plist`, `widget/Extension/KsefWidget.swift`, `widget/Shared/InvoiceListView.swift`, `widget/App/main.swift`, `widget/App/App.entitlements`, `widget/Tests/RenderTests.swift`

**Interfaces:**
- Consumes: `SnapshotFile.load`, `Snapshot`, `SnapshotLoadError`, `WidgetModel` (`make`, `timelineDates`, `rowLimit`), `KsefLink.isAllowed`, `Fixtures` (Task 5).
- Produces: `struct InvoiceListView: View { let model: WidgetModel; let isLarge: Bool; let linksEnabled: Bool }`; widget kind `KsefInvoices`; the app bundle `KsefWidget.app`.

- [ ] **Step 1: Extend `widget/project.yml`**

```yaml
  KsefWidget:
    type: application
    platform: macOS
    sources: [App, Shared/KsefLink.swift]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.ksef-daily-fetch.KsefWidget
        INFOPLIST_KEY_LSUIElement: YES
        INFOPLIST_KEY_CFBundleDisplayName: KSeF
        CODE_SIGN_ENTITLEMENTS: App/App.entitlements
    dependencies:
      - target: KsefWidgetExtension
  KsefWidgetExtension:
    type: app-extension
    platform: macOS
    sources:
      - path: Extension
        excludes: ["Info.plist", "*.entitlements"]
      - Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.ksef-daily-fetch.KsefWidget.Extension
        INFOPLIST_FILE: Extension/Info.plist
        INFOPLIST_KEY_CFBundleDisplayName: KSeF
        CODE_SIGN_ENTITLEMENTS: Extension/Extension.entitlements
```
`Extension/Info.plist`: a plist dict with only `NSExtension` → `NSExtensionPointIdentifier` = `com.apple.widgetkit-extension` (the rest is generated). `App/App.entitlements`: `com.apple.security.app-sandbox` = `true` only.

- [ ] **Step 2: Write `RenderTests` (failing)**

Each test builds `InvoiceListView(model: WidgetModel.make(.success(<fixture>), now: <now>), isLarge: <bool>, linksEnabled: false)` (`ImageRenderer` draws `Link` as a placeholder and skips `containerBackground`, spec 5), wrapped in `.padding(16).frame(width: W, height: H, alignment: .topLeading).background(Color.white).environment(\.colorScheme, .light)`, renders with `ImageRenderer` at `scale = 2` on the main actor, and writes a PNG to `ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"]`; if the variable is unset, `throw XCTSkip("set TEST_RUNNER_WIDGET_RENDER_DIR to render PNGs")`. Assert the PNG's pixel size.
- `testRenderMedium` → `medium.png`, 364×170 pt (728×340 px), default fixture (3 invoices, 2 today).
- `testRenderLarge` → `large.png`, 364×382 pt (728×764 px), `invoiceCount: 8` (includes the hostile and the long seller).
- `testRenderMediumFailed` → `medium-failed.png`, `status: .failed, reason: "Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)"`.
- `testRenderMediumStale` → `medium-stale.png`, `now = updatedAt + 5 h`.
Sizes are iOS HIG values standing in for undocumented macOS sizes (UNCONFIRMED, spec 5).

- [ ] **Step 3: Implement `InvoiceListView`**

`VStack(alignment: .leading)`: header `HStack` with `Text(verbatim: model.title).font(.headline)`, `Spacer()`, `newToday` (`.font(.subheadline).foregroundStyle(.secondary)`); banner `Text(verbatim:)` `.font(.caption)`, `lineLimit(2)`, `.red` for error / `.orange` for warning; rows `ForEach(model.rows.prefix(model.rowLimit(isLarge: isLarge)))`: `HStack` of seller (`Text(verbatim:)`, `lineLimit(1)`, `.truncationMode(.tail)`), `Spacer(minLength: 8)`, amount (`.monospacedDigit()`), date (`.monospacedDigit()`, `.secondary`); wrapped in `Link(destination:)` only when `linksEnabled` and `row.url != nil`; `emptyText` as secondary text; `Spacer(minLength: 0)` at the bottom. Every dynamic string uses `Text(verbatim:)`.

- [ ] **Step 4: Implement `Extension/KsefWidget.swift`**

`@main struct KsefWidgetBundle: WidgetBundle` with one `InvoicesWidget`. `InvoicesWidget`: `StaticConfiguration(kind: "KsefInvoices", provider: Provider())`, `.configurationDisplayName("Faktury KSeF")`, `.description("Najnowsze faktury zakupowe z KSeF.")`, `.supportedFamilies([.systemMedium, .systemLarge])`. `struct Entry: TimelineEntry { let date: Date; let result: Result<Snapshot, SnapshotLoadError> }`. `Provider`: `placeholder` → `Entry(date: .now, result: .failure(.missing))`; `getSnapshot` → entry with `SnapshotFile.load()`; `getTimeline` → `let result = SnapshotFile.load()`, entries `WidgetModel.timelineDates(result, now: now).map { Entry(date: $0, result: result) }`, policy `.after(now.addingTimeInterval(30 * 60))`. Entry view reads `@Environment(\.widgetFamily)` and shows `InvoiceListView(model: .make(entry.result, now: entry.date), isLarge: family == .systemLarge, linksEnabled: true).containerBackground(.fill.tertiary, for: .widget)`.

- [ ] **Step 5: Implement `App/main.swift`**

Top-level code: `NSApplication.shared.delegate = delegate; NSApplication.shared.run()`. `Logger(subsystem: "local.ksef-daily-fetch.widget", category: "app")`. `AppDelegate`:
- `application(_:open:)`: set `handledURL = true`; for each URL: if `KsefLink.isAllowed(url)` → `NSWorkspace.shared.open(url)` and log `opened host=<host>`; else log `ignored URL scheme=<scheme> host=<host>` (never the full URL: it carries a NIP). If launching already finished, `NSApp.terminate(nil)`.
- `applicationDidFinishLaunching`: if `!handledURL`: log `default launch`, `NSApp.activate()`, run one `NSAlert` with `messageText` `Widżet KSeF jest zainstalowany` and `informativeText` `Dodaj go: kliknij prawym przyciskiem pulpit, wybierz „Edytuj widżety…” i wyszukaj „KSeF”.`; then `NSApp.terminate(nil)`. (Verified on this Mac: on a URL launch `application(_:open:)` runs before `applicationDidFinishLaunching`.)
Log values with `privacy: .public`.

- [ ] **Step 6: Build, test and render**

Run: `xcodegen generate --spec widget/project.yml --project widget`
Run: `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build -quiet build` → no errors.
Run: `codesign --verify --deep --strict widget/build/Build/Products/Release/KsefWidget.app && echo verified` → `verified`.
Run: `codesign -d --entitlements - --xml widget/build/Build/Products/Release/KsefWidget.app/Contents/PlugIns/KsefWidgetExtension.appex | plutil -p -` → sandbox + the exception only (plus possibly `get-task-allow`).
Run: `plutil -p widget/build/Build/Products/Release/KsefWidget.app/Contents/Info.plist | grep LSUIElement` → `"LSUIElement" => true`; `plutil -p widget/build/Build/Products/Release/KsefWidget.app/Contents/PlugIns/KsefWidgetExtension.appex/Contents/Info.plist | grep NSExtensionPointIdentifier` → `com.apple.widgetkit-extension`.
Run: `mkdir -p widget/build/renders && TEST_RUNNER_WIDGET_RENDER_DIR="$PWD/widget/build/renders" xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test` → `** TEST SUCCEEDED **`; `ls widget/build/renders` lists the four PNGs.
Look at each PNG. Fix layout until: the header fits on one line; no row wraps; the long and the hostile seller are truncated on one line; amounts and dates align in columns; medium shows 3 rows (2 with a banner) without clipping; the failed banner is at most two lines. Re-run until clean. List the PNG paths in your report.

- [ ] **Step 7: Check URL handling without a browser**

Run: `open -a "$PWD/widget/build/Build/Products/Release/KsefWidget.app" "https://example.invalid/ksef-check"`
Run: `log show --last 2m --style compact --predicate 'subsystem == "local.ksef-daily-fetch.widget"'` → contains `ignored URL scheme=https host=example.invalid` and no `default launch`.
Run: `pgrep -x KsefWidget; echo "running=$?"` → `running=1` (the app quit).
Do not launch the app without a URL (its alert waits for a click) and do not pass a KSeF URL (it would open a browser).

- [ ] **Step 8: Unregister the build products**

Run: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/widget/build/Build/Products/Release/KsefWidget.app"` (and the same for `Debug/KsefWidget.app` if it exists).
Run: `pluginkit -m -p com.apple.widgetkit-extension | grep -c ksef-daily-fetch` → `0` (confirmed on this Mac: `lsregister -u` removes the entry while the bundle stays on disk). If a later build or test run registers it again, repeat this step before finishing.
Also check the deployment target held: the build above used macOS 14.0 (UNCONFIRMED in spec 8); if it failed only because an API needs a newer macOS, raise `deploymentTarget` to the lowest version that builds and say so in the commit message.

- [ ] **Step 9: Commit** `git add widget/project.yml widget/Extension widget/Shared widget/App widget/Tests` then `git commit -m "feat(widget): desktop widget, content view and link-forwarding host app"`.

---

### Task 7: README, AGENTS.md and final verification

**Files:**
- Modify: `README.md`, `AGENTS.md`

- [ ] **Step 1: README.md** (English; keep the existing style and sections; change only what follows)
  1. **What it does**: "Once a day" → "Every hour"; mention the desktop widget in one sentence; correct the example notification body to `Acme Sp. z o.o.: 1230,00 PLN; Beta S.A.: 53,63 EUR` (Node prints no thousands separator below 10 000; spec 8).
  2. **Install the daily job** → **Install the hourly job**: runs every hour at minute 0; after sleep, one run at wake; not while the Mac is off. If an older daily job is installed, run `scripts/launchagent.sh install` again to switch it (same label, it replaces the old one). Notifications still come only for new, partial or failed runs, so a lasting failure (offline Mac, revoked certificate) now notifies every hour. Keep the existing run-now, log, uninstall and Node-upgrade lines.
  3. New section **Desktop widget** after the hourly job:
     - What it shows (newest invoices, last update, `N nowe dziś`, the banners with their meaning: no data yet, cannot read, stale after 3 h, last fetch failed, partial) and that it reads only `~/Library/Application Support/ksef-daily-fetch/widget.json`, written by every run.
     - Requirements: Xcode (command-line `xcodebuild`), `brew install xcodegen`.
     - Build: `xcodegen generate --spec widget/project.yml --project widget` then `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build build`. Signing is ad hoc ("Sign to Run Locally"); no Apple developer account, certificate or Keychain access is needed.
     - Install: `mkdir -p ~/Applications && rm -rf ~/Applications/KsefWidget.app && ditto widget/build/Build/Products/Release/KsefWidget.app ~/Applications/KsefWidget.app`, then unregister the build copy so only one is known to macOS: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/widget/build/Build/Products/Release/KsefWidget.app"`.
     - Launch once: `open ~/Applications/KsefWidget.app` → an alert says the widget is installed. Then right-click the desktop, **Edit Widgets…**, search "KSeF", add the medium or large size (menu names may differ slightly).
     - The widget refreshes about every 30 minutes; macOS decides the exact moment. Clicking an invoice opens its KSeF page in the browser through the app.
     - Troubleshooting: check sandbox access from a terminal: build the `SnapshotProbe` scheme the same way and run `widget/build/Build/Products/Release/SnapshotProbe` → `OK status=…` (or `MISSING` before the first run); widget not in the gallery → make sure the app is in `~/Applications`, launch it once, and look for `purging` in `log show --last 10m --predicate 'process == "chronod"' | grep ksef-daily-fetch`; if macOS refuses an ad-hoc widget, build with Developer ID by adding `CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=<your Team ID>` to the `xcodebuild` line (never commit these); clicks do nothing → `log show --last 5m --predicate 'subsystem == "local.ksef-daily-fetch.widget"'` should show `opened host=…`.
     - Update after a code change: rebuild, repeat Install.
  4. **Development**: add the widget test command (`xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test`) and the render variant with `TEST_RUNNER_WIDGET_RENDER_DIR`.

- [ ] **Step 2: AGENTS.md**
  - First paragraph: "once a day" → "every hour"; add that a native macOS widget in `widget/` shows the latest invoices from a snapshot file; link the widget spec next to the existing one.
  - Commands: `xcodegen generate --spec widget/project.yml --project widget`; the widget test command; the widget build command.
  - Rules (add): no third-party Swift packages; signing stays ad hoc, never commit a Team ID, identity, provisioning profile or `DEVELOPMENT_TEAM`; never copy the app into `/Applications` or `~/Applications`, and after building run `lsregister -u` on the built app; the widget extension never gets network access or wider file access than the one read-only directory; the snapshot path lives in three places (`src/main.ts`, `widget/Extension/Extension.entitlements`, `widget/Shared/Snapshot.swift`) and changes together; seller text in Swift is always `Text(verbatim:)`; Polish user-facing text applies to the widget and the app alert too; tests never write under the real home (`run()` takes `snapshotPath`).
  - State: add `~/Library/Application Support/ksef-daily-fetch/widget.json` (widget snapshot, rewritten after every run) and that reports can hold several sections a day.

- [ ] **Step 3: Final verification**

Run: `pnpm test && pnpm typecheck` → PASS.
Run: the widget test command → `** TEST SUCCEEDED **`.
Run: `git grep -n "$(basename "$HOME")"` → no output, exit status 1 (no home-directory name in tracked files; `git grep` skips the untracked `widget/build` and generated project, which embed absolute paths).
Run: `git status --short` → only `README.md` and `AGENTS.md` modified; `git ls-files widget` lists no `.xcodeproj` or `build` paths.
Run: `pluginkit -m -p com.apple.widgetkit-extension | grep -c ksef-daily-fetch` → `0`; `ls ~/Library/LaunchAgents | grep -c ksef` → `0`; `test -e "$HOME/Library/Application Support/ksef-daily-fetch"; echo "exists=$?"` → `exists=1` (unless it existed before Task 1).

- [ ] **Step 4: Commit** `git add README.md AGENTS.md` then `git commit -m "docs: hourly job and desktop widget setup"`.

---

## Done when

- `pnpm test`, `pnpm typecheck` and the widget unit tests pass; the four PNGs exist in `widget/build/renders/` and were looked at; the Task 1 spike printed `OK 15 bytes` with the exception and `Operation not permitted` without it.
- `git status` is clean; no generated project, build output, Team ID, identity or home path is tracked.
- Nothing was installed into launchd or an Applications folder, nothing touched the Keychain, no notification was shown, no LaunchServices registration of the build remains.
- Left for the owner (README): build, install into `~/Applications`, launch once, add the widget, re-run `scripts/launchagent.sh install`, click one invoice and judge the look.
