#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/Overseer.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/Overseer.app"

"$ROOT/scripts/build-app.sh" >/dev/null
pkill -x Overseer 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$SOURCE_APP" "$INSTALLED_APP"
open "$INSTALLED_APP"

echo "installed → $INSTALLED_APP"
