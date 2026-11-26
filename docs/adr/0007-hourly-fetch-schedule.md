# ADR-0007 — Fetch every hour instead of once a day

Date: 2026-11-26
Status: accepted

## Context

ADR-0001 runs the fetcher from a per-user LaunchAgent "daily around 08:00". With a desktop widget (ADR-0005) the owner wants invoices roughly current through the day. KSeF limits per context and IP: metadata 20/h, single downloads 64/h, other protected endpoints 120/h; MF advises against high-frequency schedules and sets a floor of 15 minutes between cyclic syncs in production (`limity/limity-api.md`). An idle run costs one authentication and one metadata query; the tool downloads at most 60 invoices in any rolling hour, 4 s apart. `man launchd.plist`: `StartCalendarInterval` coalesces firings missed during sleep into one run at wake, `StartInterval` misses them.

## Decision

- The LaunchAgent uses `StartCalendarInterval` with only `Minute = 0`: a run at every full hour, and one run at wake for any hours slept through.
- Everything else in ADR-0001 stands: TypeScript on Node 22 without a build step, a local per-user LaunchAgent, label `local.ksef-daily-fetch`, the wrapper script and the log file, minimal pinned dependencies.
- Notification rules are unchanged: only new, partial or failed runs notify.

## Consequences

- New invoices reach the snapshot, notification and report within about an hour of KSeF settling them, instead of up to a day.
- Steady state uses 1 of 20 metadata queries and about 4 of 120 other calls per hour; a backfill caps at 60 downloads per rolling hour across all runs (counted from `savedAt` in the index), under KSeF's 64, with 429 handled as a partial run.
- A persistent failure (offline Mac, revoked certificate) notifies once per Warsaw day: a failed run with the same failure (a KSeF API error by its HTTP status, other errors by message) as the previous failed snapshot from the same day skips the notification (the report section and snapshot are still written). A large backfill notifies "pobrano częściowo" at every hourly run until done. The daily report file can hold several sections.
- The owner must re-run `scripts/launchagent.sh install` to switch an installed job to the new schedule.
