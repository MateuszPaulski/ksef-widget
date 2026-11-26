# ADR-0010 — In-app hourly scheduler, login item and native notifications instead of launchd and osascript

Date: 2026-11-26
Status: accepted

## Context

ADR-0007 runs the fetch from launchd at every full hour with one coalesced run at wake, and notifies through `osascript`. The Swift app (ADR-0008) runs all the time. Apple documents `NSBackgroundActivityScheduler` for periodic fetches every ten minutes or more; DTS notes that `Timer` stops during sleep and that timers of napping apps are throttled. `SMAppService.mainApp` registers an app as a login item; `UNUserNotificationCenter` posts native notifications. KSeF limits and MF's 15-minute floor are as in ADR-0007.

## Decision

- An `NSBackgroundActivityScheduler` (every 15 minutes, tolerance 5 minutes) and `NSWorkspace.didWakeNotification` and app launch all call one `tick()`. `tick()` starts a run only when the last run (the snapshot's `updatedAt` or the app's last run end) is an hour or more ago, only when the app is configured and verified, only when the old LaunchAgent is absent, and never while a run is in progress. A manual "Pobierz teraz" uses the same one-at-a-time gate.
- Each run holds a process activity so App Nap does not stretch its pauses; idle system sleep stays allowed.
- Start at login through `SMAppService.mainApp`, switched by the owner in the settings window.
- Notifications through `UNUserNotificationCenter` with the texts and rules of ADR-0007 unchanged (including one notification per Warsaw day for a repeated failure and always one when a failed run saved invoices).

## Consequences

- Runs happen about every 60–75 minutes from the last run, not at minute 0; catch-up after wake comes from the wake hook, not from launchd's coalescing.
- The rolling-hour cap of 60 downloads, the 4-second pacing and the 429 handling are unchanged.
- A login item and notification permission now belong to the app's bundle and signature; under ad-hoc signing a rebuild may ask again (ADR-0012).
- Supersedes ADR-0007.
