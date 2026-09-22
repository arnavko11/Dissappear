#!/bin/bash
# Builds both targets the way CI does, on this Mac.
#
# CI on a private repository is billed, and macOS runners at ten times the
# rate, so this is the cheaper way to find a compile error: it needs Xcode and
# nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/Scripts/fetch-idevice.sh"

build() {
    local scheme="$1" destination="$2"
    echo "=== ${scheme} ==="
    set -o pipefail
    xcodebuild \
        -project Dissappear.xcodeproj \
        -scheme "${scheme}" \
        -configuration Debug \
        -destination "${destination}" \
        -derivedDataPath build \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        build 2>&1 | tee "xcodebuild-${scheme}.log" | grep -E "error:|warning:|BUILD" || true

    if ! grep -q "BUILD SUCCEEDED" "xcodebuild-${scheme}.log"; then
        echo "${scheme} failed. Full log: xcodebuild-${scheme}.log" >&2
        exit 1
    fi
}

build DissappearCompanion "platform=macOS"
build Dissappear "generic/platform=iOS Simulator"
echo "Both targets built."
