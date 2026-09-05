# Making the app reachable when the menu bar icon isn't

On notched Macs, macOS can place a status item behind the camera housing, where it is
silently invisible: the app runs, the user sees nothing. This document records why that
happens, why the app cannot reliably detect it, and what Overseer does about it.

## Why the app can't just check

**`NSStatusItem.isVisible` is not a visibility check.** Apple documents that it stays
`true` when macOS suppresses an item for lack of space, and measurement shows it also
stays `true` behind the notch. Any code branching on it to decide "is the user seeing me"
is wrong.

`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (macOS 12+, `nil` when the
display has no camera housing) do give the unobscured menu bar rectangles, so comparing
the button's screen rect against them detects the notch case. Treat the result as
*geometrically suspicious*, never as proof: it cannot see space-suppression, the
"Allow in the Menu Bar" switch on newer macOS, or concealment by Ice/Bartender-style
managers.

## Placement depends on how crowded the bar is

The stored position is a hint, not an address. Measured on macOS 15.5: with one extra
menu bar app running, a requested position landed inside the camera housing and was
invisible; with one fewer, requested positions of 682, 700, 750 and 800 all clamped to
immediately right of the housing and were perfectly visible. The same preference produces
a working or a broken icon depending on what else is in the bar — a user cannot reason
about it, so the app must not depend on the icon.

There is no public API to request a position, reserve space, avoid the notch, or query
overflow. The `NSStatusItem Preferred Position Item-0` / `NSStatusItem Visible Item-0`
user defaults are AppKit implementation details, not contract: writing them can override
the user's own drag ordering, may not move a running item, and can break between
releases. `scripts/doctor.sh` writes that key deliberately as a **local repair tool**,
not as app behavior. Do not move that trick into the shipped app.

Apple's own `NSStatusBar` documentation says the menu bar has limited space, status items
are not always available, and apps must not depend on them being available.

## What Overseer does

- `applicationShouldHandleReopen` shows a real window, so reopening the app from Finder —
  the thing every user tries — recovers it.
- A first-run window confirms the app launched and names the notch/full-bar possibility.
- The window shows the same usage content as the popover and refreshes with it.
- `autosaveName` on the status item keeps its position stable.
- `Overseer --diagnose` prints `isVisible`, the assigned rect, screen geometry, the
  auxiliary areas and the stored position; the window's "Copy diagnostics" button copies
  the same report.
- The item stays compact (`squareLength`, template image, no long title) to reduce
  suppression.

Still open: a global hotkey and a URL scheme as additional entry points.

Sources: Apple docs for `NSStatusItem.isVisible`, `autosaveName`, `NSStatusBar`,
`NSScreen.auxiliaryTopLeftArea`, `applicationShouldHandleReopen`; Apple Support menu bar
guide.
