#!/bin/bash
# Run a Claude CLI worker on a specific ACCOUNT — not a directory.
#
# Accounts move between profile dirs at runtime (Overseer "Make active" swaps logins),
# so any dir chosen from a minutes-old reading can be the wrong sub by dispatch time.
# This wrapper closes the race: it resolves the account's CURRENT dir from each profile's
# own config (rewritten by the swap), and execs the worker in the same breath. Once the
# process starts it keeps the credentials it started with — a later swap can't move it.
#
# Usage:
#   run-on.sh <account-email> [claude args...]     # e.g. run-on.sh you@example.com -p "..." --model fable
#   run-on.sh @freshest      [claude args...]      # lowest session %, ties by weekly_all
#
# Exit codes:
#   0   worker ran and produced real output
#   42  worker was REFUSED (session/usage limit or not logged in) — the CLI exits 0 in
#       this case with the error as its only stdout, so callers must not trust exit
#       codes alone; this wrapper does the content check so orchestrators don't have to
#   64  account not found on any profile dir / no usable profile for @freshest
#
# Routing is reported on stderr; worker stdout passes through untouched.
set -uo pipefail

ACCOUNT="${1:-}"
if [ -z "$ACCOUNT" ]; then
  echo "usage: run-on.sh <account-email|@freshest> [claude args...]" >&2
  exit 64
fi
shift

config_of() { # dir -> its .claude.json path (default dir keeps config at $HOME level)
  if [ "$1" = "$HOME/.claude" ]; then echo "$HOME/.claude.json"; else echo "$1/.claude.json"; fi
}

email_of() {
  python3 -c "import json;print(json.load(open('$(config_of "$1")'))['oauthAccount']['emailAddress'])" 2>/dev/null
}

session_pct_of() { # dir -> "sessionPct weeklyPct" via the OAuth usage endpoint, or nothing
  local svc token
  if [ "$1" = "$HOME/.claude" ]; then
    svc="Claude Code-credentials"
  else
    svc="Claude Code-credentials-$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
  fi
  token=$(security find-generic-password -s "$svc" -w 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  [ -n "${token:-}" ] || return 1
  curl -sS -m 15 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=w=None
for l in d.get('limits',[]):
    if l['kind']=='session': s=l['percent']
    if l['kind']=='weekly_all': w=l['percent']
print(f'{s if s is not None else 999} {w if w is not None else 999}')" 2>/dev/null
}

DIR=""
if [ "$ACCOUNT" = "@freshest" ]; then
  BEST_S=1000 BEST_W=1000
  for d in "$HOME/.claude" "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    read -r S W <<<"$(session_pct_of "$d")" || continue
    [ -n "${S:-}" ] || continue
    if [ "$S" -lt "$BEST_S" ] || { [ "$S" -eq "$BEST_S" ] && [ "$W" -lt "$BEST_W" ]; }; then
      BEST_S=$S; BEST_W=$W; DIR=$d
    fi
  done
  [ -n "$DIR" ] || { echo "run-on: no profile answered the usage endpoint" >&2; exit 64; }
  ACCOUNT=$(email_of "$DIR")
  echo "run-on: @freshest -> $ACCOUNT on $DIR (session ${BEST_S}%, weekly ${BEST_W}%)" >&2
else
  for d in "$HOME/.claude" "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    [ "$(email_of "$d")" = "$ACCOUNT" ] && { DIR=$d; break; }
  done
  [ -n "$DIR" ] || { echo "run-on: no profile dir currently holds $ACCOUNT" >&2; exit 64; }
  echo "run-on: $ACCOUNT -> $DIR" >&2
fi

# Re-verify at the last instant, then exec immediately (the whole point of this script).
[ "$(email_of "$DIR")" = "$ACCOUNT" ] || { echo "run-on: $DIR rotated away from $ACCOUNT mid-dispatch; rerun" >&2; exit 64; }

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
if [ "$DIR" = "$HOME/.claude" ]; then
  # NEVER set CLAUDE_CONFIG_DIR to the default dir — it forks the profile's identity
  # onto a hash-suffixed Keychain item (lost a login on 2026-08-16).
  claude "$@" | tee "$OUT"
else
  CLAUDE_CONFIG_DIR="$DIR" claude "$@" | tee "$OUT"
fi
STATUS=${PIPESTATUS[0]}

# The CLI exits 0 when a worker dies on a limit, with the refusal as its only output.
if [ "$(wc -c <"$OUT")" -lt 600 ] \
  && grep -qE "You('|’)ve (hit|reached) your .*limit|Not logged in|usage limit" "$OUT"; then
  echo "run-on: REFUSED on $DIR ($ACCOUNT) — limit or login; route elsewhere or wait for the printed reset" >&2
  exit 42
fi
exit "$STATUS"
