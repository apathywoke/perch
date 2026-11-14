#!/bin/bash
# Packs Perch.app into a disk image: open it and drag Perch to Applications.
#   Scripts/make-dmg.sh                    uses dist/Perch.app (run ./build.sh first)
#   Scripts/make-dmg.sh path/to/Perch.app  any other build
# Writes release/Perch-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Perch.app}"
[ -d "$APP" ] || { echo "✗ $APP not found. Run ./build.sh first."; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="release/Perch-$VERSION.dmg"
mkdir -p release

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Perch.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $OUT"
rm -f "$OUT"
hdiutil create -volname "Perch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$OUT" >/dev/null

# Sign the image with the same certificate as the app, if it is available.
IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
    | awk -F'"' '/"Perch Local Signing"/ { split($1, a, " "); print a[2]; exit }')"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$OUT"
fi
hdiutil verify "$OUT" >/dev/null
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
