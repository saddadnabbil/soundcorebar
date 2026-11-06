#!/bin/bash
# Builds a universal SoundcoreBar.app and packages it as build/SoundcoreBar-<version>.dmg
# (app + Applications shortcut, so users can drag it across).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
./build.sh universal

STAGE=build/dmg
DMG=build/SoundcoreBar-$VERSION.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/SoundcoreBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SoundcoreBar $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "dmg $(pwd)/$DMG"
shasum -a 256 "$DMG"
