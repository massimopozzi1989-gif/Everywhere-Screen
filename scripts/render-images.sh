#!/bin/bash
# Rigenera le immagini del README da docs/images/*.html (serve Google Chrome).
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render() {   # nome larghezza altezza
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size="$2,$3" --screenshot="$PWD/docs/images/$1.png" "file://$PWD/docs/images/$1.html" 2>/dev/null
  echo "OK: docs/images/$1.png"
}
render hero 1280 640
render steps 1280 520
