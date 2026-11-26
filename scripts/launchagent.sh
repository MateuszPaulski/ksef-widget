#!/bin/zsh
# Generates, installs or removes the daily LaunchAgent.
# Usage: scripts/launchagent.sh print | install | uninstall

LABEL=local.ksef-daily-fetch
REPO=${0:A:h:h}
PLIST=~/Library/LaunchAgents/$LABEL.plist
LOG=~/Library/Logs/ksef-daily-fetch.log
DOMAIN=gui/$(id -u)

require_node() {
  NODE=$(command -v node)
  if [[ -z $NODE ]]; then
    echo "node not found in PATH; the LaunchAgent needs its absolute path" >&2
    exit 1
  fi
}

print_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$REPO/scripts/run-daily.sh</string>
    <string>$NODE</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>8</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF
}

case ${1:-} in
  print)
    require_node
    print_plist
    ;;
  install)
    require_node
    mkdir -p ~/Library/LaunchAgents ~/Library/Logs
    print_plist > "$PLIST"
    plutil -lint "$PLIST" || exit 1
    launchctl bootout $DOMAIN/$LABEL 2>/dev/null || true
    launchctl bootstrap $DOMAIN "$PLIST" || exit 1
    echo "Installed $LABEL: runs daily at 08:00."
    echo "Run it now: launchctl kickstart $DOMAIN/$LABEL"
    echo "Log: $LOG"
    ;;
  uninstall)
    launchctl bootout $DOMAIN/$LABEL || true
    rm -f "$PLIST"
    ;;
  *)
    echo "Usage: scripts/launchagent.sh print | install | uninstall" >&2
    exit 1
    ;;
esac
