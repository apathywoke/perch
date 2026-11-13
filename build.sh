#!/bin/bash
# Builds dist/Perch.app. Needs only the Xcode Command Line Tools.
#   ./build.sh            build
#   ./build.sh --run      build and launch
#   ./build.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.1.0"
APP="dist/Perch.app"

echo "▸ Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Perch"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Perch"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"
cp Helper/perch-media-helper.pl "$APP/Contents/Resources/"

if [ ! -f Resources/AppIcon.icns ]; then
    echo "▸ Drawing the icon"
    TMP="$(mktemp -d)"
    swift Scripts/make-icon.swift "$TMP/AppIcon.iconset"
    iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
    rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

echo "▸ Building the media helper"
clang -dynamiclib -fobjc-arc -O2 -Wall -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit \
    -o "$APP/Contents/Frameworks/PerchMediaHelper.dylib" Helper/PerchMediaHelper.m

# A local self-signed certificate keeps the code identity stable between builds,
# so macOS remembers the Accessibility permission. Without one, sign ad hoc.
# Set PERCH_SIGN_IDENTITY to use another certificate.
IDENTITY="${PERCH_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
        | awk -F'"' '/"Perch Local Signing"/ { split($1, a, " "); print a[2]; exit }')"
fi
if [ -n "$IDENTITY" ]; then
    echo "▸ Signing with $IDENTITY"
else
    IDENTITY="-"
    echo "▸ Signing (ad hoc: macOS forgets permissions after each build)"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/PerchMediaHelper.dylib"
codesign --force --sign "$IDENTITY" "$APP"

echo "✓ $APP"
case "${1:-}" in
    --run) open "$APP" ;;
    --install)
        pkill -x Perch 2>/dev/null || true
        rm -rf /Applications/Perch.app
        cp -R "$APP" /Applications/
        open /Applications/Perch.app
        echo "✓ Installed to /Applications" ;;
esac
