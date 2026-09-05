#!/bin/bash
# Sync the version-controlled skill (this directory) to the live location Claude Code
# loads it from. The repo is the source of truth; ~/.claude/skills/overseer is a copy
# and is replaced wholesale so removed or renamed files do not linger. The only file
# that survives a sync is local.md — machine-local notes that never come from the repo.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/overseer"
KEEP=""
if [ -f "$DEST/local.md" ]; then
  KEEP="$(mktemp)"
  cp "$DEST/local.md" "$KEEP"
fi
rm -rf "$DEST"
mkdir -p "$DEST/scripts"
cp "$SRC/SKILL.md" "$SRC/internals.md" "$DEST/"
cp "$SRC"/scripts/*.sh "$DEST/scripts/"
chmod +x "$DEST"/scripts/*.sh
if [ -n "$KEEP" ]; then
  cp "$KEEP" "$DEST/local.md"
  rm -f "$KEEP"
fi
echo "synced skill -> $DEST"
