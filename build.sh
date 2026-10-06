#!/bin/bash
# Compila "Everywhere Screen.app" e la firma con Developer ID (hardened runtime).
#   ./build.sh           -> build/Everywhere Screen.app
#   ./build.sh install   -> copia anche in /Applications e la avvia
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: massimo pozzi (8ZN67F8SW8)}"
APP="build/Everywhere Screen.app"
BIN="$APP/Contents/MacOS/EverywhereScreen"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # testi di sistema in italiano e inglese

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/CGVirtualDisplay.h \
  -o "$BIN" Sources/*.swift

# Icona disegnata dall'app stessa.
"$BIN" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "OK: $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x EverywhereScreen 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/Everywhere Screen.app"
  ditto "$APP" "/Applications/Everywhere Screen.app"
  open "/Applications/Everywhere Screen.app"
  echo "Installata e avviata: /Applications/Everywhere Screen.app"
fi
