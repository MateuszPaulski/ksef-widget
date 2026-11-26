# Architecture decision records

Hard-to-reverse decisions for this project. One record per file in `docs/adr/`; this file is only the index. Records are never rewritten: a changed decision gets a new record that supersedes the old one.

| ADR | Date | Status | Decision |
|---|---|---|---|
| [ADR-0001](docs/adr/0001-typescript-node22-local-launchd.md) | 2026-11-26 | accepted | TypeScript on Node 22, run daily by a local LaunchAgent |
| [ADR-0002](docs/adr/0002-ksef-certificate-xades-auth.md) | 2026-11-26 | accepted | Authenticate with a KSeF certificate and a XAdES signature, not a KSeF token |
| [ADR-0003](docs/adr/0003-hwm-metadata-sync-file-state.md) | 2026-11-26 | accepted | Incremental sync by PermanentStorage HWM via the metadata query, with file-based state |
| [ADR-0004](docs/adr/0004-hand-written-client-xml-crypto.md) | 2026-11-26 | accepted | Hand-written KSeF client; `xml-crypto` for the XAdES signature |
