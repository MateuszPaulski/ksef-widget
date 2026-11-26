# ADR-0006 — The fetcher shares data with the widget through a JSON snapshot in Application Support, read via a sandbox read-only exception

Date: 2026-11-26
Status: accepted

## Context

The widget extension must run in the App Sandbox; the fetcher is a non-sandboxed Homebrew `node` process started hourly by launchd, with no UI. Options checked on macOS 27 (spec section 5):

- An App Group container: since macOS 15 a process must claim the group in its entitlements to access the container, otherwise the user is prompted and consent lasts one process lifetime. Node claims nothing, so every run would be prompted or denied.
- Writing into the widget's own container under `~/Library/Containers`: the same per-process "access data from other apps" consent.
- A read-only temporary-exception entitlement (`com.apple.security.temporary-exception.files.home-relative-path.read-only`) for a fixed directory in the owner's home: a probe on the owner's Mac showed a sandboxed, ad-hoc-signed process with this entitlement reading the file, and the same binary without it denied with `EPERM`.

## Decision

- After every non-dry run, and after a failure in `main.ts` before the run starts, the fetcher writes `~/Library/Application Support/ksef-daily-fetch/widget.json` atomically: last update time, status and reason, today's Warsaw date, the number of invoices saved today, and the newest 8 saved invoices (seller label, invoice number, formatted amount, issue date, saved-at, KSeF view URL), newest first. The exact shape is pinned in the spec (7.2).
- The widget extension's entitlements are exactly the App Sandbox plus the read-only exception for `/Library/Application Support/ksef-daily-fetch/`. It resolves the real home with `getpwuid`, because `NSHomeDirectory()` points into its container.
- The widget treats the snapshot as the whole truth: a missing, unreadable, failed or stale (older than three hours) snapshot is shown as a banner, never hidden.
- A command-line probe target signed with the same entitlements file stays in the project to check sandbox access from a terminal.

## Consequences

- No consent prompts, no Team ID, no provisioning profile.
- The path is a contract between `src/main.ts`, the extension's entitlements and the Swift loader; changing it means changing all three.
- Temporary exceptions are discouraged for the Mac App Store, which this tool will never use.
- The snapshot duplicates a little of `index.jsonl` in display-ready form, so amounts and labels look exactly as in notifications, and the widget needs no KSeF or locale logic.
- Failures that stop Node from running at all write no snapshot; the three-hour staleness banner covers them.
