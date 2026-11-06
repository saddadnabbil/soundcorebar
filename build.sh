#!/bin/bash
# Builds SoundcoreBar.app with the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SoundcoreBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -framework IOBluetooth -framework SwiftUI -framework AppKit \
    Sources/*.swift -o "$APP/Contents/MacOS/SoundcoreBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $(pwd)/$APP"
