#!/bin/bash
# Build a signed local DMG without deleting builds or submitting anything to Apple.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: massimo pozzi (8ZN67F8SW8)}"
NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
EXEC=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' Info.plist)
mkdir -p build dist
STAGE=$(mktemp -d "$PWD/build/package.XXXXXX")
APP="$STAGE/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/CGVirtualDisplay.h -o "$APP/Contents/MacOS/$EXEC" Sources/*.swift
"$APP/Contents/MacOS/$EXEC" --render-icon "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/$NAME.app"
ln -s /Applications "$STAGE/image/Applications"
DMG="$PWD/dist/${NAME// /}-$VERSION.dmg"
if [[ -e "$DMG" ]]; then DMG="$PWD/dist/${NAME// /}-$VERSION-$(date +%Y%m%d-%H%M%S).dmg"; fi
hdiutil create -volname "$NAME" -srcfolder "$STAGE/image" -fs HFS+ -format UDZO "$DMG" >/dev/null
codesign --force --timestamp=none --sign "$IDENTITY" "$DMG"
hdiutil verify "$DMG"
codesign --verify --strict "$DMG"
echo "APP: $APP"
echo "DMG: $DMG"
