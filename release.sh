#!/bin/zsh
# Build Brainless.app and package it as build/Brainless-<version>.dmg.
# The version comes from CFBundleShortVersionString in Info.plist.
#   ./release.sh            build the DMG only
#   ./release.sh --publish  also create GitHub release v<version> with the DMG attached (needs gh)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DMG="build/Brainless-$VERSION.dmg"

./build.sh

STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Brainless.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Brainless $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null

echo "dmg: $DMG"
shasum -a 256 "$DMG"

if [[ "${1:-}" == "--publish" ]]; then
  if git rev-parse "v$VERSION" >/dev/null 2>&1 || gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "v$VERSION already exists; bump CFBundleShortVersionString in Info.plist first" >&2
    exit 1
  fi
  gh release create "v$VERSION" "$DMG" --title "Brainless $VERSION" --generate-notes
fi
