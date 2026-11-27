# ksef-daily-fetch

## What it does

The owner is a Polish sole proprietor whose purchase invoices now arrive through KSeF (Krajowy System e-Faktur, API 2.0) instead of e-mail. Nobody announces a new invoice there, and the legal date of receipt is the date KSeF assigns its number. `KSeF.app` is a macOS menu-bar app that, every hour, authenticates with a KSeF certificate, pulls every purchase invoice that is new since the last run, and saves each original XML byte for byte into an invoice folder (default `~/Documents/KSeF`). It uses the KSeF metadata query with a high-water mark checkpoint and downloads invoices one by one, so nothing is lost and nothing is fetched twice. A native macOS desktop widget, embedded in the same app, shows the newest saved invoices from a snapshot file that every run writes.

After a run that found something, the owner gets one macOS notification, for example `KSeF: 2 nowe faktury` with a body like `Acme Sp. z o.o.: 1230,00 PLN; Beta S.A.: 53,63 EUR`, and a section appended to `reports/YYYY-MM-DD.md` in the invoice folder: for each invoice the seller, NIP, invoice number, gross amount with currency, issue date, a link to view it in KSeF and the KSeF number. A run with nothing new is silent. A partial or failed run notifies with the reason and appends it to the day's report; a failure that repeats the previous run's failure on the same day notifies only once, but the report and the widget still show it, so a failure is never silent. The one thing the app cannot do is announce that it is not running: then only the widget's stale banner shows it.

The widget also shows a one-line summary of the current year at the bottom: net expenses (purchase invoices) and net incomes (sales invoices). To get it, the app also reads the metadata of the owner's sales invoices from KSeF every hour and keeps a ledger of the current year in the invoice folder; sales invoices are never downloaded, notified or reported, and no XML of theirs is saved. What the summary covers, and what it does not:

- Only invoices that are present in KSeF: an invoice issued outside KSeF, or before KSeF applied, is not in it.
- Net amounts, by issue date, for the current calendar year in Europe/Warsaw time. Gross amounts and VAT are not summed.
- PLN is always shown; every other currency is listed separately (`+ <kwota> EUR`) and never converted. A currency whose sum is zero is not listed.
- Correcting invoices count with the sign KSeF reports for them.
- Advance and settlement invoices may count twice, if the issuer entered the full value on both; KSeF's documentation does not say how it fills the net amount for them, so compare the totals with the owner's own books.
- The first run after the update reads the year from 1 January, so until it completes the line shows `podsumowanie w przygotowaniu`. `stan na …` means the last refresh did not complete (see Desktop widget).

Everything is set up in a settings window, with no terminal, no Node and no `config.json`.

Design: `docs/superpowers/specs/2026-11-26-ksef-swift-app-design.md` (the app), `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md` (the fetcher rules the app ports), `docs/superpowers/specs/2026-11-26-ksef-desktop-widget-design.md` (the widget) and `docs/superpowers/specs/2026-11-27-ksef-year-summary-and-fallback-removal-design.md` (the year summary); decisions: `ADR.md`.

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
- The invoice folder: `state.json` (checkpoint), `index.jsonl` (one line per saved invoice, also the dedup set), `invoices/YYYY/MM/<ksefNumber>.xml` and `reports/YYYY-MM-DD.md`, plus the year summary's two files: `ledger.jsonl` (append-only, one line per purchase or sales invoice of the year with its KSeF number, side, issue date, type, currency and net, gross and VAT amounts) and `ledger-state.json` (the checkpoint of each side, the time of the last complete refresh and the `skipped` invoices, see Desktop widget). The app adds `identity.json` (`{"nip", "environment"}`): a folder belongs to one NIP and environment, and a run or a check against another is refused with `Folder faktur zawiera dane innego podatnika lub środowiska`; a folder without the file (new, or written by an earlier version) is adopted.
- `~/Library/Application Support/ksef-daily-fetch/widget.json`: the widget snapshot, rewritten after every run.

## Running

The app fetches when the last run is an hour or more old. A background tick every 15 minutes checks that, and so does every launch and every wake from sleep, so a Mac that slept through an hour catches up when it wakes; relaunching within the hour of the last run does not fetch again. Only one run happens at a time. The menu-bar icon shows the status line and offers **Pobierz teraz** (a manual fetch, regardless of the hour), **Ustawienia…**, **Otwórz folder faktur** and **Zakończ**.

Notification rules: nothing for a quiet complete run, one per run for new invoices (`KSeF: 2 nowe faktury`), partial or failed; a failed run with the same failure as the previous failed run on the same Europe/Warsaw day (a KSeF API error counts by its HTTP status alone, any other error by its message) does not notify again, so a lasting failure notifies once a day, not every hour. The notification and the report section for new invoices are written as soon as the download ends, before the year summary is updated, so they never wait for it. A problem that stops a run before it starts (damaged settings, unreadable credential files, missing Keychain item) is reported the same way and also writes a failed snapshot.

KSeF allows 64 single-invoice downloads per hour, so the app never saves more than 60 invoices in any rolling hour, counting earlier runs too (from `savedAt` in `index.jsonl`). A large backfill that ends with a message ending in `pobrań na godzinę.` simply continues at the next hourly run.

KSeF also allows 20 metadata queries per hour. An idle hourly run uses 3 of them (one for the purchase download, one for each side of the year summary), the first run after the update up to 9 (up to 11 from 27 December: one download query plus up to 5 year windows per side, up to 4 before that date), and each **Pobierz teraz** 3. The year summary pauses 500 ms before each of its queries, so that KSeF's limit of 8 queries per second is never approached. The download always runs first, and a summary that stops never changes the run's status, notification or report. But the summary shares KSeF's budget of 20 queries per hour, at 3 per run instead of 1: many **Pobierz teraz** presses within an hour can use it up, and the next download is then partial (with KSeF's rate-limit reason; it resumes at the next hourly run). Reaching the limit during the summary update stops only that update, which continues at the next hourly run.

Logs go to the unified log; run lines look like `run finished trigger=… status=… saved=…`:

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "local.ksef-daily-fetch.app"'
```

(Use the full path: in zsh, `log` alone is a shell builtin.)

## Desktop widget

A medium or large widget on the desktop lists the newest saved invoices (seller, gross amount, issue date) under `KSeF · zaktualizowano HH:mm`, with `N nowe dziś` for the invoices saved today, and the year summary as a line at the bottom. It reads only `~/Library/Application Support/ksef-daily-fetch/widget.json`, which every run writes; it never talks to KSeF, has no network access and can read nothing else. One banner can appear above the list:

- `Brak danych`: no snapshot yet (nothing has been fetched since the widget was set up).
- `Nie można odczytać danych widżetu`: the snapshot cannot be read or decoded.
- `Dane nieaktualne — ostatnia aktualizacja`: the snapshot is three hours old or older, for example the Mac was off or the app is not running.
- `Błąd pobierania`: the last run failed.
- `Pobrano częściowo`: the last run was partial.

The year summary line is one of four, in the widget's secondary colour (orange when it is a warning):

- `2026 · wydatki 1230,00 PLN · przychody 0,00 PLN`: both sides are up to date as of the last run. Amounts of 10 000 and more are grouped with a non-breaking space.
- `2026 (stan na 26.11 11:00) · wydatki … · przychody …`: orange; the last run did not complete the refresh (a limit, a failure, or a partial download), so the totals are as of the time shown, in Warsaw time, and the next complete run clears it.
- `2026 · podsumowanie w przygotowaniu`: orange; the ledger has not yet completed once, for example right after the update, so no total is shown.
- `2026 · podsumowanie niedostępne: …`: orange; a ledger file cannot be read, with the reason (see Troubleshooting).

The first two lines can end with ` · pominięte: N` (orange): N invoices of the year, purchase or sales, were left out of the totals because KSeF's metadata for them is incomplete or invalid, for example a missing net amount. The invoices themselves are downloaded and reported as usual; only the summary skips them. The skipped invoices are listed under `skipped` in `ledger-state.json`, and the app logs each one once, when it first skips it:

```sh
/usr/bin/log show --last 1d --predicate 'subsystem == "local.ksef-daily-fetch.app" AND eventMessage CONTAINS "ledger"'
```

The lines look like `ledger Subject1 skipped "<KSeF number>": …` (`Subject2` is a purchase invoice, `Subject1` a sales invoice).

With the summary the medium widget shows two invoice rows instead of three (one under a banner); the large widget keeps eight. After a setup failure (no settings, unreadable credential files, missing Keychain item) there is no summary line until the next run.

The widget is part of `KSeF.app`, so installing the app installs it. Right-click the desktop, choose **Edit Widgets…**, search for "KSeF" and add the medium or large size (menu names may differ slightly). After every run the app asks the widget to refresh; otherwise macOS refreshes it about every 30 minutes. Clicking an invoice opens its KSeF page in the browser through the app, which keeps running.

Troubleshooting:

- Check sandbox access from a terminal: build the `SnapshotProbe` scheme the same way as the app (`-scheme SnapshotProbe`) and run `widget/build/Build/Products/Release/SnapshotProbe`. It prints `OK status=…` (or `MISSING` before the first run).
- Widget not in the gallery: make sure the app is in `~/Applications`, launch it once, and look for `purging` in `/usr/bin/log show --last 10m --predicate 'process == "chronod"' | grep ksef-daily-fetch`. If macOS refuses an ad-hoc widget, build with a Developer ID identity (`scripts/build-app.sh --install "<identity>"`).
- Clicks do nothing: `/usr/bin/log show --last 5m --predicate 'subsystem == "local.ksef-daily-fetch.app"'` should show `opened host=…`.

Update after a code change: `scripts/build-app.sh --install` again.

## Leftovers of the old setup

Only the owner runs these; nothing in the app needs them.

```sh
# in the main checkout of this repository
rm config.json
rm -rf node_modules
ls data   # delete data/ only if it holds nothing you want
# the old credential copies: first make sure the original .crt and .key are kept somewhere safe
rm -r ~/.config/ksef-daily-fetch
security delete-generic-password -s ksef-daily-fetch
rm -f ~/Library/Logs/ksef-daily-fetch.log
ls ~/Library/LaunchAgents | grep ksef   # expected: nothing (no LaunchAgent was installed)
```

## After updating to the year summary

The year summary and the removal of the TypeScript fetcher are installed by building again after merging: `scripts/build-app.sh --install`. Only the owner can verify these; the build was checked offline and on the KSeF TEST environment (see Development), never against production, in the real widget host or with real invoices.

1. The footer appears in the real medium and large widget after the first run, in light and dark appearance; the medium widget shows two rows.
2. The first run after the update completes the ledger (the line has no `stan na`); `ledger.jsonl` and `ledger-state.json` appear in the invoice folder, and the files that were there before are untouched. That run reads the year from 1 January, so it uses up to 11 metadata queries.
3. Expenses and incomes match the owner's own records for the year (net, by issue date), including any correction, advance or settlement invoice and foreign-currency invoice.
4. After a run that hits a limit or fails, the line shows `(stan na …)` in orange and clears at the next complete run.
5. On 1 January the line switches to the new year at the first run.
6. Delete the leftovers of the old setup that are no longer needed (Leftovers of the old setup, above).

## Troubleshooting

- `podsumowanie niedostępne: Uszkodzony plik ledger.jsonl, linia N`: that line of `ledger.jsonl` is damaged (for example a torn last line). Quit the app, delete both `ledger.jsonl` and `ledger-state.json` in the invoice folder, and start the app: the year is read again from 1 January (up to 11 metadata queries). Deleting only the damaged line would not help, because the checkpoint has already passed it and the invoice would never come back. `Uszkodzony plik ledger-state.json` is handled the same way.
- A corrupt line in `index.jsonl` fails the run loudly (`Uszkodzony plik index.jsonl, linia N`). The XML stays on disk; delete or fix that line and the next run downloads the invoice again.
- `Token dostępu wkrótce wygaśnie.`: the run ended early because the access token was about to expire; the next run continues.
- A failed run appends a `BŁĄD` section to the day's report and notifies, except when it repeats the previous failed run's reason on the same Europe/Warsaw day.
- `Uszkodzony plik ustawień`: `settings.json` was edited by hand or damaged; open **Ustawienia…**, correct the fields and press **Zapisz**.
- A "Passwords…" popup appears under a settings field and blocks typing: press Esc and click the field again.

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
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefE2ETests -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build test -only-testing:KsefE2ETests/SummaryProbeE2ETests
```

Every push and pull request is built and tested by `.github/workflows/ci.yml` on a hosted macOS runner: it generates the project, runs `KsefCoreTests`, `KsefWidgetTests` and `KsefAppTests`, compiles `KsefE2ETests` without running them, and runs `scripts/build-app.sh`. It does not run the KSeF TEST E2E tests and installs nothing.

`FetchE2ETests` (both sides of one invoice, income and expense) takes 4–8 minutes, and `SummaryProbeE2ETests` (a correcting and a EUR invoice, printing the metadata KSeF returns for them) about 6; TEST allows 20 metadata queries per hour, so run each at most twice an hour, and not from 27 to 31 December, when the year ledger needs one more window per side.

The fixtures in `widget/CoreTests/Fixtures/` are frozen outputs of the removed TypeScript implementation (see their README); the RSA signature must stay byte-identical to `xades-rsa.json`.

What was verified, and where:

- On the KSeF TEST environment: the XAdES login with an RSA and an EC self-signed certificate, and a full send, fetch and second run through the real `run()` (`KsefE2ETests`).
- Offline: all `KsefCoreTests` (ports of the 142 TypeScript tests plus the settings, schedule and status line), `KsefWidgetTests` and `KsefAppTests`; the RSA XAdES output is byte-identical to the TypeScript signer's.
- Not verified at all until the owner does it (first-run checklist): production login, the Keychain adapter and its prompt, the Documents prompt, notifications, the login item, the scheduler over a day, and the widget in the real widget host.

Building or testing registers the built app with LaunchServices; unregister it afterwards (`scripts/build-app.sh` does this for its own build):

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/widget/build/Build/Products/Release/KSeF.app"
```

See `AGENTS.md` for the project rules.
