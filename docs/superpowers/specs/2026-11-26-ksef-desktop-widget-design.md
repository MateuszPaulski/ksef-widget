# KSeF desktop widget — design

Date: 2026-11-26
Status: approved scope (owner), technical calls by the orchestrator (O), details by the spec author (S)

## 1. Intent

The fetcher (`docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md`) pulls the owner's purchase invoices from KSeF once a day and tells them through a notification and a Markdown report. The owner wants to see the latest invoices at a glance, kept roughly current through the day: "a Mac desktop widget to show latest invoices and update them more or less real time (hourly, within safe KSeF limit)".

Two changes deliver that: the fetcher runs every hour instead of daily at 08:00, and a native macOS desktop widget shows what the fetcher saved. The widget never talks to KSeF and never touches the certificate; it only reads a small file the fetcher writes after every run.

Approved layout (medium size; the amounts are illustrative, see 7.4):

```
KSeF · zaktualizowano 14:00              2 nowe dziś
Acme Sp. z o.o.        1 230,00 PLN    26.11
Orange Polska             89,99 PLN    25.11
Hetzner Online           153,75 EUR    24.11
```

Clicking an invoice opens its KSeF view link (the "KOD I" link the report already uses) in the browser.

## 2. Goals

1. A native WidgetKit desktop widget in medium and large sizes listing the newest saved invoices (seller, gross amount with currency, issue date), the time of the last fetch, and how many invoices were saved today (Europe/Warsaw).
2. The fetcher runs hourly within KSeF rate limits; notifications keep their current rules (only when something is new, partial or failed), except that a failure repeating the previous run's failure on the same day does not notify again (7.3, amendment W1).
3. After every non-dry run, complete, partial or failed, the fetcher writes a snapshot file the widget renders.
4. The widget makes a failed last run, a stale snapshot and a missing or unreadable snapshot visible.
5. Clicking a row opens that invoice's KSeF view link in the default browser.

## 3. Non-goals

- No small or extra-large size, no configuration UI, no interactivity beyond links, no app intents.
- No menu-bar item, no main app window, no settings.
- The widget does not fetch, refresh or retry anything; it only reads the snapshot.
- No App Store or notarised distribution; the app is built and installed locally by the owner.
- No change to sync, authentication, report or notification logic beyond what hourly runs require.

## 4. Anti-goals

- **A widget that quietly shows old data.** The project's anti-goal (fetcher spec 4) extends to the widget: a last run that failed, a snapshot older than three hours, a missing snapshot and an unreadable snapshot each show a visible Polish banner. Staleness also covers failures that cannot write a snapshot (launchd job not installed, Node missing, the Mac off).
- **A widget that can reach KSeF or the key.** It runs in the App Sandbox with no network entitlement and read-only access to one directory.

## 5. Constraints and recon facts

All checked on 2026-11-26 on the owner's Mac (macOS 27.0.1, Apple Silicon, Xcode 27.1, Swift 6.4, XcodeGen 2.46.0) or in Apple's documentation fetched that day. Probes ran in a scratch directory and were removed afterwards.

**Data sharing**

- App Group containers on macOS 15 and later are protected. Apple DTS ("App Groups: macOS vs iOS: Working Towards Harmony", developer.apple.com/forums/thread/721701): access to a group container requires claiming the group in the App Groups entitlement, "because of app group container protection", and is granted without a prompt only for Mac App Store, TestFlight, a Team-ID-prefixed group ID, or a group authorised by an embedded provisioning profile; otherwise "the system prompts the user to approve its access to the container. If granted, that consent applies only for the duration of that app instance." The fetcher is a plain `node` binary (installed through nvm on this Mac) that claims no entitlement, started hourly by launchd with no UI. Applying these rules to it is an inference from the DTS posts; it was not probed.
- Writing into another app's sandbox container (`~/Library/Containers/<id>`) from a non-sandboxed process triggers the "would like to access data from other apps" consent, which DTS describes as "Transient, process lifetime" (developer.apple.com/forums/thread/742147), so every hourly Node process would be asked again.
- `com.apple.security.temporary-exception.files.home-relative-path.read-only` "Enables read-only access to the specified files or subdirectories in the user's home directory"; each value starts with `/`, is relative to `~`, and a directory ends with `/` (Apple, App Sandbox Temporary Exception Entitlements).
- **Probe, confirmed:** a command-line tool ad-hoc signed with `com.apple.security.app-sandbox` plus that read-only exception for a home-relative directory read a JSON file in that directory; the same binary signed with the sandbox entitlement alone got `NSCocoaErrorDomain 257` / `EPERM` for the same file. The exception directory contained a space and worked. Inside the sandbox `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` both return the container (`~/Library/Containers/<bundle id>/Data`), so the real home must come from `getpwuid(getuid())`. A missing file gives `260` / `ENOENT` with or without the exception, so only an existing file proves access. A sandboxed command-line tool needs an embedded Info.plist with `CFBundleIdentifier` or it dies with `SIGTRAP` (`Unable to get bundle identifier for container id`); Xcode's `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` provides it. Rebuilding and re-signing ad hoc under the same identifier reused the existing container without a prompt.
- **Probe, confirmed:** an XcodeGen project with an app, an `app-extension` widget target and a `tool` target signed with the widget's entitlements file built with `xcodebuild`; the tool read the file through the sandbox (`secinitd: AppSandbox request successful`).

**Signing**

- **Confirmed:** `CODE_SIGN_IDENTITY = "-"` (ad-hoc, "Sign to Run Locally") builds, embeds and signs the app and the extension; `codesign --verify --deep --strict` passes. The App Sandbox and temporary-exception entitlements need no provisioning profile.
- **Confirmed:** another widget app on the owner's Mac, ad-hoc signed and installed in `~/Applications`, is live: `chronod` reloads its timeline every 15–16 minutes all day ("Reload success" at 10:37, 10:53, 11:09, … 16:27). So an ad-hoc-signed widget extension is accepted on this macOS.
- **Observed:** for an ad-hoc app left in a build directory, `chronod` logs "Requested to add extension, but purging instead because we shouldn't cache it", with and without the temporary exception. The likely cause is the location (the live widget is in `~/Applications`); UNCONFIRMED. The owner installs into `~/Applications`.
- Building registers the built app with LaunchServices, and its extension then appears in `pluginkit -m -p com.apple.widgetkit-extension`. **Confirmed:** `lsregister -u <app>` removes it from that list while the bundle stays on disk. Two registered copies of one bundle ID (build directory and `~/Applications`) should be avoided.

**Links** (Apple, "Linking to specific app scenes from your widget or Live Activity")

- Medium and larger widgets may contain several `Link` controls. "When the widget or Live Activity receives an interaction, the system activates the containing app and passes the URL to `onOpenURL(perform:)`, …, or `NSApplicationDelegate/application(_:open:)`." The URL goes to the containing app, which must open it in the browser itself.
- **Probe, confirmed** with `open -a <app> <url>`: on a cold launch AppKit calls `application(_:open:)` before `applicationDidFinishLaunching`, whose `launchIsDefaultUserInfoKey` is then `false`; a plain launch gives `true` and no URL. UNCONFIRMED that a widget click takes the same path; a log line makes the first real click checkable.

**Refresh** (Apple, "Keeping a widget up to date")

- A frequently viewed widget typically gets "from 40 to 70 refreshes" a day, "roughly … every 15 to 60 minutes"; entries should be "at least about 5 minutes apart"; reloads requested by the app while it is in the background count against the budget. Policies: `.atEnd`, `.after(date)`, `.never`.
- **Observed:** the live widget above gets a 15-minute `.after` policy honoured all day, about 96 reloads a day.

**KSeF frequency** (`CIRFMF/ksef-api`, `limity/limity-api.md`, main, fetched 2026-11-26, lines 117–118)

- "Nie zaleca się harmonogramów o wysokiej częstotliwości. W środowisku produkcyjnym interwał cykliczny nie powinien być krótszy niż 15 minut dla każdego podmiotu występującego na fakturze". Low-volume profiles: "pobieranie na żądanie, uzupełnione cyklem np. raz na dobę". Limits per context and IP: metadata 20/h, single download 64/h, other protected endpoints 120/h.

**launchd** (`man launchd.plist` on this Mac)

- `StartCalendarInterval`: "launchd will start the job the next time the computer wakes up. If multiple intervals transpire before the computer is woken, those events will be coalesced into one event upon wake from sleep." `StartInterval`: "If the system is asleep during the time of the next scheduled interval firing, that interval will be missed."

**Testing headlessly**

- **Confirmed:** `xcodebuild test` on a macOS unit-test bundle with no host app runs from the command line. `ImageRenderer` renders a SwiftUI view to an `NSImage` that can be written as PNG. It draws `Link` as a yellow "unavailable" placeholder and does not draw `containerBackground(for: .widget)`, so the rendered view must be the row content without `Link`, with its own padding and background. Environment variables reach the test process only with the `TEST_RUNNER_` prefix (`TEST_RUNNER_WIDGET_RENDER_DIR` becomes `WIDGET_RENDER_DIR`).
- macOS widget point sizes are not documented (the HIG table covers iOS: medium 364×170, large 364×382 on the largest iPhones). PNG renders use those sizes and are a layout check, not pixel truth; UNCONFIRMED for macOS.

**Formatting**

- Node's `Intl.NumberFormat('pl-PL')` gives `1230,00` (no grouping below five digits, CLDR minimum grouping) and `12 345,67`. The fetcher's `formatAmount` is the single source of amount text; the snapshot carries the formatted string.
- Swift `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` parses both `2026-11-26T23:30:41.123Z` (Node's `toISOString()`) and the form without milliseconds.

## 6. Approaches considered

### 6.1 Surface: native WidgetKit widget (chosen) vs menu-bar item vs third-party HTML widget host

- **Native WidgetKit widget (chosen, owner's call).** Lives on the desktop, no process of ours runs between refreshes, sandboxed by construction. Costs a small Swift app because a widget ships inside an app, and macOS decides when it redraws.
- **Menu-bar item (rejected by the owner).** Always-running process, needs a click to see anything.
- **Third-party HTML widget host (Übersicht and similar; rejected).** Another app with its own update channel and full disk access to render a list we can render natively.

### 6.2 Fetcher → widget data sharing

- **(a) App Group container (rejected).** Since macOS 15 the container is guarded: a process that does not claim the group in its entitlements is prompted, and the consent lasts one process lifetime (5). The writer is a third-party `node` binary run hourly by launchd with no UI, so by the DTS rules (not probed) every run would hit a prompt or a denial. Wrapping Node in a signed helper that claims the group adds a third binary and a Team ID in the build.
- **(b) Read-only temporary exception for a fixed home-relative directory (chosen).** The fetcher writes `~/Library/Application Support/ksef-daily-fetch/widget.json` as an ordinary file in the owner's home; the widget extension's entitlements grant read-only access to `/Library/Application Support/ksef-daily-fetch/`. No container protection, no consent, no Team ID, no provisioning profile; proven by probe on this Mac (5). Temporary exceptions are discouraged for the Mac App Store, which is a non-goal.
- **(c) Fetcher writes into the widget's own sandbox container (rejected).** Same per-process consent problem as (a) for `~/Library/Containers` (5).
- **(d) Host app as a relay (rejected).** The host app would have to run to copy data; it does not run between clicks.

### 6.3 Refresh: timeline only (chosen) vs explicit reload from the fetcher

- **Explicit reload (rejected).** Node cannot call `WidgetCenter`; it would have to launch the host app after every run (`open -g …`) to call `reloadTimelines(ofKind:)`, which still counts against the budget when the app is not in the foreground. More moving parts for at most 30 minutes of latency.
- **Timeline only (chosen).** `.after(now + 30 min)`. The live widget on this Mac shows a 15-minute policy honoured all day, well inside the documented 40–70 a day for 30 minutes (48 a day). New data appears at most about 30 minutes after a run, plus the run's own few minutes.

### 6.4 Signing: ad-hoc (chosen) vs Developer ID vs Apple Development

- **Ad-hoc, "Sign to Run Locally" (chosen).** Works for widget extensions on this Mac (5); needs no Team ID, identity or Keychain access, so nothing personal goes into the repository and building never prompts for a key. The entitlements chosen in 6.2 need no profile.
- **Developer ID Application (fallback only).** Also works without a profile for these entitlements, but `codesign` uses the private key in the login Keychain (a Keychain prompt on first build) and the identity or Team ID would live in a gitignored file. Kept as a documented command-line override (`CODE_SIGN_IDENTITY=… DEVELOPMENT_TEAM=…` on the `xcodebuild` line) if the owner's ad-hoc build is ever rejected.
- **Apple Development (rejected).** Needs a development certificate and profile the owner does not have; nothing here requires it.

### 6.5 Schedule: hourly `StartCalendarInterval` (chosen) vs `StartInterval 3600`

`StartInterval` misses firings during sleep (5); `StartCalendarInterval` with only `Minute = 0` fires at every full hour and coalesces missed ones into one run at wake.

## 7. Decisions

### 7.1 Repository layout and build
- (O) Swift code in `widget/` in this repository. The Xcode project is generated by XcodeGen from the committed `widget/project.yml`; `widget/*.xcodeproj/` and `widget/build/` are gitignored. Builds and tests run with `xcodebuild` from the command line, derived data in `widget/build`. No third-party Swift dependencies.
- (S) Targets: `KsefWidget` (application, host), `KsefWidgetExtension` (app extension, widget), `SnapshotProbe` (command-line tool signed with the extension's entitlements file; the sandbox check used by the spike and by troubleshooting), `KsefWidgetTests` (unit tests, no host). Shared Swift sources compile into each target that needs them; there is no framework target.
- (S) Bundle IDs: `local.ksef-daily-fetch.KsefWidget`, `local.ksef-daily-fetch.KsefWidget.Extension`, `local.ksef-daily-fetch.SnapshotProbe`. Widget kind `KsefInvoices`. Deployment target macOS 14.0 (`containerBackground(for: .widget)`). `SWIFT_VERSION` 6.0. Info.plists are generated (`GENERATE_INFOPLIST_FILE`) except the extension's partial plist, which carries only `NSExtension`.
- (S, overrules an orchestrator call) **No `widget/Local.xcconfig`.** Signing is ad hoc (`CODE_SIGN_IDENTITY = "-"`, committed). Reason: an ad-hoc widget runs on this Mac and the chosen entitlements need no Team ID, so there is no secret or personal value to keep out of git, and building never touches the Keychain. If the owner ever needs Developer ID, they pass it on the command line (6.4).

### 7.2 Snapshot contract (the only interface between the two halves)
- (O) The fetcher writes after every non-dry run of `run()`, whatever its status, and when `main.ts` fails before `run()` (config or Keychain error). A dry run writes nothing. A failure that kills Node before `main` runs (wrapper-script case) writes nothing and is caught by staleness.
- (S) Path: `~/Library/Application Support/ksef-daily-fetch/widget.json` (the real home; `main.ts` uses `os.homedir()`, Swift uses `getpwuid`). Written atomically (temp file in the same directory, then rename) with the existing `writeAtomic`. The path is injected into `run()` so tests and the E2E never touch the real home.
- (S) Shape (UTF-8 JSON, two-space indent, trailing newline):
  ```json
  {
    "updatedAt": "2026-11-26T13:00:41.123Z",
    "status": "complete",
    "today": "2026-11-26",
    "savedToday": 2,
    "invoices": [
      {
        "ksefNumber": "5265877635-20261126-0123456789AB-CD",
        "seller": "Acme Sp. z o.o.",
        "invoiceNumber": "FV/2/2026",
        "amount": "1230,00 PLN",
        "issueDate": "2026-11-26",
        "savedAt": "2026-11-26T13:00:39.000Z",
        "viewUrl": "https://qr.ksef.mf.gov.pl/invoice/1111111111/26-11-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"
      }
    ]
  }
  ```
  `updatedAt`: when the snapshot was built (end of the run), `toISOString()`. `status`: `complete` | `partial` | `failed`. `reason`: present only when the run summary has one (partial, failed), the same Polish text as the notification. `today`: `warsawDay(updatedAt)`. `savedToday`: index entries whose `warsawDay(savedAt)` equals `today`, counted over the whole index, not the capped list. `invoices`: the last 8 index entries, newest saved first. `seller`: the report's seller label (name, or `NIP <nip>`). `amount`: `formatAmount(grossAmount, currency)`. `viewUrl`: `invoiceViewUrl(environment, …)`.
- (S) A failed run still lists invoices from `index.jsonl`. If the index cannot be read (corrupt line; the run has then already failed with the same reason), the list is empty. A failure in `main.ts` before `run()` writes `failed` with the reason and an empty list (no config, so no data directory).
- (S) The widget decodes only `updatedAt`, `status`, `reason`, `today`, `savedToday` and, per invoice, `ksefNumber`, `seller`, `amount`, `issueDate`, `viewUrl`. Unknown keys are ignored; an unknown `status` or a missing field makes the snapshot unreadable, which is shown.

### 7.3 Fetcher changes
- (O) LaunchAgent: `StartCalendarInterval` `{Minute: 0}` instead of `{Hour: 8, Minute: 0}`. Label `local.ksef-daily-fetch`, script names and log file stay: "daily-fetch" is the project's name, and a new label would leave an old installed job running next to the new one. The install message says it runs every hour.
- (S) Rate budget per idle run: one challenge, one XAdES upload, about two status polls, one redeem, one metadata query. Hourly that is 1 metadata query of 20/h and about 4 other calls of 120/h. Downloads are capped at 60 per rolling hour across all runs (4 s apart; fetcher spec 7.4), so hourly, manual and wake-time runs together stay under 64; a 429 ends the run as partial. Hourly is four times above KSeF's 15-minute floor.
- (S) Reports: unchanged. Nothing-new runs write nothing; other runs append a section to `reports/YYYY-MM-DD.md`, so a day can now hold several sections.
- (S) Notifications: same rules, with one amendment (W1, orchestrator's call (O), overrules the first draft of this spec, which kept every hourly repeat). A `failed` run does not notify when the snapshot on disk, read before the new one is written, is also `failed` with the identical `reason` and its `today` equals the current Europe/Warsaw day. The first failure of each day, a different reason, a failure after any non-failed run, or a missing or malformed previous snapshot still notify; so does a failed run that saved new invoices. Report sections, the snapshot and a log line (`repeated failure, notification skipped`) are written as before; `partial` and "new invoices" notifications and dry runs are unchanged. `main.ts` applies the same rule before its pre-config failure notification. Consequence: a lasting failure notifies once a day, not every hour; a backfill still notifies "pobrano częściowo" at each hourly run until done. Suppression is safe against a silent failure because the snapshot, the widget banner (7.4) and the report still show every failed run.
- (S) `report.ts`: `sellerLabel` becomes exported; `sellerLabel` and `invoiceViewUrl` take only the fields they read (`Pick<InvoiceMetadata, …>`), so index entries can be passed. `store.ts`: an exported `IndexEntry` type and `readIndex(dataDir)`, used by `openStore` for the dedup set; `writeAtomic` becomes exported. New `src/snapshot.ts`.

### 7.4 Widget content and copy
- (O) Text in Polish, consistent with the notifications; code, comments and docs in English.
- (S) Amounts come preformatted from the fetcher, so the widget shows exactly what notifications and reports show (`1230,00 PLN`, `12 345,67 PLN`). The approved sketch's `1 230,00` was illustrative; `formatAmount` is not changed.
- (S) Header: `KSeF · zaktualizowano HH:mm` (`updatedAt` in Europe/Warsaw); `KSeF` alone when there is no readable snapshot. Right side: `N nowa dziś` / `N nowe dziś` / `N nowych dziś` (the fetcher's plural rule: 1 → `nowa`; last digit 2–4 except 12–14 → `nowe`; otherwise `nowych`), shown only when `savedToday > 0` and the snapshot's `today` equals today in Warsaw.
- (S) Banner, at most one, first match wins:
  1. missing file → `Brak danych — pobieranie jeszcze nie zapisało stanu widżetu.` (error)
  2. unreadable → `Nie można odczytać danych widżetu: <error description>` (error)
  3. stale (`now − updatedAt ≥ 3 h`) → `Dane nieaktualne — ostatnia aktualizacja DD.MM HH:mm` (error)
  4. failed → `Błąd pobierania: <reason>` (error)
  5. partial → `Pobrano częściowo — reszta przy następnym uruchomieniu.` (warning)
  Stale outranks failed: an old failure means the job itself stopped. Three hours = two missed hourly runs plus margin. Error tone red, warning orange; the text alone carries the meaning because desktop widgets may render without colour.
- (S) Rows: seller (one line, truncated), amount, issue date `DD.MM`. Medium shows 3 rows, 2 when a banner is shown; large shows up to 8. A readable snapshot with no invoices and a status other than `failed` shows `Brak zapisanych faktur.` (after a failure the empty list means "unknown", not "none", so only the banner shows). Seller and reason are rendered with `Text(verbatim:)` (seller text is attacker-controlled; no Markdown or localisation lookup).
- (S) Each row is a `Link` to its `viewUrl`, only if that URL is `https` on `qr.ksef.mf.gov.pl`, `qr-test.ksef.mf.gov.pl` or `qr-demo.ksef.mf.gov.pl`; otherwise the row is plain text.

### 7.5 Timeline
- (O) Policy `.after(now + 30 min)`. No reload trigger from the fetcher (6.3).
- (S) Each timeline holds the entry for now plus entries at `updatedAt + 3 h` and at the next Warsaw midnight when those are in the future. Each entry recomputes the view model for its own date, so the stale banner and the "dziś" count change even if macOS delays the next reload.

### 7.6 Host app
- (S) `LSUIElement` (no Dock icon, no menu), sandboxed with no other entitlement, AppKit delegate in one `main.swift`. `application(_:open:)`: opens each allowed URL (7.4) with `NSWorkspace.shared.open`, logs and ignores others. `applicationDidFinishLaunching`: if no URL was handled, activates and shows one alert (`Widżet KSeF jest zainstalowany` / `Dodaj go: kliknij prawym przyciskiem pulpit, wybierz „Edytuj widżety…” i wyszukaj „KSeF”.`); then terminates either way. Logs through `Logger(subsystem: "local.ksef-daily-fetch.widget", category: "app")`, so the owner can confirm the first real click reached the app.

### 7.7 Verification without a desktop
- (O) Task 1 of the plan is a spike: `SnapshotProbe`, signed with the extension's exact entitlements file, reads a real file at the real snapshot path through the sandbox, and a copy re-signed without the exception is denied. Checked from the command line by output and exit code.
- (S) Swift unit tests: snapshot decoding, view model (every banner, plural table, today check, URL allow-list, timeline dates). PNG renders of medium, large, failed and stale states into `widget/build/renders/` for the orchestrator to look at. TypeScript tests for the snapshot builder and for `run()` writing the snapshot.
- (O) The implementer never installs the LaunchAgent, never copies the app to an Applications folder, never touches the Keychain, never shows a real notification. After building it unregisters the built app from LaunchServices.

## 8. Risks and open points

- **UNCONFIRMED** that the widget extension (launched by `chronod`, not by a shell) gets the same sandbox treatment of the temporary exception as the probe tool with the same entitlements. Mitigation: the probe shares the entitlements file, and a denial shows as the "Nie można odczytać danych widżetu" banner, never as an empty widget.
- **UNCONFIRMED** that an ad-hoc widget from `~/Applications` appears in the gallery for this app; evidence is another ad-hoc widget live from `~/Applications` on the same Mac. Fallback: Developer ID on the command line (6.4).
- **UNCONFIRMED** that a widget click reaches `application(_:open:)` the way `open -a` does. Check: the owner clicks a row and `log show --predicate 'subsystem == "local.ksef-daily-fetch.widget"' --last 5m` shows the URL line.
- **UNCONFIRMED** macOS widget point sizes; renders are a layout check. The owner judges the real look.
- **UNCONFIRMED** deployment target 14.0: the prototype was built with 15.0. If an API used needs more, raise the target to the lowest that builds and say so.
- Resolved by the orchestrator (O, W1), not yet confirmed by the owner: a repeated identical failure notifies once per Warsaw day, not every hour (7.3).
- Pre-existing: the README's example notification shows `1 230,00 PLN`, but Node prints `1230,00 PLN`. The README edit in this feature corrects that one example.
- Probe leftovers outside the scratch directory: sandbox containers `~/Library/Containers/local.probe.ksef*` (nine) and two crash reports `~/Library/Logs/DiagnosticReports/reader-*.ips`. They are inert; the owner may delete them.

## 9. Left to the builder

- Fonts, spacing and colours within the pinned copy and row counts; adjust after looking at the PNGs.
- Internal Swift type and file names beyond what the plan pins; log wording beyond the pinned lines.
