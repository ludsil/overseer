#!/bin/bash
# Report subscription utilization for Claude profiles via the OAuth usage endpoint
# (same data as /usage in the interactive CLI).
#
# Usage: usage.sh               -> every profile on this machine (~/.claude, ~/.claude-*)
#        usage.sh <config_dir>  -> one profile
#
# Accounts MOVE between profile dirs at runtime (Overseer's "Make active" swaps logins),
# so every section is headed by the dir's CURRENT account, read live from its config.
set -uo pipefail

report() {
  DIR="${1/#\~/$HOME}"
  if [ "$DIR" = "$HOME/.claude" ]; then
    SVC="Claude Code-credentials"
    CFG="$HOME/.claude.json"
    ROLE=" · DEFAULT (plain claude / any tool without CLAUDE_CONFIG_DIR bills here)"
    REFRESH="claude -p 'Reply with exactly: OK' --model haiku"
  else
    SVC="Claude Code-credentials-$(printf '%s' "$DIR" | shasum -a 256 | cut -c1-8)"
    CFG="$DIR/.claude.json"
    ROLE=""
    REFRESH="CLAUDE_CONFIG_DIR=$DIR claude -p 'Reply with exactly: OK' --model haiku"
  fi
  EMAIL=$(python3 -c "import json;print(json.load(open('$CFG'))['oauthAccount']['emailAddress'])" 2>/dev/null || echo "no account recorded")
  echo "== $DIR · $EMAIL$ROLE"
  TOKEN=$(security find-generic-password -s "$SVC" -w 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  if [ -z "${TOKEN:-}" ]; then
    echo "   no stored login - mount an account on this slot (Overseer > Manage Claude accounts)"
    return 0
  fi
  BODY=$(mktemp)
  CODE=$(curl -sS -m 15 -o "$BODY" -w '%{http_code}' "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20") || CODE=000
  if [ "$CODE" != "200" ]; then
    echo "   HTTP $CODE - token likely stale. Refresh it with any tiny run on this profile:"
    echo "     $REFRESH"
    rm -f "$BODY"
    return 0
  fi
  python3 -c "
import json
d=json.load(open('$BODY'))
for l in d.get('limits',[]):
    name=((l.get('scope') or {}).get('model') or {}).get('display_name')
    label=l['kind']+(f' ({name})' if name else '')
    mark=' <- binding' if l.get('is_active') else ''
    print(f\"   {label:26s} {l['percent']:3d}%  {l['severity']:8s} resets {l.get('resets_at') or '-'}{mark}\")
"
  rm -f "$BODY"
}

if [ $# -ge 1 ]; then
  report "$1"
else
  for d in "$HOME/.claude" "$HOME"/.claude-*; do
    [ -d "$d" ] && report "$d"
  done
fi
