# ksef-daily-fetch

## What it does

The owner is a Polish sole proprietor whose purchase invoices now arrive through KSeF (Krajowy System e-Faktur, API 2.0) instead of e-mail. Nobody announces a new invoice there, and the legal date of receipt is the date KSeF assigns its number. Once a day this tool authenticates with a KSeF certificate, pulls every purchase invoice that is new since the last run, and saves each original XML byte for byte under `data/`. It uses the KSeF metadata query with a high-water mark checkpoint and downloads invoices one by one, so nothing is lost and nothing is fetched twice.

After a run that found something, the owner gets one macOS notification, for example `KSeF: 2 nowe faktury` with a body like `Acme Sp. z o.o.: 1 230,00 PLN; Beta S.A.: 53,63 EUR`, and a section appended to `data/reports/YYYY-MM-DD.md`: for each invoice the seller, NIP, invoice number, gross amount with currency, issue date, a link to view it in KSeF and the KSeF number. A run with nothing new is silent. A partial or failed run always notifies with the reason and appends it to the day's report, so a failure is never silent. Design: `docs/superpowers/specs/2026-11-26-ksef-daily-fetch-design.md`; decisions: `ADR.md`.

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

Files land in `data/invoices/YYYY/MM/<ksefNumber>.xml`, `data/reports/YYYY-MM-DD.md`, `data/index.jsonl` (one line per saved invoice) and `data/state.json` (checkpoint). Exit codes: 0 complete, 2 partial, 3 failed (handled by `main.ts`, which has notified), 1 usage error or Node crashed before `main` ran (the wrapper script notifies). KSeF allows 64 single-invoice downloads per hour, so a run saves at most 60. If a large backfill ends with `Limit 60 pobrań na jedno uruchomienie.`, run it again after an hour.

## Install the daily job

```sh
scripts/launchagent.sh install
```

Run `pnpm install --frozen-lockfile` in the checkout the LaunchAgent will run from before `install`, and never install the agent from a `.claude/worktrees/…` path: the plist records the absolute path of the checkout it was generated in.

The job runs daily at 08:00, or when the Mac wakes if it slept through 08:00; it does not run while the Mac is off. Logs: `~/Library/Logs/ksef-daily-fetch.log`. Run it now with `launchctl kickstart gui/$(id -u)/local.ksef-daily-fetch`. Remove it with `scripts/launchagent.sh uninstall`. Re-run `install` after a Node upgrade that changes the output of `command -v node`; if Node has vanished or the program cannot start (for example `node_modules` is missing), the wrapper script still shows a notification.

## Troubleshooting

- A corrupt line in `data/index.jsonl` fails the run loudly. The XML stays on disk; delete or fix that line and the next run downloads the invoice again.
- `Token dostępu wkrótce wygaśnie.`: the run ended early because the access token was about to expire; the next run continues.
- A failed run always notifies and appends a `BŁĄD` section to the day's report.

## Development

```sh
pnpm test            # offline unit tests
pnpm typecheck
pnpm test:e2e:auth   # XAdES authentication against KSeF TEST
pnpm test:e2e        # full fetch against KSeF TEST (not 16:00-18:00 Warsaw time)
```

See `AGENTS.md` for the project rules.
