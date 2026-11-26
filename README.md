# ksef-daily-fetch

## What it does

The owner is a Polish sole proprietor whose purchase invoices now arrive through KSeF (Krajowy System e-Faktur, API 2.0) instead of e-mail. Nobody announces a new invoice there, and the legal date of receipt is the date KSeF assigns its number. `KSeF.app` is a macOS menu-bar app that, every hour, authenticates with a KSeF certificate, pulls every purchase invoice that is new since the last run, and saves each original XML byte for byte into an invoice folder (default `~/Documents/KSeF`). It uses the KSeF metadata query with a high-water mark checkpoint and downloads invoices one by one, so nothing is lost and nothing is fetched twice. A native macOS desktop widget, embedded in the same app, shows the newest saved invoices from a snapshot file that every run writes.

After a run that found something, the owner gets one macOS notification, for example `KSeF: 2 nowe faktury` with a body like `Acme Sp. z o.o.: 1230,00 PLN; Beta S.A.: 53,63 EUR`, and a section appended to `reports/YYYY-MM-DD.md` in the invoice folder: for each invoice the seller, NIP, invoice number, gross amount with currency, issue date, a link to view it in KSeF and the KSeF number. A run with nothing new is silent. A partial or failed run notifies with the reason and appends it to the day's report; a failure that repeats the previous run's failure on the same day notifies only once, but the report and the widget still show it, so a failure is never silent. The one thing the app cannot do is announce that it is not running: then only the widget's stale banner shows it.

Everything is set up in a settings window, with no terminal, no Node and no `config.json`. The TypeScript fetcher it replaces is still in `src/` as a fallback (see "Fallback: the TypeScript fetcher").

Design: `docs/superpowers/specs/2026-11-26-ksef-swift-app-design.md` (the app), `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md` (the fetcher rules the app ports) and `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md` (the widget); decisions: `ADR.md`.

## Requirements

- macOS 14 or newer on Apple Silicon (built and tested on macOS 27).
- Xcode (the command-line `xcodebuild`) and `brew install xcodegen`.

## Get a KSeF certificate

In Aplikacja Podatnika KSeF (`https://ap.ksef.mf.gov.pl`): log in, open the certificates section, request a certificate of type **Authentication** (*uwierzytelnianie*), choose a strong private-key password, then download the certificate (`.crt`) and the private key (`.key`). Menu names are approximate and may differ. The password cannot be recovered, so keep it in a password manager as well.

The files are expected to be a PEM certificate and an encrypted PKCS#8 private key (`-----BEGIN ENCRYPTED PRIVATE KEY-----`), RSA 2048 or EC P-256. The app reads PBES2 with PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384 or SHA512) and AES-128/192/256-CBC; anything else is rejected at **Zapisz** with the algorithm named.

A KSeF certificate has no permission scope (ADR-0002): whoever holds the key file and its password can act with the owner's full KSeF rights, including issuing invoices. Keep the original files in a safe place, and the password in a password manager. If the Mac is lost or the files leak, revoke the certificate in Aplikacja Podatnika.

## Build and install

```sh
scripts/build-app.sh --install
```

This always builds `KSeF.app` clean, ad hoc (no Apple account needed), verifies the signature and checks that the app and its widget extension have the hardened runtime and no `get-task-allow` entitlement (it stops otherwise), copies it to `~/Applications`, unregisters the build copy so only one copy is known to macOS, and opens it; it also removes `~/Applications/KsefWidget.app`, the earlier widget-only copy that shares the bundle identifier. Without `--install` it only builds, verifies and prints the signature's designated requirement (`cdhash` means ad hoc). The build copy stays in `widget/build/Build/Products/Release/KSeF.app`.

With a Developer ID certificate the script can re-sign the app, so macOS recognises it across rebuilds:

```sh
scripts/build-app.sh --install "<signing identity: full name or SHA-1>"
```

The identity is never stored anywhere; `security find-identity -v -p codesigning` lists the ones on the Mac. What changes (ADR-0012): ad hoc, after every rebuild expect one Keychain prompt for the key password (type the login password, choose **Always Allow**) and one Documents-folder prompt at the next launch; with a Developer ID signature macOS keeps both answers. Everything works either way.

## Set up

On first launch the settings window opens by itself (later: menu-bar icon, **Ustawienia…**). Fill in:

- **NIP**: the owner's 10-digit NIP (checksum is verified).
- **Certyfikat (.crt)** and **Klucz prywatny (.key)**: choose the two files with **Wybierz…** (**Zmień…** once chosen).
- **Hasło klucza**: the key password.
- **Środowisko**: `Produkcja` for real invoices (`Test` and `Demo` exist for experiments).
- **Pobieraj faktury od**: the first sync starts at this date, so use the date from which the owner wants invoices.
- **Folder faktur**: default `~/Documents/KSeF`. Changing it does not move files: in the new folder fetching starts again from the start date.

Press **Zapisz**. It checks the key against the certificate (a wrong password, a mismatched pair or an unsupported algorithm is shown in the window and nothing is stored), copies both files into the app's own folder, stores the password in the login Keychain and writes the settings. On success it shows `Zapisano.`, or `Zapisano. Teraz naciśnij „Sprawdź połączenie”.` while the connection has not been checked since the last change. Saving also asks macOS for permission to show notifications; allow it.

Then:

1. **Wyślij testowe powiadomienie**: a banner `KSeF: test powiadomienia` appears. If nothing appears, allow notifications for KSeF in System Settings, Notifications, and repeat. While they are off, the menu shows `Powiadomienia są wyłączone — włącz je w Ustawieniach systemowych` and the settings window shows `Powiadomienia: wyłączone — włącz je w Ustawieniach systemowych › Powiadomienia`.
2. **Sprawdź połączenie**: logs in to KSeF with the saved settings, lists the first window of invoices and writes and notifies nothing. Expected result: `Połączenie działa. Faktury w pierwszym oknie: N, jeszcze niezapisane: M.` Fetching starts only after a successful check; changing NIP, environment or the credentials requires a new check. Typical errors (shown as `Błąd: …`, in red):
   - `Nie można odczytać klucza prywatnego (złe hasło lub format)`: wrong key password, or the key is not an encrypted PKCS#8 PEM.
   - `Nieobsługiwany algorytm szyfrowania klucza`: the key uses an encryption algorithm the app cannot read; the message names its OID.
   - `Klucz prywatny nie pasuje do certyfikatu`: the `.crt` and `.key` files do not belong together.
   - `Brak hasła klucza w Pęku kluczy`: the Keychain item does not exist (for example it was deleted); choose both files again, type the password and press **Zapisz**.
   - `Uwierzytelnienie w KSeF nieudane (kod …)`: KSeF rejected the certificate; the message carries KSeF's own reason.
3. **Uruchamiaj przy logowaniu**: starts the app at login. If macOS asks for approval, the window shows how (**Otwórz ustawienia logowania**).

Where things live (the widget can read only the snapshot, the last item):

- `~/Library/Application Support/local.ksef-daily-fetch.KsefWidget/`, folder mode 0700: `settings.json`, `ksef-auth.crt` and `ksef-auth.key` (still encrypted), mode 0600.
- Login Keychain: one item, service `local.ksef-daily-fetch.KsefWidget`, account `key-password`, label `KSeF — hasło klucza prywatnego`.
- The invoice folder: `state.json` (checkpoint), `index.jsonl` (one line per saved invoice, also the dedup set), `invoices/YYYY/MM/<ksefNumber>.xml` and `reports/YYYY-MM-DD.md`. The formats are the same as the TypeScript fetcher's. The app adds `identity.json` (`{"nip", "environment"}`): a folder belongs to one NIP and environment, and a run or a check against another is refused with `Folder faktur zawiera dane innego podatnika lub środowiska`; a folder without the file (new, or written by the TypeScript fetcher) is adopted.
- `~/Library/Application Support/ksef-daily-fetch/widget.json`: the widget snapshot, rewritten after every run.

## Running

The app fetches when the last run is an hour or more old. A background tick every 15 minutes checks that, and so does every launch and every wake from sleep, so a Mac that slept through an hour catches up when it wakes; relaunching within the hour of the last run does not fetch again. Only one run happens at a time. The menu-bar icon shows the status line and offers **Pobierz teraz** (a manual fetch, regardless of the hour), **Ustawienia…**, **Otwórz folder faktur** and **Zakończ**.

Notification rules are those of the TypeScript fetcher: nothing for a quiet complete run, one per run for new invoices (`KSeF: 2 nowe faktury`), partial or failed; a failed run with the same failure as the previous failed run on the same Europe/Warsaw day (a KSeF API error counts by its HTTP status alone, any other error by its message) does not notify again, so a lasting failure notifies once a day, not every hour. A problem that stops a run before it starts (damaged settings, unreadable credential files, missing Keychain item) is reported the same way and also writes a failed snapshot.

KSeF allows 64 single-invoice downloads per hour, so the app never saves more than 60 invoices in any rolling hour, counting earlier runs too (from `savedAt` in `index.jsonl`). A large backfill that ends with a message ending in `pobrań na godzinę.` simply continues at the next hourly run.

The app does not fetch while the old LaunchAgent is installed (see the fallback section); the menu says `Wstrzymane: zainstalowane jest stare zadanie launchd`. **Sprawdź połączenie** still works then.

Logs go to the unified log; run lines look like `run finished trigger=… status=… saved=…`:

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "local.ksef-daily-fetch.app"'
```

(Use the full path: in zsh, `log` alone is a shell builtin.)

## Desktop widget

A medium or large widget on the desktop lists the newest saved invoices (seller, gross amount, issue date) under `KSeF · zaktualizowano HH:mm`, with `N nowe dziś` for the invoices saved today. It reads only `~/Library/Application Support/ksef-daily-fetch/widget.json`, which every run writes; it never talks to KSeF, has no network access and can read nothing else. One banner can appear above the list:

- `Brak danych`: no snapshot yet (nothing has been fetched since the widget was set up).
- `Nie można odczytać danych widżetu`: the snapshot cannot be read or decoded.
- `Dane nieaktualne — ostatnia aktualizacja`: the snapshot is three hours old or older, for example the Mac was off or the app is not running.
- `Błąd pobierania`: the last run failed.
- `Pobrano częściowo`: the last run was partial.

The widget is part of `KSeF.app`, so installing the app installs it. Right-click the desktop, choose **Edit Widgets…**, search for "KSeF" and add the medium or large size (menu names may differ slightly). After every run the app asks the widget to refresh; otherwise macOS refreshes it about every 30 minutes. Clicking an invoice opens its KSeF page in the browser through the app, which keeps running.

Troubleshooting:

- Check sandbox access from a terminal: build the `SnapshotProbe` scheme the same way as the app (`-scheme SnapshotProbe`) and run `widget/build/Build/Products/Release/SnapshotProbe`. It prints `OK status=…` (or `MISSING` before the first run).
- Widget not in the gallery: make sure the app is in `~/Applications`, launch it once, and look for `purging` in `/usr/bin/log show --last 10m --predicate 'process == "chronod"' | grep ksef-daily-fetch`. If macOS refuses an ad-hoc widget, build with a Developer ID identity (`scripts/build-app.sh --install "<identity>"`).
- Clicks do nothing: `/usr/bin/log show --last 5m --predicate 'subsystem == "local.ksef-daily-fetch.app"'` should show `opened host=…`.

Update after a code change: `scripts/build-app.sh --install` again.

## Fallback: the TypeScript fetcher

The original fetcher is still in `src/`, unchanged, until the owner confirms the app against production. **Only one of the two may run**: the download cap counts per invoice folder, so both together could exceed KSeF's limits. The app pauses while the LaunchAgent exists and fetches again at the next tick after it is removed:

```sh
scripts/launchagent.sh uninstall
```

To use the fetcher instead (Node >= 22.18, pnpm; `pnpm install --frozen-lockfile`):

- Put `ksef-auth.crt` and `ksef-auth.key` in `~/.config/ksef-daily-fetch/` (mode 700 folder, mode 600 files).
- Store the key password: `security add-generic-password -s ksef-daily-fetch -a <NIP> -U -w` (macOS prompts twice, so it never appears in shell history).
- `cp config.example.json config.json` and fill it in: `nip`, `environment` (`prod`), `certificatePath`, `keyPath` (absolute), `startDate` (`YYYY-MM-DD`), optional `dataDir` (default `data`). `config.json` is gitignored.
- `node src/main.ts --test-notification` and `node src/main.ts --dry-run` check notifications and the login; `node src/main.ts` fetches once.
- `scripts/launchagent.sh install` installs the hourly job (from a normal checkout, never from a `.claude/worktrees/…` path: the plist records the absolute path). Logs: `~/Library/Logs/ksef-daily-fetch.log`.

The fetcher writes the same snapshot file, so the widget works with either.

## First-run checklist

Only the owner can verify these; the build was checked on the KSeF TEST environment and offline (see Development), never against production, with the real Keychain, with notifications or in the real widget host.

1. Build and install (`scripts/build-app.sh --install`, with or without an identity): the app appears in the menu bar and opens its settings window.
2. Pick the real `.crt` and `.key`, type the password, NIP, environment `Produkcja`, start date, keep or change the folder, press **Zapisz**: the Keychain item is created; macOS may ask for Documents access and notification permission. Also check that copy and paste work in the password field.
3. **Wyślij testowe powiadomienie**: the banner appears.
4. **Sprawdź połączenie**: the first production login with the Swift signer; expected `Połączenie działa. …`. On failure, send the exact message to the developer (the issuer string of the MF CA is the one thing the TEST environment could not exercise).
5. Turn on **Uruchamiaj przy logowaniu**; approve in System Settings if asked; log out and in once.
6. Add the widget; after the first run it shows data; click a row: the browser opens the KSeF page and the app keeps running.
7. After a day: hourly `run finished` lines in the log (command above), including one after a sleep.
8. After one rebuild: note which prompts reappeared (Keychain, Documents, login item, notifications), ad hoc or Developer ID.
9. Report the key's algorithm OIDs (`openssl asn1parse -in <key> | grep OBJECT`) and the certificate's issuer line (`/usr/bin/openssl x509 -in <crt> -noout -issuer -nameopt RFC2253,utf8,-esc_msb`).
10. Once satisfied, confirm, so the TypeScript fetcher can be removed in a separate change.

## Troubleshooting

- A corrupt line in `index.jsonl` fails the run loudly (`Uszkodzony plik index.jsonl, linia N`). The XML stays on disk; delete or fix that line and the next run downloads the invoice again.
- `Token dostępu wkrótce wygaśnie.`: the run ended early because the access token was about to expire; the next run continues.
- A failed run appends a `BŁĄD` section to the day's report and notifies, except when it repeats the previous failed run's reason on the same Europe/Warsaw day.
- `Uszkodzony plik ustawień`: `settings.json` was edited by hand or damaged; open **Ustawienia…**, correct the fields and press **Zapisz**.

## Development

```sh
xcodegen generate --spec widget/project.yml --project widget

# offline tests of the Swift library (KsefCore)
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefCoreTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test
# widget tests; add TEST_RUNNER_WIDGET_RENDER_DIR=<dir> to also write PNG renders
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidgetTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test
# settings window tests, with PNG renders of its states
mkdir -p widget/build/renders && TEST_RUNNER_SETTINGS_RENDER_DIR="$PWD/widget/build/renders" xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefAppTests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test

# against KSeF TEST only (network; not 16:00-18:00 Warsaw time, the TEST maintenance window)
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefE2ETests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test -only-testing:KsefE2ETests/AuthE2ETests
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefE2ETests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test -only-testing:KsefE2ETests/FetchE2ETests

# the TypeScript fallback
pnpm test
pnpm typecheck
```

`FetchE2ETests` takes 4–8 minutes, and TEST allows 20 metadata queries per hour, so run it at most twice an hour.

The Swift fixtures in `widget/CoreTests/Fixtures/` come from the TypeScript code (throwaway self-signed TEST keys). After a change to `src/` formats, regenerate them with `node test/golden/make-vectors.ts widget/CoreTests/Fixtures` and rerun `KsefCoreTests`; the RSA signature must stay byte-identical.

What was verified, and where:

- On the KSeF TEST environment: the XAdES login with an RSA and an EC self-signed certificate, and a full send, fetch and second run through the real `run()` (`KsefE2ETests`).
- Offline: all `KsefCoreTests` (ports of the 142 TypeScript tests plus the settings, schedule and status line), `KsefWidgetTests`, `KsefAppTests` and `pnpm test`; the RSA XAdES output is byte-identical to the TypeScript signer's.
- Not verified at all until the owner does it (first-run checklist): production login, the Keychain adapter and its prompt, the Documents prompt, notifications, the login item, the scheduler over a day, and the widget in the real widget host.

Building or testing registers the built app with LaunchServices; unregister it afterwards (`scripts/build-app.sh` does this for its own build):

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/widget/build/Build/Products/Release/KSeF.app"
```

See `AGENTS.md` for the project rules.
