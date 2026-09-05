#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Overseer.app"
ICONSET="$ROOT/.build/Overseer.iconset"

command -v swift >/dev/null || { echo "missing swift — install the Apple Command Line Tools: xcode-select --install" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "missing rsvg-convert — brew install librsvg" >&2; exit 1; }

swift build -c release --package-path "$ROOT" --triple arm64-apple-macosx13.0
swift build -c release --package-path "$ROOT" --triple x86_64-apple-macosx13.0

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

lipo -create \
  "$ROOT/.build/arm64-apple-macosx/release/Overseer" \
  "$ROOT/.build/x86_64-apple-macosx/release/Overseer" \
  -output "$APP/Contents/MacOS/Overseer"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/assets/overseer-menu@2x.png" "$APP/Contents/Resources/overseer-menu@2x.png"

for spec in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'
do
  size="${spec%% *}"
  name="${spec#* }"
  # App icon uses the Big Sur plate (824/1024 rounded rect, r=185) baked into the SVG;
  # the canvas stays transparent like every other macOS icon. The bare mark remains the
  # menu bar template image.
  rsvg-convert -w "$size" -h "$size" \
    -o "$ICONSET/$name" "$ROOT/assets/overseer-appicon.svg"
done

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
