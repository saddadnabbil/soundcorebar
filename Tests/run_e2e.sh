#!/bin/bash
# Builds the e2e harness from the app's real sources (minus the SwiftUI entry point) and runs it.
# Quits a running SoundcoreBar first so it does not hold the control channel.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -framework IOBluetooth -framework AppKit \
    Sources/Protocol.swift Sources/Link.swift Sources/Model.swift Sources/Log.swift Tests/main.swift -o build/e2e
pkill -x SoundcoreBar 2>/dev/null && sleep 1 || true
build/e2e
