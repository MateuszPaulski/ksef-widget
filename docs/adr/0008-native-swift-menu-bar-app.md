# ADR-0008 — One native Swift menu-bar app replaces Node, launchd and the terminal setup

Date: 2026-11-26
Status: accepted

## Context

ADR-0001 runs a TypeScript fetcher on Node 22 from a per-user LaunchAgent; ADR-0005 adds a small Swift app that only hosts the widget. Setting this up needs Node, pnpm, files in `~/.config`, a `security` command, a hand-written `config.json`, a LaunchAgent script and an Xcode build. The owner asked to fold everything into the widget's app and chose a full Swift app. The TypeScript fetcher is proven on KSeF TEST and passed a dry run on PROD; nothing is installed yet. Design: `docs/superpowers/specs/2026-11-26-ksef-swift-app-design.md` (6.1).

## Decision

- One app, `KSeF.app`: a background menu-bar agent (`LSUIElement`) that holds the settings, the credentials, the hourly schedule and the fetch, writes the widget snapshot and embeds the existing widget extension.
- The fetcher is rewritten in Swift as a library target (`KsefCore`) with no UI framework dependency; the app target is a thin shell. The TypeScript code is the behaviour spec and the test oracle: same texts, rules, limits and byte-compatible files; its 142 unit tests are ported case by case.
- The TypeScript fetcher stays in the repository, untouched, as the fallback until the owner confirms the app against production. Only one fetcher may run: the app does not fetch while the `local.ksef-daily-fetch` LaunchAgent is installed. The owner confirmed the app against production on 2026-11-27; the TypeScript fetcher, its launchd scripts and the app's LaunchAgent check were then removed, and its golden vectors stay as frozen test fixtures (`docs/superpowers/specs/2026-11-27-ksef-year-summary-and-fallback-removal-design.md`, 7.1).
- Swift, Xcode and XcodeGen only, no third-party Swift packages, deployment target macOS 14.

## Consequences

- No Node, pnpm or launchd in the owner's setup; one build script and one settings window.
- The rewrite carries the risk that ADR-0004 avoided with a library; it is contained by golden vectors from the TypeScript signer and TEST end-to-end tests.
- Until the TypeScript code was removed, the repository held two implementations, and fixes during that period went to the Swift code only. Since its removal the Swift app is the only implementation.
- If the app is not running, nothing fetches and nothing can notify; the widget's three-hour stale banner is the remaining signal.
- Supersedes ADR-0001.
