#!/bin/bash
# Builds the voice separation model that Perch downloads when the user turns on
# "Separate the voice" under "Time words by ear": Deezer's Spleeter 2stems
# (MIT licence) converted to Core ML by Scripts/convert-spleeter.py.
#
#   Scripts/make-vocal-model.sh [work folder]
#
# Fetches Python packages from PyPI (coremltools, numpy: ~20 MB) and the
# Spleeter checkpoint from GitHub (~75 MB) into the work folder, converts,
# checks Core ML against a numpy version of the networks, and writes
# dist/Spleeter2Stems-1.zip. Publish that file as a release asset and put its
# SHA-256 and size into Sources/Perch/VocalSeparator.swift.
#
# Core ML packages carry random identifiers, so each build has its own
# checksum: pin the one of the file you publish.
set -euo pipefail
cd "$(dirname "$0")/.."

SPLEETER_URL="https://github.com/deezer/spleeter/releases/download/v1.4.0/2stems.tar.gz"
SPLEETER_SHA256="f3a90b39dd2874269e8b05a48a86745df897b848c61f3958efc80a39152bd692"
NAME="Spleeter2Stems-1"

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
echo "▸ Working in $WORK"

if [ ! -x "$WORK/venv/bin/python" ]; then
    echo "▸ Python packages"
    python3 -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install --quiet --upgrade pip
    "$WORK/venv/bin/pip" install --quiet "coremltools==9.0" "numpy==2.0.2"
fi

if [ ! -f "$WORK/2stems.tar.gz" ]; then
    echo "▸ Spleeter 2stems checkpoint"
    curl --fail --silent --show-error --location --proto =https -o "$WORK/2stems.tar.gz" "$SPLEETER_URL"
fi
echo "$SPLEETER_SHA256  $WORK/2stems.tar.gz" | shasum -a 256 -c --quiet
rm -rf "$WORK/2stems" && mkdir -p "$WORK/2stems"
tar -xzf "$WORK/2stems.tar.gz" -C "$WORK/2stems"

echo "▸ Converting"
rm -rf "$WORK/Spleeter2Stems.mlpackage"
"$WORK/venv/bin/python" -I Scripts/convert-spleeter.py "$WORK/2stems" "$WORK/Spleeter2Stems.mlpackage" --verify

mkdir -p dist
rm -f "dist/$NAME.zip"
ditto -c -k --keepParent "$WORK/Spleeter2Stems.mlpackage" "dist/$NAME.zip"
echo "✓ dist/$NAME.zip"
echo "  SHA-256: $(shasum -a 256 "dist/$NAME.zip" | cut -d ' ' -f 1)"
echo "  Size:    $(stat -f %z "dist/$NAME.zip") bytes"
