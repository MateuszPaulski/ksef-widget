# ADR-0009 — Hand-written KSeF client in Swift with system crypto and a canonical-by-construction XAdES signer

Date: 2026-11-26
Status: accepted

## Context

ADR-0004 builds the client on Node's `fetch` and `crypto` and the XAdES signature on `xml-crypto`. The Swift app (ADR-0008) has no third-party packages. macOS offers `URLSession`, Security (`SecKey`, `SecCertificate`), CryptoKit (P-256 ECDSA with raw `R || S`), CommonCrypto (PBKDF2, AES-CBC) and the SDK's libxml2. Probes on the owner's Mac (spec 5.1, 5.2): `SecItemImport` returns "Unknown format" for the PBES2/AES keys LibreSSL writes; a hand-written PBES2 reader decrypts LibreSSL and Node variants; an XAdES document built string by string is byte-identical to `xml-crypto`'s for RSA and has identical digests for EC; libxml2's exclusive C14N agrees with the built strings.

## Decision

- Client by hand with `URLSession`, same six endpoints, same retry and rate-limit rules as `src/http.ts`.
- Encrypted PKCS#8 keys decrypted by a small DER reader with CommonCrypto: PBES2 + PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384, SHA512) + AES-128/192/256-CBC; any other algorithm fails with its OID named. RSA keys go to `SecKeyCreateWithData` as PKCS#1, EC P-256 keys to CryptoKit as PKCS#8.
- The XAdES-BES signature keeps the layout of ADR-0004 and the official C# client. Its canonical forms are built by construction from fixed templates; the only interpolated values are validated (challenge, NIP) or escaped (issuer). libxml2 is used only in tests, as an independent canonicalizer.
- Golden vectors from the TypeScript signer are committed as test fixtures; the RSA output must stay byte-identical.

## Consequences

- No runtime dependency outside the OS; no unsafe C interop in the shipped code.
- The signer is correct only for the document it builds. Any new signed content (another request type) needs new templates and new vectors, or a switch to libxml2 C14N, which is a new decision.
- A key encrypted with an unlisted algorithm (scrypt, PBES1, 3DES) is rejected at setup with a precise message; supporting it means extending the reader.
- Supersedes ADR-0004.
