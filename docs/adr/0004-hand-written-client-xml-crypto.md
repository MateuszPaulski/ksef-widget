# ADR-0004 — Hand-written KSeF client; `xml-crypto` for the XAdES signature

Date: 2026-11-26
Status: accepted

## Context

The tool needs about six KSeF endpoints (challenge, XAdES submit, auth status, token redeem, metadata query, invoice download). Community Node clients for KSeF 2.0 exist but are all 0.x and single-maintainer, and anything in the runtime dependency tree runs next to a private key with the owner's full KSeF rights (ADR-0002). Node 22 provides `fetch` and `crypto` (RSA, ECDSA with `ieee-p1363` encoding, X.509 parsing, encrypted PKCS#8 decryption). What Node lacks is XML canonicalization and XML-DSig. Candidates: `xml-crypto` 6.4.0 (node-saml organisation, three runtime dependencies, no built-in ECDSA, supports `Object` references with `Id`, reference `Type`, empty-URI enveloped references and custom algorithms) and `xadesjs` 3.1.0 (native XAdES, fresh major release, about three times the dependency surface).

## Decision

- Write the KSeF client by hand with `fetch`, from the official OpenAPI (`https://api-test.ksef.mf.gov.pl/docs/v2/openapi.json`).
- Build the XAdES-BES signature with `xml-crypto` 6.4.0 (exact pin), adding `xades:QualifyingProperties` as a signed `ds:Object` and registering a small ECDSA-SHA256 algorithm that emits raw `R || S`.
- Test-only code that sends invoices to the TEST environment is also hand-written with Node's `crypto` and lives under `test/support/`, never imported by product code.

## Consequences

- One runtime dependency (plus its three), all MIT, pinned through the lockfile.
- The project owns the request and response shapes; API changes (for example the `/auth/rev2` successor) are edited by hand. The changelog in `CIRFMF/ksef-api` is the place to watch.
- The XAdES structure follows the official C# client's `SignatureService`; if KSeF tightens validation, the signer is one small module to adjust.
- A future need for the async export (AES, ZIP) would need a new decision about a ZIP dependency.
