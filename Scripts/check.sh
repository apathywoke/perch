#!/bin/bash
# Runs the unit tests and checks that the app contains no networking code.
# Works with Xcode or with only the Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")/.."

# With only the Command Line Tools, SwiftPM does not find Swift Testing on its own.
ARGS=()
DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *CommandLineTools* ]]; then
    FRAMEWORKS="$DEV/Library/Developer/Frameworks"
    LIBS="$DEV/Library/Developer/usr/lib"
    ARGS=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
          -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$LIBS")
fi

echo "▸ Unit tests"
swift test ${ARGS[@]+"${ARGS[@]}"} "$@"

echo "▸ Privacy check: no networking APIs in the app"
swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)/Perch"
HELPER="$(mktemp -d)/helper.dylib"
clang -dynamiclib -fobjc-arc -O2 -framework Foundation -framework AppKit -o "$HELPER" Helper/PerchMediaHelper.m
PATTERN='NSURLSession|NSURLConnection|_nw_|NWConnection|CFSocket|CFStream|_socket$|_connect$|_getaddrinfo|SCNetworkReachability|URLSession'
FOUND="$( { nm -u "$BIN"; nm -u "$HELPER"; } | grep -E "$PATTERN" || true)"
rm -rf "$(dirname "$HELPER")"
if [ -n "$FOUND" ]; then
    echo "✗ Networking symbols found:"
    echo "$FOUND"
    exit 1
fi
echo "✓ No networking symbols"

echo "▸ Privacy check: the network is reached only by the updater"
ELSEWHERE="$(grep -rlE '/usr/bin/curl|URLSession|NWConnection|CFSocket' Sources Helper | grep -v '^Sources/Perch/Updater.swift$' || true)"
if [ -n "$ELSEWHERE" ]; then
    echo "✗ Network access outside Sources/Perch/Updater.swift:"
    echo "$ELSEWHERE"
    exit 1
fi
echo "✓ Only Sources/Perch/Updater.swift talks to the network (github.com, when the user allows it)"
