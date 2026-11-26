# KSeF daily fetch — design

Date: 2026-11-26
Status: approved scope (user), technical calls by the orchestrator, details by the spec author

## 1. Intent

The owner is a Polish sole proprietor (JDG, one NIP, active VAT payer) on macOS (Apple Silicon). Since 2026 their purchase invoices arrive through the national e-invoicing system KSeF (Krajowy System e-Faktur, API 2.0), not by e-mail. Nobody tells them when a new one appears, and the legal "date of receipt" is the date KSeF assigns its number, not the date they look.

This tool runs once a day on their Mac, pulls every new purchase invoice from KSeF, saves the original XML to disk and tells them what arrived: seller, invoice number, gross amount, issue date, and a link to view the invoice in KSeF. It is the first step ("to start with"); accounting export and other features may follow later and are out of scope now.

## 2. Goals

1. Once a day, fetch every purchase invoice (the owner is the buyer, `Podmiot2` / `subjectType: Subject2`) that KSeF has stored since the last successful fetch.
2. Never lose an invoice and never fetch one twice: incremental sync with a stored checkpoint and a dedup set keyed by KSeF number.
3. Save each invoice's original XML byte for byte, outside git.
4. Notify: one macOS notification per run that found something, plus a Markdown report for the day listing seller, invoice number, gross amount with currency, issue date and the KSeF view link.
5. Authenticate with a KSeF certificate (type `Authentication`) and a XAdES signature.
6. Prove the whole path end to end against the KSeF TEST environment with self-signed certificates before the owner supplies any real credential.

## 3. Non-goals (for now)

- No UI, no accounting export, no PDF rendering.
- No sales invoices (`Subject1`), no `Subject3` / `SubjectAuthorized` roles.
- No invoice sending. The only sending code is test-only, used to put an invoice into TEST so the fetch path can be verified.
- No cloud hosting, no server, no database.
- No KSeF token authentication, no token or session persistence between runs.

## 4. Anti-goal

**A job that fails silently.** Every run ends in exactly one of: nothing new (silent by design), new invoices (notification + report), partial (notification + report), failed (notification + report + log). A failure before the config is readable still notifies. A launchd job that cannot even start Node still notifies (wrapper script). The README's setup verifies that a notification actually appears on screen, because macOS can mute notifications per app.

## 5. Constraints and facts

All KSeF facts were checked on 2026-11-26 against the official docs repo `CIRFMF/ksef-api` (commit `c67c589`), the TEST OpenAPI (`https://api-test.ksef.mf.gov.pl/docs/v2/openapi.json`, API 2.10.1) and the official C# client `CIRFMF/ksef-client-csharp` (commit `dcea098`).

**Environments**

| env | API base | QR / view host |
|---|---|---|
| test | `https://api-test.ksef.mf.gov.pl/v2` | `https://qr-test.ksef.mf.gov.pl` |
| demo | `https://api-demo.ksef.mf.gov.pl/v2` | `https://qr-demo.ksef.mf.gov.pl` |
| prod | `https://api.ksef.mf.gov.pl/v2` | `https://qr.ksef.mf.gov.pl` |

TEST accepts self-signed certificates (`POST /auth/xades-signature?verifyCertificateChain=false`) and random NIPs; data there is shared between integrators. TEST and DEMO may be under maintenance 16:00–18:00 Warsaw time.

**Authentication (XAdES)**: `POST /auth/challenge` → `{challenge, timestamp, timestampMs, clientIp}` (valid 10 min) → build `AuthTokenRequest` (namespace `http://ksef.mf.gov.pl/auth/token/2.0`: `Challenge`, `ContextIdentifier/Nip`, `SubjectIdentifierType=certificateSubject`) → enveloped XAdES-BES signature → `POST /auth/xades-signature` (`Content-Type: application/xml`) → 202 `{referenceNumber, authenticationToken:{token, validUntil}}` → poll `GET /auth/{referenceNumber}` with `Bearer authenticationToken` until `status.code` ≠ 100 (200 = success; 415/425/450/460/470/480/500/550 = failure with `description` and `details[]`) → `POST /auth/token/redeem` (once) → `{accessToken:{token, validUntil}, refreshToken:{…}}`. `GET /auth/{referenceNumber}` is deprecated but supported until 2027-06-15; its successor `/auth/rev2/{referenceNumber}` is in the TEST OpenAPI but absent from the PROD OpenAPI as of 2026-11-26 (the changelog schedules release 2.10.1 for PROD on 2026-12-01). Signature rules (`auth/podpis-xades.md`): enveloped or enveloping, XAdES-BES or higher, RSA ≥ 2048 (PKCS#1 v1.5 or PSS) or ECDSA ≥ 256 bits with `SignatureValue` as raw `R || S`.

**Certificates**: a KSeF certificate is either `Authentication` or `Offline`. Key types allowed: RSA 2048 or EC P-256; MF recommends EC. A KSeF certificate carries **no permissions of its own**: it authenticates the person, and the person's rights in the NIP context apply (for a JDG owner: everything). Valid up to 2 years. Revocable by the owner in Aplikacja Podatnika.

**Files from Aplikacja Podatnika — UNCONFIRMED**: third-party invoicing software that imports certificates generated in Aplikacja Podatnika (`lkosson/profak`) accepts a `.crt` file containing `-----BEGIN CERTIFICATE-----` (PEM) and a `.key` file containing `-----BEGIN ENCRYPTED PRIVATE KEY-----` (PKCS#8, password chosen by the user at generation; the password cannot be recovered). The official Java client documents decrypting exactly this format for EC keys. Whether the owner's key will be RSA or EC is unknown; both are supported. The design is built around `.crt` PEM + encrypted PKCS#8 PEM `.key` + password; the first real run confirms it.

**Metadata query**: `POST /invoices/query/metadata?sortOrder=Asc&pageOffset=N&pageSize=10..250`, body `{subjectType, dateRange:{dateType, from, to?, restrictToPermanentStorageHwmDate?}}`. `pageOffset` is a page index (0 = first page). Max range 100 days; dates without an offset are read as Warsaw local time, so always send an explicit offset. Response `{hasMore, isTruncated, permanentStorageHwmDate, invoices[]}`; `isTruncated` at 10,000 records per filter. Error 400 with exception code `21183` when `from` is later than the HWM while `restrictToPermanentStorageHwmDate=true`. Metadata fields used: `ksefNumber`, `invoiceNumber`, `issueDate` (date), `permanentStorageDate` (date-time), `seller.nip`, `seller.name` (nullable), `grossAmount` (number), `currency`, `invoiceHash` (SHA-256, Base64).

**HWM** (`pobieranie-faktur/hwm.md`): `permanentStorageHwmDate` is the instant up to which KSeF guarantees the set of invoices is complete; nothing new will ever appear with a `PermanentStorage` date ≤ HWM. It is constant across pages of one query. Recommended incremental pattern: `dateType=PermanentStorage`, `sortOrder=Asc`, `restrictToPermanentStorageHwmDate=true`; `hasMore=false` → stop; `hasMore && !isTruncated` → next page; `isTruncated` → set `from` to the last record's date and reset `pageOffset`; store the HWM as the next `from`; dedupe by KSeF number.

**Single invoice**: `GET /invoices/ksef/{ksefNumber}` → `application/xml`, response header `x-ms-meta-hash` (SHA-256 Base64). KSeF numbers match `^([1-9](\d[1-9]|[1-9]\d)\d{7})-(20[2-9][0-9]|2[1-9]\d{2}|[3-9]\d{3})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])-([0-9A-F]{6})-?([0-9A-F]{6})-([0-9A-F]{2})$`.

**Rate limits** (per context + IP, sliding windows; `limity/limity-api.md`): metadata 8/s, 16/min, 20/h; single invoice download 8/s, 16/min, 64/h; other protected endpoints 10/s, 30/min, 120/h; `/auth/challenge` 60/s per IP. On 429 wait `Retry-After` seconds; repeated violations escalate the block. MF's own guidance for low-volume taxpayers: sync via the metadata query, download single invoices synchronously, run about once a day. **UNCONFIRMED**: `limity-api.md` says TEST limits are ten times PROD; changelog 2.5.0 says TEST was aligned to PROD. Design for PROD values everywhere.

**View link** (`kody-qr.md`, "KOD I"): `{qrHost}/invoice/{sellerNip}/{DD-MM-YYYY issue date}/{invoiceHash as Base64URL without padding}`. It opens a public page with the invoice's basic data and its presence in KSeF.

**Platform**: macOS on Apple Silicon, Node v22.23.4 (native TypeScript type stripping is on by default: `process.features.typescript === 'strip'`, verified), pnpm 10.17.0, `/usr/bin/openssl` (LibreSSL 3.3.6) present on every Mac.

## 6. Approaches considered

### 6.1 Where it runs: local launchd job (chosen) vs cloud scheduled job

- **Local LaunchAgent on the owner's Mac (chosen).** The certificate's private key never leaves the machine; the key password stays in the macOS Keychain; notifications are native; no hosting cost. launchd runs a `StartCalendarInterval` job that was missed while the Mac slept as soon as it wakes. Downside: if the Mac is powered off at the scheduled time the run waits for the next day, and a Mac left off for a week means a week without notifications. Acceptable for a daily personal digest; invoices are not lost, only delayed.
- **Cloud scheduled job (rejected).** Would run reliably, but the private key (which carries the owner's full KSeF rights, see 6.2) would have to live in a cloud secret store, and notifications would need another channel (e-mail, push). More attack surface and moving parts for a personal tool.

### 6.2 Authentication: KSeF certificate + XAdES (chosen) vs KSeF token

- **KSeF token (rejected).** Simplest (no XML signing), but under the regulation in force KSeF tokens authenticate only until 2026-12-31; an amendment is announced but not published. Building on it now risks a dead tool in five weeks.
- **KSeF certificate + XAdES (chosen).** Supported without an end date, verified internally by KSeF (no OCSP wait), self-signable on TEST so the whole path can be proven before any real credential exists. Consequence the owner must understand: **a certificate has no permission scope** (a token can be limited to `InvoiceRead`); whoever holds the key file and its password can act with the owner's full KSeF rights, including issuing invoices. Mitigations: key file outside the repo with `0600` permissions, password only in Keychain, minimal pinned dependencies, revocation in Aplikacja Podatnika if the Mac is lost.

### 6.3 Client: hand-written `fetch` client (chosen) vs community KSeF library

- **Community library (rejected).** Every Node KSeF 2.0 client found is 0.x and single-maintainer; it would run with access to a key that has full rights, and it would pull its own dependency tree.
- **Hand-written client (chosen).** About six endpoints, all JSON except two: the signed XML upload and the invoice download. Shapes are taken from the official OpenAPI. Node's built-in `fetch` and `crypto` cover everything except XML canonicalization and signing.
- **XAdES signer: `xml-crypto` 6.4.0 (chosen) vs `xadesjs` 3.1.0.** `xml-crypto` is maintained by the node-saml organisation (five maintainers, heavily scrutinized because SAML depends on it), has three runtime dependencies (`@xmldom/xmldom`, `xpath`, `@xmldom/is-dom-node`), was released 2026-10-14, and supports what XAdES-BES needs: an empty-URI enveloped reference, references to generated `<Object>` content by `Id`, a `Type` attribute on a reference, `KeyInfo/X509Data` from a PEM certificate, and custom signature algorithms. It has no ECDSA algorithm built in; we register one (about 15 lines) that calls `crypto.sign('sha256', data, {key, dsaEncoding: 'ieee-p1363'})`, which produces exactly the raw `R || S` KSeF requires. `xadesjs` knows XAdES natively, but 3.x is a fresh major (2026-10-29), needs `xmldsigjs`, `xml-core`, `pkijs`, `asn1js`, `@peculiar/utils` and a DOM implementation, roughly three times the dependency surface. Hand-writing exclusive canonicalization was rejected: it is exactly the kind of code that is subtly wrong.

### 6.4 Sync mechanism: metadata query + single downloads (chosen) vs async export

- **Async export `POST /invoices/exports` (rejected for now).** MF's recommended path for high volume: builds an AES-encrypted, split ZIP package server side. Needs RSA-OAEP key wrapping, AES-CBC decryption, ZIP extraction (Node has no ZIP reader, so another dependency or hand-written code) and status polling. Pointless at a JDG's volume of a few dozen purchase invoices per month.
- **Metadata query + `GET /invoices/ksef/{ksefNumber}` (chosen).** Exactly what `limity-api.md` recommends for low-volume profiles. Two endpoints, plain JSON and XML, HWM semantics identical to the export path. The download limit (64/h) only matters on the first backfill, handled by the partial-run mechanism (7.5).

## 7. Decisions

Calls marked (O) are the orchestrator's; (S) are the spec author's, made from the sources above.

### 7.1 Runtime and packaging
- (O) TypeScript on Node 22, **no build step**: `node src/main.ts` relies on native type stripping. Only erasable syntax (no `enum`, `namespace`, parameter properties); imports use explicit `.ts` extensions; type-only imports use `import type`.
- (O) Tests with `node --test`; `typescript` only as a devDependency for `tsc --noEmit`. pnpm.
- (O) Runtime dependencies kept to the bare minimum, exact versions pinned: `xml-crypto` 6.4.0 only. devDependencies: `typescript` 6.0.3 (last JS-based release; 7.x ships twenty platform-specific native binary packages), `@types/node` 22.20.5 (22.20.6/7 were published the day before this spec).
- (S) `pnpm-workspace.yaml` sets `minimumReleaseAge: 20160` (14 days) so a fresh, possibly hijacked transitive release is never resolved. pnpm 10 does not run dependency install scripts unless allow-listed; none are.
- (S) Self-signed test certificates are generated with `/usr/bin/openssl` (zero dependencies). It produces the same file shapes as Aplikacja Podatnika (PEM `.crt`, encrypted PKCS#8 `.key`), so tests exercise the real key-loading path. Verified for RSA-2048 and EC P-256.

### 7.2 Configuration and secrets
- (O) `config.json` at the repo root (gitignored) with a committed `config.example.json`:
  ```json
  {
    "nip": "1234567890",
    "environment": "prod",
    "certificatePath": "/Users/<you>/.config/ksef-daily-fetch/ksef-auth.crt",
    "keyPath": "/Users/<you>/.config/ksef-daily-fetch/ksef-auth.key",
    "startDate": "2026-02-01",
    "dataDir": "data"
  }
  ```
  `nip`: 10 digits with a valid checksum. `environment`: `test` | `demo` | `prod`. `certificatePath`, `keyPath`: absolute paths. `startDate`: `YYYY-MM-DD`, not in the future; the very first sync starts at `{startDate}T00:00:00Z` (one or two hours before Warsaw midnight; harmless, avoids time-zone math). `dataDir`: optional, default `data`, relative paths resolved against the repo root; overridable because tests use temp dirs and launchd runs from the main checkout.
- (O) Key password read at runtime from the login Keychain: `security find-generic-password -s ksef-daily-fetch -a <nip> -w`. The owner stores it with `security add-generic-password -s ksef-daily-fetch -a <nip> -U -w` (with `-w` last, `security` prompts, so the password never reaches shell history or chat).
- (S) The private key is decrypted in memory (`crypto.createPrivateKey({key, format:'pem', passphrase})`) and never written anywhere. Startup checks: the key matches the certificate (`X509Certificate.checkPrivateKey`), and it is RSA ≥ 2048 or EC `prime256v1`.

### 7.3 Authentication
- (O) Fresh authentication every run; no token persistence.
- (S) Signature built like the official C# `SignatureService`: enveloped `ds:Signature` (`Id="Signature"`) appended to `AuthTokenRequest`; `CanonicalizationMethod` exclusive C14N; reference 1 `URI=""` with transforms enveloped-signature + exclusive C14N, digest SHA-256; reference 2 `URI="#SignedProperties"` with `Type="http://uri.etsi.org/01903#SignedProperties"`, exclusive C14N, SHA-256; `ds:Object` holding `xades:QualifyingProperties Target="#Signature"` (`xmlns:xades="http://uri.etsi.org/01903/v1.3.2#"`) with `SigningTime` (now minus one minute, as the C# client does against clock skew) and `SigningCertificate/Cert` (`CertDigest` SHA-256 of the DER certificate, `IssuerSerial` with the issuer DN and the decimal serial); `KeyInfo/X509Data/X509Certificate`. `SignatureMethod` `…xmldsig-more#rsa-sha256` for RSA, `…xmldsig-more#ecdsa-sha256` for EC.
- (S) **UNCONFIRMED**: how strictly KSeF compares `X509IssuerName`. The two official clients disagree (C# writes .NET's DN string; Java uses EU DSS with `SigningCertificateV2`), which suggests KSeF does not string-compare it. We write RFC 4514 order (Node's `x509.issuer` lines reversed, joined with `, `, XML-escaped). First suspect if TEST rejects the signature.
- (S) `?verifyCertificateChain=false` is sent only when `environment` is `test`.
- (S) Auth status polled every 1 s, at most 120 times.
- (S) An access token that would expire within 60 s ends the run as **partial** ("token expiring"); no refresh-token code. With the download pacing below, a run takes a few minutes; KSeF documents access tokens as valid for "kilkanaście minut".

### 7.4 Sync and state
- (O) `subjectType: Subject2`, `dateType: PermanentStorage`, `sortOrder: Asc`, `restrictToPermanentStorageHwmDate: true`, `pageSize: 250`.
- (S) **Windows**: `from` is the checkpoint string exactly as KSeF returned it (7 fractional digits; never re-formatted, never rounded). If `from + 90 days` is before now, the window gets `to = from + 90 days` (ISO, UTC); otherwise `to` is omitted, so KSeF uses its own "now" and caps the window at the HWM. 90 days leaves margin under the 100-day cap.
- (S) **Within a window**: page until `hasMore=false`; on `isTruncated` restart from the last record's `permanentStorageDate` with `pageOffset=0`; dedupe by `ksefNumber`; the window's HWM is the last response's `permanentStorageHwmDate`. A 400 whose body contains `21183` means "nothing settled yet": the window is empty and the HWM unknown.
- (S) **Checkpoint rule (one rule)**: the checkpoint advances only when every invoice of a window is on disk, and only to that window's HWM (for a closed window, at most its `to`). For the open-ended (last) window, a null HWM (21183, or absent) means "nothing settled yet": the checkpoint stays and the run completes. For a closed window (explicit `to`, i.e. a backfill older than 90 days), KSeF documents the HWM as equal to the query's bound. A null HWM fails the run loudly instead of skipping months of invoices. An HWM later than `to` is not an error: everything up to `to` is settled, so the checkpoint advances to `to` (never beyond it) and the loop continues from `to`. **UNCONFIRMED** what KSeF returns for a closed window until the TEST E2E (which starts more than 90 days back on purpose) exercises one; the rule above works for both answers. A run cut short (rate limit, download cap, token expiry, error) leaves the checkpoint where it was; the next run re-lists the same window (cheap) and the dedup index skips what is already saved. This satisfies "the checkpoint only advances past invoices whose XML is safely on disk" without assuming whether `from` is inclusive.
- (S) Loop: after a window with an explicit `to`, continue from the checkpoint just written (its HWM, or `to` when the HWM was later); stop after the open-ended window, or when the HWM did not move past `from`.
- (O) **State on disk, no database**, under `dataDir`:
  - `state.json`: `{"checkpoint": "<server timestamp string>"}`; absent means "use `startDate`". Written atomically (temp file + rename).
  - `index.jsonl`: append-only, one JSON object per saved invoice, doubling as the dedup set: `ksefNumber`, `invoiceNumber`, `issueDate`, `sellerNip`, `sellerName`, `grossAmount`, `currency`, `permanentStorageDate`, `invoiceHash`, `file` (relative path), `savedAt`.
  - `invoices/YYYY/MM/<ksefNumber>.xml`, year and month from `issueDate`.
  - `reports/YYYY-MM-DD.md` (date of the run in Europe/Warsaw).
- (S) **Per-invoice write order**: validate `ksefNumber` against the KSeF pattern (it becomes a file name) and `issueDate` against `^\d{4}-\d{2}-\d{2}$` (it becomes the directory); download the body as bytes (`arrayBuffer()`); check `sha256(bytes)` in Base64 equals the metadata `invoiceHash` (mismatch fails the run); write to a temp file and rename; then append the index line. A crash between rename and append re-downloads that one invoice next time and overwrites the same file: idempotent.
- (S) **Download pacing**: at least 4 s between downloads (under 16/min) and at most 60 downloads per run (under 64/h), so a 429 is the exception rather than the steady state. Hitting the cap ends the run as partial. A first backfill larger than 60 invoices completes over several runs; the README says to re-run manually after an hour.
- (O/S) **429 handling**: `Retry-After` ≤ 120 s is waited out (at most 3 retries per request); longer or unparseable ends the run as partial. Saved invoices stay saved; the next run resumes.
- (S) **Network errors** (fetch throws, including the 60 s per-request timeout) are retried 3 times, 30 s apart, before failing. launchd starts a missed job right after wake, often before Wi-Fi is up.

### 7.5 Reporting and notification
- (O) One summary macOS notification per run via `osascript` (zero dependencies). Polish copy. None when the run completed with nothing new. Always one on a partial or failed run, with the reason.
- (S) Seller name and invoice number are attacker-controlled (anyone can invoice this NIP). Notification text is passed to `osascript` as argv to an `on run argv` handler via `execFile` (no shell, nothing interpolated into AppleScript). Report fields are Markdown-escaped and newlines collapsed.
- (S) The report section is appended to `reports/YYYY-MM-DD.md` at the end of every run that saved something, was partial, or failed, so two runs on one day add two sections. The report doubles as the failure record if notifications are muted. Accepted residual risk: a hard kill (power loss) between an index append and the end of the run leaves that invoice on disk and in the index but missing from the report and notification.
- (S) Exact Polish copy (pinned in the plan): titles `KSeF: 1 nowa faktura` / `KSeF: 3 nowe faktury` / `KSeF: 5 nowych faktur`; `KSeF: pobrano częściowo (N)`; `KSeF: błąd pobierania faktur`. Amounts formatted with `Intl.NumberFormat('pl-PL')`, two decimals (e.g. `12 345,67 PLN` with a no-break space). Dates `DD.MM.YYYY`.
- (S) Code, comments, docs, ADRs, README: English. User-facing strings (notification, report, and error messages written by us that reach a notification): Polish.

### 7.6 Entry points
- `node src/main.ts`: normal run. Exit code 0 = complete, 2 = partial, 1 = failed.
- `node src/main.ts --dry-run`: authenticates and lists the first window only; prints counts to stdout; downloads nothing, writes nothing, notifies nothing, even when it fails (the owner runs it in a terminal: the reason goes to stderr and the exit code is 1). Lets the owner check certificate, key password, Keychain and permissions on PROD without spending download quota.
- `node src/main.ts --test-notification`: shows a sample notification so the owner can allow notifications for Script Editor (osascript's host) in System Settings.
- `scripts/run-daily.sh <node>`: launchd's target; runs `main.ts` and, if Node exits with anything other than 0/1/2 (e.g. 127 when the Node binary vanished after an upgrade), shows a notification itself.
- `scripts/launchagent.sh print|install|uninstall`: generates the LaunchAgent plist (label `local.ksef-daily-fetch`, daily at 08:00, logs to `~/Library/Logs/ksef-daily-fetch.log`), installs it with `launchctl bootstrap gui/<uid>` or removes it. (O) The implementer only runs `print`; the owner installs after merging and after setting up the certificate.

### 7.7 Verification before real credentials
- (O) Task 1 of the plan is a thin vertical slice: XAdES authentication against TEST with self-signed certificates, both RSA-2048 and EC P-256, before anything else is built.
- (O) End-to-end test against TEST: two random NIPs with self-signed certificates (seller A: RSA, buyer B: EC); A sends one FA(3) invoice to B; the real `run()` path executes as B into a temp data dir; assertions: XML on disk byte-identical to what was sent, index entry, report section with the `qr-test` link, notification text; a second run finds nothing and changes nothing.
- (S) **Sender side is hand-written, test-only**, under `test/support/`. It needs `GET /security/public-key-certificates` (pick the `SymmetricKeyEncryption` certificate), RSA-OAEP-SHA256 wrapping of a random AES-256 key, AES-256-CBC/PKCS#7 encryption, `POST /sessions/online`, `POST /sessions/online/{ref}/invoices`, polling `GET /sessions/{ref}/invoices/{invoiceRef}`, and `POST /sessions/online/{ref}/close`. All of it is Node's built-in `crypto` plus about 80 lines; a community client as a devDependency would add a 0.x dependency tree for code we can verify ourselves.
- (S) HWM lag: the official C# incremental E2E waits a fixed 120 s after creating invoices before querying. Our E2E waits until the invoice's session status shows a `permanentStorageDate`, then 120 s, then tries `run()` up to 4 times 60 s apart. Its `startDate` is 100 days back so the first run walks one closed window and one open window. That stays inside 20 metadata queries per hour.

## 8. Risks and open points

- **UNCONFIRMED** file format from Aplikacja Podatnika (7.2) and key type. The `--dry-run` step in the README is the first real check.
- **UNCONFIRMED** `X509IssuerName` strictness (7.3). TEST self-signed certificates have issuer = subject; the PROD issuer is the MF CA. The PROD dry run is the check.
- **UNCONFIRMED** whether `sha256(downloaded bytes)` always equals the metadata `invoiceHash`. The TEST E2E verifies it for an invoice we sent; a mismatch on PROD fails loudly, never silently.
- **UNCONFIRMED** TEST rate limits (5).
- **UNCONFIRMED** closed-window HWM equals `to` (7.4); the TEST E2E records what KSeF returns. An HWM later than `to` is treated as `to`; a missing one fails loudly.
- **UNCONFIRMED** that error 21183 can be recognised by its code appearing in the 400 response body (7.4).
- Regulation: if the KSeF token deadline is extended, nothing here changes.
- `GET /auth/{referenceNumber}` sunsets 2027-06-15; switch to `/auth/rev2/{referenceNumber}` once it is on PROD (one path string).
- A Mac powered off at 08:00 delays the run to the next day (6.1).

## 9. Left to the builder

- Internal names and file layout beyond what the plan pins.
- Log line wording (stdout/stderr only, English, never tokens, passwords or key material).
- Whether a small helper is shared between test support files.
