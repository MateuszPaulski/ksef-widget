# Sourced by build-app.sh. install_app <bundle identifier> <built app> <installed app>
# Quits a running copy, replaces the installed app and reopens it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# lsappinfo asks LaunchServices by bundle identifier, so it finds the process wherever it was launched from.
app_running() {
  [[ -n $(lsappinfo find bundleid="$1" 2>/dev/null) ]]
}

install_app() {
  local id=$1 built=$2 installed=$3 i
  if app_running "$id"; then
    osascript -e "quit app id \"$id\"" 2>/dev/null
    for i in {1..100}; do app_running "$id" || break; sleep 0.1; done
    if app_running "$id"; then
      echo "error: $installed is still running 10 seconds after asking it to quit; quit it and run this again" >&2
      return 1
    fi
  fi
  mkdir -p ${installed:h} || return 1
  rm -rf "$installed" ${installed:h}/KsefWidget.app
  ditto "$built" "$installed" || return 1
  $LSREGISTER -u "$built"
  open "$installed" 2>/dev/null && return 0
  sleep 2
  open "$installed" && return 0
  echo "error: installed $installed but could not open it; open it yourself" >&2
  return 1
}
