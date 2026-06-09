# awesome.md — Alan code review

A full review of Alan's six Swift files. The README calls the app "more software satire
than useful utility", which is exactly why it deserves a loving review. Entries marked
**✅ implemented** have a companion PR; everything else is documented here.

---

## Bugs

### 1. Permission flow opens the wrong System Settings pane ✅ implemented
`AppDelegate.requestAccessibilityPermissionIfNeeded()` opens
`x-apple.systempreferences:com.apple.preference.universalaccess` — that's the
**Accessibility features** pane (VoiceOver, Zoom, …), not
**Privacy & Security ▸ Accessibility**, which is where the user actually has to enable
Alan. The alert text says one thing; the deep link goes somewhere else. The correct URL
is `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.

### 2. `register(defaults:)` is fed raw `NSColor` objects ✅ implemented
`UserDefaults.register(defaults:)` only accepts property-list values (strings, numbers,
data, dates, arrays, dicts). `Key.lightMode`/`Key.darkMode` are registered as `NSColor`
objects, which is not a plist type — the registration of those two keys is ineffective
(and inconsistent with `color(forKey:)`, which expects archived `Data`). The app only
works because every read site has its own `?? Defaults.…Color` fallback. Register
archived `Data` (or nothing) instead.

### 3. Border color doesn't react to light/dark mode switches ✅ implemented
`HighlightView.draw` picks the color from `NSAppearance.isLightMode` at draw time, but
nothing triggers a redraw when the system appearance changes. After switching themes,
the border keeps the old mode's color until the focused window moves or focus changes.
AppKit has a purpose-built hook: override `viewDidChangeEffectiveAppearance()` and mark
the view dirty.

### 4. Deprecated, non-secure color archiving ✅ implemented
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
5. **Naming nit:** `NSAppearance.isdarkMode` (lowercase d). ✅ implemented (renamed)

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
