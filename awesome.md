# Alan — code review notes, round two

A second full read-through, done at v2.1 — after the settings expansion
(PRs #10–#15) and the ideas wave (#16–#19). Everything implemented from
the first review has been removed, including items that round two fixes
in companion PRs (the hotkey-handler leak, the AX force-casts, the dead
hex helpers, the quit-and-relaunch permission flow, and party mode). The
first review's only surviving entries are the ones below marked *(round
one)*. The README still calls Alan software satire; these notes still
take that as a compliment.

---

## Bugs & suspicious corners

### 1. Live settings only apply once Preferences has been opened
`userDefaultsChanged` → `forceUpdate()` is wired up in
`PrefsWindowController.windowDidLoad`, so until the prefs window has been
shown once, a `defaults write` from Terminal doesn't trigger
re-evaluation — most settings silently wait for the next focus change,
and `findMyWindowHotkey` isn't registered until relaunch. Moving the
observer (or a KVO-based one per key) into `FocusHighlighter.start()`
would make the app honor external writes immediately. *(round one,
sharpened: the hotkey made it worse.)*

### 2. The border window can't straddle two displays
A window dragged halfway between monitors gets one `HighlightWindow`,
which belongs to a single screen for backing-scale purposes; at mixed
scale factors half the border renders at the wrong scale. Spotlight mode
already handles spanning correctly (per-screen dim windows, cut out on
every screen the window touches) — the border could borrow that design:
one border window per intersected screen, each clipped to its screen.
*(round one, narrowed: spotlight is done, the border isn't.)*

### 3. The focus-pulse checkbox silently does nothing in spotlight mode
By design (there's no border to pulse), but nothing in the UI says so.
Disabling the checkbox while spotlight is on — or pulsing the dim alpha
instead — would make the preference honest.

### 4. `showFrameWhileDragging` is the odd one out
Every other bool is registered in `register(defaults:)` and read with
`bool(forKey:)`; this one is unregistered and read twice via
`object(forKey:) as? Bool ?? true` (in `FocusHighlighter` and in
`PrefsWindowController`). Registering `true` and simplifying both reads
would remove the duplication. (Same commits also left a few stray
semicolons in `refresh()`.)

## General issues

- **The Preferences window is a wall of checkboxes.** Ten rows plus the
  excluded-apps table, 610 pt tall and growing with every feature.
  Grouping into sections (Appearance / Behavior / Apps) — or an
  `NSTabView`, or a sidebar à la System Settings — is overdue. A small
  `Settings` facade type would also centralize the `UserDefaults` reads
  that are currently sprinkled through three classes (some of them at
  draw time, 30–60 times a second during drags and pulses).
- **`forceUpdate()` now does an AX round-trip on every defaults change
  and appearance flip.** Cheap, and it's what makes toggles apply
  instantly — but a color-well drag fires it continuously. If it ever
  shows up in a profile, the fix is to re-evaluate only on the keys that
  affect placement.
- **Template menu bar.** `MainMenu.xib` is still the stock new-project
  menu: 239 items including Format, Font, Spelling, Substitutions,
  Speech, and Find — none of which do anything in an app with no text.
  Trimming it would cut the xib by ~80%. *(round one.)*
- **Animations ignore Reduce Motion.** The focus pulse, party mode, and
  the find-my-window flash all animate regardless of
  `NSWorkspace.accessibilityDisplayShouldReduceMotion`. Honoring it is a
  few guards.
- **`MARKETING_VERSION` in the project is still 1.0.** Releases stamp
  the real version at build time, so only local builds claim 1.0 in
  their About box. One-line fix per configuration whenever it bothers
  someone.

## Missing features

- **`hideDock` still has no UI** and only applies at relaunch. A
  checkbox that calls `setActivationPolicy` (and adds/removes the status
  item) live would fix both halves. *(round one.)*
- **Launch at login.** `SMAppService.mainApp.register()` plus a
  checkbox — an app like this lives or dies by being there after a
  reboot. *(round one.)*
- **Pause/disable toggle.** A status-menu item or global hotkey to
  temporarily hide the border and dimming (screenshots, screen sharing,
  presentations) without quitting. The find-my-window hotkey
  infrastructure makes a second hotkey cheap now. *(round one.)*
- **The find-my-window hotkey is hardcoded** to ⌃⌥⌘F. A recordable
  shortcut field (or at least a `defaults`-settable key code) would
  avoid collisions with whatever the user already runs.
- **Spotlight dim level is fixed at 45%.** A slider next to the
  spotlight checkbox is the obvious follow-up.
- **Live preview swatch in Preferences.** Width, inset, radius, glow,
  shadow, pulse — there are enough knobs now that a small sample
  rendering in the prefs window would beat trial-and-error against real
  windows. *(round one, re-scoped.)*
- **The status item only exists in hidden-Dock mode.** An "always show
  status item" option would give the pause toggle and Preferences a home
  without hiding the Dock icon.
- **Drag-and-drop onto the excluded-apps list.** The table currently
  only grows through the open panel; dropping an app from Finder or the
  Dock onto it is the expected interaction.

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
  icon). Terminal would be Terminal-black, Finder Finder-blue;
  the hash already taught users that color = app, this makes the colors
  *mean* something.
- **Animated spotlight.** Lerp the cut-out from the old window frame to
  the new one over ~150 ms instead of teleporting it. Spotlight mode
  would feel like a stage light swinging across the screen.
- **Mouse-shake to find.** The global mouse monitor is already there;
  detect a rapid left-right scrub and trigger the same triple flash as
  the hotkey. Spiritual sibling of macOS's shake-to-enlarge-cursor.

---

*Round two reviewed at v2.1 (`682cc72`). Implemented items are removed
rather than kept around as checklist trophies — round one's list went
from seventeen entries to four survivors, which is the best fate a
review document can hope for.*
