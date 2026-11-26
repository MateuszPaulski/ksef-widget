# AGENTS.md

A personal macOS tool: `KSeF.app`, a native menu-bar app that every hour fetches new purchase invoices from the Polish KSeF API 2.0, saves their XML to disk, and tells the owner (macOS notification and a daily Markdown report). A widget extension embedded in the app shows the latest invoices from a snapshot file. It must never fail silently. The original TypeScript fetcher (`src/`) is the fallback until the owner confirms the app against production; only one of the two may run. Design: `docs/superpowers/specs/2026-11-26-ksef-swift-app-design.md` (app), `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md` (fetcher rules), `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md` (widget). Decisions: `ADR.md` (index) and `docs/adr/`.

## Commands

- `xcodegen generate --spec widget/project.yml --project widget` — regenerate the (gitignored) Xcode project; rerun after adding a file or editing `widget/project.yml`
- `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefCoreTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test` — offline tests of `KsefCore`
- the same with `-scheme KsefWidgetTests` — widget tests (prefix with `TEST_RUNNER_WIDGET_RENDER_DIR=<dir>` to also write PNG renders)
- the same with `-scheme KsefAppTests` — settings window tests (prefix with `TEST_RUNNER_SETTINGS_RENDER_DIR=<dir>` to write PNG renders)
- the same with `-scheme KsefE2ETests` — KSeF TEST only: `-only-testing:KsefE2ETests/AuthE2ETests` (login) or `…/FetchE2ETests` (full fetch, 4–8 minutes)
- `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build build` — build the app
- `scripts/build-app.sh` — the build, signature check and printed designated requirement; agents run it without arguments only, never with `--install` or an identity
- `node test/golden/make-vectors.ts widget/CoreTests/Fixtures` — regenerate the Swift fixtures from the TypeScript code, then rerun `KsefCoreTests`
- `pnpm install` — dependencies of the fallback (exact versions, 14-day `minimumReleaseAge`)
- `pnpm test` — offline unit tests of the fallback; `pnpm typecheck` — `tsc --noEmit`; `pnpm test:e2e:auth` and `pnpm test:e2e` — the fallback against KSeF TEST

## Rules

- Swift (`widget/`): no third-party packages, no Swift Package Manager. `KsefCore` (`widget/Core/`) imports only `Foundation`, `Security`, `CryptoKit` and `CommonCrypto`; check with `grep -rhoE "^import [A-Za-z0-9]+" widget/Core | sort -u`. All logic lives there, with tests; the app target (`widget/App/`) is a thin shell, so new testable logic goes into `KsefCore` first.
- Signing stays ad hoc; never commit a Team ID, signing identity, provisioning profile or development-team build setting. Never copy the app into `/Applications` or `~/Applications` (only the owner installs it); after any build that produced `KSeF.app`, run `lsregister -u` on it and check that `pluginkit -m -p com.apple.widgetkit-extension | grep -c ksef-daily-fetch` prints `0`.
- The app is not sandboxed and has no entitlements file. The widget extension is sandboxed, never gets network access, and has no file access wider than the one read-only directory in `widget/Extension/Extension.entitlements`.
- Never touch the owner's Keychain, `~/.config/ksef-daily-fetch/`, `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/` or a real certificate. Never run `security`. Never instantiate `KeychainSecretStore` in a test or a smoke run: only the owner's **Zapisz** exercises it. Tests use self-signed certificates from `/usr/bin/openssl` in temp directories and `FakeSecretStore`.
- Never launch the app when the owner's app folder (`~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/`) exists; an unconfigured launch touches no Keychain, invoice folder or notification centre and is the only launch an agent may do. Never register a login item or show a real notification.
- Network access only to `https://api-test.ksef.mf.gov.pl/v2`, only from the E2E targets (`widget/E2ETests/`, `test/e2e/`), and not during the TEST maintenance window 16:00–18:00 Europe/Warsaw. Never call DEMO or PROD from code you run for development. TEST rate limits are tight (20 metadata queries per hour): run the full fetch E2E at most twice an hour.
- Never install or load the LaunchAgent (`scripts/launchagent.sh install`, `launchctl bootstrap`); only the owner does. `scripts/launchagent.sh print` is safe.
- Fixtures in `widget/CoreTests/Fixtures/` come from `test/golden/make-vectors.ts`; the RSA XAdES signature must stay byte-identical to the TypeScript signer's (`XadesTests`), and the on-disk formats byte-compatible (`formats.json`).
- Polish for user-facing strings (notification, report, menu, settings window, error messages that can reach them); English for code, comments, docs, ADRs and log lines. Log lines never carry tokens, passwords, key material or full widget URLs.
- Seller names, invoice numbers and reasons are attacker-controlled (anyone can invoice this NIP): in SwiftUI always `Text(verbatim:)`.
- Never commit `config.json`, keys, certificates or an invoice folder. Never print or log tokens, passwords or key material.
- The snapshot path lives in four places that change together: `widget/Core/AppPaths.swift` (the app), `src/main.ts` (the fallback), `widget/Extension/Extension.entitlements` and `widget/Shared/Snapshot.swift`.
- Fallback (TypeScript, `src/`): no build step, Node 22 runs `.ts` directly; erasable TypeScript only (no `enum`, `namespace`, constructor parameter properties); relative imports end in `.ts`; type-only imports use `import type`; dependencies pinned (`xml-crypto` at runtime, `typescript` and `@types/node` for development), ask before adding any other. `test/` is never imported by `src/`. `src/` changes only for fallback fixes.
- Tests never write under the real home: `run()` takes `snapshotURL` (Swift) and `snapshotPath` (TypeScript), and `AppPaths(home:)` takes a temp folder.
- Refer to the owner as "they" or "the owner".

## State

The app folder `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/` (folder 0700): `settings.json`, `ksef-auth.crt`, `ksef-auth.key` (0600); the key password is one generic-password item in the login Keychain. Under the invoice folder (default `~/Documents/KSeF`, unchanged formats): `state.json` (checkpoint), `index.jsonl` (append-only, one line per saved invoice, also the dedup set), `invoices/YYYY/MM/<ksefNumber>.xml` (bytes exactly as KSeF returned them), `reports/YYYY-MM-DD.md` (a day can hold several sections). Outside both: `~/Library/Application Support/ksef-daily-fetch/widget.json` (widget snapshot, rewritten after every run).

## Known follow-ups

- `GET /auth/{referenceNumber}` is deprecated and sunsets 2027-06-15. Switch to `/auth/rev2/{referenceNumber}` (one path string in `widget/Core/KsefClient.swift` and one in `src/ksef.ts`) once it is on PROD, before that date.
- Remove the TypeScript fetcher after the owner confirms the app against production (a separate change).
- New hard-to-reverse decisions go to `docs/adr/NNNN-slug.md` plus a row in `ADR.md`.
