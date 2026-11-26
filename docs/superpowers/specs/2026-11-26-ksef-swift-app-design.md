# KSeF Swift app — design

Date: 2026-11-26
Status: approved scope (owner), technical calls by the orchestrator (O), details by the spec author (S)

## 1. Intent

The fetcher (`docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md`) and the widget (`docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md`) work, but setting them up takes a terminal: Node and pnpm, files in `~/.config`, a `security` command for the Keychain, a hand-written `config.json`, a LaunchAgent script, an Xcode build. The owner asked "can't we integrate all that stuff into the widget directly?" and chose a **full Swift app**:

- They open the app once, pick the certificate and key files, type the key password and NIP. No terminal, no `config.json`, no Keychain command.
- The app starts at login, sits in the menu bar and fetches every hour itself. No Node, no launchd.
- The widget, notifications and saved XML files work as they do now.
- The fetcher is rewritten in Swift. The riskiest part is the XAdES signature; it is proven on the KSeF TEST environment like before.

The TypeScript fetcher is proven end to end on TEST, and the owner reports a successful `--dry-run` against PRODUCTION with their real certificate. Nothing is installed on the Mac yet (no LaunchAgent, no app, no data folder).

## 2. Goals

1. One self-contained, native macOS app (`KSeF.app`) that does everything the TypeScript fetcher does, with the same rules, limits, Polish texts and on-disk formats, and embeds the existing widget extension unchanged.
2. Setup without a terminal: a settings window for NIP, certificate file, key file, key password, environment, start date, invoice folder and "start at login"; a **Sprawdź połączenie** button equivalent to `--dry-run`.
3. A background menu-bar agent: hourly fetch, catch-up after wake, one run at a time, native notifications, widget timelines reloaded after each run, widget link clicks handled without quitting.
4. All logic in a Swift library with unit tests ported case by case from the 142 TypeScript tests; the XAdES signer proven byte-identical to the TypeScript signer; TEST authentication (RSA and EC) and the full TEST fetch as XCTests.
5. The owner builds with one script, ad hoc by default or with their Developer ID when they pass it.

## 3. Non-goals

- No new fetch features: no sales invoices, no export API, no accounting export, no PDF, no new notification kinds.
- No App Store, no notarisation, no distribution to other Macs, no auto-update.
- No import of the TypeScript tool's Keychain item, `config.json` or `~/.config/ksef-daily-fetch/` files; no migration of a TypeScript data folder (none exists; the formats are compatible anyway).
- No deletion of the TypeScript fetcher in this change. It stays, untouched, as the fallback until the owner confirms the app against production; removing it is a later, separate change.
- No change to the widget extension, its view, its tests or the snapshot contract.

## 4. Anti-goals

- **A fetch that fails silently** (unchanged from the fetcher spec, section 4). Every run ends complete-and-quiet, new invoices (notification + report), partial (notification + report) or failed (notification + report + log; a repeated same-day failure skips only the notification). Setup problems that stop a run (missing settings, missing Keychain item, unreadable credential files) notify and write a failed snapshot, as `main.ts` does before `run()` today. If the app is not running at all, the widget's three-hour stale banner is the only sign; that is now the designed last line of defence. Notifications denied in System Settings show as a warning in the menu and the settings window.
- **A widget that can reach the key.** The key, certificate and settings never live in the directory the widget extension may read.
- **Two fetchers at once.** The download cap counts per data folder, so the TypeScript job and the app running together could exceed KSeF's limits. The app refuses to fetch while the old LaunchAgent is installed.

## 5. Constraints and recon facts

Checked on 2026-11-26 on the owner's Mac (macOS 27.0.1, Apple Silicon, Xcode 27.1, Swift 6.4, XcodeGen 2.46.0, LibreSSL 3.3.6, Node 22.23.4) with throwaway probes in a scratch directory (self-signed test certificates only, ad hoc signing, nothing installed), and in Apple documentation and Apple DTS forum posts fetched that day. "Probe" marks something run here; "Doc" an Apple source; "DTS" a post by Apple Developer Technical Support; "Inference" a conclusion without either.

### 5.1 Keys and certificates

- **Probe:** `/usr/bin/openssl req -x509 -newkey … -passout …` writes `-----BEGIN ENCRYPTED PRIVATE KEY-----` as PBES2 + PBKDF2 (no PRF field, i.e. HMAC-SHA1) + AES-256-CBC, 2048 iterations; `openssl pkcs8 -topk8 -v2 aes-128-cbc` gives the same with AES-128. LibreSSL 3.3.6 has no `-v2prf`. Node 22 (`KeyObject.export({type:'pkcs8', cipher, passphrase})`) writes PBES2 + PBKDF2 **HMAC-SHA256** + AES-128/192/256-CBC.
- **Probe:** `SecItemImport` with `kSecFormatWrappedPKCS8`, item type private key, a passphrase and no keychain returned `errSecUnknownFormat` (-25257) for both LibreSSL keys. Only that format/flag combination was tried; the loader needs a DER reader anyway, because an unsupported algorithm must fail with a Polish message naming its OID.
- **Probe:** a minimal DER reader + `CCKeyDerivationPBKDF` (PRF taken from the parameters, default HMAC-SHA1) + `CCCrypt` (AES-CBC, PKCS#7 padding) decrypted all five variants above (LibreSSL SHA1/AES-256, SHA1/AES-128; Node SHA256/AES-128/192/256).
- **Probe:** CryptoKit `P256.Signing.PrivateKey(derRepresentation:)` accepts the decrypted PKCS#8 `PrivateKeyInfo` directly; its ECDSA signature's `rawRepresentation` is 64 bytes (R || S). `SecKeyCreateWithData` for RSA rejects PKCS#8 (`-50`) and accepts the inner PKCS#1 `RSAPrivateKey`; a `SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA256)` signature was byte-identical to `openssl dgst -sha256 -sign`.
- **Probe:** `X509IssuerName` and `X509SerialNumber` derived from the certificate DER in Swift (issuer RDNs in reverse order joined with `, `, OpenSSL short names, RFC 2253 escaping; serial as a decimal big integer) matched the TypeScript output for three certificates: the test subject `GN/SN/serialNumber/CN/C`; an issuer with `O=Ministerstwo Finansów & "Spółka" <x>, a+b; c\d` plus `OU/L/ST` and Polish letters; and one with `organizationIdentifier` (OID 2.5.4.97, needs an OpenSSL config file because `-subj` drops unknown OIDs).

### 5.2 XAdES canonicalization

- **Probe:** `import libxml2` works in Swift 6.4 against the macOS 27 SDK with no extra settings (the SDK ships `usr/include/libxml2/module.modulemap`), in a command-line tool and in an XCTest bundle.
- **Probe:** with a fixed RSA key, certificate, challenge `20261126-CR-0123456789-ABCDEF0123-AB`, NIP `5265877635` and signing time `2026-11-26T08:00:00Z`, a Swift program that builds every string itself ("canonical by construction": the enveloped root, the canonical `SignedProperties`, the canonical `SignedInfo`) produced output **byte-identical** to `signXades` (xml-crypto 6.4.0) for the plain and the awkward-issuer certificate. For EC the two digests and the whole document except `SignatureValue` were identical, and the TypeScript 64-byte signature verified over the Swift canonical `SignedInfo`.
- **Probe:** libxml2's `xmlC14NDocDumpMemory(…, XML_C14N_EXCLUSIVE_1_0, …)` over the TypeScript documents produced exactly the same three canonical strings as the by-construction code, for all three vectors.
- Exact canonical forms that matter: in exclusive C14N every `ds:` element inside `SignedProperties` carries its own `xmlns:ds` (the declaration sits on `ds:Signature`, outside the subset), empty elements are written as start/end pairs, the namespace declaration precedes attributes, and `Reference` attributes are sorted (`Type` before `URI`) while the serialised document keeps `URI` first. Issuer text is escaped for `&`, `<`, `>` only (xml-crypto's DOM re-serialises the TypeScript `&quot;` as `"`).

### 5.3 Formatting and JSON

- **Probe:** `FloatingPointFormatStyle<Double>.number.locale(pl_PL).precision(.fractionLength(2)).rounded(rule: .toNearestOrAwayFromZero)` matches Node's `Intl.NumberFormat('pl-PL')` for every value tried: `1230,00` (no grouping below five digits), `12 345,67` and `1 234 567,89` with U+00A0, `0,13` for 0.125, `1,01` for 1.005, `-12 345,68` with U+002D. Without the rounding rule ICU rounds half-even (`0,12`, `1,00`).
- **Probe:** `Date.ISO8601FormatStyle` parses KSeF's 7-digit fractions but keeps sub-millisecond precision in a `Double`: `…00.9999999+00:00` became the next second, where JavaScript's `Date.parse` truncates to `.999`. `ISO8601DateFormatter` with fractional seconds truncates but rejects strings without a fraction. The port therefore keeps KSeF instants as integer milliseconds with its own parser.
- **Probe:** `JSONEncoder` does not keep key order, escapes `/` unless told not to, and pretty-prints `"key" : value`; `JSON.stringify` keeps insertion order, never escapes `/`, and writes `"key": value`. Numbers matched (`123.45`, `200.5`, `1230`, `0.30000000000000004`, `1e+21`). Byte-compatible files need a small ordered JSON writer.

### 5.4 Platform

- **Doc (TN3137):** the data protection keychain builds its access groups from entitlements that "must be authorized by a provisioning profile"; an ad-hoc-signed app cannot carry a profile (DTS, forum thread 776087) and gets `errSecMissingEntitlement` (-34018). The file-based (login) keychain needs no entitlement.
- **DTS (threads 649081, 795739; TN3127):** a file-based keychain item's ACL is set to the designated requirement (DR) of the app that created it; "ad hoc signed code … has a DR but it's tied to that specific version of the code", so macOS cannot tell that a rebuilt ad-hoc app is the same app. **Probe:** an ad-hoc build's DR is `cdhash H"…"`. **Inference:** after every ad-hoc rebuild, the first Keychain read shows the "wants to use your confidential information" prompt (login password, Always Allow); a Developer ID DR (`identifier … and anchor apple generic and certificate leaf[subject.OU] = …`) stays the same across rebuilds, so no prompt. `SecItemCopyMatching` "blocks the calling thread" (Doc). DTS (thread 844097, 2026): significant file-based keychain changes since macOS 26.4, a related regression believed fixed in 27.2.
- **DTS (threads 678819, 729748):** the Documents-folder privacy prompt applies to non-sandboxed apps too, and "in order for the system to remember the answer your code must be signed with a stable signing identity"; ad hoc leads to "excessive prompts". Whether a folder picked in an open panel skips the prompt: UNCONFIRMED.
- **Doc/DTS:** macOS app extensions must be sandboxed; "if you distribute the container app directly, you have the option to sandbox it or not" (thread 798886). **Probe:** a non-sandboxed, ad-hoc-signed copy of this project's app with the unchanged sandboxed widget extension builds, passes `codesign --verify --deep --strict`, keeps the extension's entitlements exactly (sandbox + the read-only exception), and its extension is listed by `pluginkit -m -p com.apple.widgetkit-extension` (then removed with `lsregister -u`). Whether `chronod` shows it: UNCONFIRMED (the widget has never run in the real host).
- **Doc (`SMAppService`):** `SMAppService.mainApp.register()` makes the app launch at login; `status` is `.enabled`, `.requiresApproval`, `.notRegistered` or `.notFound`; `openSystemSettingsLoginItems()` opens the Login Items pane. Behaviour for ad-hoc apps and after a rebuild: UNCONFIRMED (DTS reports problems with ad-hoc helpers, thread 799910).
- **Doc (`NSBackgroundActivityScheduler`):** meant for "periodic content fetches" and "activities occurring in intervals of 10 minutes or more"; tolerance defaults to half the interval; it takes a process activity assertion while the block runs; the completion handler must be called or the activity is not rescheduled. **DTS (thread 106199):** `Timer`'s clock stops during sleep, so a timer slips by the time asleep and does not fire once at wake; re-check on `NSWorkspace.didWakeNotification`. **Doc:** App Nap throttles timers of apps without a process activity assertion.
- **Doc (`UNUserNotificationCenter`):** the first authorization request prompts, later ones do not; without `userNotificationCenter(_:willPresent:…)` a notification arriving while the app is active is not shown. Signing requirements for ad-hoc apps: UNCONFIRMED.
- **Doc ("Keeping a widget up to date"):** 40–70 refreshes a day; the containing app being in the foreground exempts reloads. **Inference:** reloads from a background agent count against the budget; one reload per hour (24 a day) fits.
- **Doc (widget links):** "the system activates the containing app and passes the URL to … `NSApplicationDelegate.application(_:open:)`". The already-running case: UNCONFIRMED; the app logs each URL it receives.
- **Probe:** a hostless macOS unit-test bundle run by `xcodebuild test` is not sandboxed (`APP_SANDBOX_CONTAINER_ID` unset), can `POST https://api-test.ksef.mf.gov.pl/v2/auth/challenge` (HTTP 200), links an XcodeGen `library.static` target with `@testable import`, and can `import libxml2`.
- **Probe:** a SwiftUI `Form` with AppKit-backed controls (text field, secure field, picker, toggle, buttons) renders to PNG offscreen through `NSHostingView` + `cacheDisplay(in:to:)` in a never-shown window; `ImageRenderer` renders the same form as a blank image.
- **Fact (TypeScript test suite):** `node --test "test/unit/**/*.test.ts"` reports 142 tests, all passing, on this branch.

## 6. Approaches considered

### 6.1 Shape: full Swift app (chosen, owner's call) vs setup window over Node vs status quo

- **Full Swift app (chosen).** One bundle, no runtime to install, native notifications and login item, the widget reload can be requested directly. Costs a rewrite of about 1,100 lines of TypeScript and a new XAdES signer, which the TypeScript code makes cheap to verify: it is the behaviour spec and the oracle.
- **Settings window over the Node fetcher (rejected).** Keeps the proven TypeScript, but the owner would still install Node and pnpm, the app would launch a third-party `node` binary that macOS attributes Keychain, Documents and notification permissions to unpredictably, and `osascript` notifications would stay. Two runtimes for one personal tool.
- **Status quo (rejected by the owner).** Works, but the terminal setup is what they asked to remove.

### 6.2 Canonicalization: by construction (chosen) vs libxml2 exclusive C14N

Both passed every vector (5.2), so the choice is about code. **By construction (chosen):** the signer controls every byte it signs (a fixed `AuthTokenRequest` and a fixed `QualifyingProperties` shape), so the canonical forms are three string templates with four escaped values; no C interop, no unsafe pointers, no XPath. The fetcher spec (6.3) rejected hand-writing exclusive canonicalization as "exactly the kind of code that is subtly wrong"; that was about a general C14N for arbitrary XML. Here nothing general is written: the only inputs are a validated challenge, a validated NIP, a formatted time, a Base64 digest, a decimal serial and the issuer text, and the tests canonicalize the Swift output independently with libxml2 and compare. **libxml2 (test-only):** an independent check that the by-construction strings are what a real canonicalizer produces, including for the awkward issuer.

### 6.3 Encrypted key: hand-written PBES2 (chosen) vs `SecItemImport`

`SecItemImport` returned "Unknown format" for the LibreSSL keys (5.1) and could not name an unsupported algorithm anyway. A DER reader of about 60 lines plus CommonCrypto PBKDF2 and AES-CBC covers PBES2 + PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384, SHA512) + AES-128/192/256-CBC. Anything else (PBES1, scrypt, DES-EDE3) fails with the OID in the message. The algorithms of the owner's real key are being requested (`openssl asn1parse -in <key> | grep OBJECT`); if they fall outside this list the loader is extended before the first production run.

### 6.4 Key storage (chosen: encrypted key file copy + password in Keychain)

- **Copies of the `.crt` and the still-encrypted `.key` in the app's own Application Support folder (mode 0600, folder 0700), key password in a Keychain item the app creates (chosen).** The key stays exactly as Aplikacja Podatnika delivered it, encrypted at rest under the owner's password; the password is the only secret in the Keychain; every run re-checks password, format and key/certificate match like the TypeScript tool; the owner can delete the picked originals.
- **Decrypted key bytes in the Keychain (rejected).** One item instead of item + file, but it removes the password layer and trades a file the owner recognises for an opaque blob; equal exposure to anyone who can read the Keychain item.
- **Keep paths to the owner's original files (rejected).** Breaks when they tidy their Downloads folder.
- The copies must not go under `~/Library/Application Support/ksef-daily-fetch/`: the widget extension can read that whole directory (ADR-0006).

### 6.5 Sandboxing the host app: not sandboxed (chosen) vs sandboxed

- **Not sandboxed (chosen).** The app needs outbound network, the snapshot path under `~/Library/Application Support/ksef-daily-fetch/`, a user-chosen invoice folder (default `~/Documents/KSeF`) and the file-based Keychain. Unsandboxed, none of these needs an entitlement, a security-scoped bookmark or a temporary exception, and the build has no entitlements file at all. Privacy protection still applies: reading or writing `~/Documents` shows the "access files in your Documents folder" prompt once per signing identity (once per rebuild for ad hoc).
- **Sandboxed (rejected).** Needs `network.client`, user-selected read-write with persisted security-scoped bookmarks for the invoice folder, and a read-write temporary exception for the snapshot directory; more moving parts for a personal tool that runs only the owner's own code. The extension stays sandboxed exactly as today (an app extension must be).

### 6.6 Scheduling: `NSBackgroundActivityScheduler` tick + wall-clock due check (chosen) vs `Timer` vs launchd

- **Chosen.** A repeating `NSBackgroundActivityScheduler` (interval 15 minutes, tolerance 5 minutes) only calls `tick()`; `tick()` starts a run when the last run (the snapshot's `updatedAt`, or this process's last finish) is an hour or more ago. The same `tick()` runs at launch and on `NSWorkspace.didWakeNotification`, which gives the catch-up after wake. Apple names this API for periodic fetches every 10+ minutes and it handles App Nap during the block; the wall-clock check makes the interval independent of how the system spreads the ticks. Every run holds a `ProcessInfo` activity (`.userInitiatedAllowingIdleSystemSleep`) so its pauses are not throttled.
- **`Timer` (rejected).** Throttled by App Nap and slips across sleep (DTS); would need the same wake handling plus an assertion.
- **launchd (rejected).** The reason for this change; also cannot reach the app's in-memory state ("one run at a time").

### 6.7 Signing: ad hoc by default, Developer ID optional (chosen)

Developer ID is **recommended, not required.** Everything works ad hoc; what Developer ID buys is a stable designated requirement, so macOS remembers the owner's answers across rebuilds: the Keychain "Always Allow", the Documents-folder permission and, probably, the login-item approval (UNCONFIRMED). Ad hoc, each rebuild costs one Keychain prompt and one Documents prompt at the next launch. The data protection keychain, which would avoid prompts altogether, needs a provisioning profile even with Developer ID (5.4), so it is not used. The orchestrator's earlier statement to the owner ("would have to be signed with their Developer ID, otherwise macOS re-asks for Keychain access after every rebuild") is right about the mechanism and wrong about "have to": it re-asks once per rebuild, not per run, and only after a rebuild.

## 7. Decisions

### 7.1 Architecture and repository layout
- (O) All logic in a Swift **library target** with no AppKit, SwiftUI, WidgetKit, UserNotifications or ServiceManagement dependency, with unit tests; the app target is a thin shell (menu-bar item, settings window, scheduler trigger, notifications, login item, widget reload, URL forwarding). Nothing important is testable only by launching the app.
- (S) The library is an XcodeGen `library.static` target `KsefCore` (`widget/Core/`), linked into the app, so nothing is embedded or signed separately; tests use `@testable import KsefCore`; the app sees only `public` declarations. Tests: `KsefCoreTests` (offline, `widget/CoreTests/`), `KsefE2ETests` (KSeF TEST, `widget/E2ETests/`), `KsefAppTests` (settings window renders, `widget/AppTests/`). The existing `widget/` directory, project name, `KsefWidgetExtension`, `SnapshotProbe`, `KsefWidgetTests` and every file they compile stay unchanged.
- (S) The app target keeps its name and bundle ID (`local.ksef-daily-fetch.KsefWidget`, so the extension's ID and all widget files stay as they are) and gets `PRODUCT_NAME: KSeF`, so the owner installs and sees `KSeF.app`. It loses `App/App.entitlements` (not sandboxed, 6.5).
- (O) No third-party Swift packages. Deployment target stays macOS 14.0 (the newest API used, `SMAppService`, needs 13).
- Decision records: ADR-0008 (one native Swift app; supersedes ADR-0001), ADR-0009 (Swift client with system crypto; supersedes ADR-0004), ADR-0010 (in-app hourly scheduler, login item and native notifications; supersedes ADR-0007), ADR-0011 (unsandboxed host app, file locations and secret storage; supersedes the host-app part of ADR-0005), ADR-0012 (ad hoc by default, optional Developer ID re-sign). ADR-0002 (certificate + XAdES), ADR-0003 (HWM sync, file state) and ADR-0006 (snapshot + read-only exception) stay accepted unchanged; the widget half of ADR-0005 stays accepted.

### 7.2 Port rules
- (O) The TypeScript code is the behaviour spec and the oracle. Same Polish texts, rules, limits and file formats; the 142 tests are ported case by case (plan, Task table); the TypeScript code stays untouched.
- (O) On-disk formats byte-compatible: `state.json`, `index.jsonl`, `invoices/YYYY/MM/<ksefNumber>.xml`, `reports/YYYY-MM-DD.md` and `widget.json`. For identical inputs the Swift code writes the same bytes as the TypeScript code; a committed golden file generated by the TypeScript code (`test/golden/make-vectors.ts`) proves it, and the Swift store reads a TypeScript-written index and checkpoint.
- (S) A data folder belongs to one NIP and environment: the app writes `identity.json` (`{"nip", "environment"}`, atomically) into it, the first time a run or a successful connection check uses the folder. Every run and every check compares it with the settings before anything else and fails with `Folder faktur zawiera dane innego podatnika lub środowiska (NIP <nip>, <environment>). Wybierz inny folder w Ustawieniach.` (the NIP and environment are the marker's); a folder without the marker is adopted. `state.json` and `index.jsonl` stay byte-identical to the TypeScript formats.
- (S) Time: KSeF instants are integer milliseconds, parsed and formatted like `Date.parse` and `toISOString()` (5.3). Amounts: the format style in 5.3. Warsaw days and times: a Gregorian calendar in `Europe/Warsaw`.
- (S) **Deliberate deviations** (texts that came from Node or from `config.json`, and checks Swift needs where TypeScript only cast):

  | TypeScript | Swift |
  |---|---|
  | `Brak połączenia z KSeF: fetch failed` | `Brak połączenia z KSeF: <URLError.localizedDescription>` (system language) |
  | `Nie można odczytać klucza prywatnego (złe hasło lub format): <OpenSSL text>` | same prefix, then `odszyfrowanie nie powiodło się` / `oczekiwano -----BEGIN ENCRYPTED PRIVATE KEY-----` / `uszkodzona struktura PKCS#8` |
  | (no equivalent) | `Nieobsługiwany algorytm szyfrowania klucza: <OID> (<name>). Obsługiwane: PBES2 z PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384, SHA512) i AES-128/192/256-CBC.` |
  | Node `X509Certificate` error text | `Nie można odczytać certyfikatu: <reason>` |
  | `config.json: nip musi mieć 10 cyfr i poprawną sumę kontrolną` | `NIP musi mieć 10 cyfr i poprawną sumę kontrolną` |
  | `config.json: startDate musi mieć format RRRR-MM-DD i nie może być z przyszłości` | `Data początkowa musi mieć format RRRR-MM-DD i nie może być z przyszłości` |
  | other `config.json: …` and `Nie można wczytać config.json: …` | `Uszkodzony plik ustawień: <detail>`; `Folder faktur musi być ścieżką bezwzględną` |
  | `Brak hasła klucza w Pęku kluczy (usługa ksef-daily-fetch, konto <NIP>)` | `Brak hasła klucza w Pęku kluczy (usługa local.ksef-daily-fetch.KsefWidget, konto key-password)` |
  | a malformed KSeF JSON answer crashed later with a `TypeError` | `Nieprawidłowa odpowiedź KSeF na <endpoint>` with a fixed endpoint name (`GET /auth/{referenceNumber}`, not the reference), so its failure key is stable |
  | a garbled `state.json` failed with Node's `SyntaxError` text | `Uszkodzony plik state.json` |
  | an `index.jsonl` line needed only a string `ksefNumber` | every field of the index entry is required; a short line fails as `Uszkodzony plik index.jsonl, linia N` |
  | an unexpected challenge string was signed as is | the challenge must match `^[0-9A-Za-z-]{1,64}$`, else `Nieoczekiwany format wyzwania KSeF` (the signer interpolates it) |

  `failureKey` stays `KSeF <status>` for API errors and the message for everything else.

### 7.3 Settings and secrets
- (O) Setup in the app only; no import of anything from the TypeScript setup.
- (S) Paths, all under the real home: app folder `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/` (mode 0700) holding `settings.json`, `ksef-auth.crt` and `ksef-auth.key` (mode 0600); snapshot `~/Library/Application Support/ksef-daily-fetch/widget.json` (unchanged); default invoice folder `~/Documents/KSeF`.
- (S) `settings.json`: `{"nip", "environment", "startDate", "dataDir", "verified"}`. `verified` is true only after a successful **Sprawdź połączenie** with the current NIP, environment and credentials; saving a change to any of those resets it. Scheduled and manual fetches run only when `verified` is true, so the new signer's first production login is the check the owner watches, with its exact error shown, not an unattended run.
- (S) Keychain: one generic-password item in the login (file-based) keychain, service `local.ksef-daily-fetch.KsefWidget`, account `key-password`, label `KSeF — hasło klucza prywatnego`; created and replaced only by **Zapisz**, read at launch and after saving (off the main thread) and kept in memory, so a Keychain prompt after a rebuild appears at launch while the owner is there, never inside an unattended run. The data protection keychain is not used (5.4).
- (S) **Zapisz** validates NIP and start date, decrypts the chosen key with the typed password and checks it against the chosen certificate (so a wrong password, a mismatched pair or an unsupported algorithm is reported in the window), then copies both files, stores the password and writes `settings.json`. A save with no new files and no password keeps the stored ones. The private key is decrypted only in memory and never logged or written.

### 7.4 Scheduling, runs and the menu
- (O) One run at a time; a manual **Pobierz teraz** during a run does not start a second. Catch-up after wake when the last run is an hour or more old. Widget link clicks handled without quitting. The widget's stale banner stays.
- (S) Trigger and due rule as 6.6. "Last run" = the later of the snapshot's `updatedAt` and this process's last run end, so a relaunch or login within the hour does not spend another authentication and metadata query. A last-run time in the future (clock moved back) counts as due.
- (O) The app refuses to fetch (scheduled and manual) while `~/Library/LaunchAgents/local.ksef-daily-fetch.plist` exists and tells the owner to run `scripts/launchagent.sh uninstall`; it re-checks at every tick, so no relaunch is needed after removal. **Sprawdź połączenie** stays allowed (no downloads).
- (O) Background app (`LSUIElement`), menu-bar item: status line, **Pobierz teraz**, **Ustawienia…**, **Otwórz folder faktur**, **Zakończ**. (S) AppKit `NSStatusItem` + `NSMenu`, settings in an `NSWindow` hosting a SwiftUI view: the app already needs an `NSApplicationDelegate` for widget URLs, and AppKit gives direct control of activating an accessory app's window (DTS notes the SwiftUI `Settings` scene may open behind other apps). On first launch without settings the settings window opens by itself.
- (S) Launch never requests a permission: notification authorization is requested by the first successful **Zapisz** and by **Wyślij testowe powiadomienie**; the Keychain and the invoice folder are touched at launch only when the app is configured.
- (S) After every non-dry run the app calls `WidgetCenter.shared.reloadTimelines(ofKind: "KsefInvoices")`. Logs go to the unified log, subsystem `local.ksef-daily-fetch.app` (English, never tokens, passwords or key material).

### 7.5 Notifications
- (O) Native `UNUserNotificationCenter` notifications replace `osascript`, with the same titles, bodies and rules: nothing for a quiet complete run, one per run otherwise, a repeated same-day failure (same `failureKey`, previous snapshot failed today) notifies once, a failed run that saved invoices always notifies. (S) The app's delegate presents notifications as banners even while its menu is open. If notifications are not authorized, the notifier throws `Powiadomienia są wyłączone`, the run logs it as it logs a failing `osascript`, and the menu shows a warning line.
- (S) **Wyślij testowe powiadomienie** replaces `--test-notification` (`KSeF: test powiadomienia` / `Powiadomienia działają.`).

### 7.6 Mapping of the TypeScript entry points
- `node src/main.ts` → scheduled and manual runs. `--dry-run` → **Sprawdź połączenie** (logs in, lists the first window, writes and notifies nothing; result or exact error in the window). `--test-notification` → **Wyślij testowe powiadomienie**. The pre-config failure path in `main.ts` → the same function in `KsefCore`, used when settings, credential files or the Keychain item cannot be read. `scripts/run-daily.sh` (Node did not start) → dropped: if the app is not running there is nothing to notify from, and the stale banner covers it. Exit codes → dropped.
- `scripts/launchagent.sh`, `scripts/run-daily.sh`, `src/`, `test/` and `package.json` stay untouched; the README documents the TypeScript fetcher as the fallback.

### 7.7 Build and signing
- (O) Implementers build ad hoc only and never touch a signing identity. The owner builds with `scripts/build-app.sh [--install] [signing-identity]`: XcodeGen, an ad-hoc Release build, then, only when an identity is given, a re-sign inside out (extension with its committed entitlements, then the app without entitlements) with that identity, `codesign --verify --deep --strict`, and the designated requirement printed so the owner can see which kind they got. The identity is a parameter because two "Developer ID Application" identities exist on the Mac; nothing about it is committed. No notarisation, no hardened runtime. `--install` quits a running copy, replaces `~/Applications/KSeF.app`, unregisters the build copy and opens the installed app.

### 7.8 Verification
- (O) First implementation task = the risk slice: key loading and XAdES in Swift against the TypeScript signer as oracle (RSA byte-identical; EC digests identical, signature verified, `SignatureValue` 64 bytes), then TEST authentication with both key types.
- (S) Golden vectors come from `test/golden/make-vectors.ts`, run with the existing Node code: it creates throwaway self-signed certificates with random NIPs, signs with `src/xades.ts`, exports keys in every supported PBES2 variant and one PBES1 key, and formats sample invoices with `src/store.ts`, `src/snapshot.ts` and `src/report.ts`. Its output is committed as JSON under `widget/CoreTests/Fixtures/`. Committing these keys is safe: they are self-signed, so KSeF PROD and DEMO reject them, and on TEST they can only act as random NIPs that anyone can create there with their own self-signed certificate. JSON files also avoid the `*.key`/`*.crt`/`*.pem` ignore rules. Tests that need fresh credentials still generate them with `/usr/bin/openssl`, as the TypeScript tests do.
- (S) TEST E2E as XCTest: two random NIPs, self-signed certificates (seller RSA, buyer EC), a test-only Swift sender (RSA-OAEP-SHA256 key wrap with `SecKeyCreateEncryptedData`, AES-256-CBC with `CCCrypt`), the real `run()` as the buyer into a temp folder, the same assertions and waits as `test/e2e/fetch.e2e.ts`.

## 8. Risks and open points

- **UNCONFIRMED — the owner's key algorithms.** Asked via `openssl asn1parse`; anything outside 6.3 fails at **Zapisz** with the OID named, before any run.
- **UNCONFIRMED — `X509IssuerName` on PROD.** The TypeScript dry run passed on PROD with Node's issuer string; the Swift string is proven identical for three test issuers but not for the MF CA issuer. Asking the owner for their certificate's issuer line (`/usr/bin/openssl x509 -in <crt> -noout -issuer -nameopt RFC2253,utf8,-esc_msb`; the issuer is the MF CA, not personal data; LibreSSL prints an attribute it does not know, such as `organizationIdentifier`, as `2.5.4.97=#<hex DER>`, which decodes by hand) lets a unit test pin it; **Sprawdź połączenie** is the live check.
- **UNCONFIRMED — ad-hoc behaviour, by inference from DTS only:** one Keychain prompt and one Documents prompt after each rebuild; login-item approval possibly lost on rebuild; notifications under ad-hoc signing. The safety rules forbid probing these (no real Keychain, no login item, no notification), so they are on the owner's first-run checklist (section 10), not the implementer's. Developer ID removes the first two.
- **UNCONFIRMED — the widget in the real widget host**, with a non-sandboxed containing app (it never ran there; the probe shows only that it builds, signs and registers).
- **UNCONFIRMED — `NSBackgroundActivityScheduler` timing** for a napping accessory app; the wall-clock rule and the wake hook bound the damage, the stale banner shows the rest. The owner checks the log after a day.
- **UNCONFIRMED — Settings window activation** for an accessory app opened from its menu.
- **File-based keychain changes since macOS 26.4** (DTS, regression said to be fixed in 27.2; the Mac runs 27.0.1). The Keychain adapter is about 40 lines behind a protocol and is exercised for the first time by the owner's **Zapisz**; its errors carry the `OSStatus` and `SecCopyErrorMessageString`.
- **iCloud Desktop & Documents.** If enabled, `~/Documents/KSeF` syncs to iCloud and files may be evicted to placeholders; reading an evicted `index.jsonl` offline would fail the run loudly. The owner can pick another folder.
- **Changing the invoice folder** starts a fresh sync from the start date in the new folder (the index there is empty); the settings window says so.
- **UNCONFIRMED — the challenge pattern** `^[0-9A-Za-z-]{1,64}$` is derived from observed TEST challenges (`20261126-CR-…`), not from a documented format. Task 4 (TEST login) is the first check; a too-tight pattern fails loudly with `Nieoczekiwany format wyzwania KSeF`.
- **Golden keys in a public repository** may raise GitHub secret-scanning alerts although they are throwaway TEST-only keys.
- Unchanged from the fetcher spec: `/auth/{referenceNumber}` sunsets 2027-06-15; PROD `invoiceHash` equality and rate-limit values remain as recorded there.

## 9. Left to the builder

- Internal type and file names beyond what the plan pins; layout and spacing of the settings window within the pinned copy (judged from the PNG renders).
- Swift 6 concurrency shape (actors, `Sendable` closures) as long as the pinned signatures hold in substance.
- Log wording beyond the pinned lines.

## 10. Only the owner can verify (first-run checklist, also in the README)

1. Build and install (`scripts/build-app.sh --install`, with or without their identity); the app appears in the menu bar and opens its settings window.
2. Pick the real `.crt` and `.key`, type the password, NIP, environment `Produkcja`, start date, keep or change the folder, press **Zapisz**: the Keychain item is created; macOS may ask for Documents access and notification permission.
3. **Wyślij testowe powiadomienie**: the banner appears.
4. **Sprawdź połączenie**: the first production login with the Swift signer; expected `Połączenie działa. …`. On failure, the exact message goes to the orchestrator.
5. Turn on **Uruchamiaj przy logowaniu**; approve in System Settings if asked; log out and in once.
6. Add the widget; after the first run it shows data; click a row: the browser opens the KSeF page and the app keeps running.
7. After a day: hourly `run finished` lines in `log show --predicate 'subsystem == "local.ksef-daily-fetch.app"'`, including one after a sleep.
8. After one rebuild: note which prompts reappeared (Keychain, Documents, login item, notifications), ad hoc or Developer ID.
9. Report the key's algorithm OIDs and the certificate's issuer line.
10. Once satisfied, confirm, so the TypeScript fetcher can be removed in a separate change.
