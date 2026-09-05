#!/bin/bash
# Verify Overseer is installed, running, and that its menu bar item is not parked
# under the notch (macOS silently hides status items placed there).
# Safe to re-run; fixes what it finds.
#
# NOTE: the position key this writes is an AppKit implementation detail, not public API.
# That is acceptable for a local repair tool but must not become app behavior - see
# docs/menu-bar-visibility.md for the supported ways to stay reachable.
set -uo pipefail

BUNDLE_ID="com.ludsil.overseer"
POSITION_KEY="NSStatusItem Preferred Position Item-0"
SAFE_POSITION=200

fail=0

APP=""
for candidate in "/Applications/Overseer.app" "$HOME/Applications/Overseer.app"; do
  if [ -d "$candidate" ]; then APP="$candidate"; break; fi
done
if [ -z "$APP" ]; then
  echo "✗ not installed - drag Overseer.app from the DMG into Applications,"
  echo "  or build from source with ./install.sh"
  exit 1
fi
echo "✓ installed: $APP"

# May trigger a one-time macOS Automation permission prompt on first run.
width=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | awk -F', ' '{print $3}')
if [ -z "${width:-}" ]; then
  width=1470
  echo "• could not read the screen width (Automation permission?) - assuming ${width}pt; the notch check below may be off for this display"
fi

# The camera housing sits at the middle of the menu bar. macOS stores the item's
# preferred position as a distance from the right edge, so the unusable band is
# centred the same way.
notch_lo=$(( width / 2 - 90 ))
notch_hi=$(( width / 2 + 90 ))

position=$(defaults read "$BUNDLE_ID" "$POSITION_KEY" 2>/dev/null || echo "")
if [ -z "$position" ]; then
  echo "• no saved position - pinning to $SAFE_POSITION"
  defaults write "$BUNDLE_ID" "$POSITION_KEY" -int "$SAFE_POSITION"
  fail=1
elif [ "$position" -ge "$notch_lo" ] && [ "$position" -le "$notch_hi" ]; then
  echo "✗ position $position is inside the notch band ($notch_lo-$notch_hi) - repinning to $SAFE_POSITION"
  defaults write "$BUNDLE_ID" "$POSITION_KEY" -int "$SAFE_POSITION"
  fail=1
else
  echo "✓ menu bar position $position is clear of the notch ($notch_lo-$notch_hi)"
fi

if ! pgrep -x Overseer >/dev/null; then
  echo "✗ not running - launching"
  open "$APP"
  fail=1
elif [ "$fail" = "1" ]; then
  echo "• restarting so the new position takes effect"
  pkill -x Overseer; sleep 1; open "$APP"
fi

sleep 2
if pgrep -x Overseer >/dev/null; then
  echo "✓ running (pid $(pgrep -x Overseer))"
else
  echo "✗ failed to start"
  exit 1
fi

if osascript -e 'tell application "System Events" to get name of every login item' 2>/dev/null | grep -q Overseer; then
  echo "✓ starts at login"
else
  echo "• not a login item - add it in System Settings > General > Login Items"
fi
