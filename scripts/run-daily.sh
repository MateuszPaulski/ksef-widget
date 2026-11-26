#!/bin/zsh
# launchd's target: runs the fetch with the given Node binary and shows a notification itself
# when Node could not even run (any exit code other than main.ts's own 0, 1 or 2).
# Usage: scripts/run-daily.sh <node-path>

cd "${0:A:h:h}" || exit 1
"$1" src/main.ts
code=$?

if (( code != 0 && code != 1 && code != 2 )); then
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' \
    'KSeF: zadanie nie zadziałało' \
    "Node zakończył się kodem $code. Sprawdź ~/Library/Logs/ksef-daily-fetch.log"
fi
exit $code
