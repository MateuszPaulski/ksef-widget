# Architecture decision records

Hard-to-reverse decisions for this project. One record per file in `docs/adr/`; this file is only the index. Records are never rewritten: a changed decision gets a new record that supersedes the old one.

| ADR | Date | Status | Decision |
|---|---|---|---|
| [ADR-0001](docs/adr/0001-typescript-node22-local-launchd.md) | 2026-11-26 | superseded by ADR-0008 | TypeScript on Node 22, run daily by a local LaunchAgent |
| [ADR-0002](docs/adr/0002-ksef-certificate-xades-auth.md) | 2026-11-26 | accepted | Authenticate with a KSeF certificate and a XAdES signature, not a KSeF token |
| [ADR-0003](docs/adr/0003-hwm-metadata-sync-file-state.md) | 2026-11-26 | accepted | Incremental sync by PermanentStorage HWM via the metadata query, with file-based state |
| [ADR-0004](docs/adr/0004-hand-written-client-xml-crypto.md) | 2026-11-26 | superseded by ADR-0009 | Hand-written KSeF client; `xml-crypto` for the XAdES signature |
| [ADR-0005](docs/adr/0005-native-widgetkit-app-in-swift.md) | 2026-11-26 | accepted; host app superseded by ADR-0011 | Native WidgetKit desktop widget in a small Swift app, ad-hoc signed, next to the TypeScript fetcher |
| [ADR-0006](docs/adr/0006-widget-snapshot-file-with-sandbox-read-exception.md) | 2026-11-26 | accepted | The fetcher shares data with the widget through a JSON snapshot in Application Support, read via a sandbox read-only exception |
| [ADR-0007](docs/adr/0007-hourly-fetch-schedule.md) | 2026-11-26 | superseded by ADR-0010 | Fetch every hour instead of once a day |
| [ADR-0008](docs/adr/0008-native-swift-menu-bar-app.md) | 2026-11-26 | accepted | One native Swift menu-bar app replaces Node, launchd and the terminal setup |
| [ADR-0009](docs/adr/0009-swift-client-system-crypto.md) | 2026-11-26 | accepted | Hand-written KSeF client in Swift with system crypto and a canonical-by-construction XAdES signer |
| [ADR-0010](docs/adr/0010-in-app-hourly-scheduler.md) | 2026-11-26 | accepted | In-app hourly scheduler, login item and native notifications instead of launchd and osascript |
| [ADR-0011](docs/adr/0011-unsandboxed-host-app-and-secret-storage.md) | 2026-11-26 | accepted | Unsandboxed host app; credentials in its own folder, key password in the login Keychain |
| [ADR-0012](docs/adr/0012-ad-hoc-signing-optional-developer-id.md) | 2026-11-26 | accepted | Ad-hoc signing by default; the owner may re-sign with their Developer ID through the build script |
| [ADR-0013](docs/adr/0013-sales-metadata-and-year-ledger.md) | 2026-11-27 | accepted | The app also syncs sales-invoice metadata into a year ledger in the invoice folder |
