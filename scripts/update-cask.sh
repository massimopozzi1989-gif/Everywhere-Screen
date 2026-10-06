#!/bin/bash
# Aggiorna il cask Homebrew (massimopozzi1989-gif/homebrew-tap) al DMG della release corrente.
# Da lanciare dopo scripts/release.sh e dopo aver pubblicato la release su GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="dist/EverywhereScreen-$VERSION.dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
TAP=build/homebrew-tap
rm -rf "$TAP"
git clone -q https://github.com/massimopozzi1989-gif/homebrew-tap.git "$TAP"
CASK="$TAP/Casks/everywhere-screen.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP" commit -qam "everywhere-screen $VERSION"
git -C "$TAP" push -q
echo "OK: cask everywhere-screen $VERSION ($SHA)"
