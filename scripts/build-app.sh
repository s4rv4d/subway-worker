#!/usr/bin/env bash
# Builds "Subway Worker.app" into ./build and code-signs it.
#
# Signing matters here: macOS ties the Accessibility permission to the app's code
# signature. With an "Apple Development" certificate the permission survives rebuilds;
# with ad-hoc signing ("-") you'll have to re-grant it after every build.
#
#   CONFIG=debug scripts/build-app.sh            # debug build
#   SIGN_IDENTITY="-" scripts/build-app.sh       # force ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Subway Worker.app"

swift build -c "$CONFIG" --product SubwayWorker
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SubwayWorker" "$APP/Contents/MacOS/SubwayWorker"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -d Resources/Fonts ]]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Hardened runtime: blocks code injection (e.g. DYLD_INSERT_LIBRARIES) into an app that holds
# the Accessibility permission. WebKit and AVFoundation need no extra entitlements.
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP" >/dev/null
echo "Built $APP (signed with: $SIGN_IDENTITY)"
