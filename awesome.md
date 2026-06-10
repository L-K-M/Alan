# awesome.md — Alan code review

A full review of Alan's six Swift files. The README calls the app "more software satire
than useful utility", which is exactly why it deserves a loving review. Entries marked
**✅ implemented** have a companion PR; everything else is documented here.
# Alan Code Review — Findings & Ideas

A review of Alan (the active-window border, and acknowledged software satire).
Bugs, general issues, missing features, and some ideas in the spirit of the
project. Items marked **[implementing]** are being addressed in a follow-up
PR; the rest are documented for future consideration.

> Follow-up PR: **#2**.

---

## Bugs

### 1. Permission flow opens the wrong System Settings pane ✅ implemented in PR #5
`AppDelegate.requestAccessibilityPermissionIfNeeded()` opens
`x-apple.systempreferences:com.apple.preference.universalaccess` — that's the
**Accessibility features** pane (VoiceOver, Zoom, …), not
**Privacy & Security ▸ Accessibility**, which is where the user actually has to enable
Alan. The alert text says one thing; the deep link goes somewhere else. The correct URL
is `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.

### 2. `register(defaults:)` is fed raw `NSColor` objects ✅ implemented in PR #5
`UserDefaults.register(defaults:)` only accepts property-list values (strings, numbers,
data, dates, arrays, dicts). `Key.lightMode`/`Key.darkMode` are registered as `NSColor`
objects, which is not a plist type — the registration of those two keys is ineffective
(and inconsistent with `color(forKey:)`, which expects archived `Data`). The app only
works because every read site has its own `?? Defaults.…Color` fallback. Register
archived `Data` (or nothing) instead.

### 3. Border color doesn’t react to light/dark mode switches ✅ implemented in PR #5
`HighlightView.draw` picks the color from `NSAppearance.isLightMode` at draw time, but
nothing triggers a redraw when the system appearance changes. After switching themes,
the border keeps the old mode's color until the focused window moves or focus changes.
AppKit has a purpose-built hook: override `viewDidChangeEffectiveAppearance()` and mark
the view dirty.

### 4. Deprecated, non-secure color archiving ✅ implemented in PR #5
`UserDefaults.setColor`/`color(forKey:)` use `NSKeyedArchiver.archivedData(withRootObject:)`
and `NSKeyedUnarchiver.unarchiveObject(with:)`, both deprecated since macOS 10.13/10.14
and bypassing secure coding. `NSColor` conforms to `NSSecureCoding`; the modern
`archivedData(withRootObject:requiringSecureCoding:)` /
`unarchivedObject(ofClass:from:)` pair is a drop-in replacement.

### 5. Wide borders get clipped at the window edge
`HighlightWindow.updateFrame` pads the borderless window by a fixed `-2` points, and
`HighlightView.draw` strokes a path inset by the `inset` preference. Strokes are centered
on the path, so half of `width` extends outward; with `width/2 > inset + 2` (e.g.
width 20, inset 1 — both within the allowed 1…20 ranges) the outer half of the border is
clipped flat by the window edge. The window padding should be derived from the
configured width and inset rather than hard-coded.

### 6. Multi-monitor Y-flip uses `max(maxY)` across all screens — suspicious
`cocoaRect(fromAXRect:)` flips AX coordinates using
`NSScreen.screens.map { $0.frame.maxY }.max()`. The documented AX/CG coordinate system
has its origin at the **top-left of the primary screen** (`NSScreen.screens[0]`), which
makes `screens[0].frame.maxY` the textbook flip constant. The two agree unless some
display extends above the primary one — where, per the docs, `max()` should be wrong.
However, commit `558034d` says this exact expression was arrived at *empirically* to fix
secondary-screen placement, so it is flagged here rather than changed: worth re-testing
with a display arranged above the primary, and worth a comment documenting which
arrangements were verified.

### 7. `toHex` mishandles grayscale and catalog colors
`NSColor.toHex` reads `cgColor.components` directly. System grays (including the default
`NSColor.black`/`.white`!) have 2 components (white, alpha), so the guard fails and the
method returns `nil`; catalog colors can throw worse surprises. It should convert via
`usingColorSpace(.sRGB)` first. Currently moot — both `toHex` and `init(hex:)` are dead
code — but it's a landmine for whoever wires up hex color prefs.

### 8. Force-casts in the AX plumbing
`focusedElement as! AXUIElement?` and `cfValue as! AXValue` in `FocusHighlighter` will
crash the app if the attribute ever comes back as an unexpected type. AX is exactly the
kind of API that returns surprises; a `CFGetTypeID` check (already done for the frame
value — nice) or conditional cast would make the poller crash-proof.
### B1. Accessibility prompt opens the wrong Settings pane **[implementing]**
`AppDelegate.requestAccessibilityPermissionIfNeeded()` opens
`x-apple.systempreferences:com.apple.preference.universalaccess`, which is the
*Accessibility* (display/zoom/VoiceOver) settings — not where the permission
lives. The permission is under **Privacy & Security → Accessibility**:
`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
So the alert tells the user to go one place while the app opens another.

### B2. `register(defaults:)` is fed `NSColor` objects **[implementing]**
`UserDefaults.register(defaults:)` only accepts property-list values; raw
`NSColor` objects aren't plist types. The registration for `Key.lightMode` /
`Key.darkMode` is invalid — it only *appears* to work because every read goes
through `color(forKey:)` → `data(forKey:)` which fails and falls back to the
`?? Defaults.…` defaults. Either register archived `Data` or don't register
colors at all (the read-side fallbacks already cover it).

### B3. Theme switches don't recolor the border **[implementing]**
The border only redraws when the focused window's frame changes (or any
UserDefaults value changes). Switching macOS between light and dark mode
leaves the old color on screen until you move a window. Observing the
distributed `AppleInterfaceThemeChangedNotification` and forcing a redraw
fixes it.

### B4. Deprecated, insecure archiving APIs **[implementing]**
`Extensions.swift` uses `NSKeyedArchiver.archivedData(withRootObject:)` and
`NSKeyedUnarchiver.unarchiveObject(with:)`, both deprecated since macOS 10.13/
10.14 (the latter is also the "insecure" variant). The modern secure-coding
equivalents are drop-in replacements for `NSColor`.

### B5. Hidden-Dock mode is a roach motel
With `hideDock` set, the app calls `setActivationPolicy(.accessory)` — no Dock
icon *and* no menu bar. There is then no way to open Preferences or quit Alan
short of `killall Alan`. An accessory app needs a status-bar item (see F1).
Also worth noting: `hideDock` has **no UI anywhere** — it's settable only via
`defaults write`. A checkbox in Preferences should toggle it live.

### B6. Multi-display Y-flip uses the wrong reference screen
`cocoaRect(fromAXRect:)` flips Y using `max(maxY)` across all screens. The AX
coordinate space has its origin at the **top-left of the primary screen**
(`NSScreen.screens[0]`, whose Cocoa frame origin is (0,0)), so the correct
flip constant is `NSScreen.screens[0].frame.maxY`. The two agree unless a
display is arranged *above* the primary, in which case every border is offset
upward by the height of that display. Noting rather than changing it: commit
`558034d` says the current calculation was arrived at experimentally, and I
can't test display arrangements from here — but the screens-above-primary case
is worth a look next time that Mac has two monitors.

### B7. Thick borders clip at the window edge
`HighlightWindow.updateFrame` expands the window by a fixed 2 pt, but the
stroke is centered on a path inset by the user's `inset` (1–20) with a width
up to 20. Whenever `width / 2 > inset + 2`, the outer half of the stroke is
clipped by the window bounds (e.g. inset 1, width 20 loses 7 pt). Expanding
the window by `width/2 - inset` (when positive) — or clamping in the prefs UI
— would keep fat borders intact.

---

## General issues

1. **10 Hz polling** — `FocusHighlighter` polls the focused window frame every 100 ms,
   forever, even when nothing changes. The grown-up approach is an `AXObserver` per
   frontmost app subscribed to `kAXFocusedWindowChanged`/`kAXMoved`/`kAXResized` plus
   `NSWorkspace.didActivateApplicationNotification` to re-attach. (The code comment
   "Hello, darkness, my old friend" suggests the author knows. The timer is honest
   work; the README's satire disclaimer covers the rest.)
2. **Quit-and-relaunch permission UX** — when permission is missing the app shows the
   system prompt, opens Settings, *and* shows its own alert, then terminates. It could
   instead poll `AXIsProcessTrusted()` once a second and spring to life the moment the
   user flips the toggle — no relaunch, a genuinely delightful touch.
3. **`userDefaultsChanged` redraws on *any* defaults change**, including unrelated keys
   (cheap, but a targeted KVO observation on the five Alan keys would be tidier), and is
   only wired up once the prefs window has loaded.
4. **`hideDock` takes effect only on relaunch** — there's no observer applying
   `setActivationPolicy` when the checkbox changes.
5. **Naming nit:** `NSAppearance.isdarkMode` (lowercase d). ✅ implemented in PR #5 (renamed)
### G1. 10 Hz polling instead of AX notifications
`FocusHighlighter` polls the focused window every 100 ms, forever, with
multiple AX round-trips per tick. The grown-up approach is an `AXObserver`
per frontmost app subscribed to `kAXFocusedWindowChangedNotification`,
`kAXWindowMovedNotification`, `kAXWindowResizedNotification` plus
`NSWorkspace.didActivateApplicationNotification` — event-driven, zero idle
cost, and the border stops lagging 100 ms behind window drags.
**[implemented in PR #7]** — AXObserver on the frontmost app plus a
drag-scoped 30 Hz timer, since AX doesn't deliver move/resize notifications
continuously during a live drag, only when the gesture ends.

### G2. `isdarkMode` naming **[implementing]**
The `NSAppearance.isdarkMode` property is camelCase-with-a-stumble. Renamed to
`isDarkMode`.

### G3. Permission-flow dialog pile-up
On first launch without permission, three things happen at once: the system's
own AX prompt (from `AXIsProcessTrustedWithOptions` with prompt=true), System
Settings opening, and Alan's modal "quit" alert. Consider showing the alert
*first*, then opening Settings, and polling `AXIsProcessTrusted()` on a timer
so Alan starts working the moment the box is ticked instead of demanding a
relaunch.

### G4. `NSColor.toHex` can't encode its own defaults
`toHex` reads `cgColor.components` and bails when there are fewer than 3 —
which is the case for the default colors (`NSColor.black`/`.white` are
grayscale, 2 components). It's currently dead code (nothing calls it), as is
`NSColor(hex:)`. Either convert via `usingColorSpace(.sRGB)` first or delete
both.

### G5. Template menu bar
`MainMenu.xib` still carries the full new-project template: Format, Font,
Spelling, Substitutions, Speech… none of which do anything in an app with no
text. Cosmetic, but trimming it would cut the xib by ~80%.

---

## Missing features

1. **Launch at login** (`SMAppService.mainApp`) — an app like this lives or dies by
   being there after reboot.
2. **A menu bar item** — quick enable/disable toggle, prefs, quit; especially important
   in dock-hidden accessory mode, where the app is otherwise invisible and unquittable
   without Activity Monitor.
3. **Width/inset live preview in prefs** — the color wells update live (via the
   defaults-change observer); a small preview swatch showing the actual border
   width/inset combination would make tuning pleasant.
4. **Pause/disable shortcut** — a global hotkey or menu toggle to temporarily hide the
   border (screenshots, screen recording, presentations).

---

## Novel / cool / delightful / quirky ideas

1. **Rounded corners** — macOS windows have had rounded corners since approximately the
   Mesozoic, but Alan draws a sharp rectangle over them. `NSBezierPath(roundedRect:...)`
   with ~10 pt radius would hug modern windows beautifully (bonus: make the radius a
   hidden preference for the Rectangle Purists).
2. **Party mode** 🌈 — slowly rotate the border hue. Zero practical value, maximal joy.
   Perfectly on-brand for a self-described satire app.
3. **Focus pulse** — flash or briefly thicken the border when focus *changes*, then
   settle. Helps the actual underlying use case: finding where your keyboard input goes.
4. **Per-app colors** — terminal gets green, browser gets blue. The AX element already
   knows its `pid`; `NSRunningApplication` gives the bundle id.
5. **Spotlight mode** — instead of a border, dim everything *except* the focused window
   (one translucent black window per screen with a cut-out path). The inverse-Alan.
6. **Shake to find** — like the system's shake-to-enlarge cursor: wiggle the mouse and
   the border briefly glows. Same accessibility instinct, same wink.

---

*Review performed across all of `Alan/` (AppDelegate, Constants, Extensions,
FocusHighlighter, HighlightWindow, PrefsWindowController). The sibling repo Baegun has
its own `awesome.md` from the same review pass. Note: this review environment has no
macOS toolchain, so the companion fix PR sticks to small, conservative changes — please
build once in Xcode before merging.*
### F1. Status-bar item **[implementing]**
The companion fix for B5, and useful generally: a menu-bar item with
Preferences… and Quit. Implemented so it's always available in hidden-Dock
mode (where there's otherwise nothing), keeping the regular menu bar when the
Dock icon is shown.

### F2. Launch at login
The natural habitat of a window-border utility is "always running".
`SMAppService.mainApp.register()` plus a Preferences checkbox is all it takes
on macOS 13+.

### F3. Pause/disable toggle
No way to temporarily turn the border off (screenshots, screen sharing,
presentations) without quitting. A status-item menu toggle (see F1) is the
obvious place.

### F4. Width/inset live preview bounds
Prefs binds `width`/`inset` straight to UserDefaults (clamped 1–20 at draw
time), but the controls themselves don't communicate the limits. Minor.

---

## Novel / delightful ideas

### D1. Per-app border colors
Hash the frontmost app's bundle identifier into a hue. Terminal is always
teal, Safari always blue-ish, Xcode always whatever it deserves. Zero
configuration, surprisingly practical — you learn the colors within a day.

### D2. Party mode
A preferences checkbox that slowly cycles the border hue. This app's README
calls it software satire; satire deserves a rainbow option.

### D3. Rounded corners
macOS windows have had rounded corners since 2001, and *very* rounded ones
since Big Sur. A `NSBezierPath(roundedRect:xRadius:yRadius:)` with ~10 pt
radius would hug modern windows instead of poking square corners past them.

### D4. Focus-change pulse
On focus change, draw the border at 3× width and animate down to the set
width over ~200 ms. Makes the "where did my focus go" moment — the app's whole
reason to exist — impossible to miss.

### D5. "Find my window" shortcut
A global hotkey that flashes the border three times. Spiritual cousin of
shake-to-find-cursor.
