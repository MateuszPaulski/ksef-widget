# ksef-daily-fetch

## What it does

The owner is a Polish sole proprietor whose purchase invoices now arrive through KSeF (Krajowy System e-Faktur, API 2.0) instead of e-mail. Nobody announces a new invoice there, and the legal date of receipt is the date KSeF assigns its number. Every hour this tool authenticates with a KSeF certificate, pulls every purchase invoice that is new since the last run, and saves each original XML byte for byte under `data/`. It uses the KSeF metadata query with a high-water mark checkpoint and downloads invoices one by one, so nothing is lost and nothing is fetched twice. A native macOS desktop widget (`widget/`) shows the newest saved invoices from a snapshot file that every run writes.

After a run that found something, the owner gets one macOS notification, for example `KSeF: 2 nowe faktury` with a body like `Acme Sp. z o.o.: 1230,00 PLN; Beta S.A.: 53,63 EUR`, and a section appended to `data/reports/YYYY-MM-DD.md`: for each invoice the seller, NIP, invoice number, gross amount with currency, issue date, a link to view it in KSeF and the KSeF number. A run with nothing new is silent. A partial or failed run notifies with the reason and appends it to the day's report; a failure that repeats the previous run's failure on the same day notifies only once (see the hourly job below), but the report and the widget still show it, so a failure is never silent. Design: `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md` and, for the widget, `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md`; decisions: `ADR.md`.

## Requirements

- macOS (Apple Silicon), Node >= 22.18 (`node --version`), pnpm.
- `pnpm install --frozen-lockfile`

## Get a KSeF certificate

In Aplikacja Podatnika KSeF (`https://ap.ksef.mf.gov.pl`): log in, open the certificates section, request a certificate of type **Authentication** (*uwierzytelnianie*), choose a strong private-key password, then download the certificate (`.crt`) and the private key (`.key`). Menu names are approximate and may differ. The password cannot be recovered, so keep it in a password manager as well.

The files are expected to be a PEM certificate and an encrypted PKCS#8 private key (`-----BEGIN ENCRYPTED PRIVATE KEY-----`), RSA 2048 or EC P-256. The first dry run (below) confirms this.

A KSeF certificate has no permission scope (ADR-0002): whoever holds the key file and its password can act with the owner's full KSeF rights, including issuing invoices. Keep the key outside the repository, readable only by the owner, and the password only in the Keychain. If the Mac is lost or the files leak, revoke the certificate in Aplikacja Podatnika.

## Put the files in place

```sh
mkdir -p ~/.config/ksef-daily-fetch && chmod 700 ~/.config/ksef-daily-fetch
# move ksef-auth.crt and ksef-auth.key there, then:
chmod 600 ~/.config/ksef-daily-fetch/*
```

## Store the key password in Keychain

```sh
security add-generic-password -s ksef-daily-fetch -a <NIP> -U -w
```

With `-w` last, macOS prompts for the password twice, so it never appears in shell history. Check that it is stored:

```sh
security find-generic-password -s ksef-daily-fetch -a <NIP> >/dev/null && echo stored
```

## Create `config.json`

```sh
cp config.example.json config.json
```

- `nip`: the owner's 10-digit NIP (checksum is verified).
- `environment`: `prod` for real invoices (`test` and `demo` exist for experiments).
- `certificatePath`, `keyPath`: absolute paths to the two files above.
- `startDate`: `YYYY-MM-DD`, not in the future. The first sync starts here, so use the date from which the owner wants invoices, for example the date KSeF became mandatory for them.
- `dataDir`: optional, default `data`; a relative path is resolved against the repository root.

`config.json` is gitignored.

## Check notifications

```sh
node src/main.ts --test-notification
```

If nothing appears, allow notifications for **Script Editor** (the host of `osascript`) in System Settings, Notifications, and repeat.

## Dry run

```sh
node src/main.ts --dry-run
```

Authenticates and lists the first window without downloading or writing anything, and without notifying even on failure (the reason goes to stderr, exit code 3). Expected line: `dry run: N invoices in the first window, M not yet saved`. Typical errors:

- `Nie można odczytać klucza prywatnego (złe hasło lub format)`: wrong key password in the Keychain, or the key is not an encrypted PKCS#8 PEM.
- `Brak hasła klucza w Pęku kluczy`: the Keychain item for this NIP does not exist.
- `Klucz prywatny nie pasuje do certyfikatu`: the `.crt` and `.key` files do not belong together.
- `Uwierzytelnienie w KSeF nieudane (kod …)`: KSeF rejected the certificate; the message carries KSeF's own reason.

## First real run

```sh
node src/main.ts
```

Files land in `data/invoices/YYYY/MM/<ksefNumber>.xml`, `data/reports/YYYY-MM-DD.md`, `data/index.jsonl` (one line per saved invoice) and `data/state.json` (checkpoint). Exit codes: 0 complete, 2 partial, 3 failed (handled by `main.ts`, which has notified), 1 usage error or Node crashed before `main` ran (the wrapper script notifies). KSeF allows 64 single-invoice downloads per hour, so the tool never saves more than 60 invoices in any rolling hour, counting earlier runs too (from `savedAt` in `data/index.jsonl`). If a large backfill ends with `Limit 60 pobrań na godzinę.`, run it again after an hour; hourly runs and manual runs share the same budget.

## Install the hourly job

```sh
scripts/launchagent.sh install
```

Run `pnpm install --frozen-lockfile` in the checkout the LaunchAgent will run from before `install`, and never install the agent from a `.claude/worktrees/…` path: the plist records the absolute path of the checkout it was generated in.

The job runs every hour at minute 0, or once when the Mac wakes after sleeping through one or more full hours; it does not run while the Mac is off. If an older daily job is installed, run `scripts/launchagent.sh install` again to switch it (same label, so it replaces the old one). Notifications still come only for new, partial or failed runs. A failed run whose reason is identical to the previous failed run's, on the same Europe/Warsaw day, does not notify again, so a lasting failure (offline Mac, revoked certificate) notifies once a day, not every hour; a backfill still notifies "pobrano częściowo" at each hourly run. Every failed or partial run still appends a report section, refreshes the snapshot and shows its banner in the widget. Logs: `~/Library/Logs/ksef-daily-fetch.log`. Run it now with `launchctl kickstart gui/$(id -u)/local.ksef-daily-fetch`. Remove it with `scripts/launchagent.sh uninstall`. Re-run `install` after a Node upgrade that changes the output of `command -v node`; if Node has vanished or the program cannot start (for example `node_modules` is missing), the wrapper script still shows a notification.

## Desktop widget

A medium or large widget on the desktop lists the newest saved invoices (seller, gross amount, issue date) under `KSeF · zaktualizowano HH:mm`, with `N nowe dziś` for the invoices saved today. It reads only `~/Library/Application Support/ksef-daily-fetch/widget.json`, which every run writes; it never talks to KSeF, has no network access and can read nothing else. One banner can appear above the list:

- `Brak danych …`: no snapshot yet (the fetcher has not run since the widget was set up).
- `Nie można odczytać danych widżetu: …`: the snapshot cannot be read or decoded.
- `Dane nieaktualne — ostatnia aktualizacja …`: the snapshot is three hours old or older, for example the Mac was off or the job is not installed.
- `Błąd pobierania: …`: the last run failed.
- `Pobrano częściowo …`: the last run was partial.

Requirements: Xcode (the command-line `xcodebuild`) and `brew install xcodegen`.

Build (signing is ad hoc, "Sign to Run Locally"; no Apple developer account, certificate or Keychain access is needed):

```sh
xcodegen generate --spec widget/project.yml --project widget
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build build
```

Install, then unregister the build copy so only one copy is known to macOS:

```sh
mkdir -p ~/Applications && rm -rf ~/Applications/KsefWidget.app && ditto widget/build/Build/Products/Release/KsefWidget.app ~/Applications/KsefWidget.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/widget/build/Build/Products/Release/KsefWidget.app"
```

Launch it once with `open ~/Applications/KsefWidget.app`: an alert says the widget is installed. Then right-click the desktop, choose **Edit Widgets…**, search for "KSeF" and add the medium or large size (menu names may differ slightly). The widget refreshes about every 30 minutes; macOS decides the exact moment. Clicking an invoice opens its KSeF page in the browser through the app.

Troubleshooting:

- Check sandbox access from a terminal: build the `SnapshotProbe` scheme the same way and run `widget/build/Build/Products/Release/SnapshotProbe`. It prints `OK status=…` (or `MISSING` before the first run).
- Widget not in the gallery: make sure the app is in `~/Applications`, launch it once, and look for `purging` in `/usr/bin/log show --last 10m --predicate 'process == "chronod"' | grep ksef-daily-fetch`. (Use the full path: in zsh, `log` alone is a shell builtin.) If macOS refuses an ad-hoc widget, build with Developer ID by adding `CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=<your Team ID>` to the `xcodebuild` line (never commit these).
- Clicks do nothing: `/usr/bin/log show --last 5m --predicate 'subsystem == "local.ksef-daily-fetch.widget"'` should show `opened host=…`.

Update after a code change: rebuild and repeat the install.

## Troubleshooting

- A corrupt line in `data/index.jsonl` fails the run loudly. The XML stays on disk; delete or fix that line and the next run downloads the invoice again.
- `Token dostępu wkrótce wygaśnie.`: the run ended early because the access token was about to expire; the next run continues.
- A failed run appends a `BŁĄD` section to the day's report and notifies, except when it repeats the previous failed run's reason on the same Europe/Warsaw day.

## Development

```sh
pnpm test            # offline unit tests
pnpm typecheck
pnpm test:e2e:auth   # XAdES authentication against KSeF TEST
pnpm test:e2e        # full fetch against KSeF TEST (not 16:00-18:00 Warsaw time)

# widget unit tests
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test
# the same, also rendering PNGs of the widget states
mkdir -p widget/build/renders && TEST_RUNNER_WIDGET_RENDER_DIR="$PWD/widget/build/renders" xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test
```

Building or testing the widget registers the built app with LaunchServices; unregister it with the `lsregister -u` command above afterwards.

See `AGENTS.md` for the project rules.
