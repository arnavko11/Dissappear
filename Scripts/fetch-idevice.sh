#!/bin/bash
# Fetches the prebuilt idevice static libraries the iOS app links against.
#
# idevice is the Rust client for Apple's iOS services. The iOS app uses it to
# open the developer location service on the phone it is running on, which is
# what lets a location be spoofed with no computer present.
#
# The library is ~190 MB per slice, so it is downloaded rather than committed,
# and Vendor/ is ignored by git. Run this once before building the iOS app.
set -euo pipefail

VERSION="${IDEVICE_VERSION:-v0.1.68}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor/idevice"
STAMP="$VENDOR/.version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "${VERSION}" ]; then
    echo "idevice ${VERSION} already present in Vendor/idevice"
    exit 0
fi

URL="https://github.com/jkcoxson/idevice/releases/download/${VERSION}/idevice-xcframework-${VERSION}.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading idevice ${VERSION}..."
curl -fsSL -o "$WORK/bundle.zip" "$URL"

echo "Extracting..."
unzip -q "$WORK/bundle.zip" -d "$WORK/x"

FRAMEWORK="$WORK/x/swift/IDevice.xcframework"
[ -d "$FRAMEWORK" ] || { echo "IDevice.xcframework missing from the archive" >&2; exit 1; }

rm -rf "$VENDOR"
mkdir -p "$VENDOR/include" "$VENDOR/ios-arm64" "$VENDOR/ios-simulator"

# Only the two iOS slices are kept; the macOS and Catalyst ones are unused
# here and together weigh more than twice as much.
#
# Each slice names its archive differently (libidevice_ffi.a for the device,
# idevice-ios-sim.a for the simulator), so whatever archive the slice holds is
# copied under the one name -lidevice_ffi expects, rather than assuming.
copy_slice() {
    local slice="$1" destination="$2" archive
    archive="$(find "$FRAMEWORK/$slice" -maxdepth 1 -name '*.a' | head -1)"
    if [ -z "$archive" ]; then
        echo "No static library in $slice" >&2
        exit 1
    fi
    cp "$archive" "$destination/libidevice_ffi.a"
}

copy_slice "ios-arm64" "$VENDOR/ios-arm64"
copy_slice "ios-arm64_x86_64-simulator" "$VENDOR/ios-simulator"
cp "$FRAMEWORK/ios-arm64/Headers/"*.h "$VENDOR/include/"

echo "${VERSION}" > "$STAMP"
echo "idevice ${VERSION} ready in Vendor/idevice"
