#!/bin/zsh
# launchd's target: runs the fetch with the given Node binary and shows a notification itself
# when main.ts did not get to handle the run (any exit code other than its own 0, 2 or 3).
# Usage: scripts/run-daily.sh <node-path>

cd "${0:A:h:h}" || exit 1
"$1" src/main.ts
code=$?

if (( code != 0 && code != 2 && code != 3 )); then
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' \
    'KSeF: zadanie nie zadziałało' \
    "Program nie uruchomił się albo zakończył się awarią (kod $code). Sprawdź ~/Library/Logs/ksef-daily-fetch.log"
fi
exit $code
