# KSeF Daily Fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A personal macOS tool that once a day fetches new purchase invoices from KSeF API 2.0, saves their XML to disk, and notifies the owner (macOS notification + daily Markdown report), never failing silently.

**Architecture:** TypeScript run directly by Node 22 (type stripping, no build). A hand-written `fetch` client authenticates with a KSeF certificate via a XAdES signature (`xml-crypto`), lists invoice metadata by PermanentStorage high-water mark, downloads each new invoice, and keeps file-based state (checkpoint + append-only index). A launchd LaunchAgent runs it daily; the owner installs it.

**Tech Stack:** Node v22.23.4 (native TS), pnpm 10.17.0, `xml-crypto` 6.4.0 (only runtime dependency), `typescript` 6.0.3 + `@types/node` 22.20.5 (dev), `node:test`, `/usr/bin/openssl` for test certificates, `osascript`, `security`, `launchctl`.

**Spec:** `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md` (read it first; section numbers below refer to it). ADRs: `ADR.md`.

## Global Constraints

- Work only in this repository. Never push, never add a remote.
- Coding guidelines: think first and state assumptions; minimum code; no unrequested features, no single-use abstractions, no speculative flexibility, no handling for impossible cases; surgical changes; every task ends with a verifiable check.
- Node: run code with `node <file>.ts`. Only erasable TypeScript syntax: no `enum`, no `namespace`, no constructor parameter properties. Relative imports end in `.ts`. Type-only imports use `import type`.
- Dependencies, exact versions, nothing else: `dependencies: {"xml-crypto": "6.4.0"}`, `devDependencies: {"typescript": "6.0.3", "@types/node": "22.20.5"}`. Adding any other package requires stopping and asking.
- Code, comments, docs, README, AGENTS.md, log lines: English. User-facing strings (notification, report, error messages we author that can reach a notification): Polish, exactly as pinned in this plan.
- Secrets: never print, log or write tokens, passwords or key material. Never write to the user's Keychain. Never use a real certificate. Never call the DEMO or PROD API.
- Network calls only to `https://api-test.ksef.mf.gov.pl/v2` and only in the `test/e2e/` tests. TEST may be under maintenance 16:00–18:00 Europe/Warsaw; do not run E2E then.
- Never run `scripts/launchagent.sh install` or `uninstall`, never call `launchctl bootstrap`/`bootout`. Only `print` is allowed.
- Every commit message ends with the attribution lines your harness provides (the orchestrator decides if in doubt).
- pnpm `minimumReleaseAge` needs pnpm ≥ 10.16 (UNCONFIRMED that 10.17.0 honours it from `pnpm-workspace.yaml`): after `pnpm install`, `pnpm config get minimumReleaseAge` must print `20160`; if it does not, report it instead of working around it.

## Review Focus

1. **Seller-controlled text** (anyone can invoice this NIP): a seller name or invoice number containing quotes, backslashes, newlines, `"; do shell script "…`, or Markdown (`*`, `[`, `` ` ``, `|`, `#`, `<`) must reach the notification verbatim as one argv element and appear escaped on one line in the report. Tests in Task 7.
2. **Mac wakes before the network is up**: fetch throws → retried 3× 30 s apart → then a failure notification with a Polish reason. Tests in Task 3 and Task 8.
3. **Wrong key password / missing Keychain item / key not matching certificate**: the run fails with a Polish reason in the notification and in the report. Tests in Task 1 (wrong password, mismatched key), Task 2 (missing Keychain item), Task 8 (run-level notification and report).
4. **Hostile or malformed `ksefNumber` or `issueDate` from the API** (e.g. `../../x`): rejected before either becomes part of a path; nothing written; run fails loudly. Tests in Task 6.
5. **Two runs on one day, and a run with nothing new**: the report gets a second section (never overwritten); a run with nothing new writes no report and shows no notification; the index never gets a duplicate line. Tests in Task 5 and Task 8.

---

## File structure

```
.gitignore
package.json                 # scripts, pinned deps, "type": "module"
pnpm-workspace.yaml          # minimumReleaseAge
tsconfig.json                # noEmit type check only
config.example.json          # committed; config.json is gitignored
AGENTS.md                    # project instructions for agents
README.md                    # owner's setup guide
src/
  environments.ts            # Environment type, API and QR hosts per env
  config.ts                  # parse + validate config.json, NIP checksum
  credentials.ts             # load cert + decrypt key; read key password from Keychain
  xades.ts                   # AuthTokenRequest XML + XAdES-BES signature
  http.ts                    # fetch wrapper: errors, timeout, 429 and network retries
  ksef.ts                    # authenticate, queryMetadata, downloadInvoice + API types
  store.ts                   # state.json, index.jsonl, invoice files, report append
  sync.ts                    # windows, paging/truncation, per-invoice processing, checkpoint
  report.ts                  # pure: Polish report section + notification text
  notify.ts                  # osascript notifier
  run.ts                     # one run end to end (injectable fetch/clock/notifier)
  main.ts                    # CLI: flags, config, Keychain, exit codes
scripts/
  run-daily.sh               # launchd target; notifies if Node cannot run
  launchagent.sh             # print | install | uninstall the LaunchAgent
test/
  support/certs.ts           # self-signed test cert + encrypted PKCS#8 key via /usr/bin/openssl
  support/nip.ts             # random valid NIP
  support/fake-ksef.ts       # in-memory fake of the KSeF endpoints for run() tests
  support/send-invoice.ts    # TEST-only online-session sender (never imported by src/)
  fixtures/fa3-invoice.xml   # FA(3) template with placeholders
  unit/*.test.ts             # offline unit tests (pnpm test)
  e2e/auth.e2e.ts            # Task 1 slice against TEST
  e2e/fetch.e2e.ts           # full E2E against TEST
```

Shared types (defined once, used everywhere):

```ts
// src/environments.ts
export type Environment = 'test' | 'demo' | 'prod';
export const ENVIRONMENTS: Record<Environment, { apiBase: string; qrBase: string }>;
// test: https://api-test.ksef.mf.gov.pl/v2, https://qr-test.ksef.mf.gov.pl
// demo: https://api-demo.ksef.mf.gov.pl/v2, https://qr-demo.ksef.mf.gov.pl
// prod: https://api.ksef.mf.gov.pl/v2,      https://qr.ksef.mf.gov.pl

// src/ksef.ts
export interface AccessToken { token: string; validUntil: string }
export interface Window { from: string; to?: string }
export interface InvoiceMetadata {
  ksefNumber: string; invoiceNumber: string; issueDate: string;          // issueDate: YYYY-MM-DD
  permanentStorageDate: string; seller: { nip: string; name?: string | null };
  grossAmount: number; currency: string; invoiceHash: string;            // invoiceHash: SHA-256 Base64
}
export interface MetadataPage {
  hasMore: boolean; isTruncated: boolean;
  permanentStorageHwmDate?: string | null; invoices: InvoiceMetadata[];
}

// src/report.ts
export interface RunSummary {
  startedAt: Date; status: 'complete' | 'partial' | 'failed';
  reason?: string; failureKey?: string; saved: InvoiceMetadata[]; // failureKey: stable key of a failed run, see the widget plan's W1
}
```

---

### Task 1: Scaffold + XAdES authentication slice against TEST

The riskiest piece first: prove that our XAdES signature authenticates against KSeF TEST with self-signed certificates, RSA-2048 and EC P-256, before anything is built on top.

**Files:**
- Create: `.gitignore`, `package.json`, `pnpm-workspace.yaml`, `tsconfig.json`, `pnpm-lock.yaml` (generated)
- Create: `src/environments.ts`, `src/credentials.ts`, `src/xades.ts`, `src/http.ts`, `src/ksef.ts`
- Create: `test/support/certs.ts`, `test/support/nip.ts`
- Test: `test/unit/xades.test.ts`, `test/unit/credentials.test.ts`, `test/unit/auth.test.ts`, `test/e2e/auth.e2e.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ENVIRONMENTS`, `Environment` (`src/environments.ts`, values above).
  - `interface Credentials { certificatePem: string; certificate: X509Certificate; privateKey: KeyObject }` and `loadCredentials(certificatePath: string, keyPath: string, password: string): Promise<Credentials>` (`src/credentials.ts`).
  - `buildAuthTokenRequest(challenge: string, nip: string): string` and `signXades(xml: string, credentials: Credentials, signingTime: Date): string` (`src/xades.ts`).
  - `class KsefApiError extends Error` with `constructor(status: number, method: string, path: string, body: string)` and those four as public readonly fields, `interface HttpDeps { fetch: typeof fetch; sleep: (ms: number) => Promise<void> }`, `interface RequestOptions { token?: string; json?: unknown; xml?: string; accept?: string }`, `type Http = (method: 'GET' | 'POST', path: string, options?: RequestOptions) => Promise<Response>`, `createHttp(apiBase: string, deps: HttpDeps): Http` (`src/http.ts`).
  - `authenticate(http: Http, credentials: Credentials, nip: string, environment: Environment, deps: { sleep: (ms: number) => Promise<void> }): Promise<AccessToken>` (`src/ksef.ts`).
  - Test helpers: `makeTestCredentials(options: { nip: string; keyType: 'rsa' | 'ec'; dir: string }): Promise<{ certificatePath: string; keyPath: string; password: string }>` (`test/support/certs.ts`); `randomNip(): string` (`test/support/nip.ts`).

- [ ] **Step 1: Scaffold the project**

`package.json`:
```json
{
  "name": "ksef-daily-fetch",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22.18" },
  "packageManager": "pnpm@10.17.0",
  "scripts": {
    "test": "node --test \"test/unit/**/*.test.ts\"",
    "typecheck": "tsc --noEmit -p .",
    "test:e2e:auth": "node --test test/e2e/auth.e2e.ts",
    "test:e2e": "node --test test/e2e/fetch.e2e.ts"
  },
  "dependencies": { "xml-crypto": "6.4.0" },
  "devDependencies": { "typescript": "6.0.3", "@types/node": "22.20.5" }
}
```
`pnpm-workspace.yaml`: `minimumReleaseAge: 20160` (one line; holds back releases younger than 14 days).
`tsconfig.json` compilerOptions: `target: "es2023"`, `module: "nodenext"`, `moduleResolution: "nodenext"`, `strict: true`, `noEmit: true`, `allowImportingTsExtensions: true`, `verbatimModuleSyntax: true`, `erasableSyntaxOnly: true`, `types: ["node"]`, `skipLibCheck: true`; `include: ["src", "test"]`. If TypeScript 6.0.3 rejects an option, remove only that option and say so in the commit message.
`.gitignore`: `node_modules/`, `data/`, `config.json`, `*.key`, `*.crt`, `*.pem`, `*.p12`, `.DS_Store`.

Run: `pnpm install` → creates `pnpm-lock.yaml`. Expected: no install scripts run; `xml-crypto 6.4.0` resolved.

- [ ] **Step 2: Write test helpers**

`randomNip()`: 10 digits; first digit 1–9; digits 2–3 not both `0` (OpenAPI pattern `^[1-9]((\d[1-9])|([1-9]\d))\d{7}$`); check digit = Σ(dᵢ·wᵢ) mod 11 with weights `6,5,7,2,3,4,5,6,7`, redraw when it is 10.

`makeTestCredentials`: random hex password (`randomBytes(12)`), then `execFile('/usr/bin/openssl', [...])` (never a shell):
```
req -x509 -newkey rsa:2048                                   (rsa)
req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256        (ec)
  -keyout <dir>/<nip>.key -out <dir>/<nip>.crt -days 30 -passout pass:<password>
  -subj /GN=Jan/SN=Testowy/serialNumber=TINPL-<nip>/CN=Jan Testowy/C=PL
```
Output is a PEM `.crt` and a `-----BEGIN ENCRYPTED PRIVATE KEY-----` `.key`, the same shapes the owner gets from Aplikacja Podatnika (spec 5, UNCONFIRMED).

- [ ] **Step 3: Write failing tests for credentials and XAdES**

`test/unit/credentials.test.ts` (temp dir via `mkdtemp`):
- `loads an encrypted RSA key and its certificate`: `privateKey.asymmetricKeyType === 'rsa'`, `certificate.subject` contains `serialNumber=TINPL-<nip>`.
- `loads an encrypted EC P-256 key`: `asymmetricKeyDetails.namedCurve === 'prime256v1'`.
- `rejects a wrong password`: rejects with message starting `Nie można odczytać klucza prywatnego (złe hasło lub format)`.
- `rejects a key that does not match the certificate` (key of fixture A + cert of fixture B): message `Klucz prywatny nie pasuje do certyfikatu`.

`test/unit/xades.test.ts`:
- `buildAuthTokenRequest` returns exactly:
  ```xml
  <?xml version="1.0" encoding="utf-8"?><AuthTokenRequest xmlns="http://ksef.mf.gov.pl/auth/token/2.0"><Challenge>20261126-CR-0123456789-ABCDEF0123-AB</Challenge><ContextIdentifier><Nip>5265877635</Nip></ContextIdentifier><SubjectIdentifierType>certificateSubject</SubjectIdentifierType></AuthTokenRequest>
  ```
- For each key type (`rsa`, `ec`), sign with `signingTime = new Date('2026-11-26T08:00:00Z')` and assert with string/regex checks on the output (do not import `@xmldom/xmldom`: pnpm does not hoist transitive dependencies):
  - `SignatureMethod Algorithm` is `http://www.w3.org/2001/04/xmldsig-more#rsa-sha256` (rsa) / `http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256` (ec).
  - `CanonicalizationMethod` is `http://www.w3.org/2001/10/xml-exc-c14n#`.
  - Exactly two `Reference`s: one `URI=""` with transforms `http://www.w3.org/2000/09/xmldsig#enveloped-signature` then `http://www.w3.org/2001/10/xml-exc-c14n#`; one `URI="#SignedProperties"` with `Type="http://uri.etsi.org/01903#SignedProperties"` and the exc-c14n transform; both `DigestMethod` `http://www.w3.org/2001/04/xmlenc#sha256`.
  - The `Signature` element has `Id="Signature"` and is the last child of `AuthTokenRequest`.
  - `xades:QualifyingProperties` has `Target="#Signature"`, `xmlns:xades="http://uri.etsi.org/01903/v1.3.2#"`, and is inside a `ds:Object`.
  - `xades:SigningTime` is `2026-11-26T07:59:00.000Z` (signing time minus one minute).
  - `CertDigest/DigestValue` equals `createHash('sha256').update(certificate.raw).digest('base64')`.
  - `X509SerialNumber` equals `BigInt('0x' + certificate.serialNumber).toString()`.
  - `X509IssuerName` equals `certificate.issuer.split('\n').reverse().join(', ')` XML-escaped.
  - `X509Certificate` text equals the certificate's Base64 body (PEM without header/footer/newlines).
  - ec only: decoded `SignatureValue` is exactly 64 bytes.
  - The signature verifies: a fresh `SignedXml` with `publicCert: certificatePem` and the same ECDSA algorithm registered, `loadSignature(<the ds:Signature substring>)`, returns `true` from `checkSignature(signedXml)`. (Self-verification only proves internal consistency; Step 7 is the real check.)

Run: `pnpm test` → FAIL (modules do not exist).

- [ ] **Step 4: Implement `loadCredentials` in `src/credentials.ts`**

Read both files; `createPrivateKey({ key, format: 'pem', passphrase: password })` (wrap failure: `Nie można odczytać klucza prywatnego (złe hasło lub format): ${err.message}`); `new X509Certificate(pem)`; `certificate.checkPrivateKey(key)` else `Klucz prywatny nie pasuje do certyfikatu`; accept only `rsa` with `modulusLength >= 2048` or `ec` with `namedCurve === 'prime256v1'`, else `Nieobsługiwany typ klucza: ${type}; wymagany RSA 2048+ lub EC P-256`.

- [ ] **Step 5: Implement `buildAuthTokenRequest` and `signXades` in `src/xades.ts`**

`signXades` uses `xml-crypto`'s `SignedXml` (spec 7.3; mirrors the official C# `SignatureService`):
- `new SignedXml({ privateKey: credentials.privateKey, publicCert: credentials.certificatePem, signatureAlgorithm, canonicalizationAlgorithm: 'http://www.w3.org/2001/10/xml-exc-c14n#', objects: [{ content: qualifyingProperties }] })`.
- For EC register `sig.SignatureAlgorithms['http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256'] = EcdsaSha256`, a class with `getSignature(signedInfo, key)` → `crypto.sign('sha256', Buffer.from(signedInfo), { key, dsaEncoding: 'ieee-p1363' }).toString('base64')`, `verifySignature(material, key, value)` → `crypto.verify(...)` with the same encoding, `getAlgorithmName()` → the URI. Export the class so the unit test can register it for verification.
- `addReference({ xpath: '/*', isEmptyUri: true, transforms: [enveloped, excC14n], digestAlgorithm: 'http://www.w3.org/2001/04/xmlenc#sha256' })`.
- `addReference({ xpath: "//*[@Id='SignedProperties']", type: 'http://uri.etsi.org/01903#SignedProperties', transforms: [excC14n], digestAlgorithm: sha256 })`.
- `computeSignature(xml, { prefix: 'ds', attrs: { Id: 'Signature' }, location: { reference: '/*', action: 'append' } })`; return `getSignedXml()`.
- `qualifyingProperties` (one string, no whitespace between elements; `ds:` resolves through the generated `ds:Signature`):
  ```xml
  <xades:QualifyingProperties xmlns:xades="http://uri.etsi.org/01903/v1.3.2#" Target="#Signature"><xades:SignedProperties Id="SignedProperties"><xades:SignedSignatureProperties><xades:SigningTime>{signingTime − 60 s, toISOString()}</xades:SigningTime><xades:SigningCertificate><xades:Cert><xades:CertDigest><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>{sha256(cert.raw) base64}</ds:DigestValue></xades:CertDigest><xades:IssuerSerial><ds:X509IssuerName>{escaped issuer}</ds:X509IssuerName><ds:X509SerialNumber>{decimal serial}</ds:X509SerialNumber></xades:IssuerSerial></xades:Cert></xades:SigningCertificate></xades:SignedSignatureProperties></xades:SignedProperties></xades:QualifyingProperties>
  ```
  XML-escape `&`, `<`, `>`, `"` in the issuer.

Run: `pnpm test` → xades and credentials tests PASS. The summary must show a non-zero `# tests` count; if it is 0, the glob in the `test` script did not match and must be fixed. Import `SignedXml` with a named import from `'xml-crypto'` (its CommonJS exports are statically detectable).

- [ ] **Step 6: Write failing auth unit test, then implement `createHttp` (basic) and `authenticate`**

`test/unit/auth.test.ts` with a hand-rolled fake `fetch` (records requests, answers by path) and `sleep` that records calls and resolves immediately:
- `authenticates: challenge, signed XML, polls until 200, redeems`: status sequence `100, 100, 200` → three status calls, two `sleep(1000)`; returns `{ token: 'acc', validUntil }` from `/auth/token/redeem`. Assert: `POST {apiBase}/auth/challenge`; `POST /auth/xades-signature?verifyCertificateChain=false` with `Content-Type: application/xml` and a body containing `<ds:Signature`; status `GET /auth/<referenceNumber>` and redeem `POST /auth/token/redeem` both with `Authorization: Bearer <authenticationToken.token>`.
- `omits verifyCertificateChain outside test`: environment `prod` → path is exactly `/auth/xades-signature`.
- `fails with KSeF status details`: status `{ code: 460, description: 'Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu', details: ['Certyfikat odwołany'] }` → rejects with `Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)`.
- `gives up after 120 polls`: always `100` → rejects with `Uwierzytelnienie w KSeF nie zakończyło się w 120 s`.
- `non-2xx becomes KsefApiError`: challenge answers 500 `{"x":1}` → rejects with `KsefApiError`, `status === 500`, message `KSeF odpowiedział 500 na POST /auth/challenge: {"x":1}` (body excerpt max 300 chars).

`createHttp` (basic, Task 3 adds retries): URL = `apiBase + path`; headers `Accept: options.accept ?? 'application/json'`; `Authorization: Bearer <token>` when given; `json` → `Content-Type: application/json` + `JSON.stringify`; `xml` → `Content-Type: application/xml`; `signal: AbortSignal.timeout(60_000)`; non-2xx → read text, throw `KsefApiError`. Response shapes: spec 5 "Authentication". Poll interval 1000 ms, max 120 polls. Signing time `new Date()`.

Run: `pnpm test` → PASS. `pnpm typecheck` → no errors.

- [ ] **Step 7: Write and run the TEST slice `test/e2e/auth.e2e.ts`**

For `keyType` of `['rsa', 'ec']` (sequential): `nip = randomNip()`, `makeTestCredentials` in a temp dir, `loadCredentials`, `createHttp(ENVIRONMENTS.test.apiBase, { fetch, sleep: real })`, `authenticate(..., 'test', ...)`. Assert `token.length > 0` and `Date.parse(validUntil) > Date.now()`. Never print the token.

Run: `pnpm test:e2e:auth`
Expected: 2 tests PASS.

If KSeF rejects the signature (status 4xx/450/460 or 400 from `/auth/xades-signature`), investigate in this order, changing one thing at a time and re-running: (1) `X509IssuerName` format (spec 7.3, UNCONFIRMED) — try the subject/issuer lines in the original order; (2) `SigningTime` format (try without milliseconds); (3) EC only: `SignatureValue` must be 64 raw bytes; (4) `KeyInfo` must contain the certificate; (5) the `?verifyCertificateChain=false` query; (6) the certificate subject (`GN`, `SN`, `serialNumber=TINPL-…`, `CN`, `C=PL`). Record what fixed it in the commit message. Stop and report if none works; do not build further tasks on a failing slice.

- [ ] **Step 8: Commit**

```bash
git add .gitignore package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.json src test
git commit -m "feat: XAdES certificate authentication against KSeF TEST"
```

---

### Task 2: Configuration

**Files:**
- Create: `src/config.ts`, `config.example.json`
- Modify: `src/credentials.ts` (add `readKeyPassword`)
- Test: `test/unit/config.test.ts`, `test/unit/credentials.test.ts`

**Interfaces:**
- Consumes: `Environment` (Task 1).
- Produces:
  - `interface Config { nip: string; environment: Environment; certificatePath: string; keyPath: string; startDate: string; dataDir: string }` (`dataDir` absolute after parsing).
  - `isValidNip(nip: string): boolean`; `parseConfig(raw: unknown, repoRoot: string, today: Date): Config`; `loadConfig(path: string, repoRoot: string): Promise<Config>` (reads JSON, calls `parseConfig` with `new Date()`; unreadable/missing file → `Nie można wczytać config.json: ${err.message}`).
  - `readKeyPassword(nip: string, exec?: (file: string, args: string[]) => Promise<{ stdout: string }>): Promise<string>` in `src/credentials.ts`, default `exec` = promisified `execFile`.

- [ ] **Step 1: Write failing tests**

`test/unit/config.test.ts` (`repoRoot = '/repo'`, `today = new Date('2026-11-26T12:00:00Z')`, base = the example below with `nip: '5265877635'`):
- `accepts a valid config and resolves dataDir`: `dataDir: 'data'` → `'/repo/data'`; absent `dataDir` → `'/repo/data'`; `dataDir: '/tmp/x'` → `'/tmp/x'`.
- `isValidNip`: `true` for `5265877635`; `false` for `5265877636` (checksum), `526587763` (length), `0265877635` (leading zero).
- Each invalid field throws exactly:
  - nip → `config.json: nip musi mieć 10 cyfr i poprawną sumę kontrolną`
  - environment `'production'` → `config.json: environment musi być jednym z: test, demo, prod`
  - certificatePath `'cert.crt'` or `'~/x.crt'` → `config.json: certificatePath musi być ścieżką bezwzględną`
  - keyPath likewise → `config.json: keyPath musi być ścieżką bezwzględną`
  - startDate `'2026-13-01'`, `'1.02.2026'`, `'2026-11-27'` (future vs `today`) → `config.json: startDate musi mieć format RRRR-MM-DD i nie może być z przyszłości`
  - dataDir `42` → `config.json: dataDir musi być tekstem`
  - `raw` not an object → `config.json: oczekiwano obiektu JSON`

Add to `test/unit/credentials.test.ts`:
- `readKeyPassword calls security with the service and NIP`: fake exec receives `('security', ['find-generic-password', '-s', 'ksef-daily-fetch', '-a', '5265877635', '-w'])` and returns `{ stdout: 'secret\n' }` → resolves `'secret'`.
- `readKeyPassword explains a missing Keychain item`: exec rejects → message `Brak hasła klucza w Pęku kluczy (usługa ksef-daily-fetch, konto 5265877635)`.

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement `src/config.ts` and `readKeyPassword`**

`startDate` must match `^\d{4}-\d{2}-\d{2}$` and round-trip through `new Date(startDate + 'T00:00:00Z').toISOString().slice(0, 10)`, and be ≤ `today`'s UTC date. Absolute path = `path.isAbsolute`.

`config.example.json`:
```json
{
  "nip": "1234567890",
  "environment": "prod",
  "certificatePath": "/Users/YOU/.config/ksef-daily-fetch/ksef-auth.crt",
  "keyPath": "/Users/YOU/.config/ksef-daily-fetch/ksef-auth.key",
  "startDate": "2026-02-01",
  "dataDir": "data"
}
```

- [ ] **Step 3: Verify**

Run: `pnpm test && pnpm typecheck` → PASS, no errors.

- [ ] **Step 4: Commit**

```bash
git add src/config.ts src/credentials.ts config.example.json test/unit
git commit -m "feat: validated config and Keychain password lookup"
```

---

### Task 3: HTTP resilience (429 and network errors)

**Files:**
- Modify: `src/http.ts`
- Test: `test/unit/http.test.ts`

**Interfaces:**
- Consumes: `createHttp`, `KsefApiError` (Task 1).
- Produces: `class RateLimitError extends Error` with `constructor(retryAfterSeconds: number)` and a public readonly `retryAfterSeconds` (message `Limit zapytań KSeF — trzeba odczekać ${retryAfterSeconds} s.`); `createHttp` keeps its signature. Constants exported from `src/http.ts`: `MAX_RETRY_AFTER_SECONDS = 120`, `MAX_RATE_LIMIT_RETRIES = 3`, `NETWORK_RETRIES = 3`, `NETWORK_RETRY_DELAY_MS = 30_000`, `REQUEST_TIMEOUT_MS = 60_000`.

- [ ] **Step 1: Write failing tests** (fake `fetch` returning queued responses or throwing; `sleep` records ms)
- `waits out a short Retry-After`: 429 `Retry-After: 5`, then 200 → resolves the 200; `sleep` called with `[5000]`.
- `missing Retry-After counts as 60 s`: 429 without header, then 200 → `sleep` `[60000]`.
- `long Retry-After ends with RateLimitError`: 429 `Retry-After: 600` → rejects `RateLimitError`, `retryAfterSeconds === 600`, `sleep` never called.
- `gives up after three rate-limit retries`: four 429 `Retry-After: 1` → `RateLimitError`; fetch called 4 times.
- `retries network errors`: fetch throws `new TypeError('fetch failed')` twice, then 200 → resolves; `sleep` `[30000, 30000]`.
- `network error after retries`: throws 4 times → rejects with message `Brak połączenia z KSeF: fetch failed`; fetch called 4 times.
- `server errors are not retried`: 500 → `KsefApiError` after one call.
- `passes a timeout signal`: `init.signal instanceof AbortSignal`.

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement** in `createHttp`: a request is re-sent (with a fresh timeout signal) after a waited 429 or a thrown fetch; the two retry budgets are independent. Non-numeric `Retry-After` → treat as longer than the threshold.

- [ ] **Step 3: Verify** `pnpm test && pnpm typecheck` → PASS.

- [ ] **Step 4: Commit** `git commit -m "feat: retry KSeF 429 and network errors"` (add `src/http.ts test/unit/http.test.ts`).

---

### Task 4: Metadata query and invoice download

**Files:**
- Modify: `src/ksef.ts`
- Test: `test/unit/ksef.test.ts`

**Interfaces:**
- Consumes: `Http` (Task 1), shared types above.
- Produces: `queryMetadata(http: Http, token: string, window: Window, pageOffset: number): Promise<MetadataPage>`; `downloadInvoice(http: Http, token: string, ksefNumber: string): Promise<Buffer>`; constant `PAGE_SIZE = 250`.

- [ ] **Step 1: Write failing tests**
- `queries purchase invoices by PermanentStorage`: `window = { from: '2026-11-25T08:00:00.1234567+00:00' }`, `pageOffset = 2` → `POST /invoices/query/metadata?sortOrder=Asc&pageOffset=2&pageSize=250`, Bearer token, JSON body deep-equals `{ subjectType: 'Subject2', dateRange: { dateType: 'PermanentStorage', from: '2026-11-25T08:00:00.1234567+00:00', restrictToPermanentStorageHwmDate: true } }` (no `to` key); with `to` set, `to` is included verbatim. Returns the parsed body.
- `downloads raw invoice bytes`: `GET /invoices/ksef/5265877635-20261126-0123456789AB-CD` with `Accept: application/xml` and Bearer token; returns a `Buffer` equal byte for byte to the response (include a UTF-8 `ł` and a `\r\n` in the fixture body).

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement** (`downloadInvoice` uses `Buffer.from(await res.arrayBuffer())`; never `res.text()`).

- [ ] **Step 3: Verify** `pnpm test && pnpm typecheck` → PASS.

- [ ] **Step 4: Commit** `git commit -m "feat: KSeF metadata query and invoice download"`.

---

### Task 5: File-based store

**Files:**
- Create: `src/store.ts`
- Test: `test/unit/store.test.ts`

**Interfaces:**
- Consumes: `InvoiceMetadata`.
- Produces:
  ```ts
  export interface Store {
    readonly checkpoint: string | null;
    has(ksefNumber: string): boolean;
    savedSince(instant: Date): number; // invoices whose index `savedAt` is after `instant`, this run's saves included
    saveInvoice(invoice: InvoiceMetadata, xml: Buffer): Promise<void>;
    writeCheckpoint(value: string): Promise<void>;
  }
  export function openStore(dataDir: string, now: () => Date): Promise<Store>;
  export function appendReport(dataDir: string, day: string, section: string): Promise<void>;
  ```
  Layout (spec 7.4): `state.json` `{"checkpoint": "..."}`; `index.jsonl` lines `{ksefNumber, invoiceNumber, issueDate, sellerNip, sellerName, grossAmount, currency, permanentStorageDate, invoiceHash, file, savedAt}` with `file` relative to `dataDir` and `sellerName` `null` when absent; `invoices/YYYY/MM/<ksefNumber>.xml` from `issueDate`; `reports/<day>.md`.

- [ ] **Step 1: Write failing tests** (temp dirs)
- `opening a missing dataDir creates nothing`: `checkpoint === null`, `has('x') === false`, directory still absent afterwards.
- `saves invoice bytes and indexes them`: `issueDate '2026-11-20'` → file `invoices/2026/11/<ksefNumber>.xml` equals the Buffer; one `index.jsonl` line whose JSON has `file === 'invoices/2026/11/<ksefNumber>.xml'` and `savedAt === now().toISOString()`; `has(ksefNumber) === true`; no `*.tmp` file left in the directory.
- `savedSince counts saves of earlier runs and of this one`: three saves at 07:00, 07:45 (separate `openStore` calls with those clocks) and 08:00 → `savedSince(06:00) === 3`, `(07:30) === 2`, `(07:45) === 1`, `(08:00) === 0`.
- `reopening keeps the dedup set`: new `openStore` on the same dir → `has(ksefNumber) === true`.
- `checkpoint is stored verbatim`: `writeCheckpoint('2026-11-26T07:00:00.1234567+00:00')`, reopen → identical string.
- `a corrupt index line fails loudly`: `index.jsonl` with a valid line then `{"ksefNumber":` → `openStore` rejects with message `Uszkodzony plik index.jsonl, linia 2`.
- `appendReport appends, never overwrites`: two calls for day `2026-11-26` → file is `# Faktury z KSeF — 2026-11-26\n\n` + section1 + `\n` + section2 + `\n` (header written only when the file is new).

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement.** Directories created lazily with `mkdir({ recursive: true })` inside the write functions. Invoice and `state.json` writes: write `<target>.tmp`, then `rename`. Index: `appendFile` of `JSON.stringify(line) + '\n'` after the rename.

- [ ] **Step 3: Verify** `pnpm test && pnpm typecheck` → PASS.

- [ ] **Step 4: Commit** `git commit -m "feat: file-based checkpoint, index and invoice store"`.

---

### Task 6: Sync engine

**Files:**
- Create: `src/sync.ts`
- Test: `test/unit/sync.test.ts`

**Interfaces:**
- Consumes: `Store` (Task 5), `RateLimitError`, `KsefApiError` (Tasks 1, 3), `MetadataPage`, `InvoiceMetadata`, `Window`.
- Produces:
  ```ts
  export const MAX_WINDOW_DAYS = 90;
  export const MAX_DOWNLOADS_PER_HOUR = 60;
  export const MIN_DOWNLOAD_INTERVAL_MS = 4_000;
  export const TOKEN_MARGIN_MS = 60_000;
  export const KSEF_NUMBER_PATTERN: RegExp; // OpenAPI KsefNumber pattern, spec 5
  export type Query = (window: Window, pageOffset: number) => Promise<MetadataPage>;
  export function nextWindow(from: string, now: Date): Window;
  export function listWindow(query: Query, window: Window): Promise<{ invoices: InvoiceMetadata[]; hwm: string | null }>;
  export interface SyncDeps {
    from: string; store: Store; query: Query;
    download: (ksefNumber: string) => Promise<Buffer>;
    tokenValidUntil: string; now: () => Date; sleep: (ms: number) => Promise<void>;
    onSaved: (invoice: InvoiceMetadata) => void;
  }
  export type SyncOutcome = { status: 'complete' } | { status: 'partial'; reason: string };
  export function syncInvoices(deps: SyncDeps): Promise<SyncOutcome>;
  ```

Algorithm (spec 7.4 — the checkpoint rule is the one subtle part):
```
from = deps.from
loop:
  window = nextWindow(from, now())
  { invoices, hwm } = listWindow(query, window)            // RateLimitError → partial
  for invoice in invoices (ascending, as listed):
    if store.has(invoice.ksefNumber): continue
    if !KSEF_NUMBER_PATTERN.test(invoice.ksefNumber): throw
    if !/^\d{4}-\d{2}-\d{2}$/.test(invoice.issueDate): throw
    if Date.parse(tokenValidUntil) - now() < TOKEN_MARGIN_MS: return partial(token)
    sleep(MIN_DOWNLOAD_INTERVAL_MS - (now() - lastDownloadAt)) when positive
    if store.savedSince(now() - 1 h) >= MAX_DOWNLOADS_PER_HOUR: return partial(cap)   // rolling hour across runs, evaluated per download
    bytes = download(ksefNumber)                            // RateLimitError → partial
    if sha256(bytes).base64 !== invoice.invoiceHash: throw
    store.saveInvoice(invoice, bytes); onSaved(invoice)
  if window.to !== undefined and hwm === null: throw        // closed window must report an HWM
  if hwm === null: return complete                          // open window: checkpoint unchanged
  next = (window.to !== undefined and Date.parse(hwm) > Date.parse(window.to)) ? window.to : hwm
  store.writeCheckpoint(next)                               // an HWM past a closed window's `to` settles only up to `to`
  if window.to === undefined or next === from: return complete
  from = next
```
`nextWindow`: `to = new Date(Date.parse(from) + MAX_WINDOW_DAYS * 86_400_000).toISOString()` only if that instant is before `now`; otherwise no `to`. `from` is passed through unchanged.
`listWindow`: page from `pageOffset = 0`; collect; stop when `!hasMore`; if `isTruncated`, continue with `from` = last invoice's `permanentStorageDate` and `pageOffset = 0`, else `pageOffset + 1`; dedupe by `ksefNumber` keeping first occurrence; `hwm` = last page's `permanentStorageHwmDate ?? null`. A `KsefApiError` with `status === 400` whose `body` contains `21183` → `{ invoices: [], hwm: null }`; any other error propagates.

Polish texts: cap → `Limit 60 pobrań na godzinę.`; token → `Token dostępu wkrótce wygaśnie.`; rate limit → the `RateLimitError` message; hash → `Skrót pobranej faktury ${ksefNumber} nie zgadza się z metadanymi KSeF`; pattern → `Nieprawidłowy numer KSeF w odpowiedzi API: ${JSON.stringify(ksefNumber).slice(0, 60)}`; issue date → `Nieprawidłowa data wystawienia w odpowiedzi API: ${JSON.stringify(issueDate).slice(0, 60)}`; closed-window HWM → `Nieoczekiwany permanentStorageHwmDate (${hwm}) dla okna ${from} – ${to}`.

- [ ] **Step 1: Write failing tests** (in-memory fake `Store`; fake clock where `sleep(ms)` advances `now` by `ms`; invoices built by a helper whose `invoiceHash` is the real SHA-256 of its bytes)
- `nextWindow`: from `2026-01-01T00:00:00Z`, now `2026-11-26T08:00:00Z` → `{ from: '2026-01-01T00:00:00Z', to: '2026-04-01T00:00:00.000Z' }`; from `2026-11-01T00:00:00.1234567+00:00` → `{ from: '2026-11-01T00:00:00.1234567+00:00' }` (no `to`, `from` verbatim).
- `listWindow pages until hasMore is false`: pages `[A,B] hasMore` then `[C] !hasMore` → query calls `(w, 0)`, `(w, 1)`; invoices `[A,B,C]`; hwm from the second page.
- `listWindow narrows from on truncation`: page 1 `[A,B] hasMore isTruncated` → call 2 has `window.from === B.permanentStorageDate`, `pageOffset 0`, same `to`; page 2 `[B,C]` → result `[A,B,C]` (B once).
- `listWindow treats 21183 as nothing settled yet`: query rejects `new KsefApiError(400, ..., body containing '"exceptionCode":21183')` → `{ invoices: [], hwm: null }`; a 400 without `21183` rejects.
- `saves new invoices in order and advances the checkpoint to the HWM`: store already has B; window `[A,B,C]`, hwm `H` → downloads A then C; `onSaved` A, C; `writeCheckpoint('H')` once; `complete`.
- `walks a closed window then the open one`: from 100 days before now; first page's hwm equals the first window's `to` → first query has `to`, second has none and `from === hwm1`; checkpoint written twice, ending at `hwm2`.
- `rate limit mid-window is partial and keeps the checkpoint`: download of the 2nd invoice rejects `RateLimitError(600)` → `{ status: 'partial', reason: 'Limit zapytań KSeF — trzeba odczekać 600 s.' }`; first invoice saved; `writeCheckpoint` never called.
- `stops at the hourly download cap`: 61 new invoices → 60 saved, `partial` with `Limit 60 pobrań na godzinę.`, no checkpoint write.
- `earlier saves count against the hourly cap` (fake store whose `savedSince` counts earlier `savedAt` values plus this run's saves): 60 saves from 30 minutes ago + 1 new → no download, `partial`; 60 from 61 minutes ago + 1 new → downloads; 59 recent + 2 new → one download, then `partial`; saves that age out mid-run free up room.
- `paces downloads`: 3 downloads with instant fake downloads → `sleep` called with `4000` twice.
- `token about to expire ends the run`: `tokenValidUntil` = now + 30 s → `partial` with `Token dostępu wkrótce wygaśnie.`, nothing downloaded.
- `hash mismatch fails`: wrong `invoiceHash` → rejects with the hash message; `saveInvoice` not called.
- `hostile ksefNumber is rejected before download`: `ksefNumber: '../../etc/passwd'` → rejects with the pattern message; `download` and `saveInvoice` not called.
- `hostile issueDate is rejected before download`: `issueDate: '../../x'` → rejects with the issue-date message; `download` and `saveInvoice` not called.
- `null HWM on the open window keeps the checkpoint`: hwm `null`, no `to` → `complete`, no `writeCheckpoint`.
- `closed window must report its HWM`: window with `to`, hwm `null` → rejects with the closed-window message; no `writeCheckpoint`.
- `closed window with an HWM past its end settles up to its end`: hwm one day after `to` → `writeCheckpoint(to)`, then the loop continues from `to` with the next window.

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement** as above.

- [ ] **Step 3: Verify** `pnpm test && pnpm typecheck` → PASS.

- [ ] **Step 4: Commit** `git commit -m "feat: HWM-based incremental sync with dedup and partial runs"`.

---

### Task 7: Report and notification text, osascript notifier

**Files:**
- Create: `src/report.ts`, `src/notify.ts`
- Test: `test/unit/report.test.ts`, `test/unit/notify.test.ts`

**Interfaces:**
- Consumes: `RunSummary`, `InvoiceMetadata`, `Environment`, `ENVIRONMENTS`.
- Produces:
  ```ts
  // src/report.ts (pure)
  export function formatAmount(amount: number, currency: string): string;
  export function invoiceViewUrl(environment: Environment, invoice: InvoiceMetadata): string;
  export function invoiceCountLabel(n: number): string;
  export function escapeMarkdown(text: string): string;
  export function warsawDay(date: Date): string;   // 'YYYY-MM-DD' in Europe/Warsaw
  export function formatReportSection(summary: RunSummary, environment: Environment): string;
  export function formatNotification(summary: RunSummary): { title: string; message: string } | null;
  // src/notify.ts
  export type Notifier = (title: string, message: string) => Promise<void>;
  export function createOsascriptNotifier(exec?: (file: string, args: string[]) => Promise<unknown>): Notifier;
  ```

Pinned copy:
- `formatAmount(12345.67, 'PLN')` → `'12 345,67 PLN'`; `formatAmount(53.63, 'EUR')` → `'53,63 EUR'` (`Intl.NumberFormat('pl-PL', { minimumFractionDigits: 2, maximumFractionDigits: 2 })`).
- `invoiceViewUrl('prod', {seller.nip '1111111111', issueDate '2026-02-01', invoiceHash 'UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE='})` → `'https://qr.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE'` (Base64 → Base64URL, no padding); `'test'` uses `https://qr-test.ksef.mf.gov.pl`.
- `invoiceCountLabel`: 1 → `1 nowa faktura`; 2, 3, 4, 22, 104 → `N nowe faktury`; 5, 11, 12, 13, 14, 21, 112 → `N nowych faktur`.
- `escapeMarkdown`: backslash-escape each of `` \ ` * _ [ ] < > # | `` and replace any run of `\r`/`\n` with one space.
- Seller label: `seller.name` if non-empty, else `NIP <seller.nip>`.
- `formatReportSection` (time = `startedAt` in Europe/Warsaw `HH:MM:SS`):
  ```
  ## Uruchomienie 08:00:12

  Status: zakończone
  Nowe faktury: 2

  - **<escaped seller label>** (NIP <nip>) — nr <escaped invoiceNumber>, <formatAmount>, wystawiona <DD.MM.YYYY> — [podgląd w KSeF](<invoiceViewUrl>) — `<ksefNumber>`
  ```
  Status line: `zakończone` | `częściowe — <escaped reason>` | `BŁĄD — <escaped reason>`. With zero invoices the list is omitted.
- `formatNotification`:
  - complete, 0 saved → `null`.
  - complete, n > 0 → title `KSeF: <invoiceCountLabel(n)>`; message = first three as `<seller label>: <formatAmount>` joined by `; `, plus `; i <n−3> więcej` when n > 3.
  - partial → title `KSeF: pobrano częściowo (<n>)`; message `<reason> Reszta przy następnym uruchomieniu.`
  - failed → title `KSeF: błąd pobierania faktur`; message `<reason>` + (` Zapisano wcześniej: <n>.` when n > 0); cut to 240 characters ending with `…` if longer.
- Notifier: `exec('osascript', ['-e', 'on run argv', '-e', 'display notification (item 2 of argv) with title (item 1 of argv)', '-e', 'end run', title, message])`; default `exec` = promisified `execFile` (never a shell, never interpolate text into the script).

- [ ] **Step 1: Write failing tests** for every pinned value above, plus:
  - `report escapes a hostile seller`: seller name `Evil*Corp [x](http://e) | # <b>\nline2` → the bullet line is a single line and contains `Evil\*Corp \[x\](http://e) \| \# \<b\> line2`.
  - `notifier passes text as argv`: title `KSeF: 1 nowa faktura`, message `A "quoted" \\ name"; do shell script "rm -rf ~"` → fake exec receives that exact message string as the last array element, and the `-e` script lines are exactly the three above.
  - `failed notification is truncated`: 500-char reason → message length 240, ends with `…`.

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement.** `warsawDay` via `Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Warsaw' })`; time via the same with hour/minute/second, `hourCycle: 'h23'`.

- [ ] **Step 3: Verify** `pnpm test && pnpm typecheck` → PASS.

- [ ] **Step 4: Commit** `git commit -m "feat: Polish report and macOS notification"`.

---

### Task 8: Run orchestration and CLI

**Files:**
- Create: `src/run.ts`, `src/main.ts`, `test/support/fake-ksef.ts`
- Test: `test/unit/run.test.ts`

**Interfaces:**
- Consumes: everything above.
- Produces:
  ```ts
  // src/run.ts
  export interface RunOptions {
    config: Config; keyPassword: string;
    fetch: typeof fetch; sleep: (ms: number) => Promise<void>; now: () => Date;
    notify: Notifier; log: (line: string) => void; dryRun?: boolean;
  }
  export function run(options: RunOptions): Promise<RunSummary>; // never rejects
  // test/support/fake-ksef.ts
  export function createFakeKsef(options: {
    invoices: Array<{ metadata: InvoiceMetadata; xml: Buffer }>;
    hwm: string;
    now: () => Date; // the test's fake clock; token validUntil is derived from it
    authStatus?: { code: number; description: string; details?: string[] };
    downloadStatus?: (ksefNumber: string) => { status: number; headers?: Record<string, string> } | undefined;
    fetchError?: Error; // every request throws this
  }): { fetch: typeof fetch; requests: Array<{ method: string; path: string }> };
  ```
  The fake answers: `POST /auth/challenge` → `{challenge: '20261126-CR-0123456789-ABCDEF0123-AB', timestamp, timestampMs, clientIp}`; `POST /auth/xades-signature…` → 202 `{referenceNumber: '20261126-AU-0000000000-0000000000-00', authenticationToken: {token: 'auth', validUntil}}`; `GET /auth/<ref>` → `{status: authStatus ?? {code: 200, description: 'ok'}}`; `POST /auth/token/redeem` → `{accessToken: {token: 'acc', validUntil: now + 15 min}, refreshToken: {...}}`; `POST /invoices/query/metadata…` → one page `{hasMore: false, isTruncated: false, permanentStorageHwmDate: hwm, invoices: <metadata of all invoices>}`; `GET /invoices/ksef/<n>` → the XML bytes (or `downloadStatus`). It does not validate the signature.

`run` flow (spec 7.4–7.6): `startedAt = now()`; `loadCredentials`; `openStore(config.dataDir, now)`; `createHttp(ENVIRONMENTS[env].apiBase, {fetch, sleep})`; `authenticate`; if `dryRun`: `listWindow` on `nextWindow(store.checkpoint ?? startFrom, now())`, `log` `dry run: <total> invoices in the first window, <not yet saved> not yet saved`, return a `complete` summary with `saved: []` — no writes, no report, no notification. A failing dry run returns `failed` with the reason and also writes no report and sends no notification (the owner runs it in a terminal; `main` prints the reason to stderr and exits 3). Otherwise `syncInvoices({ from: store.checkpoint ?? `${config.startDate}T00:00:00Z`, ... onSaved: push to saved })`. Any thrown error → `status: 'failed'`, `reason: err.message`. Afterwards (all statuses except complete-with-nothing-new): `appendReport(config.dataDir, warsawDay(startedAt), formatReportSection(...))`; then `formatNotification` → `notify` if non-null. Errors from `appendReport`/`notify` are logged, never thrown. Log one line per run: status, saved count, reason.

`main.ts`: `repoRoot = path.resolve(import.meta.dirname, '..')`. Flags: none, `--dry-run`, `--test-notification`; anything else → stderr `Usage: node src/main.ts [--dry-run | --test-notification]`, exit 1. `--test-notification` → `notify('KSeF: test powiadomienia', 'Powiadomienia działają.')`, exit 0. Otherwise `loadConfig(join(repoRoot, 'config.json'), repoRoot)` and `readKeyPassword(config.nip)`; a failure there → log to stderr, `notify('KSeF: błąd pobierania faktur', err.message)`, exit 3. Then `run` with real `fetch`, `setTimeout`-based `sleep`, `() => new Date()`, `createOsascriptNotifier()`, `log` = `console.log` with an ISO timestamp prefix. With `--dry-run`, a failure is not notified: print the reason to stderr. Exit code: complete 0, partial 2, failed 3 (1 is left to usage errors and to Node dying before `main` runs).

- [ ] **Step 1: Write failing tests** `test/unit/run.test.ts` (real RSA test credentials from `makeTestCredentials`, temp `dataDir`, recording `notify`, `sleep` that advances a fake clock starting at `2026-11-26T07:00:00Z`, config `environment: 'test'`, `startDate: '2026-11-01'`, `hwm: '2026-11-26T06:59:00.1234567+00:00'`; each fake invoice's `invoiceHash` is the real SHA-256 Base64 of its XML bytes):
- `saves new invoices, reports and notifies once`: 2 invoices → summary `complete` with 2 saved; both XML files byte-equal; `index.jsonl` has 2 lines; `state.json` checkpoint equals `hwm`; `reports/<warsawDay>.md` contains both invoice numbers and `https://qr-test.ksef.mf.gov.pl/invoice/`; exactly one notification with title `KSeF: 2 nowe faktury`.
- `a second run finds nothing and stays quiet`: same fake, run again on the same dir → `complete`, 0 saved; no new notification; report file unchanged; `index.jsonl` still 2 lines; no `/invoices/ksef/` request in the second run.
- `long rate limit is partial and resumable`: `downloadStatus` returns 429 `Retry-After: 900` for the second invoice → `partial`, 1 saved; notification title `KSeF: pobrano częściowo (1)`; report status line `częściowe — Limit zapytań KSeF — trzeba odczekać 900 s.`; no `state.json` written. Then a run with no rate limit saves the second invoice and writes the checkpoint.
- `authentication failure notifies with the reason`: `authStatus` 460 → `failed`; notification title `KSeF: błąd pobierania faktur`, message starts `Uwierzytelnienie w KSeF nieudane (kod 460`; report contains `BŁĄD — `.
- `wrong key password fails before any request`: `keyPassword: 'wrong'` → `failed`, reason starts `Nie można odczytać klucza prywatnego`; `requests.length === 0`; notification sent.
- `offline Mac fails after retries`: `fetchError: new TypeError('fetch failed')` → `failed`, reason `Brak połączenia z KSeF: fetch failed`; `sleep` recorded `30000` three times.
- `dry run writes and notifies nothing`: `dryRun: true` → `dataDir` does not exist afterwards; no notification; no `/invoices/ksef/` request; one log line starting `dry run: 2 invoices`.
- `failed dry run stays quiet`: `dryRun: true` with `authStatus` 460 → summary `failed` with the auth reason; `dataDir` does not exist; no notification.

Run: `pnpm test` → FAIL.

- [ ] **Step 2: Implement `src/run.ts` and `test/support/fake-ksef.ts`.** Run `pnpm test` → PASS.

- [ ] **Step 3: Implement `src/main.ts` and smoke-test it**

Run: `node src/main.ts --bogus; echo "exit=$?"` → usage line, `exit=1`.
Run (no `config.json` exists): `node src/main.ts; echo "exit=$?"` → stderr `Nie można wczytać config.json: …`, `exit=3`, and one macOS notification "KSeF: błąd pobierania faktur" appears on this Mac (expected; it proves the pre-config failure path).
Run: `pnpm typecheck` → no errors.

- [ ] **Step 4: Commit** `git commit -m "feat: run orchestration and CLI entry point"`.

---

### Task 9: End-to-end test against KSeF TEST

**Files:**
- Create: `test/support/send-invoice.ts`, `test/fixtures/fa3-invoice.xml`, `test/e2e/fetch.e2e.ts`

**Interfaces:**
- Consumes: `run`, `authenticate`, `createHttp`, `loadCredentials`, `ENVIRONMENTS`, `warsawDay`, `makeTestCredentials`, `randomNip`.
- Produces: `sendTestInvoice(http: Http, accessToken: string, xml: Buffer, sleep: (ms: number) => Promise<void>): Promise<{ ksefNumber: string; permanentStorageDate: string }>` (test-only; nothing in `src/` imports `test/`).

`sendTestInvoice` (shapes from the OpenAPI; spec 7.7):
1. `GET /security/public-key-certificates` (no token) → pick the entry whose `usage` includes `SymmetricKeyEncryption` and `validFrom ≤ now ≤ validTo`; `publicKey = new X509Certificate(Buffer.from(certificate, 'base64')).publicKey`.
2. `key = randomBytes(32)`, `iv = randomBytes(16)`; `encryptedSymmetricKey = publicEncrypt({ key: publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, key)`.
3. `POST /sessions/online` `{ formCode: { systemCode: 'FA (3)', schemaVersion: '1-0E', value: 'FA' }, encryption: { encryptedSymmetricKey: b64, initializationVector: b64(iv), publicKeyId } }` → 201 `{ referenceNumber }`.
4. `encrypted = aes-256-cbc(xml)` (Node default PKCS#7 padding); `POST /sessions/online/{ref}/invoices` `{ invoiceHash: sha256b64(xml), invoiceSize: xml.length, encryptedInvoiceHash: sha256b64(encrypted), encryptedInvoiceSize: encrypted.length, encryptedInvoiceContent: b64(encrypted) }` → 202 `{ referenceNumber: invoiceRef }`.
5. Poll `GET /sessions/{ref}/invoices/{invoiceRef}` every 2 s, at most 90 times, until `status.code === 200` and `permanentStorageDate` is set; `status.code >= 400` → throw with `status.description` and `status.details`.
6. `POST /sessions/online/{ref}/close` (204).

`test/fixtures/fa3-invoice.xml` — adapted from `invoice-template-fa-3-with-custom-Subject2.xml` in `CIRFMF/ksef-client-csharp` (MIT, © 2025 Ministerstwo Finansów; mention this in a comment in `send-invoice.ts`, not in the XML). UTF-8 without BOM; no comments or processing instructions. Placeholders replaced by the test: `{{SELLER_NIP}}`, `{{BUYER_NIP}}`, `{{INVOICE_NUMBER}}` (`E2E/<random hex>`), `{{ISSUE_DATE}}` (`warsawDay(now)`), `{{CREATED_AT}}` (now − 60 s, ISO).
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Faktura xmlns:etd="http://crd.gov.pl/xml/schematy/dziedzinowe/mf/2022/01/05/eD/DefinicjeTypy/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://crd.gov.pl/wzor/2025/06/25/13775/">
	<Naglowek>
		<KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza>
		<WariantFormularza>3</WariantFormularza>
		<DataWytworzeniaFa>{{CREATED_AT}}</DataWytworzeniaFa>
		<SystemInfo>ksef-daily-fetch-e2e</SystemInfo>
	</Naglowek>
	<Podmiot1>
		<DaneIdentyfikacyjne><NIP>{{SELLER_NIP}}</NIP><Nazwa>Sprzedawca Testowy Sp. z o.o.</Nazwa></DaneIdentyfikacyjne>
		<Adres><KodKraju>PL</KodKraju><AdresL1>ul. Kwiatowa 1 m. 2</AdresL1><AdresL2>00-001 Warszawa</AdresL2></Adres>
	</Podmiot1>
	<Podmiot2>
		<DaneIdentyfikacyjne><NIP>{{BUYER_NIP}}</NIP><Nazwa>Nabywca Testowy</Nazwa></DaneIdentyfikacyjne>
		<Adres><KodKraju>PL</KodKraju><AdresL1>ul. Polna 1</AdresL1><AdresL2>00-001 Warszawa</AdresL2></Adres>
		<JST>2</JST>
		<GV>2</GV>
	</Podmiot2>
	<Fa>
		<KodWaluty>PLN</KodWaluty>
		<P_1>{{ISSUE_DATE}}</P_1>
		<P_1M>Warszawa</P_1M>
		<P_2>{{INVOICE_NUMBER}}</P_2>
		<P_13_1>43.60</P_13_1>
		<P_14_1>10.03</P_14_1>
		<P_15>53.63</P_15>
		<Adnotacje>
			<P_16>2</P_16><P_17>2</P_17><P_18>2</P_18><P_18A>2</P_18A>
			<Zwolnienie><P_19N>1</P_19N></Zwolnienie>
			<NoweSrodkiTransportu><P_22N>1</P_22N></NoweSrodkiTransportu>
			<P_23>2</P_23>
			<PMarzy><P_PMarzyN>1</P_PMarzyN></PMarzy>
		</Adnotacje>
		<RodzajFaktury>VAT</RodzajFaktury>
		<FaWiersz><NrWierszaFa>1</NrWierszaFa><P_7>Usługa testowa A</P_7><P_11>18.00</P_11><P_12>23</P_12></FaWiersz>
		<FaWiersz><NrWierszaFa>2</NrWierszaFa><P_7>Usługa testowa B</P_7><P_11>25.60</P_11><P_12>23</P_12></FaWiersz>
	</Fa>
</Faktura>
```
If TEST rejects the invoice with a schema error (status 450/430), compare against the original template (it also has `DaneKontaktowe`, `NrKlienta`, `OkresFa`, `Rozliczenie`, `Platnosc`, `Stopka`, all optional per the C# tests) and restore elements one at a time.

- [ ] **Step 1: Write `test/e2e/fetch.e2e.ts`** (one `test()`; temp dir; real `fetch`; real `sleep`; recording `notify`):
  1. `sellerNip = randomNip()`, `buyerNip = randomNip()`; seller credentials `rsa`, buyer credentials `ec` (so both key types authenticate).
  2. Authenticate the seller (`environment 'test'`), fill the fixture, `xml = Buffer.from(filled, 'utf8')`, `sendTestInvoice` → `ksefNumber`.
  3. Wait 120 s (HWM lag, as in the official `IncrementalInvoiceRetrievalE2ETests`).
  4. Up to 4 attempts, 60 s apart: `run({ config: { nip: buyerNip, environment: 'test', certificatePath, keyPath, startDate: warsawDay(now − 100 days), dataDir }, keyPassword, ... })` until `summary.saved` contains `ksefNumber`. The 100-day `startDate` makes the first attempt walk one closed window (explicit `to`) and then the open one, which checks the closed-window HWM rule (spec 7.4, UNCONFIRMED) against the real API. Every attempt must return `complete` (fail on `partial`/`failed`, printing `reason`). After the first attempt, assert `state.json` exists (the closed window advanced the checkpoint).
  5. Assert: `readFile(dataDir/invoices/YYYY/MM/<ksefNumber>.xml)` equals `xml` byte for byte (also proves `sha256(bytes) === invoiceHash` on real data, spec 8); `index.jsonl` has exactly one line with that `ksefNumber` and `sellerNip === sellerNip`; `reports/<warsawDay(now)>.md` contains the invoice number and `https://qr-test.ksef.mf.gov.pl/invoice/<sellerNip>/`; the last notification title is `KSeF: 1 nowa faktura`.
  6. Run once more → `complete`, 0 saved, no new notification, index still one line.
  Budget: at most 7 metadata queries (2 on the first attempt, 1 per later run), 7 authentications, 1 download (within PROD-level limits, spec 5). Do not re-run the E2E more than twice within an hour.

- [ ] **Step 2: Run it**

Run: `pnpm test:e2e` (outside 16:00–18:00 Warsaw; takes about 4–8 minutes)
Expected: 1 test PASS. On failure, fix the cause in `src/` (with a unit test reproducing it) or in the test support code; never weaken an assertion.

- [ ] **Step 3: Verify the unit suite still passes** `pnpm test && pnpm typecheck`.

- [ ] **Step 4: Commit** `git commit -m "test: end-to-end fetch against KSeF TEST"`.

---

### Task 10: launchd job scripts

**Files:**
- Create: `scripts/run-daily.sh`, `scripts/launchagent.sh` (both `chmod +x`, `#!/bin/zsh`)

**Interfaces:**
- Consumes: `src/main.ts` exit codes (0 complete, 2 partial, 3 failed).
- Produces: the LaunchAgent the owner installs (README, Task 11).

`run-daily.sh <node-path>`: `cd` to the repo root (`${0:A:h:h}`); run `"$1" src/main.ts`; capture the exit code; if it is not 0, 2 or 3 (e.g. 127: Node binary missing; 1: Node died before `main` ran), run `osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' 'KSeF: zadanie nie zadziałało' "Program nie uruchomił się albo zakończył się awarią (kod $code). Sprawdź ~/Library/Logs/ksef-daily-fetch.log"`; exit with the same code.

`launchagent.sh print|install|uninstall`: `LABEL=local.ksef-daily-fetch`; `REPO=${0:A:h:h}`; `NODE=$(command -v node)` (fail with a message if empty); `PLIST=~/Library/LaunchAgents/$LABEL.plist`; `LOG=~/Library/Logs/ksef-daily-fetch.log`.
- `print` writes the plist to stdout: `Label`; `ProgramArguments` = `/bin/zsh`, `$REPO/scripts/run-daily.sh`, `$NODE`; `WorkingDirectory` `$REPO`; `StartCalendarInterval` `{Hour 8, Minute 0}`; `StandardOutPath` and `StandardErrorPath` `$LOG`; `RunAtLoad` false.
- `install`: `mkdir -p ~/Library/LaunchAgents ~/Library/Logs`; `print > $PLIST`; `plutil -lint $PLIST`; `launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true`; `launchctl bootstrap gui/$(id -u) $PLIST`; echo how to run it now (`launchctl kickstart gui/$(id -u)/$LABEL`) and where the log is.
- `uninstall`: `launchctl bootout gui/$(id -u)/$LABEL || true`; `rm -f $PLIST`.
- Anything else: usage, exit 1.

- [ ] **Step 1: Write both scripts.**

- [ ] **Step 2: Verify without loading anything**

Run: `zsh -n scripts/run-daily.sh && zsh -n scripts/launchagent.sh` → no output.
Run: `scripts/launchagent.sh print > "$TMPDIR/ksef.plist" && plutil -lint "$TMPDIR/ksef.plist" && plutil -p "$TMPDIR/ksef.plist"` → `OK`, and the printed dict shows the absolute repo path, the absolute node path, `Hour => 8`, `Minute => 0`.
Run: `scripts/run-daily.sh /usr/bin/false; echo "exit=$?"` → `exit=1` and a wrapper notification (exit 1 means Node died before `main` ran; only 0, 2 and 3 are main's own).
Do NOT run `install` or `uninstall`.

- [ ] **Step 3: Commit** `git commit -m "feat: LaunchAgent scripts for the daily run"`.

---

### Task 11: AGENTS.md and README.md

**Files:**
- Create: `AGENTS.md`, `README.md` (do not create `CLAUDE.md`)

- [ ] **Step 1: Write `AGENTS.md`** (English, short): what the tool does (link the spec and `ADR.md`); commands (`pnpm install`, `pnpm test`, `pnpm typecheck`, `pnpm test:e2e:auth`, `pnpm test:e2e`); rules: the Global Constraints above that apply to future work (no build step and erasable syntax only; exact-pinned deps, ask before adding one; Polish user-facing copy, English everything else; never commit `config.json`, keys, certificates or `data/`; never touch the Keychain or a real certificate; E2E only against TEST, not 16:00–18:00; never install/load the LaunchAgent; `test/` is never imported by `src/`); where state lives; the `/auth/{referenceNumber}` → `/auth/rev2/{referenceNumber}` switch due before 2027-06-15; new decisions go to `docs/adr/` + `ADR.md`.

- [ ] **Step 2: Write `README.md`** (English) with these sections and exact commands:
  1. **What it does** — two paragraphs from spec 1–2, including what a notification and a report look like.
  2. **Requirements** — macOS, Node ≥ 22.18 (`node --version`), pnpm; `pnpm install --frozen-lockfile`.
  3. **Get a KSeF certificate** — in Aplikacja Podatnika KSeF (`https://ap.ksef.mf.gov.pl`): log in, open the certificates section, request a certificate of type **Authentication** (*uwierzytelnianie*), choose a strong private-key password (it cannot be recovered), download the certificate (`.crt`) and the private key (`.key`). Mark menu names as approximate (UNCONFIRMED in spec 5). Explain the no-permission-scope consequence (ADR-0002) and how to revoke the certificate if the Mac is lost.
  4. **Put the files in place** — `mkdir -p ~/.config/ksef-daily-fetch && chmod 700 ~/.config/ksef-daily-fetch`; move both files there; `chmod 600 ~/.config/ksef-daily-fetch/*`.
  5. **Store the key password in Keychain** — `security add-generic-password -s ksef-daily-fetch -a <NIP> -U -w` (with `-w` last, macOS prompts twice; the password never appears in shell history). Check: `security find-generic-password -s ksef-daily-fetch -a <NIP> >/dev/null && echo stored`.
  6. **Create `config.json`** — `cp config.example.json config.json`; field-by-field explanation (spec 7.2), with `startDate` advice (e.g. the date KSeF became mandatory for you).
  7. **Check notifications** — `node src/main.ts --test-notification`; if nothing appears, allow notifications for **Script Editor** in System Settings → Notifications and repeat.
  8. **Dry run** — `node src/main.ts --dry-run`: authenticates and lists the first window, writes nothing. Expected line `dry run: N invoices in the first window, M not yet saved`. Typical errors and what they mean (wrong password, Keychain item missing, certificate rejected).
  9. **First real run** — `node src/main.ts`; where files land (`data/invoices/…`, `data/reports/…`, `data/index.jsonl`, `data/state.json`); exit codes; if the backfill hits `Limit 60 pobrań…`, run again after an hour.
  10. **Install the daily job** — `scripts/launchagent.sh install`; runs daily at 08:00, or at wake if the Mac slept through it, not if it was off; logs in `~/Library/Logs/ksef-daily-fetch.log`; run now with `launchctl kickstart gui/$(id -u)/local.ksef-daily-fetch`; remove with `scripts/launchagent.sh uninstall`. Re-run `install` after a Node upgrade that changes `command -v node`.
  11. **Troubleshooting** — corrupt `index.jsonl` line (the XML stays on disk; delete or fix that line, the next run re-downloads it); "token expiring"; a failed run always notifies and appends `BŁĄD` to the day's report.
  12. **Development** — `pnpm test`, `pnpm typecheck`, `pnpm test:e2e:auth`, `pnpm test:e2e` (TEST only).

- [ ] **Step 3: Verify** every command in README exists (`grep -n "src/main.ts\|launchagent.sh\|security " README.md`) and matches Tasks 2, 8 and 10 exactly; `pnpm test && pnpm typecheck` still pass.

- [ ] **Step 4: Commit** `git commit -m "docs: AGENTS.md and owner setup README"`.

---

## Done when

- `pnpm test` and `pnpm typecheck` pass; `pnpm test:e2e:auth` and `pnpm test:e2e` passed against TEST at least once (record the date and the KSeF number in the final report).
- `git status` is clean; `git ls-files` contains no `config.json`, `*.key`, `*.crt` or `data/`.
- Nothing was installed into launchd and nothing was written to the Keychain.
