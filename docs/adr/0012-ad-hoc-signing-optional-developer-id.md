# ADR-0012 — Ad-hoc signing by default; the owner may re-sign with their Developer ID through the build script

Date: 2026-11-26
Status: accepted

## Context

ADR-0005 signs ad hoc and commits nothing personal; the repository is public. The app now owns a Keychain item, a Documents-folder permission, a login item and notification permission (ADR-0010, ADR-0011). macOS ties Keychain item ACLs and privacy answers to the app's designated requirement; an ad-hoc build's requirement is its cdhash, which changes with every build (TN3127, DTS), while a Developer ID requirement names the bundle ID and Team ID and survives rebuilds. The owner's Mac has two "Developer ID Application" identities. Notarisation is not needed for an app built and run on the same Mac.

## Decision

- Builds are ad hoc by default (`CODE_SIGN_IDENTITY = "-"` in `widget/project.yml`); implementers never use a signing identity.
- `scripts/build-app.sh [--install] [signing-identity]` builds Release ad hoc and, when an identity is passed, re-signs inside out with it: the extension with `widget/Extension/Extension.entitlements`, then the app with no entitlements. Both targets are built with the hardened runtime and without `get-task-allow` (`ENABLE_HARDENED_RUNTIME`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` in `widget/project.yml`), and the re-sign passes `--options runtime`, so another process of the owner cannot attach to the app or inject code to read the key password; no runtime exception entitlements are used. No notarisation. The identity is never written to a tracked file.
- Developer ID is recommended, not required.

## Consequences

- Ad hoc (expected from Apple DTS statements, not probed): after each rebuild the first Keychain read prompts for the login password ("Always Allow" ends it), and the Documents permission is asked again; login-item approval may need repeating. The app reads the Keychain and touches the folder at launch, so these prompts appear while the owner is at the Mac. The owner's first rebuild confirms or corrects this.
- Developer ID (expected): these answers survive rebuilds. Switching from ad hoc to Developer ID once causes one more prompt for the existing item.
- The data protection keychain stays out of reach either way (it needs a provisioning profile).
