#!/bin/zsh
# Builds KSeF.app ad hoc, optionally re-signs it with a signing identity, verifies it and optionally installs it.
# The identity is never stored: pass its full name or SHA-1 as shown by `security find-identity -v -p codesigning`.
# Usage: scripts/build-app.sh [--install] [signing-identity]

REPO=${0:A:h:h}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALL=0
IDENTITY=

for arg in "$@"; do
  if [[ $arg == --install ]]; then
    INSTALL=1
  elif [[ $arg != -* && -z $IDENTITY ]]; then
    IDENTITY=$arg
  else
    echo "usage: scripts/build-app.sh [--install] [signing-identity]" >&2
    exit 1
  fi
done

cd $REPO || exit 1
APP=$REPO/widget/build/Build/Products/Release/KSeF.app
EXTENSION=$APP/Contents/PlugIns/KsefWidgetExtension.appex

# Fails unless the bundle has the hardened runtime and no get-task-allow entitlement.
check_hardened() {
  codesign -d --verbose=2 "$1" 2>&1 | grep -q 'flags=.*runtime' \
    || { echo "error: $1 is not signed with the hardened runtime" >&2; return 1; }
  codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -q com.apple.security.get-task-allow \
    && { echo "error: $1 has the com.apple.security.get-task-allow entitlement" >&2; return 1; }
  return 0
}

xcodegen generate --spec widget/project.yml --project widget || exit 1
# Clean: an incremental build can keep a stale, unhardened extension inside the app.
xcodebuild -project widget/KsefWidget.xcodeproj -scheme KsefWidget -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath widget/build -quiet clean build || exit 1

if [[ -n $IDENTITY ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --entitlements widget/Extension/Extension.entitlements "$EXTENSION" || exit 1
  codesign --force --sign "$IDENTITY" --options runtime "$APP" || exit 1
fi

codesign --verify --deep --strict "$APP" || exit 1
check_hardened "$APP" || exit 1
check_hardened "$EXTENSION" || exit 1
echo "hardened runtime present and no get-task-allow in the app and the extension"
echo "signature verified; designated requirement (cdhash = ad hoc, certificate leaf[subject.OU] = Developer ID):"
codesign -dr - "$APP" 2>&1 | grep designated

if (( INSTALL )); then
  osascript -e 'quit app id "local.ksef-daily-fetch.KsefWidget"' 2>/dev/null
  mkdir -p ~/Applications || exit 1
  rm -rf ~/Applications/KSeF.app ~/Applications/KsefWidget.app
  ditto "$APP" ~/Applications/KSeF.app || exit 1
  $LSREGISTER -u "$APP"
  open ~/Applications/KSeF.app
else
  $LSREGISTER -u "$APP"
  echo "built $APP (not installed); run scripts/build-app.sh --install to install it into ~/Applications"
fi
