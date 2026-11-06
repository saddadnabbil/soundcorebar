#!/bin/bash
# Offline parser tests (no Bluetooth). Builds Protocol.swift + Tests/parse.swift and runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/Protocol.swift Tests/parse/main.swift -o build/parse
build/parse
