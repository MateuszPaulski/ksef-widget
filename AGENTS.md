# AGENTS.md

A personal macOS tool: every hour it fetches new purchase invoices from the Polish KSeF API 2.0, saves their XML to disk, and tells the owner (macOS notification and a daily Markdown report). A native macOS widget in `widget/` shows the latest invoices from a snapshot file. It must never fail silently. Design: `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md`, widget: `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md`. Decisions: `ADR.md` (index) and `docs/adr/`.

## Commands

- `pnpm install` — dependencies (exact versions, 14-day `minimumReleaseAge`)
- `pnpm test` — offline unit tests
- `pnpm typecheck` — `tsc --noEmit`
- `pnpm test:e2e:auth` — XAdES authentication against KSeF TEST
- `pnpm test:e2e` — full fetch against KSeF TEST (4–8 minutes)
- `xcodegen generate --spec widget/project.yml --project widget` — regenerate the (gitignored) Xcode project
- `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test` — widget unit tests (prefix with `TEST_RUNNER_WIDGET_RENDER_DIR=<dir>` to also write PNG renders)
- `xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build build` — build the widget app

## Rules

- No build step: Node 22 runs `.ts` directly (`node src/main.ts`). Erasable TypeScript only (no `enum`, `namespace`, constructor parameter properties); relative imports end in `.ts`; type-only imports use `import type`.
- Dependencies are pinned to exact versions: `xml-crypto` at runtime, `typescript` and `@types/node` for development. Ask before adding any other package.
- Polish for user-facing strings (notification, report, error messages that can reach a notification); English for code, comments, docs, ADRs and log lines.
- Never commit `config.json`, keys, certificates or `data/` (all gitignored). Never print or log tokens, passwords or key material.
- Never touch the owner's Keychain or a real certificate. Tests use self-signed certificates from `/usr/bin/openssl` in temp directories.
- Network access in tests only to `https://api-test.ksef.mf.gov.pl/v2`, only in `test/e2e/`, and not during the TEST maintenance window 16:00–18:00 Europe/Warsaw. Never call DEMO or PROD from code you run for development. TEST rate limits are tight (20 metadata queries per hour): do not run `pnpm test:e2e` more than twice an hour.
- Never install or load the LaunchAgent (`scripts/launchagent.sh install`, `launchctl bootstrap`); only the owner does. `scripts/launchagent.sh print` is safe.
- `test/` is never imported by `src/`.
- Swift (`widget/`): no third-party packages. Signing stays ad hoc; never commit a Team ID, signing identity, provisioning profile or `DEVELOPMENT_TEAM`. Never copy the app into `/Applications` or `~/Applications` (only the owner installs it); after building, run `lsregister -u` on the built app.
- The widget extension never gets network access or file access wider than the one read-only directory in `widget/Extension/Extension.entitlements`.
- The snapshot path lives in three places that change together: `src/main.ts`, `widget/Extension/Extension.entitlements`, `widget/Shared/Snapshot.swift`.
- Seller text in Swift is always `Text(verbatim:)` (anyone can invoice this NIP). Polish user-facing text applies to the widget and the app alert too.
- Tests never write under the real home: `run()` takes `snapshotPath`.
- Refer to the owner as "they" or "the owner".

## State

Under `dataDir` (default `data/`, gitignored): `state.json` (checkpoint), `index.jsonl` (append-only, one line per saved invoice, also the dedup set), `invoices/YYYY/MM/<ksefNumber>.xml` (bytes exactly as KSeF returned them), `reports/YYYY-MM-DD.md` (a day can hold several sections). Outside it: `~/Library/Application Support/ksef-daily-fetch/widget.json` (widget snapshot, rewritten after every run).

## Known follow-ups

- `GET /auth/{referenceNumber}` is deprecated and sunsets 2027-06-15. Switch to `/auth/rev2/{referenceNumber}` (one path string in `src/ksef.ts`) once it is on PROD, before that date.
- New hard-to-reverse decisions go to `docs/adr/NNNN-slug.md` plus a row in `ADR.md`.
