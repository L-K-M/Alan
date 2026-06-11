# Alan — code review notes

A read-through of the whole app (it's pleasantly small), consolidated from
three overlapping review passes. Items that have since been implemented —
the Settings deep link, `register(defaults:)` colors, secure color
archiving, the `isDarkMode` rename, the status-bar item in hidden-Dock
mode, event-driven AX observing, and appearance-change recoloring (PRs
#4–#7) — have been removed; everything below is still open. The README
calls Alan "more software satire than useful utility", and these notes are
written in that spirit.

---

## Bugs & suspicious corners

### 1. Multi-monitor Y-flip uses `max(maxY)` across all screens (doc-only)
`cocoaRect(fromAXRect:)` flips AX coordinates using
`NSScreen.screens.map { $0.frame.maxY }.max()`. The documented AX/CG origin
is the **top-left of the primary screen** (`NSScreen.screens[0]`, whose
Cocoa frame origin is `(0,0)`), which makes `screens[0].frame.maxY` the
textbook flip constant. The two agree unless a display is arranged *above*
the primary one, in which case the border should be offset by that
display's height. Commit `558034d` says the current expression was arrived
at empirically to fix secondary-screen placement, so it stays — but if a
report ever comes in of the border floating one screen height away on a
stacked-monitor arrangement, this is why.

### 2. `NSColor.toHex` can't encode its own defaults
`toHex` reads `cgColor.components` directly and bails when there are fewer
than 3 — which is the case for the default colors (`NSColor.black`/`.white`
are grayscale: 2 components). Currently moot, since `toHex` and
`init(hex:)` are both dead code, but it's a landmine for whoever wires up
hex color prefs. Convert via `usingColorSpace(.sRGB)` first, or delete
both.

### 3. Force-casts in the AX plumbing
`focusedElement as! AXUIElement?` and `cfValue as! AXValue` in
`FocusHighlighter` would crash if an attribute ever came back as an
unexpected type, and AX is exactly the kind of API that returns surprises.
A `CFGetTypeID` check (already done for the frame value — nice) or a
conditional cast would make it crash-proof.

## General issues

- **Quit-and-relaunch permission flow, with a dialog pile-up.** On first
  launch without permission, three things happen at once: the system's own
  AX prompt, System Settings opening, and Alan's modal "quit" alert — then
  the app terminates. Friendlier: show the alert first, then open Settings,
  and poll `AXIsProcessTrusted()` on a timer so Alan springs to life the
  moment the box is ticked, no relaunch required.
- **`hideDock` has no UI and only applies at relaunch.** It's settable only
  via `defaults write`, and the activation policy is read once at launch. A
  Preferences checkbox that applies `setActivationPolicy` (and adds/removes
  the status item) live would fix both halves.
- **`userDefaultsChanged` redraws on *any* defaults change**, including
  keys Alan doesn't own, and it's only wired up once the prefs window has
  loaded. (The observer is also never removed — harmless, since the
  controller lives for the app's lifetime.)
- **Template menu bar.** `MainMenu.xib` still carries the full new-project
  template: Format, Font, Spelling, Substitutions, Speech… none of which do
  anything in an app with no text. Trimming it would cut the xib by ~80%.

## Missing features

- **Width/inset have no UI.** The drawing code clamps them to 1–20, but the
  prefs window only exposes the two colors; power users must `defaults
  write`. A live preview swatch showing the width/inset combination would
  make tuning pleasant.
- **Launch at login.** `SMAppService.mainApp.register()` plus a Preferences
  checkbox — an app like this lives or dies by being there after a reboot.
- **Pause/disable toggle.** A status-menu item or global hotkey to
  temporarily hide the border (screenshots, screen sharing, presentations)
  without quitting.
- **Windows straddling two displays.** A single overlay window can't span
  them cleanly.

## Ideas — novel, delightful, quirky

- **Focus pulse.** Flash or briefly thicken the border when focus
  *changes*, then settle — helps the app's whole reason to exist: noticing
  where keyboard input goes.
- **Per-app colors.** Hash the frontmost app's bundle ID into a hue (the AX
  element already knows its pid; `NSRunningApplication` gives the bundle
  ID). Terminal is always teal, Xcode always whatever it deserves — you
  learn the colors within a day.
- **Party mode** 🌈. Slowly cycle the border hue. Zero practical value,
  maximal joy, perfectly on-brand for a self-described satire app.
- **Spotlight mode.** Instead of a border, dim everything *except* the
  focused window (one translucent black window per screen with a cut-out
  path). The inverse-Alan.
- **"Find my window".** A global hotkey that flashes the border three
  times; spiritual cousin of shake-to-find-cursor.

---

*Consolidated from three review passes at commit `ebdaad7`, updated after
PRs #4–#7 landed. Implemented items are removed rather than kept around as
checklist trophies.*
