# ADR-0001 — TypeScript on Node 22, run daily by a local LaunchAgent

Date: 2026-11-26
Status: superseded by ADR-0008

## Context

The tool fetches the owner's purchase invoices from KSeF once a day and notifies them. It holds a KSeF certificate private key that acts with the owner's full KSeF rights (see ADR-0002). The owner works on a single Mac (Apple Silicon) with Node v22.23.4 and pnpm. Options for where it runs: a scheduled job on that Mac, or a cloud scheduled job. Options for how it is built: a compiled TypeScript project, or TypeScript executed directly by Node 22's built-in type stripping (on by default since 22.18).

## Decision

- Run locally as a per-user LaunchAgent (`StartCalendarInterval`, daily around 08:00). launchd starts a run missed during sleep as soon as the Mac wakes.
- Write TypeScript and run it with `node src/main.ts`, no build step. Only erasable TypeScript syntax; `typescript` is a devDependency used for `tsc --noEmit` only. Tests use `node --test`. Package manager: pnpm.
- Runtime dependencies are kept to the minimum and pinned to exact versions; pnpm's `minimumReleaseAge` holds back releases younger than 14 days.

## Consequences

- The private key, its password (in the macOS Keychain) and the downloaded invoices never leave the owner's machine; notifications are native macOS notifications.
- No hosting, no secrets in a cloud store, nothing to deploy.
- If the Mac is powered off at the scheduled time, the run waits until the next scheduled time; invoices are delayed, not lost.
- The launchd job depends on an absolute Node path; a Node upgrade that moves the binary breaks the job. A wrapper script notifies when Node cannot start.
- No build step means no `enum`, `namespace` or parameter properties, and imports carry `.ts` extensions.
- Moving to a server later would need a new decision on secret storage and notifications.
