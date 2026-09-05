#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Overseer.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
DMG="$ROOT/dist/Overseer-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

"$ROOT/scripts/build-app.sh" >/dev/null
cp -R "$APP" "$STAGE/Overseer.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Overseer -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "$DMG"
