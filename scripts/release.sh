#!/bin/bash
# Prepara un rilascio: build firmata → notarizzazione dell'app → DMG firmato → notarizzazione del DMG.
#
#   scripts/release.sh            DMG firmato e notarizzato in dist/
#   scripts/release.sh --no-notarize   solo DMG firmato (per prove locali)
#
# Una tantum, per la notarizzazione (chiede la password specifica per app di appleid.apple.com):
#   xcrun notarytool store-credentials everywhere-notary --apple-id <email> --team-id 8ZN67F8SW8
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: massimo pozzi (8ZN67F8SW8)}"
PROFILE="${NOTARY_PROFILE:-everywhere-notary}"
APP="build/Everywhere Screen.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="dist/EverywhereScreen-$VERSION.dmg"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$2"
}

./build.sh

if (( NOTARIZE )); then
  echo "→ Notarizzazione dell'app…"
  ditto -c -k --keepParent "$APP" build/app.zip
  notarize build/app.zip "$APP"
fi

echo "→ Creazione DMG…"
mkdir -p dist
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
ditto "$APP" "build/dmg/Everywhere Screen.app"
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Everywhere Screen" -srcfolder build/dmg -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( NOTARIZE )); then
  echo "→ Notarizzazione del DMG…"
  notarize "$DMG" "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

echo "OK: $DMG"
