#!/bin/bash
# Rigenera le immagini del README da docs/images/*.html (serve Google Chrome).
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render() {   # nome larghezza altezza: versione italiana (nome.png) e inglese (nome-en.png)
  for lang in it en; do
    local out="$1.png"; [[ $lang == en ]] && out="$1-en.png"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
      --window-size="$2,$3" --screenshot="$PWD/docs/images/$out" "file://$PWD/docs/images/$1.html?lang=$lang" 2>/dev/null
    echo "OK: docs/images/$out"
  done
}
render hero 1280 640
render steps 1280 520
