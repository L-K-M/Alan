# Alan — code review notes, round two

A second full read-through, done at v2.1 — after the settings expansion
(PRs #10–#15) and the ideas wave (#16–#19) — and thinned again after the
big roundup branch (preferences redesign with live preview, recordable
hotkey, dim-level slider, drag-and-drop exclusions, animated spotlight,
shake-to-find, launch at login, menu-bar trim, and the live-settings
fixes) implemented most of it. Implemented items are removed rather than
kept around as checklist trophies; what's below is still open.

---

## Bugs & suspicious corners

### 1. The border window can't straddle two displays
A window dragged halfway between monitors gets one `HighlightWindow`,
which belongs to a single screen for backing-scale purposes; at mixed
scale factors half the border renders at the wrong scale. Spotlight mode
already handles spanning correctly (per-screen dim windows, cut out on
every screen the window touches) — the border could borrow that design:
one border window per intersected screen, each clipped to its screen.
*(round one, narrowed: spotlight is done, the border isn't.)*

## General issues

- **`forceUpdate()` does an AX round-trip on every defaults change and
  appearance flip.** Cheap, and it's what makes toggles apply instantly —
  but a color-well drag fires it continuously. If it ever shows up in a
  profile, the fix is to re-evaluate only on the keys that affect
  placement.
- **Animations ignore Reduce Motion.** The focus pulse, party mode, the
  find-my-window flash, and now the animated spotlight all animate
  regardless of `NSWorkspace.accessibilityDisplayShouldReduceMotion`.
  Honoring it is a few guards.
- **`UserDefaults` reads are scattered.** Three classes read raw keys at
  draw time (30–60 times a second during drags and pulses). A small
  `Settings` facade would centralize the keys, the clamping, and the
  registration in one place.

## Missing features

- **`hideDock` still has no UI** and only applies at relaunch. A
  checkbox that calls `setActivationPolicy` (and adds/removes the status
  item) live would fix both halves. *(round one.)*
- **Pause/disable toggle.** A status-menu item or global hotkey to
  temporarily hide the border and dimming (screenshots, screen sharing,
  presentations) without quitting. The hotkey infrastructure makes a
  second shortcut cheap now. *(round one.)*
- **The status item only exists in hidden-Dock mode.** An "always show
  status item" option would give the pause toggle and Preferences a home
  without hiding the Dock icon.

## Ideas — novel, delightful, quirky

- **Marching ants.** An animated dash pattern (`setLineDash` with a
  cycling phase) as an alternative border style. The selection rectangle
  grew legs and found your window.
- **Hand-drawn mode.** Jitter the border path with a little noise,
  redrawn a few times a second — an xkcd-style wobble. The Comic Sans of
  window borders, and therefore perfect for this app.
- **Focus trail.** When focus moves, leave a ghost border on the
  previous window that fades over a second — you see where focus *came
  from*, not just where it went.
- **Per-app colors from the app icon.** Instead of hashing the bundle
  ID, sample the app icon's dominant color (`NSWorkspace` provides the
  icon). Terminal would be Terminal-black, Finder Finder-blue; the hash
  already taught users that color = app, this makes the colors *mean*
  something.

---

*Round two reviewed at v2.1 (`682cc72`), thinned after the roundup
branch. The committed `MARKETING_VERSION` staying current is now
`scripts/release.sh`'s job, so it left the list too.*
