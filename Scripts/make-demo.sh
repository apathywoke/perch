#!/bin/bash
# Records the README images into docs/: the demo GIF and the Settings window,
# in English and Russian. The song in the demo is made up.
# Keep the screen unlocked while it runs: windows drawn on a locked screen come out blank.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O Scripts/make-gif.swift -o "$WORK/make-gif"
mkdir -p docs

for LANG_CODE in en ru; do
    echo "▸ Demo ($LANG_CODE)"
    dist/Perch.app/Contents/MacOS/Perch -AppleLanguages "($LANG_CODE)" --snapshot-demo "$WORK/demo-$LANG_CODE"
    "$WORK/make-gif" "$WORK/demo-$LANG_CODE" "docs/demo-$LANG_CODE.gif" 1 6
    dist/Perch.app/Contents/MacOS/Perch -AppleLanguages "($LANG_CODE)" --snapshot-settings "$WORK/settings-$LANG_CODE"
    cp "$WORK/settings-$LANG_CODE/appearance-dark.png" "docs/settings-$LANG_CODE.png"
done
sips -s format png -Z 256 Resources/AppIcon.icns --out docs/icon.png > /dev/null
echo "✓ docs/"
