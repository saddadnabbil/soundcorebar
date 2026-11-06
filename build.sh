#!/bin/bash
# Builds SoundcoreBar.app with the Command Line Tools (no Xcode needed).
#   ./build.sh            build for this Mac's architecture
#   ./build.sh universal  build for Apple Silicon and Intel (used for releases)
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SoundcoreBar.app
ARCHS=("$(uname -m)")
[ "${1:-}" = "universal" ] && ARCHS=(arm64 x86_64)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" build/obj
BINS=()
for arch in "${ARCHS[@]}"; do
    swiftc -O -parse-as-library -swift-version 5 \
        -target "$arch-apple-macos13.0" \
        -framework IOBluetooth -framework SwiftUI -framework AppKit \
        Sources/*.swift -o "build/obj/SoundcoreBar-$arch"
    BINS+=("build/obj/SoundcoreBar-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/SoundcoreBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/SoundcoreBar"))"
