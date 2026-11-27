# AGENTS.md

A personal macOS tool: `KSeF.app`, a native menu-bar app that every hour fetches new purchase invoices from the Polish KSeF API 2.0, saves their XML to disk, and tells the owner (macOS notification and a daily Markdown report). A widget extension embedded in the app shows the latest invoices from a snapshot file. It must never fail silently. The app also keeps a ledger of the current year's purchase and sales invoice metadata and shows a net expenses and incomes summary line in the widget. Design: `docs/superpowers/specs/2026-11-26-ksef-swift-app-design.md` (app), `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md` (fetcher rules the app ports), `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md` (widget), `docs/superpowers/specs/2026-11-27-ksef-year-summary-and-fallback-removal-design.md` (year summary). Decisions: `ADR.md` (index) and `docs/adr/`.

## Commands

- `xcodegen generate --spec widget/project.yml --project widget` — regenerate the (gitignored) Xcode project; rerun after adding a file or editing `widget/project.yml`
- `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefCoreTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test` — offline tests of `KsefCore`
- the same with `-scheme KsefWidgetTests` — widget tests (prefix with `TEST_RUNNER_WIDGET_RENDER_DIR=<dir>` to also write PNG renders)
- the same with `-scheme KsefAppTests` — settings window tests (prefix with `TEST_RUNNER_SETTINGS_RENDER_DIR=<dir>` to write PNG renders)
- the same with `-scheme KsefE2ETests` — KSeF TEST only: `-only-testing:KsefE2ETests/AuthE2ETests` (login), `…/FetchE2ETests` (full fetch, both sides, 4–8 minutes) or `…/SummaryProbeE2ETests` (correction and EUR invoice)
- `scripts/build-app.sh` — the build, signature check and printed designated requirement; agents run it without arguments only, never with `--install` or an identity

## Rules

- Swift (`widget/`): no third-party packages, no Swift Package Manager. `KsefCore` (`widget/Core/`) imports only `Foundation`, `Security`, `CryptoKit` and `CommonCrypto`; check with `grep -rhoE "^import [A-Za-z0-9]+" widget/Core | sort -u`. All logic lives there, with tests; the app target (`widget/App/`) is a thin shell, so new testable logic goes into `KsefCore` first.
- Signing stays ad hoc; never commit a Team ID, signing identity, provisioning profile or development-team build setting. Never copy the app into `/Applications` or `~/Applications` (only the owner installs it).
- The app is not sandboxed and has no entitlements file. The widget extension is sandboxed, never gets network access, and has no file access wider than the one read-only directory in `widget/Extension/Extension.entitlements`.
- Never touch the owner's Keychain, `~/.config/ksef-daily-fetch/`, `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/` or a real certificate. Never run `security`. Never instantiate `KeychainSecretStore` in a test or a smoke run: only the owner's **Zapisz** exercises it, plus the one opt-in exception, `KeychainAdapterTests` (a random throwaway service; agents never set `KSEF_KEYCHAIN_TEST`). Tests use self-signed certificates from `/usr/bin/openssl` in temp directories and `FakeSecretStore`.
- The owner's app is installed, configured and running with real credentials and invoice data. Never read, list or touch `~/Applications/KSeF.app`, the app folder, the snapshot folder (`~/Library/Application Support/ksef-daily-fetch/`) or the invoice folder. Never launch, quit, kill or signal the app, register a login item or show a real notification (no `open`, `pkill`, `killall`, `osascript`, `launchctl`).
- Build the app only through `scripts/build-app.sh` without arguments, at most once per change: a build registers a second copy with macOS and can disturb the owner's live widget. Test bundles (`KsefCoreTests`, `KsefWidgetTests`, `KsefAppTests`, `KsefE2ETests`) never build the app and may run freely; never build the `KsefWidget` or `SnapshotProbe` schemes by hand. After the app build, `pluginkit -m -v -p com.apple.widgetkit-extension | grep -c "/widget/build/"` must print `0` (it filters out the owner's installed copy); first check that `… | grep -c "/Contents/PlugIns/"` prints more than `0`, otherwise the output has no paths and the check proves nothing.
- Network access only to `https://api-test.ksef.mf.gov.pl/v2`, only from the E2E target (`widget/E2ETests/`), and not during the TEST maintenance window 16:00–18:00 Europe/Warsaw. Never call DEMO or PROD from code you run for development. TEST rate limits are tight (20 metadata queries per hour): run the full fetch E2E and the probe each at most twice an hour.
- Fixtures in `widget/CoreTests/Fixtures/` are frozen (their README); never regenerate or hand-edit them; the RSA XAdES signature must stay byte-identical (`XadesTests`) and the on-disk formats byte-compatible (`formats.json`).
- Polish for user-facing strings (notification, report, menu, settings window, error messages that can reach them); English for code, comments, docs, ADRs and log lines. Log lines never carry tokens, passwords, key material or full widget URLs.
- Seller names, invoice numbers and reasons are attacker-controlled (anyone can invoice this NIP): in SwiftUI always `Text(verbatim:)`.
- Never commit `config.json`, keys, certificates or an invoice folder. Never print or log tokens, passwords or key material.
- The snapshot path lives in three places that change together: `widget/Core/AppPaths.swift`, `widget/Extension/Extension.entitlements` and `widget/Shared/Snapshot.swift`.
- Tests never write under the real home: `run()` takes `snapshotURL` and `AppPaths(home:)` takes a temp folder.
- Refer to the owner as "they" or "the owner".

## Before handing work to the owner

- Run the exact command path the owner will be told to run, end to end. When the real target is off-limits (the installed app, production KSeF), run the identical code path against a stand-in (e.g. `install_app` from `scripts/install-app.zsh` on a throwaway app with its own bundle identifier in a scratch directory) and say plainly which part was only exercised on the stand-in.
- `scripts/build-app.sh` without arguments exits 0 on the final commit: clean build, no warnings in `widget/` sources, hardened runtime on both bundles. Read the whole output, never reduce it to pass/fail lines.
- `.github/workflows/ci.yml` runs on pull requests only (when opened and on each update) and is green on the pull request's latest commit before the owner is told to merge or install; give the run link, or say it is not green and why.
- Say what was not verified: anything only the owner's Mac can show.

## State

The app folder `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/` (folder 0700): `settings.json`, `ksef-auth.crt`, `ksef-auth.key` (0600); the key password is one generic-password item in the login Keychain. Under the invoice folder (default `~/Documents/KSeF`, unchanged formats): `identity.json` (the NIP and environment the folder belongs to; app only), `state.json` (checkpoint), `index.jsonl` (append-only, one line per saved invoice, also the dedup set), `ledger.jsonl` (append-only, one line per purchase or sales invoice of the year: metadata and amounts only) and `ledger-state.json` (checkpoint per side, `completeAt` and the `skipped` invoices the ledger could not sum), `invoices/YYYY/MM/<ksefNumber>.xml` (bytes exactly as KSeF returned them), `reports/YYYY-MM-DD.md` (a day can hold several sections). Outside both: `~/Library/Application Support/ksef-daily-fetch/widget.json` (widget snapshot, rewritten after every run).

## Known follow-ups

- `GET /auth/{referenceNumber}` is deprecated and sunsets 2027-06-15. Switch to `/auth/rev2/{referenceNumber}` (one path string in `widget/Core/KsefClient.swift`) once it is on PROD, before that date.
- New hard-to-reverse decisions go to `docs/adr/NNNN-slug.md` plus a row in `ADR.md`.
