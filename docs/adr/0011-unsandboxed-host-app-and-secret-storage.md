# ADR-0011 — Unsandboxed host app; credentials in its own folder, key password in the login Keychain

Date: 2026-11-26
Status: accepted

## Context

ADR-0005 made the widget's host app a sandboxed agent with no window, no network and no file access that quits after forwarding a click. The app now fetches (ADR-0008): it needs the network, a user-chosen invoice folder (default `~/Documents/KSeF`), the snapshot path of ADR-0006 and the Keychain. The widget extension can read the whole `~/Library/Application Support/ksef-daily-fetch/` directory. The data protection keychain needs entitlements authorised by a provisioning profile (TN3137), which an ad-hoc app cannot have; the file-based login keychain needs none. Privacy protection of `~/Documents` applies to unsandboxed apps as well.

## Decision

- The host app is not sandboxed and has no entitlements file. The widget extension keeps exactly its sandbox and read-only exception (ADR-0006).
- The app keeps its settings and credential copies in `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/` (folder 0700, files 0600): `settings.json`, `ksef-auth.crt` and the still-encrypted `ksef-auth.key`, copied from files the owner picks. Nothing of it goes under the widget-readable directory.
- The key password is one generic-password item in the login keychain (service `local.ksef-daily-fetch.KsefWidget`, account `key-password`), created by the app's settings window, read at launch and after saving, kept in memory. The TypeScript tool's item and files are never read.
- Invoices, index, checkpoint and reports stay in the formats of ADR-0003, in a folder the owner chooses, default `~/Documents/KSeF`.
- The host app stays running: widget clicks open allow-listed KSeF links without quitting; a plain launch shows the menu-bar item instead of an alert.

## Consequences

- No bookmarks, temporary exceptions or entitlements for the app; the only sandbox in the bundle is the extension's.
- macOS is expected to ask once for access to the Documents folder; per Apple DTS, Keychain and Documents answers are remembered per signing identity (ADR-0012). Not probed on this Mac: the safety rules forbid touching the real Keychain.
- Whoever can read the owner's login keychain and home folder can use the key, exactly as with ADR-0002's setup; revocation in Aplikacja Podatnika stays the remedy.
- Supersedes the host-app part of ADR-0005; its widget part (native WidgetKit widget, XcodeGen, no third-party packages) stays accepted.
