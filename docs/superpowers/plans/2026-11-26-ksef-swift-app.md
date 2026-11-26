# KSeF Swift App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One self-contained macOS menu-bar app, `KSeF.app`, that does everything the TypeScript fetcher does (same rules, Polish texts and files), is set up in a settings window, fetches every hour, notifies natively, and embeds the existing widget extension unchanged.

**Architecture:** A static Swift library `KsefCore` (`widget/Core/`, Foundation + Security + CryptoKit + CommonCrypto only) ports `src/` module by module, with tests ported case by case from `test/unit/` and golden vectors produced by the TypeScript code. The app target (`widget/App/`, product `KSeF.app`, not sandboxed) is a thin AppKit shell: status item and menu, a SwiftUI settings view in an `NSWindow`, an `NSBackgroundActivityScheduler` tick, `UNUserNotificationCenter`, `SMAppService`, `WidgetCenter`. Task order: risk slice (keys, XAdES, TEST login) → library ports → TEST fetch E2E → app shell → build script and docs.

**Tech Stack:** Swift 6.4 (language mode 6.0), Xcode 27.1 (`xcodebuild`), XcodeGen 2.46.0 (`/opt/homebrew/bin/xcodegen`), XCTest, Security, CryptoKit, CommonCrypto, libxml2 (tests only), AppKit, SwiftUI, WidgetKit, UserNotifications, ServiceManagement; macOS 27 on Apple Silicon, deployment target macOS 14.0. Node 22.23.4 only to run the existing TypeScript code as the oracle (`test/golden/make-vectors.ts`).

**Spec:** `docs/superpowers/specs/2026-11-26-ksef-swift-app-design.md` (read it first; section numbers below refer to it). ADRs: ADR-0008 … ADR-0012 in `ADR.md`. The TypeScript sources in `src/` and tests in `test/unit/` are the behaviour spec: when this plan says "port X", read X and reproduce its behaviour, texts and constants exactly, except for the deviations in spec 7.2.

## Global Constraints

**Safety — real credentials exist on this Mac (orchestrator's hard rules):**
- Never read, list or reference the contents of `~/.config/ksef-daily-fetch/`. Never run `security` (no `security find-*`, no `security add-*`), never call a Keychain API from code you run: `KeychainSecretStore` is never instantiated by a test or a smoke run. Never read the repository root's `config.json` of the main checkout, never run anything from the main checkout; work only in this worktree.
- Network only to `https://api-test.ksef.mf.gov.pl/v2`, only from the `KsefE2ETests` target, with self-signed test certificates and random NIPs, never during the TEST maintenance window 16:00–18:00 Europe/Warsaw (check `TZ=Europe/Warsaw date` first). The full fetch E2E at most twice an hour (TEST allows 20 metadata queries per hour). Never call DEMO or PROD.
- Never install anything into launchd, `/Applications` or `~/Applications`; never run `scripts/launchagent.sh install|uninstall`, `launchctl bootstrap|bootout`, `scripts/build-app.sh --install`. Never register a login item (`SMAppService.register()` runs only when the owner flips the toggle). Never show a real notification (tests use fake notifiers; in a launched app press no button). Never pass a signing identity or `DEVELOPMENT_TEAM`; `codesign -s -` (ad hoc) is allowed.
- Launch the built app only in Task 11's smoke step, under its conditions. After any build or test that produced `KSeF.app`, unregister it: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path to the built KSeF.app>`; `pluginkit -m -p com.apple.widgetkit-extension | grep -c ksef-daily-fetch` must print `0` before you finish a task.
- Leave untouched: `src/`, `test/` (except adding `test/golden/make-vectors.ts` in Task 1), `scripts/launchagent.sh`, `scripts/run-daily.sh`, `package.json`, `pnpm-*`, `widget/Extension/`, `widget/Shared/`, `widget/Tests/`, `widget/Probe/`, every `docs/adr/000[1-7]*` file. The TypeScript fetcher stays as the fallback; do not plan or perform its removal.

**Repository and git:**
- Work only in this worktree on branch `ksef-swift-app`. Never push, never add a remote, never touch `main`. One `git` command per shell call; commit with `git commit -F <message file>` (message file outside the worktree, e.g. in `$TMPDIR`). Every commit message ends with the attribution lines your harness provides.
- The repository is public: no real name, e-mail, NIP of the owner, Team ID, signing identity name or hash, absolute path containing a home-directory name, or names of other apps or projects on this Mac in tracked files or commit messages. Write home paths as `~/…`. Before each commit: `git grep -n "$(basename "$HOME")"` prints nothing.

**Coding guidelines (follow them in every task):**
1. Think first — state assumptions; push back if something simpler exists.
2. Simplicity — minimum code; no unrequested features, single-use abstractions, speculative flexibility, or handling for impossible cases.
3. Surgical changes — every changed line traces to the request; match existing style; don't touch adjacent code.
4. Goal-driven — every task ends in a verifiable check.
5. Comments — write code that needs none. A comment is either a directive a tool reads, or one or two lines saying what the code cannot show: why this and not the obvious alternative, a constraint, a unit, a gotcha. What the code does belongs in names and types; what changed and why belongs in the commit message; future work is one `TODO` line. A doc block carries only what the signature lacks.

**Swift and build:**
- No third-party packages, no Swift Package Manager. `SWIFT_VERSION` 6.0, deployment target macOS 14.0, both already set in `widget/project.yml`.
- `KsefCore` imports only `Foundation`, `Security`, `CryptoKit`, `CommonCrypto`. Check: `grep -rhoE "^import [A-Za-z0-9]+" widget/Core | sort -u` prints only those four.
- Every `xcodebuild` call: `-project widget/KsefWidget.xcodeproj -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build`. Regenerate after editing `project.yml`: `xcodegen generate --spec widget/project.yml --project widget`.
- Test commands (used throughout): `CORE_TESTS` = `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefCoreTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test`; `WIDGET_TESTS` = the same with `-scheme KsefWidgetTests` (must keep passing unchanged, 30 tests).
- Public API of `KsefCore`: only what the app target uses is `public`; tests use `@testable import KsefCore`.
- Errors shown to the owner conform to `LocalizedError`; `errorMessage(_ error: Error) -> String` (= `error.localizedDescription`) is the one way to turn an error into reason text.

**Copy:** Polish for every user-facing string (notifications, reports, menu, settings window, error messages that can reach them), exactly as pinned here or in `src/`; English for code, comments, docs, log lines. Seller names, invoice numbers and reasons are attacker-controlled: in SwiftUI always `Text(verbatim:)`.

## Review Focus

1. **A wrong password, a key/certificate mismatch or an unsupported key algorithm at Zapisz** must show the precise Polish message in the window and leave nothing behind: no copied file, no Keychain write, `settings.json` unchanged. Test in Task 9 (`testInstallRejectsWrongPasswordAndLeavesNothing`, `testInstallRejectsUnsupportedAlgorithm`).
2. **Relaunch or login within the hour of the last run** must not fetch again (each fetch costs an authentication and a metadata query of 20/h); a missing snapshot or one an hour old must. Test in Task 9 (`RunScheduleTests`).
3. **"Pobierz teraz" pressed during a scheduled run** must not start a second run. Test in Task 9 (`testRunGateRunsOneAtATime`).
4. **The old LaunchAgent installed, then removed** while the app runs: no fetch while the plist exists, fetches resume at the next tick without a relaunch. Test in Task 9 (`LegacyLaunchAgentTests`) and the tick wiring in Task 11.
5. **The owner's real issuer DN** (MF CA: Polish letters, `organizationIdentifier`, commas) must produce the same `X509IssuerName` as Node did, because PROD accepted the TypeScript string. Golden vectors with an awkward and an `organizationIdentifier` issuer in Task 1; byte-identical signed XML in Task 2.

---

## File structure

```
.gitignore                               # unchanged (fixtures are .json, outside the *.key/*.crt/*.pem rules)
test/golden/make-vectors.ts              # NEW (Task 1): TypeScript oracle → widget/CoreTests/Fixtures/*.json
scripts/build-app.sh                     # NEW (Task 12)
README.md, AGENTS.md                     # rewritten around the app (Task 12)
widget/
  project.yml                            # + KsefCore, KsefCoreTests (T1), KsefE2ETests (T4), app changes + KsefAppTests (T11)
  App/App.entitlements                   # DELETED (Task 11, app not sandboxed)
  App/main.swift                         # rewritten (Task 11)
  App/AppDelegate.swift, StatusMenu.swift, SettingsWindow.swift, SettingsView.swift, Notifier.swift, LoginItem.swift  # NEW (T11)
  Core/                                  # KsefCore (static library)
    DER.swift            PrivateKey.swift      Certificate.swift   Credentials.swift   (T1)
    KsefTime.swift       Xades.swift                                                  (T2)
    JSONText.swift       KsefEnvironment.swift     HTTP.swift          KsefClient.swift   (T3)
    Report.swift                                                                      (T5)
    Store.swift                                                                       (T6)
    Sync.swift                                                                        (T7)
    WidgetSnapshot.swift Run.swift                                                    (T8)
    Settings.swift       AppPaths.swift        Secrets.swift       CredentialInstall.swift  Schedule.swift  StatusLine.swift  (T9)
  CoreTests/
    Fixtures/xades-rsa.json, xades-ec.json, xades-awkward-issuer.json, xades-organization-identifier.json, keys.json, formats.json  (T1)
    Support/Fixtures.swift, TestCredentials.swift, RandomNip.swift (T1), XadesCheck.swift (T2), FakeTransport.swift (T3), FakeKsef.swift (T8)
    PrivateKeyTests.swift CertificateTests.swift CredentialsTests.swift (T1), KsefTimeTests.swift XadesTests.swift (T2),
    JSONTextTests.swift HTTPTests.swift AuthTests.swift KsefClientTests.swift (T3), ReportTests.swift (T5), StoreTests.swift (T6),
    SyncTests.swift (T7), WidgetSnapshotTests.swift RunTests.swift (T8), SettingsTests.swift CredentialInstallTests.swift
    RunScheduleTests.swift LegacyLaunchAgentTests.swift StatusLineTests.swift (T9)
  E2ETests/AuthE2ETests.swift (T4), SendInvoice.swift FetchE2ETests.swift (T10)
  AppTests/SettingsRenderTests.swift     (T11)
```

Unchanged and still building: `KsefWidgetExtension`, `SnapshotProbe`, `KsefWidgetTests`.

### Port table (142 TypeScript tests)

| TypeScript file | TS tests | Swift test file (task) | Not ported, and why |
|---|---|---|---|
| `config.test.ts` | 15 | `SettingsTests` (T9) | 4 path cases (`relative/tilde certificatePath/keyPath`): the app manages the credential paths itself; replaced by `CredentialInstallTests`. `environment` and `dataDir type` cases become `Uszkodzony plik ustawień` decode cases; `resolves dataDir` becomes "rejects a relative dataDir". |
| `credentials.test.ts` | 6 | `CredentialsTests` (T1), `SettingsTests`/`CredentialInstallTests` (T9) | `readKeyPassword calls security`: no `security` CLI; the Keychain adapter is owner-verified (spec 8). Its message test becomes `testMissingPasswordMessage` against `SecretStoreError`. |
| `xades.test.ts` | 18 | `XadesTests` (T2) | `verifies against its own certificate` (xml-crypto) becomes the libxml2 check in `XadesCheck`. |
| `http.test.ts` | 10 | `HTTPTests` (T3) | `passes a fresh timeout signal` becomes "every attempt carries `timeoutInterval == 60`" plus a session-configuration test. |
| `auth.test.ts` | 5 | `AuthTests` (T3) | — |
| `ksef.test.ts` | 3 | `KsefClientTests` (T3) | — |
| `report.test.ts` | 14 | `ReportTests` (T5) | — |
| `store.test.ts` | 11 | `StoreTests` (T6) | — |
| `sync.test.ts` | 26 | `SyncTests` (T7) | — |
| `snapshot.test.ts` | 10 | `WidgetSnapshotTests` (T8) | — |
| `run.test.ts` | 23 | `RunTests` (T8) | — |
| `notify.test.ts` | 1 | — | `osascript` argv quoting: notifications no longer go through a script; `UNMutableNotificationContent` takes plain strings. |

Each ported test keeps the TypeScript test's name in camelCase (`it('waits out a short Retry-After')` → `testWaitsOutAShortRetryAfter`) and its exact expected values.

---

### Task 1: Golden vectors, the library target and key loading (risk slice, part 1)

Spec 5.1, 6.3, 7.2, 7.8. Size: large.

**Files:**
- Create: `test/golden/make-vectors.ts`, `widget/CoreTests/Fixtures/*.json` (generated), `widget/Core/DER.swift`, `widget/Core/PrivateKey.swift`, `widget/Core/Certificate.swift`, `widget/Core/Credentials.swift`, `widget/CoreTests/Support/Fixtures.swift`, `widget/CoreTests/Support/TestCredentials.swift`, `widget/CoreTests/Support/RandomNip.swift`, `widget/CoreTests/PrivateKeyTests.swift`, `widget/CoreTests/CertificateTests.swift`, `widget/CoreTests/CredentialsTests.swift`
- Modify: `widget/project.yml`

**Interfaces:**
- Produces:
  ```swift
  // DER.swift
  struct DERElement { let tag: UInt8; let body: [UInt8]; func children() throws -> [DERElement] }
  struct DERReader { init(_ bytes: [UInt8]); var isAtEnd: Bool { get }; mutating func next() throws -> DERElement }
  func oidString(_ body: [UInt8]) -> String                 // "1.2.840.113549.1.5.13"
  func pemBody(_ text: String, label: String) -> [UInt8]?   // Base64 between -----BEGIN label----- and -----END label-----
  // PrivateKey.swift
  enum SigningKey { case rsa(SecKey); case ec(P256.Signing.PrivateKey) }
  func decryptPrivateKey(pem: String, password: String) throws -> SigningKey
  // Certificate.swift
  struct Certificate { let pem: String; let der: Data; let issuerName: String; let serialNumber: String; let publicKey: SecKey
                       init(pem: String) throws }
  // Credentials.swift
  struct Credentials { let certificate: Certificate; let key: SigningKey }
  func loadCredentials(certificateURL: URL, keyURL: URL, password: String) throws -> Credentials
  struct KsefError: LocalizedError, Equatable { let message: String }   // errorDescription == message
  public func errorMessage(_ error: Error) -> String
  // CoreTests/Support
  enum Fixtures { static func json<T: Decodable>(_ name: String, as: T.Type) throws -> T }   // reads CoreTests/Fixtures/<name> via #filePath
  struct TestCredentialFiles { let certificateURL: URL; let keyURL: URL; let password: String }
  enum TestCredentials { static func make(nip: String, keyType: KeyType, in dir: URL) throws -> TestCredentialFiles }  // enum KeyType { case rsa, ec }
  func randomNip() -> String
  ```

- [ ] **Step 1: Write the golden generator `test/golden/make-vectors.ts`**

Run as `node test/golden/make-vectors.ts <outDir>`. Node TypeScript like `src/` (erasable syntax, `.ts` imports); imports `src/credentials.ts`, `src/xades.ts`, `src/store.ts`, `src/snapshot.ts`, `src/report.ts`; uses `/usr/bin/openssl` through `execFile` exactly as `test/support/certs.ts` does; works in a `mkdtemp` directory it removes; never touches the network. It writes six files (two-space JSON, trailing newline):

1. `xades-rsa.json`, `xades-ec.json`, `xades-awkward-issuer.json`, `xades-organization-identifier.json`, each `{ "certificatePem", "keyPem", "password", "contextNip": "5265877635", "challenge": "20261126-CR-0123456789-ABCDEF0123-AB", "signingTime": "2026-11-26T08:00:00.000Z", "issuer", "serial", "signedXml" }`. `issuer` = `certificate.issuer.split('\n').reverse().join(', ')`, `serial` = `BigInt('0x' + certificate.serialNumber).toString()`, `signedXml` = `signXades(buildAuthTokenRequest(challenge, contextNip), credentials, new Date(signingTime))`. Certificates (password: 24 random hex characters; NIP: a random valid NIP):
   - rsa: `openssl req -x509 -newkey rsa:2048 … -subj "/GN=Jan/SN=Testowy/serialNumber=TINPL-<nip>/CN=Jan Testowy/C=PL"` (as `certs.ts`).
   - ec: the same with `-newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve`.
   - awkward-issuer (RSA): `-utf8 -subj "/C=PL/O=Ministerstwo Finansów & \"Spółka\" <x>, a+b; c\\\\d/OU=KSeF/L=Warszawa/ST=mazowieckie/CN=Test CA ł/serialNumber=TINPL-<nip>"` (the shell-level backslashes yield one literal `\` in the value).
   - organization-identifier (EC): `-utf8 -config <file>` with `oid_section = new_oids`, `[ new_oids ] orgId = 2.5.4.97`, `[ req ] distinguished_name = dn`, `prompt = no`, `string_mask = utf8only`, `[ dn ] C = PL`, `orgId = VATPL-5260250274`, `O = Ministerstwo Finansów`, `CN = Test CA` (`-subj` silently drops 2.5.4.97 in LibreSSL).
2. `keys.json`: `{ "certificates": { "rsa": <pem>, "ec": <pem> }, "keys": [ { "name", "certificate": "rsa"|"ec", "keyPem", "password", "expect": "ok"|"unsupported", "oid"? } ] }` with these keys, all encrypting the two base keys of the `rsa`/`ec` certificates generated for this file:
   - `libressl-sha1-aes256-rsa`, `libressl-sha1-aes256-ec`: the files `openssl req` wrote.
   - `libressl-sha1-aes128-ec`: `openssl pkcs8 -topk8 -v2 aes-128-cbc -in <ec key> -passin … -passout …`.
   - `node-sha256-aes128-rsa`, `node-sha256-aes192-ec`, `node-sha256-aes256-ec`: `createPrivateKey({key, passphrase}).export({ type: 'pkcs8', format: 'pem', cipher: 'aes-128-cbc' | 'aes-192-cbc' | 'aes-256-cbc', passphrase })` (Node writes HMAC-SHA256).
   - `pbes1-3des-ec`: `openssl pkcs8 -topk8 -v1 PBE-SHA1-3DES …`, `"expect": "unsupported"`, `"oid": "1.2.840.113549.1.12.1.3"`.
3. `formats.json`: `{ "now": "2026-11-26T13:00:39.123Z", "invoices": [InvoiceMetadata…], "indexLines": [string…], "stateJson": string, "reportFile": string, "notifications": [{ "title", "message" }…], "snapshotJson": string, "amounts": [[number, string]…] }`:
   - `invoices`: (a) `ksefNumber` `5265877635-20261120-0123456789AB-CD`, `invoiceNumber` `FV/1/2026`, `issueDate` `2026-11-20`, `permanentStorageDate` `2026-11-20T09:00:00.1234567+00:00`, seller `{ nip: '1111111111', name: 'Acme Sp. z o.o.' }`, `grossAmount` 1230, `currency` `PLN`, `invoiceHash` `UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE=`; (b) like (a) with number suffix `…-0123456789AC-CD`, `name: null`, `grossAmount` 12345.675, `currency` `EUR`, `issueDate` `2026-10-31`; (c) suffix `…-0123456789AD-CD`, seller name `Zakład "Ł/ódź" \\ <b>*x*</b>\n\ttab\u0001\u2028 ✓`, `invoiceNumber` `FV|1\n# x`, `grossAmount` -0.5.
   - `indexLines`: open a store in a temp dir with `now = () => new Date(now)`, `saveInvoice` (a), (b), (c) with any XML bytes, then the index file split after each `\n` (each element ends with `\n`).
   - `stateJson`: the file text after `writeCheckpoint('2026-11-26T07:00:00.1234567+00:00')`.
   - `reportFile`: the file text after `appendReport(dir, '2026-11-26', formatReportSection({ startedAt: new Date(now), status: 'complete', saved: [a, b, c] }, 'prod'))` then `appendReport(…, formatReportSection({ startedAt: new Date(now), status: 'failed', reason: 'Brak połączenia z KSeF: fetch failed', saved: [a] }, 'test'))`.
   - `notifications`: `formatNotification` of `{status: 'complete', saved: [a, b, c]}`, `{status: 'partial', reason: 'Limit 60 pobrań na godzinę.', saved: [a]}`, `{status: 'failed', reason: 'x'.repeat(300), saved: [a, b]}`.
   - `snapshotJson`: the file text of `writeSnapshot(path, buildSnapshot({ status: 'failed', reason: 'Uwierzytelnienie w KSeF nieudane (kod 460: Błąd)', failureKey: 'KSeF 500' }, (await readIndex(dir)).map((e) => widgetInvoice(e, 'prod')), new Date(now)))`.
   - `amounts`: `[v, formatAmount(v, 'PLN')]` for 1230, 12345.67, 1234567.891, 0.125, 1.005, 2.675, -12345.675, 0, -0.001, 10.

Run: `node test/golden/make-vectors.ts widget/CoreTests/Fixtures` then `ls widget/CoreTests/Fixtures` → the six files. Open each and check: no field empty; `xades-awkward-issuer.json` `issuer` contains `\"Spółka\"` and `\,`; `xades-organization-identifier.json` `issuer` is `CN=Test CA, O=Ministerstwo Finansów, organizationIdentifier=VATPL-5260250274, C=PL`.

- [ ] **Step 2: Add the targets to `widget/project.yml`**

```yaml
  KsefCore:
    type: library.static
    platform: macOS
    sources: [Core]
  KsefCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: CoreTests
        excludes: ["Fixtures/**"]
    dependencies:
      - target: KsefCore
```
Fixtures are read from disk via `#filePath`, not bundled. Regenerate the project.

- [ ] **Step 3: Write the failing tests**

`TestCredentials.make` ports `test/support/certs.ts` (same `openssl req` arguments, random 12-byte hex password, files `<nip>.crt`/`<nip>.key` in `dir`, `Process` with `/usr/bin/openssl`); `randomNip()` ports `test/support/nip.ts`.

`PrivateKeyTests`:
- `testDecryptsEverySupportedFixtureKey`: for every `keys.json` entry with `expect == "ok"`, `decryptPrivateKey` succeeds and gives `.rsa` for `certificate == "rsa"`, `.ec` otherwise; and `loadCredentials` with that entry's certificate (written to a temp file) succeeds (proves the key is the right one).
- `testRejectsPbes1WithItsOid`: `pbes1-3des-ec` throws `KsefError(message: "Nieobsługiwany algorytm szyfrowania klucza: 1.2.840.113549.1.12.1.3 (pbeWithSHAAnd3-KeyTripleDES-CBC). Obsługiwane: PBES2 z PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384, SHA512) i AES-128/192/256-CBC.")`.
- `testWrongPassword`: `libressl-sha1-aes256-ec` with `"wrong"` throws `Nie można odczytać klucza prywatnego (złe hasło lub format): odszyfrowanie nie powiodło się`.
- `testNotAnEncryptedKey`: PEM text `-----BEGIN PRIVATE KEY-----…` (any) throws `Nie można odczytać klucza prywatnego (złe hasło lub format): oczekiwano -----BEGIN ENCRYPTED PRIVATE KEY-----`.
- `testGarbageInsideThePem`: `-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----` throws `Nie można odczytać klucza prywatnego (złe hasło lub format): uszkodzona struktura PKCS#8`.

`CertificateTests`:
- `testIssuerAndSerialMatchNode`: for each of the four `xades-*.json`, `Certificate(pem:)` gives `issuerName == issuer` and `serialNumber == serial`.
- `testDerAndPublicKey`: `der` equals the PEM body; `SecKeyCopyExternalRepresentation(publicKey)` is non-nil.
- `testRejectsNonCertificate`: `"x"` throws `Nie można odczytać certyfikatu: oczekiwano -----BEGIN CERTIFICATE-----`.

`CredentialsTests` (port of `credentials.test.ts` `loadCredentials`, with `TestCredentials` in a temp dir):
- `testLoadsAnEncryptedRsaKeyAndItsCertificate`: key is `.rsa`; `certificate.pem` starts with `-----BEGIN CERTIFICATE-----`.
- `testLoadsAnEncryptedEcP256Key`: key is `.ec`.
- `testRejectsAWrongPassword`: message has prefix `Nie można odczytać klucza prywatnego (złe hasło lub format)`.
- `testRejectsAKeyThatDoesNotMatchTheCertificate`: RSA certificate + EC key → `Klucz prywatny nie pasuje do certyfikatu`.
- `testRejectsASmallRsaKey`: an `openssl req -x509 -newkey rsa:1024 …` pair → `Nieobsługiwany typ klucza: rsa; wymagany RSA 2048+ lub EC P-256`.

Run `CORE_TESTS` → FAIL (types missing).

- [ ] **Step 4: Implement**

- `DERReader`: definite lengths only (short form and long form up to 4 bytes); anything else or a length past the end throws (mapped by callers to the messages above).
- `decryptPrivateKey`: `pemBody(label: "ENCRYPTED PRIVATE KEY")` → `EncryptedPrivateKeyInfo { AlgorithmIdentifier, OCTET STRING }`. Supported only: algorithm `1.2.840.113549.1.5.13` (PBES2) whose KDF is `1.2.840.113549.1.5.12` (PBKDF2: salt OCTET STRING, iteration INTEGER, optional keyLength INTEGER that must equal the cipher's, optional PRF AlgorithmIdentifier, default HMAC-SHA1) and whose cipher is AES-CBC with a 16-byte IV. PRF OIDs → `CCPseudoRandomAlgorithm`: `1.2.840.113549.2.7` SHA1, `.2.8` SHA224, `.2.9` SHA256, `.2.10` SHA384, `.2.11` SHA512. Cipher OIDs → key size: `2.16.840.1.101.3.4.1.2` 16, `.1.22` 24, `.1.42` 32. `CCKeyDerivationPBKDF` then `CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding)`. Any unsupported OID (outer, KDF, PRF or cipher) → the "Nieobsługiwany algorytm szyfrowania klucza" message with that OID and its name in parentheses from a small table (`pbeWithSHAAnd3-KeyTripleDES-CBC`, `scrypt` = `1.3.6.1.4.1.11591.4.11`, `des-ede3-cbc` = `1.2.840.113549.3.7`, `hmacWithSHA1` …); unknown name → `(nieznany)`. Decrypt failure or an unparseable decrypted `PrivateKeyInfo` → `odszyfrowanie nie powiodło się`. Wipe the derived key and decrypted buffer after use (`resetBytes`/overwrite).
- `PrivateKeyInfo` algorithm `1.2.840.113549.1.1.1` → inner OCTET STRING (PKCS#1) → `SecKeyCreateWithData(kSecAttrKeyTypeRSA, kSecAttrKeyClassPrivate)`; reject `kSecAttrKeySizeInBits < 2048` with `Nieobsługiwany typ klucza: rsa; wymagany RSA 2048+ lub EC P-256`. Algorithm `1.2.840.10045.2.1` with parameter `1.2.840.10045.3.1.7` → `P256.Signing.PrivateKey(derRepresentation:)` on the whole `PrivateKeyInfo`; another curve → `Nieobsługiwany typ klucza: ec; …`; another algorithm → `Nieobsługiwany typ klucza: <oid>; …`.
- `Certificate(pem:)`: `pemBody(label: "CERTIFICATE")`, `SecCertificateCreateWithData`, `SecCertificateCopyKey`. Serial: the tbsCertificate INTEGER (after the optional `[0]` version) as an unsigned big-endian number in decimal (repeated division by 10). Issuer: the tbsCertificate issuer `Name`, RDNs in **reverse** order joined with `, `; each RDN's AVAs joined with ` + `; each AVA `<label>=<escaped value>`. Labels (OpenSSL short names): `2.5.4.3 CN`, `2.5.4.4 SN`, `2.5.4.5 serialNumber`, `2.5.4.6 C`, `2.5.4.7 L`, `2.5.4.8 ST`, `2.5.4.9 street`, `2.5.4.10 O`, `2.5.4.11 OU`, `2.5.4.12 title`, `2.5.4.42 GN`, `2.5.4.97 organizationIdentifier`, `1.2.840.113549.1.9.1 emailAddress`; any other OID in dotted form. Values: UTF8String/PrintableString/IA5String as UTF-8, BMPString as UTF-16BE, TeletexString as Latin-1. Escaping (Node prints with `ASN1_STRFLGS_ESC_2253 | ASN1_STRFLGS_ESC_CTRL | ASN1_STRFLGS_UTF8_CONVERT`), per Unicode scalar:
  ```
  , + " \ < > ;            → backslash + the character
  # or space at index 0    → backslash + the character
  space at the last index  → backslash + space
  U+0000…U+001F, U+007F    → backslash + two uppercase hex digits
  anything else            → itself (UTF-8, unescaped)
  ```
- `loadCredentials`: read both files as UTF-8, `decryptPrivateKey`, `Certificate(pem:)`, then match: the certificate public key's external representation equals the private key's public key (RSA: `SecKeyCopyPublicKey` → external representation; EC: `x963Representation`), else `Klucz prywatny nie pasuje do certyfikatu`. File read errors propagate as is.

- [ ] **Step 5: Verify**

Run `CORE_TESTS` → `** TEST SUCCEEDED **`, all tests of the three files pass. `WIDGET_TESTS` → still 30 tests, 0 failures. Import check from Global Constraints. `git status --short` lists no `widget/build` or `.xcodeproj` path.

- [ ] **Step 6: Commit**

`git add test/golden/make-vectors.ts widget/project.yml widget/Core widget/CoreTests` then commit `feat(app): key loading and golden vectors from the TypeScript signer`. In the message, state that the fixture keys are throwaway self-signed TEST keys.

---

### Task 2: XAdES signer, canonical by construction (risk slice, part 2)

Spec 5.2, 6.2. Size: medium.

**Files:**
- Create: `widget/Core/KsefTime.swift`, `widget/Core/Xades.swift`, `widget/CoreTests/Support/XadesCheck.swift`, `widget/CoreTests/KsefTimeTests.swift`, `widget/CoreTests/XadesTests.swift`

**Interfaces:**
- Consumes: `Credentials`, `Certificate`, `SigningKey`, `KsefError` (Task 1).
- Produces:
  ```swift
  enum KsefTime {
    static func millis(_ iso: String) -> Int64?        // Date.parse for ISO strings: fraction truncated to ms, Z or ±HH:MM
    static func iso(millis: Int64) -> String           // toISOString(): yyyy-MM-ddTHH:mm:ss.SSSZ, UTC
    static func iso(_ date: Date) -> String            // floor to whole milliseconds, then iso(millis:)
    static func millis(_ date: Date) -> Int64          // floor
  }
  func buildAuthTokenRequest(challenge: String, nip: String) -> String
  func signXades(challenge: String, nip: String, credentials: Credentials, signingTime: Date) throws -> String
  // CoreTests/Support/XadesCheck.swift
  func checkXades(_ signedXml: String, certificate: Certificate) throws   // libxml2: recompute both digests and verify SignatureValue; throws on any mismatch
  ```

- [ ] **Step 1: Write the failing tests**

`KsefTimeTests`:
- `testParsesKsefSevenDigitFractions`: `millis("2026-01-01T00:00:00.1234567+00:00") == 1767225600123`; `millis("2026-01-01T00:00:00.9999999+00:00") == 1767225600999` (truncation, not rounding); `millis("2026-11-16T00:00:00+00:00") == 1794787200000`; `millis("2026-01-01T00:00:00Z") == 1767225600000`; `millis("2026-01-01T01:00:00+01:00") == 1767225600000`; `millis("garbage") == nil`.
- `testFormatsLikeToISOString`: `iso(millis: 1767225600999) == "2026-01-01T00:00:00.999Z"`; `iso(Date(timeIntervalSince1970: 1767225600.9999)) == "2026-01-01T00:00:00.999Z"`.

`XadesTests` — fixture tests run for each of the four `xades-*.json` vectors (load credentials from the fixture PEMs and password, `signingTime` parsed from the fixture), structural tests for `rsa` and `ec`:
- `testBuildsTheAuthTokenRequestDocument`: `buildAuthTokenRequest(challenge: "20261126-CR-0123456789-ABCDEF0123-AB", nip: "5265877635")` equals the string in `test/unit/xades.test.ts` exactly.
- `testRsaOutputIsByteIdenticalToTypeScript`: for `xades-rsa.json` and `xades-awkward-issuer.json`, `signXades(...) == signedXml`.
- `testEcOutputMatchesTypeScriptExceptTheSignature`: for `xades-ec.json` and `xades-organization-identifier.json`, the Swift output with its `<ds:SignatureValue>…</ds:SignatureValue>` content replaced by the fixture's equals `signedXml`; the Swift `SignatureValue` decodes to 64 bytes; `checkXades(fixture.signedXml, …)` passes (the TypeScript signature verifies over the Swift-independent libxml2 canonical form) and `checkXades(swiftOutput, …)` passes.
- Ports of the per-key-type tests (rsa and ec): `testUsesTheExpectedSignatureAndCanonicalizationMethods`, `testHasExactlyTheTwoXadesReferences`, `testAppendsAnIdSignatureSignatureAsTheLastChildOfTheRoot`, `testCarriesQualifyingPropertiesTargetingTheSignatureInsideDsObject`, `testSignsOneMinuteBeforeTheGivenTime` (`2026-11-26T07:59:00.000Z` for `2026-11-26T08:00:00Z`), `testDescribesTheSigningCertificate` (CertDigest = Base64 SHA-256 of `certificate.der`; serial and issuer from `Certificate`), `testEmbedsTheCertificateInKeyInfo`, `testWritesSignatureValueAs64RawBytes` (ec only), `testVerifiesAgainstItsOwnCertificate` (`checkXades`). Use the same regular expressions as the TypeScript tests. Also run `checkXades` on a signature made with fresh `TestCredentials` for each key type.
- `testRejectsAnUnexpectedChallenge`: challenge `a<b` throws `Nieoczekiwany format wyzwania KSeF`.

Run `CORE_TESTS` → FAIL.

- [ ] **Step 2: Implement `XadesCheck` (test support, libxml2)**

`import libxml2`; parse with `xmlReadMemory`; register prefixes `ds` = `http://www.w3.org/2000/09/xmldsig#`, `xades` = `http://uri.etsi.org/01903/v1.3.2#`; canonicalize node sets with `xmlC14NDocDumpMemory(doc, nodes, Int32(XML_C14N_EXCLUSIVE_1_0.rawValue), nil, 0, &out)` for these XPath sets (probed, spec 5.2):
```
root (enveloped):  (/descendant-or-self::node() | //@* | //namespace::*)[not(ancestor-or-self::ds:Signature)]
SignedProperties:  (//xades:SignedProperties/descendant-or-self::node() | //xades:SignedProperties//@* | //xades:SignedProperties//namespace::*)
SignedInfo:        (//ds:SignedInfo/descendant-or-self::node() | //ds:SignedInfo//@* | //ds:SignedInfo//namespace::*)
```
Compare Base64 SHA-256 of the first two with the two `DigestValue`s; verify `SignatureValue` over the third with the certificate key (`SecKeyVerifySignature(.rsaSignatureMessagePKCS1v15SHA256)` for RSA, `P256.Signing.PublicKey(x963Representation:)` + `ECDSASignature(rawRepresentation:)` for EC).

- [ ] **Step 3: Implement `KsefTime` and `Xades.swift`**

`KsefTime.millis`: a hand-written parser for `yyyy-MM-ddTHH:mm:ss` + optional `.` and 1+ digits (first three used, rest ignored) + `Z` or `±HH:MM`; days from civil date arithmetic, no `DateFormatter`. `signXades`: validate the challenge against `^[0-9A-Za-z-]{1,64}$` (else `KsefError("Nieoczekiwany format wyzwania KSeF")`); the NIP is validated by settings before it gets here. Signing time = `KsefTime.iso(signingTime - 60 s)`. `issuer` text = `issuerName` with `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;` (nothing else). `certDigest` = Base64 SHA-256 of `certificate.der`; `certBase64` = Base64 of `der` (one line). `method` = `http://www.w3.org/2001/04/xmldsig-more#rsa-sha256` or `…#ecdsa-sha256`. The bytes, with `DS = http://www.w3.org/2000/09/xmldsig#`, `EXC = http://www.w3.org/2001/10/xml-exc-c14n#`, `ENV = http://www.w3.org/2000/09/xmldsig#enveloped-signature`, `SHA = http://www.w3.org/2001/04/xmlenc#sha256`, `SP = http://uri.etsi.org/01903#SignedProperties`, `XADES = http://uri.etsi.org/01903/v1.3.2#`:
```
root        = <AuthTokenRequest xmlns="http://ksef.mf.gov.pl/auth/token/2.0"><Challenge>{challenge}</Challenge><ContextIdentifier><Nip>{nip}</Nip></ContextIdentifier><SubjectIdentifierType>certificateSubject</SubjectIdentifierType>
digest1     = b64(sha256(root + "</AuthTokenRequest>"))

props(c)    = {c ? <xades:SignedProperties xmlns:xades="XADES" Id="SignedProperties"> : <xades:SignedProperties Id="SignedProperties">}
              <xades:SignedSignatureProperties><xades:SigningTime>{time}</xades:SigningTime><xades:SigningCertificate><xades:Cert><xades:CertDigest>
              {c ? <ds:DigestMethod xmlns:ds="DS" Algorithm="SHA"></ds:DigestMethod> : <ds:DigestMethod Algorithm="SHA"/>}
              <ds:DigestValue{c ? ' xmlns:ds="DS"'}>{certDigest}</ds:DigestValue></xades:CertDigest><xades:IssuerSerial>
              <ds:X509IssuerName{c ? ' xmlns:ds="DS"'}>{issuer}</ds:X509IssuerName><ds:X509SerialNumber{c ? ' xmlns:ds="DS"'}>{serial}</ds:X509SerialNumber>
              </xades:IssuerSerial></xades:Cert></xades:SigningCertificate></xades:SignedSignatureProperties></xades:SignedProperties>
digest2     = b64(sha256(props(canonical: true)))

info(c)     = {c ? <ds:SignedInfo xmlns:ds="DS"> : <ds:SignedInfo>}
              E(CanonicalizationMethod, Algorithm=EXC) E(SignatureMethod, Algorithm={method})
              <ds:Reference URI=""><ds:Transforms>E(Transform, Algorithm=ENV)E(Transform, Algorithm=EXC)</ds:Transforms>E(DigestMethod, Algorithm=SHA)<ds:DigestValue>{digest1}</ds:DigestValue></ds:Reference>
              {c ? <ds:Reference Type="SP" URI="#SignedProperties"> : <ds:Reference URI="#SignedProperties" Type="SP">}<ds:Transforms>E(Transform, Algorithm=EXC)</ds:Transforms>E(DigestMethod, Algorithm=SHA)<ds:DigestValue>{digest2}</ds:DigestValue></ds:Reference></ds:SignedInfo>
              where E(n, a) = c ? <ds:n a></ds:n> : <ds:n a/>
signature   = RSA: SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA256, utf8(info(true)));  EC: P256 signature(for: utf8(info(true))).rawRepresentation

output      = <?xml version="1.0" encoding="utf-8"?> + root
              + <ds:Signature Id="Signature" xmlns:ds="DS"> + info(false) + <ds:SignatureValue>{b64(signature)}</ds:SignatureValue>
              + <ds:KeyInfo><ds:X509Data><ds:X509Certificate>{certBase64}</ds:X509Certificate></ds:X509Data></ds:KeyInfo>
              + <ds:Object><xades:QualifyingProperties xmlns:xades="XADES" Target="#Signature"> + props(false) + </xades:QualifyingProperties></ds:Object>
              + </ds:Signature></AuthTokenRequest>
```
(Line breaks above are for reading only; the output has none.) One short comment in `Xades.swift` says why by construction is safe here (fixed document, validated or escaped values, libxml2 cross-check in tests).

- [ ] **Step 4: Verify** `CORE_TESTS` → `** TEST SUCCEEDED **`. If `testRsaOutputIsByteIdenticalToTypeScript` fails, diff the two strings and fix the template; do not loosen the test.

- [ ] **Step 5: Commit** `git add widget/Core widget/CoreTests` → `feat(app): XAdES signer byte-identical to the TypeScript signer`.

---

### Task 3: JSON writer, HTTP layer and KSeF client

Spec 5.3, 7.2. Size: medium.

**Files:**
- Create: `widget/Core/JSONText.swift`, `widget/Core/KsefEnvironment.swift`, `widget/Core/HTTP.swift`, `widget/Core/KsefClient.swift`, `widget/CoreTests/Support/FakeTransport.swift`, `widget/CoreTests/JSONTextTests.swift`, `widget/CoreTests/HTTPTests.swift`, `widget/CoreTests/AuthTests.swift`, `widget/CoreTests/KsefClientTests.swift`

**Interfaces:**
- Consumes: `signXades`, `buildAuthTokenRequest`, `Credentials`, `KsefTime`, `KsefError` (Tasks 1–2).
- Produces:
  ```swift
  enum JSONValue: Equatable { case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([(String, JSONValue)]) }
  extension JSONValue { func compact() -> String; func pretty() -> String }   // JSON.stringify(x) and JSON.stringify(x, null, 2)
  public enum KsefEnvironment: String, Codable, CaseIterable, Sendable { case test, demo, prod; var apiBase: String; var qrBase: String }  // values from src/environments.ts
  public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
  public struct URLSessionTransport: HTTPTransport { public init() }
  struct KsefApiError: LocalizedError { let status: Int; let method: String; let path: String; let body: String }
  struct RateLimitError: LocalizedError { let retryAfterSeconds: Int }
  struct KsefHTTP: Sendable {
    init(apiBase: String, transport: HTTPTransport, sleep: @escaping @Sendable (Int) async -> Void)   // sleep in milliseconds
    func send(_ method: String, _ path: String, token: String? = nil, json: JSONValue? = nil, xml: String? = nil,
              accept: String = "application/json") async throws -> Data
  }
  func decodeKsef<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T
  struct AccessToken: Equatable, Sendable { let token: String; let validUntil: String }
  struct Seller: Codable, Equatable, Sendable { let nip: String; let name: String? }
  struct InvoiceMetadata: Codable, Equatable, Sendable { ksefNumber, invoiceNumber, issueDate, permanentStorageDate: String; seller: Seller; grossAmount: Double; currency, invoiceHash: String }
  struct MetadataPage: Decodable, Equatable { let hasMore: Bool; let isTruncated: Bool; let permanentStorageHwmDate: String?; let invoices: [InvoiceMetadata] }
  struct Window: Equatable, Sendable { let from: String; let to: String? }
  let pageSize = 250    // the TypeScript constants keep their values under lowerCamelCase names
  func authenticate(http: KsefHTTP, credentials: Credentials, nip: String, environment: KsefEnvironment, now: @Sendable () -> Date,
                    sleep: @Sendable (Int) async -> Void) async throws -> AccessToken
  func queryMetadata(http: KsefHTTP, token: String, window: Window, pageOffset: Int) async throws -> MetadataPage
  func downloadInvoice(http: KsefHTTP, token: String, ksefNumber: String) async throws -> Data
  // CoreTests/Support/FakeTransport.swift
  actor FakeTransport: HTTPTransport  // answers by "METHOD path?query" with a single answer, a queue or a closure; records method, path, headers, body, timeoutInterval
  ```

Rules: port `src/http.ts` and `src/ksef.ts` exactly (constants 120 s, 3, 3, 30 000 ms, 60 s, default 60 s, unparseable 3600 s, 300-character excerpt; `Retry-After` must match `^\d+$` after trimming; status polling every 1000 ms, at most 120 polls; `?verifyCertificateChain=false` only for `test`; the TypeScript `Uwierzytelnienie w KSeF …` messages). Messages: `KsefApiError` → `KSeF odpowiedział <status> na <method> <path>: <body prefix of 300 Characters>`; `RateLimitError` → `Limit zapytań KSeF — trzeba odczekać <n> s.`; a transport error after the retries → `KsefError("Brak połączenia z KSeF: " + error.localizedDescription)`. `decodeKsef` failure → `KsefError("Nieprawidłowa odpowiedź KSeF na <endpoint>")` with the fixed endpoints `POST /auth/challenge`, `POST /auth/xades-signature`, `GET /auth/{referenceNumber}`, `POST /auth/token/redeem`, `POST /invoices/query/metadata`. Request headers: `Accept`, `Authorization: Bearer <token>`, `Content-Type: application/json` or `application/xml`; JSON bodies via `JSONValue.compact()`; `timeoutInterval = 60` on every request. `URLSessionTransport` uses an ephemeral configuration with `timeoutIntervalForRequest = 60`, `timeoutIntervalForResource = 60` (a total limit like `AbortSignal.timeout`), `urlCache = nil`, `httpCookieStorage = nil`, `waitsForConnectivity = false`. The signing time passed to `signXades` is `now()`.

`JSONValue`: object keys in the given order; strings escaped like `JSON.stringify`: `"` → `\"`, `\` → `\\`, U+0008 `\b`, U+000C `\f`, U+000A `\n`, U+000D `\r`, U+0009 `\t`, other U+0000…U+001F → `\u00xx` (lowercase hex), everything else literal (including `/`, U+2028, non-ASCII). Numbers: integral and `abs < 1e21` → integer digits (`-0` → `0`); otherwise `Double.description`. `pretty()`: two-space indent, `"key": value`, `[]` and `{}` for empty containers, as `JSON.stringify(x, null, 2)`.

- [ ] **Step 1: Write the failing tests**
- `JSONTextTests`: `testEscapesLikeJsonStringify` (`JSONValue.string("a\"b\\c/d\u{1}\n\t\u{8}\u{c}\rł\u{2028}").compact()` equals `"\"a\\\"b\\\\c/d\\u0001\\n\\t\\b\\f\\rł\u{2028}\""` as a Swift literal: U+2028 stays unescaped, `/` is not escaped); `testNumbersLikeJavaScript` (1230 → `1230`, 200.5 → `200.5`, 0.1+0.2 → `0.30000000000000004`, 1e21 → `1e+21`, -0.0 → `0`); `testPrettyLikeStringifyWithTwoSpaces` (`{"a":1,"b":[],"c":[{"d":null}]}` pretty equals the Node output `{\n  "a": 1,\n  "b": [],\n  "c": [\n    {\n      "d": null\n    }\n  ]\n}`).
- `HTTPTests`: the 10 tests of `http.test.ts` with `FakeTransport` and a recording `sleep`; the network-error steps throw `URLError(.notConnectedToInternet)`, and the "fails after the network retries are used up" assertion is `message.hasPrefix("Brak połączenia z KSeF: ")`. The timeout test asserts every recorded request has `timeoutInterval == 60`; add `testSessionTimeouts` (the `URLSessionTransport`'s configuration has both timeouts 60 and no cache or cookie storage; expose it as an internal `configuration` property).
- `AuthTests`: the 5 tests of `auth.test.ts` with the same fake answers and expected messages (credentials from `TestCredentials`, RSA).
- `KsefClientTests`: the 3 tests of `ksef.test.ts`; body equality by parsing both sides with `JSONSerialization`. Add `testMalformedAnswerNamesTheEndpoint`: a metadata answer `{"hasMore":true}` throws `Nieprawidłowa odpowiedź KSeF na POST /invoices/query/metadata`.

Run `CORE_TESTS` → FAIL.

- [ ] **Step 2: Implement** per the rules above. **Step 3: Verify** `CORE_TESTS` → pass.

- [ ] **Step 4: Commit** `git add widget/Core widget/CoreTests` → `feat(app): KSeF HTTP client with the TypeScript retry rules`.

---

### Task 4: XAdES login on KSeF TEST (risk slice, part 3)

Spec 7.8. Size: small. Network: TEST only, mind the maintenance window.

**Files:**
- Create: `widget/E2ETests/AuthE2ETests.swift`
- Modify: `widget/project.yml`

**Interfaces:**
- Consumes: `authenticate`, `KsefHTTP`, `URLSessionTransport`, `loadCredentials`, `KsefEnvironment.test` (Task 3), `TestCredentials`, `randomNip` (Task 1).

- [ ] **Step 1: Add the target**

```yaml
  KsefE2ETests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - E2ETests
      - CoreTests/Support/TestCredentials.swift
      - CoreTests/Support/RandomNip.swift
    dependencies:
      - target: KsefCore
```

- [ ] **Step 2: Write `AuthE2ETests`** — port of `test/e2e/auth.e2e.ts`: `testAuthenticatesARandomNipWithASelfSignedRsaCertificate` and `…Ec…`: fresh NIP and credentials in a temp dir, `@testable import KsefCore` (tests build Debug, which has testability); `authenticate(http: KsefHTTP(apiBase: KsefEnvironment.test.apiBase, transport: URLSessionTransport(), sleep: <Task.sleep>), …, environment: .test, now: { Date() }, …)`; assert a non-empty token and `KsefTime.millis(validUntil)! > now`.

- [ ] **Step 3: Run once**

Run: `TZ=Europe/Warsaw date` (not 16:00–18:00), then `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefE2ETests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test -only-testing:KsefE2ETests/AuthE2ETests`
Expected: `** TEST SUCCEEDED **`, 2 tests. A KSeF rejection (`Uwierzytelnienie w KSeF nieudane (kod 4xx …)`) means the signer is wrong: stop and report the message and both signed documents; do not continue to Task 5.

- [ ] **Step 4: Commit** `git add widget/project.yml widget/E2ETests` → `test(app): XAdES login on KSeF TEST with RSA and EC`; put the test output summary line in the message.

---

### Task 5: Report and notification text

Port `src/report.ts`. Size: small.

**Files:**
- Create: `widget/Core/Report.swift`, `widget/CoreTests/ReportTests.swift`

**Interfaces:**
- Consumes: `InvoiceMetadata`, `KsefEnvironment`, `KsefTime` (Tasks 2–3).
- Produces:
  ```swift
  public enum RunStatus: String, Codable, Sendable { case complete, partial, failed }
  public struct RunSummary: Sendable { public let startedAt: Date; public let status: RunStatus; public let reason: String?
                                        public let failureKey: String?; public let saved: [InvoiceMetadata]; public let checked: DryRunCounts? }
  public struct DryRunCounts: Equatable, Sendable { public let listed: Int; public let notSaved: Int }
  func formatAmount(_ amount: Double, _ currency: String) -> String
  func invoiceViewUrl(_ environment: KsefEnvironment, sellerNip: String, issueDate: String, invoiceHash: String) -> String
  public func invoiceCountLabel(_ n: Int) -> String
  func escapeMarkdown(_ text: String) -> String
  func warsawDay(_ date: Date) -> String                 // yyyy-MM-dd
  func warsawTime(_ date: Date) -> String                // HH:mm:ss
  func sellerLabel(_ seller: Seller) -> String
  func formatReportSection(_ summary: RunSummary, _ environment: KsefEnvironment) -> String
  func formatNotification(_ summary: RunSummary) -> (title: String, message: String)?
  ```
  `formatAmount` = `amount.formatted(.number.locale(Locale(identifier: "pl_PL")).precision(.fractionLength(2)).rounded(rule: .toNearestOrAwayFromZero)) + " " + currency` (spec 5.3). Warsaw functions use a Gregorian `Calendar` with `TimeZone(identifier: "Europe/Warsaw")` and zero-padded components (no shared mutable formatter). The 240-character truncation counts Characters.

- [ ] **Step 1: Failing tests** — the 14 tests of `report.test.ts` with identical expected strings (`NBSP` = `"\u{00A0}"`), plus `testMatchesTheTypeScriptGoldenFormats`: every `formats.json` `amounts` pair; `formatNotification` of the three summaries listed in Task 1 equals `notifications`; the report file text built as in Task 1 (header `# Faktury z KSeF — 2026-11-26\n\n` + section + `\n` + second section + `\n`) equals `reportFile`.
- [ ] **Step 2: Implement.** **Step 3:** `CORE_TESTS` → pass.
- [ ] **Step 4: Commit** `git add widget/Core widget/CoreTests` → `feat(app): report and notification text`.

---

### Task 6: File store

Port `src/store.ts`. Size: small.

**Files:**
- Create: `widget/Core/Store.swift`, `widget/CoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `InvoiceMetadata`, `JSONValue`, `KsefTime`, `KsefError` (Tasks 1–3).
- Produces:
  ```swift
  struct IndexEntry: Codable, Equatable, Sendable { ksefNumber, invoiceNumber, issueDate, sellerNip: String; sellerName: String?; grossAmount: Double
                                                   currency, permanentStorageDate, invoiceHash, file, savedAt: String }  // all keys required; sellerName may be null
  func readIndex(dataDir: URL) throws -> [IndexEntry]           // missing file → []
  func writeAtomic(_ data: Data, to url: URL) throws            // creates parent folders; Data.write(options: .atomic)
  func appendReport(dataDir: URL, day: String, section: String) throws
  final class Store {                                            // used by one run at a time
    static func open(dataDir: URL, now: @escaping @Sendable () -> Date) throws -> Store
    var checkpoint: String? { get }
    func has(_ ksefNumber: String) -> Bool
    func savedSince(_ instant: Date) -> Int
    func saveInvoice(_ invoice: InvoiceMetadata, xml: Data) throws
    func writeCheckpoint(_ value: String) throws
  }
  ```
  Index line = `JSONValue.object` in the TypeScript key order (`ksefNumber, invoiceNumber, issueDate, sellerNip, sellerName, grossAmount, currency, permanentStorageDate, invoiceHash, file, savedAt`) `.compact() + "\n"`, appended (create the file if missing). `state.json` = `{"checkpoint":"<value>"}\n`; a missing, unparseable or non-string checkpoint → `KsefError("Uszkodzony plik state.json")`. A line that does not decode as `IndexEntry` → `Uszkodzony plik index.jsonl, linia N` (1-based). `savedSince` compares `KsefTime.millis(savedAt)` with the instant's milliseconds (`>`). `appendReport` creates `reports/<day>.md` with `Data.write(options: .withoutOverwriting)` and header `# Faktury z KSeF — <day>\n\n<section>\n`, and on "file exists" appends `<section>\n`.

- [ ] **Step 1: Failing tests** — the 11 tests of `store.test.ts` (the corrupt-index tests write a **complete** valid first line, taken from `formats.json` `indexLines[0]`, then `{"ksefNumber":`, and still expect `linia 2`; spec 7.2 deviation), plus:
  - `testWritesTheTypeScriptBytes`: a store in a temp dir with `now` = `formats.json` `now` saves invoices (a), (b), (c) → the index file equals `indexLines.joined()`; `writeCheckpoint("2026-11-26T07:00:00.1234567+00:00")` → `state.json` equals `stateJson`.
  - `testReadsATypeScriptDataFolder`: write `indexLines` and `stateJson` into a temp folder → `Store.open` gives that checkpoint, `has` true for the three numbers, `readIndex` returns three entries with `sellerName == nil` for (b).
  - `testAShortIndexLineFailsLoudly`: `{"ksefNumber":"x"}\n` → `Uszkodzony plik index.jsonl, linia 1`.
- [ ] **Step 2: Implement.** **Step 3:** `CORE_TESTS` → pass.
- [ ] **Step 4: Commit** `git add widget/Core widget/CoreTests` → `feat(app): file store compatible with the TypeScript data folder`.

---

### Task 7: HWM sync engine

Port `src/sync.ts`. Size: medium.

**Files:**
- Create: `widget/Core/Sync.swift`, `widget/CoreTests/SyncTests.swift`

**Interfaces:**
- Consumes: `Window`, `MetadataPage`, `InvoiceMetadata`, `KsefApiError`, `RateLimitError` (Task 3), `Store` (Task 6), `KsefTime`.
- Produces:
  ```swift
  typealias Query = @Sendable (Window, Int) async throws -> MetadataPage
  func nextWindow(from: String, now: Date) -> Window
  func listWindow(_ query: Query, _ window: Window) async throws -> (invoices: [InvoiceMetadata], hwm: String?)
  protocol SyncStore: AnyObject { func has(_: String) -> Bool; func savedSince(_: Date) -> Int
                                  func saveInvoice(_: InvoiceMetadata, xml: Data) throws; func writeCheckpoint(_: String) throws }  // Store conforms
  struct SyncDeps { let from: String; let store: SyncStore; let query: Query; let download: @Sendable (String) async throws -> Data
                    let tokenValidUntil: String; let now: @Sendable () -> Date; let sleep: @Sendable (Int) async -> Void; let onSaved: (InvoiceMetadata) -> Void }
  enum SyncOutcome: Equatable { case complete; case partial(String) }
  func syncInvoices(_ deps: SyncDeps) async throws -> SyncOutcome
  let ksefNumberPattern: Regex<…>   // the pattern of src/sync.ts, whole-match
  ```
  Constants and messages exactly as `src/sync.ts` (90 days, 60 per rolling hour, 4000 ms, 60 000 ms token margin, `21183` in the body of a 400, all Polish messages). Instants as `KsefTime` milliseconds: `nextWindow` closes the window at `millis(from) + 90 days` formatted with `KsefTime.iso(millis:)` when that is before `now`; an unparseable `from` gives an open window (as `NaN` does in JavaScript). The HWM-versus-`to` comparison uses `millis`. Error messages that quote a value use the JavaScript `JSON.stringify(value).slice(0, 60)` form: `JSONValue.string(value).compact()` cut to 60 Characters.

- [ ] **Step 1: Failing tests** — the 26 tests of `sync.test.ts` with the same fixtures, fake store, fake clock (`sleep` advances it) and expected values. Add `testClosesTheWindowWithMillisecondTruncation`: `nextWindow(from: "2026-01-01T00:00:00.9999999+00:00", now: 2026-11-26T08:00:00Z)` → `to == "2026-04-01T00:00:00.999Z"`.
- [ ] **Step 2: Implement.** **Step 3:** `CORE_TESTS` → pass.
- [ ] **Step 4: Commit** `git add widget/Core widget/CoreTests` → `feat(app): incremental sync by permanent-storage HWM`.

---

### Task 8: Widget snapshot, run orchestration and the setup-failure path

Port `src/snapshot.ts`, `src/run.ts` and the pre-config path of `src/main.ts`. Size: large.

**Files:**
- Create: `widget/Core/WidgetSnapshot.swift`, `widget/Core/Run.swift`, `widget/Core/Settings.swift` (the struct only; Task 9 adds validation and the file), `widget/CoreTests/Support/FakeKsef.swift`, `widget/CoreTests/WidgetSnapshotTests.swift`, `widget/CoreTests/RunTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces:
  ```swift
  public struct Settings: Codable, Equatable, Sendable { public var nip: String; public var environment: KsefEnvironment
                                                         public var startDate: String; public var dataDir: String; public var verified: Bool }
  struct WidgetInvoice: Equatable { ksefNumber, seller, invoiceNumber, amount, issueDate, savedAt, viewUrl: String }
  struct WidgetSnapshot: Equatable { updatedAt: String; status: RunStatus; reason: String?; failureKey: String?; today: String; savedToday: Int; invoices: [WidgetInvoice] }
  let snapshotInvoices = 8
  func widgetInvoice(_ entry: IndexEntry, _ environment: KsefEnvironment) -> WidgetInvoice
  func buildSnapshot(status: RunStatus, reason: String?, failureKey: String?, invoices: [WidgetInvoice], now: Date) -> WidgetSnapshot
  func writeSnapshot(_ snapshot: WidgetSnapshot, to url: URL) throws        // pretty() + "\n", key order of src/snapshot.ts, absent keys omitted
  func readPreviousFailure(_ url: URL) -> (failureKey: String, today: String)?
  public struct RunOptions: Sendable {
    public var settings: Settings; public var certificateURL: URL; public var keyURL: URL; public var keyPassword: String
    public var transport: HTTPTransport; public var sleep: @Sendable (Int) async -> Void; public var now: @Sendable () -> Date
    public var notify: @Sendable (String, String) async throws -> Void; public var log: @Sendable (String) -> Void
    public var snapshotURL: URL; public var dryRun: Bool
    public init(…all of the above, dryRun: Bool = false)
  }
  public func run(_ options: RunOptions) async -> RunSummary
  public func reportSetupFailure(_ message: String, snapshotURL: URL, now: Date,
                                 notify: @Sendable (String, String) async throws -> Void, log: @Sendable (String) -> Void) async
  // CoreTests/Support/FakeKsef.swift — port of test/support/fake-ksef.ts (fakeInvoice(n), FakeKsefOptions, a transport answering the same endpoints)
  ```
  `run` follows `src/run.ts` line by line: credentials from the two URLs and `keyPassword`; `Store.open(dataDir: URL(fileURLWithPath: settings.dataDir))`; `from = checkpoint ?? "<startDate>T00:00:00Z"`; dry run lists the first window, logs `dry run: <n> invoices in the first window, <m> not yet saved` and returns `.complete` with `checked = DryRunCounts(listed:notSaved:)`, writing and notifying nothing; `failureKey` = `KSeF <status>` for `KsefApiError`, else the message; repeated-failure check before the report; report, notification (failures logged as `could not show the notification: …`), snapshot (`could not read the index for the widget: …`, `could not write the widget snapshot: …`), final log line `status=<s> saved=<n>[ reason=<r>]`. `reportSetupFailure` is the `catch` block of `src/main.ts` (non-dry branch): repeated-failure check against `snapshotURL`, notification `KSeF: błąd pobierania faktur` / message unless repeated (`repeated failure, notification skipped` logged instead), failed snapshot with `reason = failureKey = message` and an empty list.

- [ ] **Step 1: Failing tests**
  - `WidgetSnapshotTests`: the 10 tests of `snapshot.test.ts`; "writes pretty JSON atomically" compares with `pretty() + "\n"` of the same object and lists the folder; plus `testWritesTheTypeScriptBytes`: index from `formats.json` `indexLines` → `buildSnapshot(status: .failed, reason: "Uwierzytelnienie w KSeF nieudane (kod 460: Błąd)", failureKey: "KSeF 500", invoices: …, now: formats.now)` written → file text equals `snapshotJson`; and `testTheWidgetCanReadIt`: parse the written file with `JSONSerialization` and assert what `widget/Shared/Snapshot.swift` decodes: `updatedAt` parses with `Date.ISO8601FormatStyle(includingFractionalSeconds: true)`, `status` is one of the three values, `reason` and `today` are strings, `savedToday` an integer, and every invoice has string `ksefNumber`, `seller`, `amount`, `issueDate`, `viewUrl`.
  - `RunTests`: the 23 tests of `run.test.ts` with `FakeKsef`, a temp root, RSA `TestCredentials`, `START = 2026-11-26T07:00:00Z`, `HWM = 2026-11-26T06:59:00.1234567+00:00`, recording notifier and log, clock advanced by `sleep`. In "an offline Mac fails after retries" the transport throws `URLError(.notConnectedToInternet)`; assert `sleeps == [30000, 30000, 30000]`, `reason` has prefix `Brak połączenia z KSeF: ` and the notification message equals `reason`. In "survives a failing notifier" the notifier throws `KsefError("Powiadomienia są wyłączone")` and a log line contains it. Add:
    - `testADryRunReportsTheCounts`: two invoices → `checked == DryRunCounts(listed: 2, notSaved: 2)`.
    - `testSetupFailureNotifiesAndWritesAFailedSnapshot`: `reportSetupFailure("Brak hasła klucza w Pęku kluczy (usługa local.ksef-daily-fetch.KsefWidget, konto key-password)", …)` → one notification with title `KSeF: błąd pobierania faktur`; snapshot `status == "failed"`, `failureKey == reason`, `invoices == []`.
    - `testARepeatedSetupFailureNotifiesOnce`: twice on the same Warsaw day → one notification, log contains `repeated failure, notification skipped`.
- [ ] **Step 2: Implement.** **Step 3:** `CORE_TESTS` → pass.
- [ ] **Step 4: Commit** `git add widget/Core widget/CoreTests` → `feat(app): run orchestration, widget snapshot and setup-failure path`.

---

### Task 9: Settings, secrets, credential install, schedule and menu status

New logic for the app, all in `KsefCore` so it is testable (spec 7.3, 7.4). Size: medium.

**Files:**
- Modify: `widget/Core/Settings.swift` (from Task 8)
- Create: `widget/Core/AppPaths.swift`, `widget/Core/Secrets.swift`, `widget/Core/CredentialInstall.swift`, `widget/Core/Schedule.swift`, `widget/Core/StatusLine.swift`, `widget/CoreTests/SettingsTests.swift`, `widget/CoreTests/CredentialInstallTests.swift`, `widget/CoreTests/RunScheduleTests.swift`, `widget/CoreTests/LegacyLaunchAgentTests.swift`, `widget/CoreTests/StatusLineTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public func isValidNip(_ nip: String) -> Bool                                    // port of src/config.ts
  extension Settings { public func validate(today: Date) throws }                  // NIP, startDate, absolute dataDir
  public enum SettingsFile { public static func load(_ url: URL) throws -> Settings?   // nil when the file is missing
                             public static func save(_ settings: Settings, to url: URL) throws }   // folder 0700, file 0600, atomic
  public struct AppPaths: Sendable {
    public init(home: URL); public static var current: AppPaths   // home = FileManager.default.homeDirectoryForCurrentUser (app is not sandboxed)
    public let appFolder, settings, certificate, key, snapshot, defaultDataDir, legacyLaunchAgent: URL
  }
  public protocol SecretStore: Sendable { func readKeyPassword() throws -> String; func saveKeyPassword(_ password: String) throws }
  public struct KeychainSecretStore: SecretStore { public init() }                 // never instantiated in tests
  public func installCredentials(certificate: URL, key: URL, password: String, paths: AppPaths, secrets: SecretStore) throws
  public enum RunSchedule { public static let interval: TimeInterval = 3600
                            public static func isDue(lastRunAt: Date?, now: Date) -> Bool
                            public static func lastRunAt(snapshot: URL, lastRunEnd: Date?) -> Date? }
  public actor RunGate { public init(); public private(set) var isRunning: Bool
                         public func runIfIdle(_ body: @Sendable () async -> RunSummary) async -> RunSummary? }
  public enum LegacyLaunchAgent { public static func isInstalled(_ paths: AppPaths) -> Bool }
  public struct SnapshotStatus: Equatable, Sendable { public let updatedAt: Date; public let status: RunStatus; public let reason: String? }
  public func readSnapshotStatus(_ url: URL) -> SnapshotStatus?
  public enum MenuState: Equatable, Sendable { case running, legacyAgent, notConfigured, notVerified, idle(SnapshotStatus?) }
  public func menuStatusLine(_ state: MenuState) -> String
  ```
  Paths (spec 7.3): `appFolder` = `home/Library/Application Support/local.ksef-daily-fetch.KsefWidget`, `settings` = `appFolder/settings.json`, `certificate` = `appFolder/ksef-auth.crt`, `key` = `appFolder/ksef-auth.key`, `snapshot` = `home/Library/Application Support/ksef-daily-fetch/widget.json`, `defaultDataDir` = `home/Documents/KSeF`, `legacyLaunchAgent` = `home/Library/LaunchAgents/local.ksef-daily-fetch.plist`.

  Messages: `NIP musi mieć 10 cyfr i poprawną sumę kontrolną`; `Data początkowa musi mieć format RRRR-MM-DD i nie może być z przyszłości` (same check as `isValidStartDate` in `src/config.ts`, comparing UTC dates); `Folder faktur musi być ścieżką bezwzględną`; a `settings.json` that does not decode → `Uszkodzony plik ustawień: <DecodingError localizedDescription>`; a decoded file that fails `validate` → `Uszkodzony plik ustawień: <validate message>`.

  `KeychainSecretStore`: generic password, `kSecAttrService` `local.ksef-daily-fetch.KsefWidget`, `kSecAttrAccount` `key-password`, `kSecAttrLabel` `KSeF — hasło klucza prywatnego`, no `kSecUseDataProtectionKeychain`. Save = `SecItemUpdate`, on `errSecItemNotFound` `SecItemAdd`. Read: `errSecItemNotFound` → `KsefError("Brak hasła klucza w Pęku kluczy (usługa local.ksef-daily-fetch.KsefWidget, konto key-password)")`; any other status → `KsefError("Pęk kluczy: <SecCopyErrorMessageString> (OSStatus <n>)")`.

  `installCredentials`: `loadCredentials(certificateURL: certificate, keyURL: key, password:)` first (its errors propagate unchanged); then create `appFolder` with 0700, copy both files over the previous copies (write to a temp file in `appFolder`, set 0600, rename), then `secrets.saveKeyPassword`. Nothing is copied or saved when loading fails.

  Schedule: `isDue` = `lastRunAt == nil` or `now − lastRunAt >= interval` or `lastRunAt > now` (clock moved back). `lastRunAt` = the later of the snapshot's `updatedAt` (`KsefTime.millis`, any status; unreadable → nil) and `lastRunEnd`. `RunGate.runIfIdle` returns nil without calling `body` while another call is inside.

  Status line copy (times in Warsaw, `DD.MM HH:mm`):
  | state | line |
  |---|---|
  | `.running` | `Pobieranie w toku…` |
  | `.legacyAgent` | `Wstrzymane: zainstalowane jest stare zadanie launchd` |
  | `.notConfigured` | `Nie skonfigurowano — otwórz Ustawienia…` |
  | `.notVerified` | `Sprawdź połączenie w Ustawieniach, aby zacząć pobieranie` |
  | `.idle(nil)` | `Jeszcze nie pobierano` |
  | `.idle` complete | `Ostatnio 26.11 14:00 — zakończone` |
  | `.idle` partial | `Ostatnio 26.11 14:00 — pobrano częściowo` |
  | `.idle` failed | `Ostatnio 26.11 14:00 — błąd: <reason; if longer than 80 Characters, the first 79 + "…">` |

- [ ] **Step 1: Failing tests** (all with temp folders as `home`; `FakeSecretStore` records saves)
  - `SettingsTests` (port of `config.test.ts`, see the port table): `testAcceptsAValidSettings`, `testAcceptsAStartDateEqualToToday` (`today = 2026-11-26T12:00:00Z`), the invalid cases `nip checksum` (`5265877636`), `startDate month` (`2026-13-01`), `startDate format` (`1.02.2026`), `startDate future` (`2026-11-27`), `testRejectsARelativeDataDir` (`data`); `testCorruptSettingsFiles`: file text `null`, `"x"`, `[]`, `{"nip":5265877635,…}`, `{"environment":"production",…}`, `{"dataDir":42,…}` and a valid shape with a bad NIP each throw a message with prefix `Uszkodzony plik ustawień: `; `testMissingFileIsNil`; `testSaveRoundTripsWithPermissions` (file 0600, folder 0700); `testIsValidNip` (the four cases of `config.test.ts`); `testMissingPasswordMessage` (`KeychainSecretStore.missingPasswordMessage`, a `static let` holding the pinned `Brak hasła klucza …` text, equals it; never call the Keychain).
  - `CredentialInstallTests`: `testInstallCopiesBothFilesAndSavesThePassword` (byte-equal copies, both 0600, folder 0700, secret saved once); `testInstallRejectsWrongPasswordAndLeavesNothing` (message prefix `Nie można odczytać klucza prywatnego (złe hasło lub format)`, `appFolder` absent, no secret saved); `testInstallRejectsUnsupportedAlgorithm` (`keys.json` `pbes1-3des-ec` with the `ec` certificate → the Task 1 message, nothing left); `testInstallRejectsAMismatchedPair`; `testReinstallReplacesTheCopies`.
  - `RunScheduleTests`: `isDue(nil, now)` true; 59 min 59 s → false; exactly 60 min → true; `lastRunAt` 5 min in the future → true; `lastRunAt` picks the later of snapshot and `lastRunEnd`; unreadable snapshot → `lastRunEnd`; `testRunGateRunsOneAtATime` (start a body that awaits a continuation, call `runIfIdle` again → nil, `isRunning` true; release → first returns its summary, `isRunning` false, a third call runs).
  - `LegacyLaunchAgentTests`: absent → false; create `Library/LaunchAgents/local.ksef-daily-fetch.plist` → true; delete → false.
  - `StatusLineTests`: every row of the table, the failed row with an 81-Character reason (80 Characters out, last `…`), `readSnapshotStatus` of a written snapshot and of garbage (nil).
- [ ] **Step 2: Implement.** **Step 3:** `CORE_TESTS` → pass; import check.
- [ ] **Step 4: Commit** `git add widget/Core widget/CoreTests` → `feat(app): settings, credential install, schedule and status line`.

---

### Task 10: Full fetch on KSeF TEST as an XCTest

Port `test/e2e/fetch.e2e.ts` and `test/support/send-invoice.ts`. Size: medium. Network: TEST only; takes 4–8 minutes; at most twice an hour; not 16:00–18:00 Warsaw.

**Files:**
- Create: `widget/E2ETests/SendInvoice.swift`, `widget/E2ETests/FetchE2ETests.swift`
- Modify: `widget/project.yml` (nothing if `E2ETests` is already a source folder)

**Interfaces:**
- Consumes: `run`, `RunOptions`, `Settings`, `URLSessionTransport`, `KsefHTTP`, `authenticate`, `decodeKsef`, `warsawDay`, `KsefTime` (Tasks 3–9).
- Produces: `func sendTestInvoice(http: KsefHTTP, accessToken: String, xml: Data, sleep: @Sendable (Int) async -> Void) async throws -> (ksefNumber: String, permanentStorageDate: String)` (test-only).

Sender rules = `send-invoice.ts`: public-key certificate with `SymmetricKeyEncryption` valid now, key from `SecCertificateCreateWithData` + `SecCertificateCopyKey`; random 32-byte key and 16-byte IV (`SecRandomCopyBytes`); `SecKeyCreateEncryptedData(.rsaEncryptionOAEPSHA256)`; AES-256-CBC PKCS#7 with `CCCrypt`; same endpoints, JSON fields, poll interval 2000 ms, 90 polls, rejection from code 400, close the session. The invoice template is `test/fixtures/fa3-invoice.xml`, read through `#filePath` (three folders up to the repository root) with the same placeholders.

- [ ] **Step 1: Write the test** — same flow and assertions as `fetch.e2e.ts`: seller RSA, buyer EC; wait 120 s; up to 4 attempts 60 s apart; `startDate` 100 days back; first attempt writes `state.json`; saved XML byte-equal to the sent bytes; one index line with the right `ksefNumber` and `sellerNip`; report contains the invoice number and `https://qr-test.ksef.mf.gov.pl/invoice/<sellerNip>/`; last notification title `KSeF: 1 nowa faktura`; second run saves nothing and does not notify; `snapshotURL` in the temp folder. Log metadata responses like the TypeScript test (`print` is fine). Set `executionTimeAllowance` off or ≥ 20 minutes.
- [ ] **Step 2: Run once**

`TZ=Europe/Warsaw date`, then `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefE2ETests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test -only-testing:KsefE2ETests/FetchE2ETests` → `** TEST SUCCEEDED **`. On failure, read the printed metadata lines before retrying; never loop it.
- [ ] **Step 3: Commit** `git add widget/E2ETests widget/project.yml` → `test(app): full fetch on KSeF TEST as an XCTest`; put the `ksefNumber` line and the duration in the message.

---

### Task 11: The app shell

Spec 7.3–7.6. Size: large. This is the only task that launches the app (Step 6).

**Files:**
- Delete: `widget/App/App.entitlements`
- Rewrite: `widget/App/main.swift`
- Create: `widget/App/AppDelegate.swift`, `widget/App/StatusMenu.swift`, `widget/App/SettingsWindow.swift`, `widget/App/SettingsView.swift`, `widget/App/Notifier.swift`, `widget/App/LoginItem.swift`, `widget/AppTests/SettingsRenderTests.swift`
- Modify: `widget/project.yml`

**Interfaces:**
- Consumes (all `public` in `KsefCore`): `Settings`, `SettingsFile`, `AppPaths`, `SecretStore`, `KeychainSecretStore`, `installCredentials`, `run`, `RunOptions`, `RunSummary`, `RunStatus`, `DryRunCounts`, `reportSetupFailure`, `URLSessionTransport`, `RunSchedule`, `RunGate`, `LegacyLaunchAgent`, `readSnapshotStatus`, `MenuState`, `menuStatusLine`, `isValidNip`, `errorMessage`, `KsefEnvironment`; `KsefLink` (`widget/Shared/KsefLink.swift`).
- Produces:
  ```swift
  struct SettingsForm: Equatable {
    var nip: String; var environment: KsefEnvironment; var startDate: Date; var dataDir: String
    var certificateName: String?; var keyName: String?; var password: String; var hasStoredCredentials: Bool
    var startAtLogin: Bool; var loginNeedsApproval: Bool; var notificationsAllowed: Bool?; var legacyAgent: Bool
    var message: SettingsMessage?
  }
  struct SettingsMessage: Equatable { let text: String; let isError: Bool }
  struct SettingsActions { let chooseCertificate, chooseKey, chooseFolder, save, check, testNotification, openLoginItems: () -> Void
                           let setStartAtLogin: (Bool) -> Void }
  struct SettingsView: View { @Binding var form: SettingsForm; let busy: Bool; let actions: SettingsActions }   // pure SwiftUI, no AppKit types
  ```

`project.yml` changes for `KsefWidget`: remove `CODE_SIGN_ENTITLEMENTS`, add `PRODUCT_NAME: KSeF`, add `- target: KsefCore` to `dependencies`, sources `[App, Shared/KsefLink.swift]` unchanged. New target:
```yaml
  KsefAppTests:
    type: bundle.unit-test
    platform: macOS
    sources: [AppTests, App/SettingsView.swift]
    dependencies:
      - target: KsefCore
```

Behaviour (`AppDelegate`, `@MainActor`, `Logger(subsystem: "local.ksef-daily-fetch.app", category: "app")`, values `privacy: .public`):
- **Launch:** log `launch configured=<bool> verified=<bool> legacyAgent=<bool>`. Create the status item. Schedule `NSBackgroundActivityScheduler(identifier: "local.ksef-daily-fetch.app.tick")` with `interval = 900`, `tolerance = 300`, `repeats = true`, `qualityOfService = .utility`; its block calls `tick("schedule")` and completes immediately. Observe `NSWorkspace.shared.notificationCenter` `didWakeNotification` → `tick("wake")`. If not configured: open the settings window and touch **nothing else** (no Keychain, no invoice folder, no `UNUserNotificationCenter`, no `SMAppService` call beyond reading `status` for the form). If configured: in a detached task read the password (`KeychainSecretStore().readKeyPassword()`, kept in memory) and list the invoice folder (creating it if missing), then `tick("launch")`.
- **`tick(trigger)`:** stop unless configured, `verified`, `!LegacyLaunchAgent.isInstalled`, and `RunSchedule.isDue(lastRunAt: RunSchedule.lastRunAt(snapshot:lastRunEnd:), now: Date())`; otherwise `fetch(trigger)`. Log `tick trigger=<t> due=<bool>` only when it fetches or is blocked by the LaunchAgent.
- **`fetch(trigger)`:** through the one `RunGate`; inside, hold `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "KSeF fetch")` until the end. If the cached password is nil, read it; on error call `reportSetupFailure(errorMessage(error), …)` and stop. Load settings; on error `reportSetupFailure`. Then `run(RunOptions(… certificateURL: paths.certificate, keyURL: paths.key, transport: URLSessionTransport(), sleep: Task.sleep in ms, now: Date.init, notify: Notifier.post, log: logger, snapshotURL: paths.snapshot))`. After every non-dry run: `lastRunEnd = Date()`, `WidgetCenter.shared.reloadTimelines(ofKind: "KsefInvoices")`, refresh the menu, log `run finished trigger=<t> status=<s> saved=<n>`.
- **Menu** (`NSMenuDelegate.menuNeedsUpdate` rebuilds it): item 1 disabled = `menuStatusLine(state)`; if configured and notifications are not authorized, a disabled item `Powiadomienia są wyłączone — włącz je w Ustawieniach systemowych`; separator; `Pobierz teraz` (enabled only when configured, verified, no LaunchAgent, not running → `fetch("manual")` ignoring `isDue`); `Ustawienia…` (key `,`); `Otwórz folder faktur` (enabled when configured; creates the folder if missing, then `NSWorkspace.shared.open`); separator; `Zakończ` (key `q`). Status button image: SF Symbol `doc.text`, or `exclamationmark.triangle` when the last snapshot failed or the LaunchAgent is installed; `accessibilityDescription` `KSeF`.
- **Widget URLs:** `application(_:open:)` opens `KsefLink.isAllowed` URLs with `NSWorkspace.shared.open` and logs `opened host=<host>`, else logs `ignored URL scheme=<scheme> host=<host>`; never the full URL, never terminate.
- **Settings window:** `NSWindow` titled `Ustawienia KSeF` with `NSHostingController(rootView: SettingsView…)`; on open `NSApp.activate()` and `makeKeyAndOrderFront`. Form initialised from `settings.json` (or `nip ""`, `environment .prod`, `startDate` today, `dataDir` `paths.defaultDataDir`), `hasStoredCredentials` = both copies exist. File pickers: `NSOpenPanel` for one file (`.crt` / `.key`, any file allowed) and one folder (`canCreateDirectories`).
- **Zapisz:** build `Settings` from the form (startDate `yyyy-MM-dd` in Warsaw), `validate(today:)`; if a certificate, key or password was entered, all three are required (`Wybierz certyfikat i klucz oraz wpisz hasło klucza.`) and go through `installCredentials` with `KeychainSecretStore()`; without them, stored credentials are required (`Wybierz certyfikat i klucz oraz wpisz hasło klucza.` if none). `verified` stays true only if NIP, environment and credentials are unchanged. Save, create the invoice folder, refresh the cached password, request notification authorization (`[.alert]`) if not yet determined, clear the password field. Message `Zapisano.`, or `Zapisano. Teraz naciśnij „Sprawdź połączenie”.` when not verified; errors `Błąd: <errorMessage>` in red.
- **Sprawdź połączenie** (enabled when configured; also allowed with the LaunchAgent installed): message `Sprawdzanie…`, `run(… dryRun: true)` with the saved settings and the cached or freshly read password; success → `Połączenie działa. Faktury w pierwszym oknie: <listed>, jeszcze niezapisane: <notSaved>.`, set `verified = true`, save, `tick("verified")`; failure → `Błąd: <reason>`.
- **Wyślij testowe powiadomienie:** request authorization if not determined, then post `KSeF: test powiadomienia` / `Powiadomienia działają.`; message `Wysłano testowe powiadomienie.` or `Błąd: <message>`.
- **Uruchamiaj przy logowaniu:** `LoginItem` wraps `SMAppService.mainApp` (`register()`/`unregister()`, `status`); the toggle shows `status == .enabled`; `.requiresApproval` shows `Zatwierdź KSeF w Ustawieniach systemowych › Ogólne › Rzeczy otwierane podczas logowania.` and a button `Otwórz ustawienia logowania` (`SMAppService.openSystemSettingsLoginItems()`); errors `Błąd: <localizedDescription>`.
- **Other pinned form copy:** labels `NIP`, `Certyfikat (.crt)`, `Klucz prywatny (.key)`, `Hasło klucza`, `Środowisko` (`Produkcja`, `Test`, `Demo`), `Pobieraj faktury od`, `Folder faktur`, `Uruchamiaj przy logowaniu`; buttons `Wybierz…`, `Zmień…`, `Zapisz`, `Sprawdź połączenie`, `Wyślij testowe powiadomienie`; password placeholder when credentials are stored `zapisane — wpisz, aby zmienić`; under the folder `Zmiana folderu nie przenosi plików: w nowym folderze pobieranie zacznie się od daty początkowej.`; notification line `Powiadomienia: włączone` / `Powiadomienia: wyłączone — włącz je w Ustawieniach systemowych › Powiadomienia` (hidden while `nil`); LaunchAgent banner (red) `Wykryto stare zadanie launchd „local.ksef-daily-fetch”. Dopóki jest zainstalowane, aplikacja nie pobiera faktur. Usuń je w Terminalu poleceniem scripts/launchagent.sh uninstall w katalogu repozytorium.` Every dynamic string with `Text(verbatim:)`.
- **Notifier:** `UNUserNotificationCenter.current()`; the delegate's `willPresent` returns `[.banner, .list]`; `post(title, body)` throws `KsefError("Powiadomienia są wyłączone")` unless `authorizationStatus` is `.authorized` or `.provisional`, then adds a request with a UUID identifier and no sound. The center is first touched only by these paths (never at an unconfigured launch).

- [ ] **Step 1: Write `SettingsRenderTests` (failing)** — `@MainActor`; each test builds `SettingsView(form: .constant(<form>), busy: false, actions: <no-ops>)` in an `NSHostingView` inside a never-shown `NSWindow` with `appearance = NSAppearance(named: .aqua)`, sized to the view's `fittingSize`, `layoutSubtreeIfNeeded()`, renders with `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` (probed, spec 5.4; `ImageRenderer` renders a `Form` blank), writes PNG to `ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"]` or throws `XCTSkip("set TEST_RUNNER_SETTINGS_RENDER_DIR to render PNGs")`; asserts the image is wider than 300 px. Forms: `settings-first-launch.png` (empty NIP, default folder, nothing stored); `settings-error.png` (filled, stored credentials, message `Błąd: Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)`); `settings-legacy-agent.png` (`legacyAgent: true`, `notificationsAllowed: false`); `settings-needs-approval.png` (`startAtLogin: false`, `loginNeedsApproval: true`, success message `Połączenie działa. Faktury w pierwszym oknie: 3, jeszcze niezapisane: 1.`).
- [ ] **Step 2: Implement** the files above. Keep `AppDelegate` free of logic that `KsefCore` already has; anything new and testable belongs in Task 9's files (add a test there if you move logic).
- [ ] **Step 3: Build, test, render**

Run: `xcodegen generate --spec widget/project.yml --project widget`
Run: `xcodebuild … -scheme KsefWidget -configuration Release … -quiet build` → no errors.
Run: `codesign --verify --deep --strict widget/build/Build/Products/Release/KSeF.app && echo verified` → `verified`.
Run: `codesign -d --entitlements - --xml widget/build/Build/Products/Release/KSeF.app | plutil -p -` → no `com.apple.security.app-sandbox` (only `get-task-allow` may appear). The same for `KSeF.app/Contents/PlugIns/KsefWidgetExtension.appex` → sandbox + the read-only exception exactly as before.
Run: `plutil -p widget/build/Build/Products/Release/KSeF.app/Contents/Info.plist | grep -E "LSUIElement|CFBundleIdentifier"` → `true`, `local.ksef-daily-fetch.KsefWidget`.
Run: `mkdir -p widget/build/renders && TEST_RUNNER_SETTINGS_RENDER_DIR="$PWD/widget/build/renders" xcodebuild … -scheme KsefAppTests … test` → `** TEST SUCCEEDED **`, four PNGs. Look at each: no clipped label, the long error wraps, the red banner is readable, Polish letters render. Fix layout and re-render until clean. List the PNG paths in your report.
Run: `CORE_TESTS` and `WIDGET_TESTS` → pass.

- [ ] **Step 4: Smoke-launch the app (only under these conditions)**

Run: `test -e "$HOME/Library/Application Support/local.ksef-daily-fetch.KsefWidget"; echo "exists=$?"` → must print `exists=1`. If it prints `exists=0` the owner has configured the app: skip this step and say so.
Run: `open -a "$PWD/widget/build/Build/Products/Release/KSeF.app" "https://example.invalid/ksef-check"`
Wait 5 s. Run: `/usr/bin/log show --last 2m --style compact --predicate 'subsystem == "local.ksef-daily-fetch.app"'` → contains `launch configured=false` and `ignored URL scheme=https host=example.invalid`.
Run: `pgrep -x KSeF; echo "running=$?"` → `running=0` (it stayed running). The settings window is open: do not click anything in it.
Run: `pkill -x KSeF`. Then `test -e "$HOME/Library/Application Support/local.ksef-daily-fetch.KsefWidget"; echo "exists=$?"` → `exists=1`; `test -e "$HOME/Documents/KSeF"; echo "exists=$?"` → `exists=1` (unless it existed before; then report it untouched).
Unregister: `lsregister -u` on the Release (and Debug, if present) `KSeF.app`; the `pluginkit` check → `0`.

- [ ] **Step 5: Commit** `git rm widget/App/App.entitlements` then `git add widget/project.yml widget/App widget/AppTests` → `feat(app): menu-bar app with settings window and hourly scheduler`.

---

### Task 12: Build script, README, AGENTS.md, final verification

Spec 7.7, 10. Size: medium.

**Files:**
- Create: `scripts/build-app.sh`
- Modify: `README.md`, `AGENTS.md`

- [ ] **Step 1: Write `scripts/build-app.sh`** (zsh, like `scripts/launchagent.sh`; usage `scripts/build-app.sh [--install] [signing-identity]`):
  1. `cd` to the repository root (`${0:A:h:h}`); `xcodegen generate --spec widget/project.yml --project widget`; `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build -quiet build` (exit on failure).
  2. With an identity: `codesign --force --sign "$IDENTITY" --entitlements widget/Extension/Extension.entitlements <app>/Contents/PlugIns/KsefWidgetExtension.appex`, then `codesign --force --sign "$IDENTITY" <app>` (no entitlements, no `--options runtime`). Without: leave the ad-hoc build.
  3. `codesign --verify --deep --strict <app>` (exit on failure); print `codesign -dr - <app>` (the designated requirement: `cdhash` means ad hoc, `certificate leaf[subject.OU]` means Developer ID).
  4. With `--install`: quit a running copy (`osascript -e 'quit app id "local.ksef-daily-fetch.KsefWidget"'`, ignore errors), `mkdir -p ~/Applications`, `rm -rf ~/Applications/KSeF.app`, `ditto <app> ~/Applications/KSeF.app`, `lsregister -u <app>` (the build copy), `open ~/Applications/KSeF.app`. Without: `lsregister -u <app>` and print the `--install` hint.
  Header comment: two lines (what it does; that the identity is never stored, pass the full name or SHA-1 shown by `security find-identity -v -p codesigning`).
  Verify: `zsh -n scripts/build-app.sh` → no output; `scripts/build-app.sh` (no arguments; ad hoc; never `--install`, never an identity) → `cdhash` in the printed requirement; `pluginkit` check → `0`.

- [ ] **Step 2: Rewrite `README.md`** around the app (English; keep the existing "What it does" paragraph style; copy the exact Polish strings from the code):
  1. **What it does:** the menu-bar app, hourly fetch, notifications, reports, widget; anti-goal sentence; links to the three specs and `ADR.md`.
  2. **Requirements:** macOS 14+ on Apple Silicon, Xcode (`xcodebuild`), `brew install xcodegen`.
  3. **Get a KSeF certificate:** keep the current section's text (Aplikacja Podatnika, Authentication type, `.crt` + encrypted `.key`, scope warning, revocation).
  4. **Build and install:** `scripts/build-app.sh --install` (ad hoc) or `scripts/build-app.sh --install "<identity>"`; what Developer ID changes (spec 6.7): ad hoc, after each rebuild expect one Keychain prompt (type the login password, Always Allow) and one Documents-folder prompt at launch.
  5. **Set up:** the settings window fields; **Zapisz**; **Wyślij testowe powiadomienie** (allow notifications for KSeF if nothing appears); **Sprawdź połączenie** with the expected success line and the typical errors (the four from the old Dry run section with their Swift texts, plus the unsupported-algorithm and `Brak hasła klucza w Pęku kluczy` messages); fetching starts only after a successful check; **Uruchamiaj przy logowaniu** and the Login Items approval; where things live (spec 7.3 paths; credentials never in the widget-readable folder).
  6. **Running:** hourly from the last run, catch-up at wake, one run at a time, **Pobierz teraz**, notification rules (unchanged, including once a day for a repeated failure), the 60-per-hour cap, reports, logs: `/usr/bin/log show --last 1h --predicate 'subsystem == "local.ksef-daily-fetch.app"'`.
  7. **Desktop widget:** keep the current section's banners and troubleshooting, adapted: the app is `KSeF.app`; clicks open the browser and the app keeps running; `SnapshotProbe` troubleshooting unchanged.
  8. **Fallback: the TypeScript fetcher:** it is still in `src/`, unchanged, until the owner confirms the app; how to run it (link to the git history of this README or keep the old setup sections condensed under this heading: Node, `config.json`, Keychain item `ksef-daily-fetch`, `node src/main.ts --dry-run`, `scripts/launchagent.sh install`). Never run both: the app pauses while the LaunchAgent is installed; remove it with `scripts/launchagent.sh uninstall`.
  9. **First-run checklist:** spec section 10, items 1–10.
  10. **Development:** `CORE_TESTS`, `WIDGET_TESTS`, `KsefAppTests` with renders, the two E2E commands with their limits, the golden generator (`node test/golden/make-vectors.ts widget/CoreTests/Fixtures`, then rerun `CORE_TESTS`), `pnpm test` for the fallback.

- [ ] **Step 3: Rewrite `AGENTS.md`:** first paragraph: the menu-bar app is the product, the TypeScript fetcher is the fallback; links to the spec and ADRs. Commands: xcodegen, the four test commands, the app build command, `scripts/build-app.sh` (never with `--install` or an identity by agents), `pnpm test`. Rules: keep the existing ones that still apply (Polish/English, no personal data, never touch the owner's Keychain or real certificate, network only to TEST in E2E targets, maintenance window and rate limit, never install the LaunchAgent, widget extension entitlements, `Text(verbatim:)`, snapshot path in three places — now `widget/Core/AppPaths.swift` instead of `src/main.ts` for the app, plus `src/main.ts` for the fallback); add: `KsefCore` imports only Foundation/Security/CryptoKit/CommonCrypto; the app is not sandboxed and has no entitlements; never instantiate `KeychainSecretStore` in tests; never launch the app when the owner's app folder exists; fixtures come from `test/golden/make-vectors.ts` and the RSA signature must stay byte-identical; `src/` changes only for fallback fixes. State: the app folder, the invoice folder files (unchanged formats), the snapshot. Known follow-ups: `/auth/rev2` (now one path string in `widget/Core/KsefClient.swift` and one in `src/ksef.ts`), removal of the TypeScript fetcher after the owner's confirmation.

- [ ] **Step 4: Final verification**

Run: `CORE_TESTS`, `WIDGET_TESTS`, `KsefAppTests` → all `** TEST SUCCEEDED **`; report the test counts (`KsefCoreTests` must be ≥ 140).
Run: `pnpm test` → 142 pass (the TypeScript fallback is untouched).
Run: `git diff --stat main -- src test/unit test/e2e test/support scripts/launchagent.sh scripts/run-daily.sh package.json widget/Extension widget/Shared widget/Tests widget/Probe` → empty.
Run: `git grep -n "$(basename "$HOME")"` → nothing; `git grep -nE "DEVELOPMENT_TEAM|Developer ID Application:"` → nothing.
Run: `grep -rhoE "^import [A-Za-z0-9]+" widget/Core | sort -u` → only the four allowed modules.
Run: `pluginkit -m -p com.apple.widgetkit-extension | grep -c ksef-daily-fetch` → `0`; `ls ~/Library/LaunchAgents | grep -c ksef` → `0`; `test -e ~/Applications/KSeF.app; echo "exists=$?"` → `exists=1`.
Run: `git status --short` → only `README.md`, `AGENTS.md`, `scripts/build-app.sh`.

- [ ] **Step 5: Commit** `git add scripts/build-app.sh README.md AGENTS.md` → `docs: build script and owner setup for the Swift app`.

---

## Done when

- All four Swift test bundles pass offline (`KsefCoreTests`, `KsefWidgetTests` unchanged at 30, `KsefAppTests`) and both E2E tests passed once on TEST (Tasks 4 and 10); `pnpm test` still passes 142.
- The RSA XAdES output is byte-identical to the TypeScript output; EC digests identical, signatures verified by libxml2-canonicalized checks.
- `formats.json` goldens match: index lines, `state.json`, report file, notifications, widget snapshot, amounts.
- The four settings PNGs exist in `widget/build/renders/` and were looked at.
- Nothing installed, no Keychain touched, no notification shown, no login item registered, no LaunchServices registration left; `git status` clean; nothing personal tracked.

## Verifiable headlessly vs left for the owner

| Task | Implementer verifies | Owner verifies (spec 10) |
|---|---|---|
| 1–3, 5–9 | everything, offline | — |
| 4, 10 | TEST login with RSA and EC; full TEST fetch | PROD login through **Sprawdź połączenie** (item 4) |
| 9 | Keychain adapter compiles; its messages | the real Keychain item and prompts (items 2, 8) |
| 11 | build, signatures, entitlements, renders, URL forwarding, no side effects at an unconfigured launch | settings flow, Documents prompt, notifications, login item, scheduler over a day, widget in the real host, widget click with the app running (items 2–7) |
| 12 | script syntax, ad-hoc build path, docs | `--install`, Developer ID re-sign (items 1, 8) |
