# Alan — code review notes

A read-through of the whole app (it's pleasantly small). Organized as:
**bugs**, **general issues**, **missing features**, and **ideas**. Items
marked **[implementing]** are being fixed in a follow-up PR; the rest are
written up for future consideration — mindful that this app is, per the
README, "more software satire than useful utility" :)

---

## Bugs

### 1. The accessibility prompt deep-links to the wrong Settings pane **[implementing]**
`AppDelegate.requestAccessibilityPermissionIfNeeded()` opens

```
x-apple.systempreferences:com.apple.preference.universalaccess
```

which is the *Accessibility features* pane (pointer size, zoom, VoiceOver…),
not the pane the alert tells the user to visit. The permission toggle lives
in **Privacy & Security → Accessibility**, whose deep link is:

```
x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
```

### 2. Deprecated, insecure NSColor archiving **[implementing]**
`UserDefaults.setColor/color(forKey:)` use
`NSKeyedArchiver.archivedData(withRootObject:)` and
`NSKeyedUnarchiver.unarchiveObject(with:)`, both deprecated since macOS
10.13/10.14 (the unarchiver path also allows arbitrary-class decoding).
The modern secure-coding API is a drop-in replacement and still reads
archives written by the old method:

```swift
try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
```

### 3. Multi-monitor Y-flip is suspicious (needs hardware to confirm)
`cocoaRect(fromAXRect:)` flips coordinates using
`NSScreen.screens.map { $0.frame.maxY }.max()`. The AX/CoreGraphics origin
is the **top-left of the primary screen**, and Cocoa's origin is the
**bottom-left of the primary screen**, so the mathematically correct flip
constant is the *primary* screen's height (`NSScreen.screens[0].frame.maxY`
— `screens[0]` always has origin `(0,0)`). The two formulas agree unless a
display is arranged *above* the primary's top edge, in which case the
current code offsets the highlight by that display's height.

Commit `558034d` says the current formula was arrived at by experimentation
and works on the author's setup, so I'm **not** changing it blind — but if a
report ever comes in of the border floating one-screen-height away on a
stacked-monitor arrangement, this is why. (Doc-only.)

### 4. `NSColor.toHex` returns nil for non-RGB colors
`Defaults.lightModeColor` is `NSColor.black`, which lives in a grayscale
colorspace (2 components), so `toHex` bails at `components.count >= 3`.
The function is currently unused, but it's a landmine: convert via
`usingColorSpace(.sRGB)` first if it's ever called. (Doc-only while unused.)

### 5. "Hide dock icon" can strand the user
With `hideDock` set, the app becomes an `.accessory` with **no menu bar and
no status item** — there is no way to open Preferences or quit except
`killall Alan`. A tiny `NSStatusItem` (or at least keeping a way back) would
fix it. (Feature-sized; doc-only for now.)

## General issues

- **Permission flow is quit-and-relaunch**: after prompting, the app shows an
  alert and terminates. Friendlier: poll `AXIsProcessTrusted()` on a timer
  and start highlighting the moment permission is granted, no relaunch.
- **10 Hz AX polling**: `FocusHighlighter` polls every 0.1 s forever. An
  `AXObserver` subscribed to focus/move/resize notifications would be
  event-driven, lower-latency (no 100 ms lag while dragging), and use ~zero
  idle CPU. The polling fallback is still worth keeping — some apps have
  broken AX notification support.
- **Hard-coded window expansion**: `updateFrame` outsets the overlay window
  by a fixed 2 pt, but border *width* may be up to 20 and *inset* as low
  as 1, in which case the outer half of the stroke clips at the window edge.
  The expansion should be derived from `width / 2 - inset`.
- `isdarkMode` is a naming typo (`isDarkMode`). **[implementing]**
- `PrefsWindowController` adds a `UserDefaults.didChangeNotification`
  observer and never removes it — harmless here (the controller lives for
  the app's lifetime), just noting it.
- Force-casts like `focusedElement as! AXUIElement?` would crash if the AX
  API ever returned an unexpected type; `unsafeBitCast`-free safe bridging
  of `AXUIElement` is awkward, so this is understandable — noting it only.

## Missing features

- **Width/inset have no UI**: the defaults register `width` and `inset`, and
  the drawing code clamps them 1–20, but the prefs window only exposes the
  two colors. Power users must use `defaults write`.
- **Launch at login** (SMAppService) — the natural companion for a utility
  that wants to always run.
- **Multiple-display edge case**: when the focused window straddles two
  displays the single overlay window can't span them cleanly.

## Ideas — novel, cool, delightful, quirky

- **Rounded corners**: macOS windows have ~10 pt rounded corners; the
  highlight rectangle draws square ones. An `NSBezierPath(roundedRect:)`
  with a radius pref would hug windows much more lovingly.
- **Focus pulse**: animate a quick 1.1× → 1.0× scale (or a glow) when focus
  *changes*, then settle — makes the satire even more theatrical.
- **Per-app colors**: a dictionary of bundle-ID → color, so Terminal gets
  green, Xcode blue, and you can *feel* the context switch.
- **"Disco mode"**: cycle the border hue continuously. Completely useless.
  Perfectly on-brand.
- **Click-through toggle**: a hotkey to flash the highlight border briefly
  ("where is my focus?") instead of showing it permanently.

---

*Reviewed at commit `ebdaad7`. Items 1, 2 and the naming typo are being
implemented in a follow-up PR; everything else is intentionally left as
documentation.*
