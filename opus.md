# Alan — review pass (Opus 5)

A fresh read of the whole tree at `064ae3e` (v3.0.0): every Swift file, the
Xcode project, the CI/release workflows, the xib, the asset catalog and the
README. `ANALYSIS.md` was read *after* forming the findings below, so the two
were reconciled rather than anchored — entries that duplicate a still-open
`ANALYSIS.md` item say so explicitly, and everything else is new.

**Method and its limits.** This pass was authored on Linux with no Xcode, so
nothing here was compiled or run; findings come from close reading, and CI
builds every PR on macOS. Items whose *outcome* (as opposed to whose logic) can
only be judged on a device are marked **[dev]**.

Legend: **sev** = severity · **conf** = confidence that the finding is real ·
**[dev]** = wants on-device confirmation.

---

## Status of this pass

Of the 28 entries below, **13 ship in this pass** across 5 branches; the rest
are documented with a rationale for deferring. Branches are cut from `main` and
kept to disjoint files/regions where possible.

| PR | Branch | Entries |
|---|---|---|
| 1 | `claude/opus-transient-overlays` | BUG-9, BUG-10, BUG-11, BUG-12, BUG-13 |
| 2 | `claude/opus-preview-idle` | PERF-8 |
| 3 | `claude/opus-settings-ui` | UX-12, VIS-8, VIS-10, VIS-11 |
| 4 | `claude/opus-status-menu` | UX-13, UX-14, UX-15, UX-16, UX-17, FEAT-4 |
| 5 | `claude/opus-auto-update` | FEAT-3 |

The only files touched by more than one branch are
`PrefsWindowController.swift` (PRs 2, 3, 5 — three disjoint regions: the
`BorderPreviewView` class, the tab builders, and one row appended to the
Behavior stack) and `AppDelegate.swift` (PRs 4, 5 — the menu build vs. one
call added to `applicationDidFinishLaunching`). Both are keep-both
resolutions if they collide at all.

---

## A. Bugs

### BUG-9 · The focus chip can go permanently invisible
*sev medium / conf high*

**Where:** `FocusChipWindow.show(icon:name:above:)` — the
`NSAnimationContext.runAnimationGroup { animator().alphaValue = 0 }` fade and
the `alphaValue = 1` at the top of the next `show`.

**Problem:** `generation` guards the *completion handler*, but nothing cancels
the running alpha animation itself. `NSWindow`'s animator proxy drives
`alphaValue` toward its target over the animation's duration; assigning
`alphaValue = 1` directly does not stop it, so the assignment is overwritten by
the very next animation step. Sequence:

1. `t = 0` — chip A shows, hold timer armed for `focusChipDuration` (0.8 s).
2. `t = 0.8` — hold fires, a 0.25 s fade to 0 starts.
3. `t = 0.9` — focus changes again. `show()` bumps `generation`, sets
   `alphaValue = 1`, orders front, arms a new hold timer.
4. `t = 0.9…1.05` — **A's fade is still running** and drags the *new* chip's
   alpha back down to 0.
5. `t = 1.05` — A's completion handler runs, sees a stale generation, and
   correctly declines to `orderOut`. The window is now ordered in at alpha 0.
6. The new chip is invisible for its whole life; at `t = 1.7` its own hold
   timer fires and fades an already-invisible window from 0 to 0.

So the chip silently stops appearing for a run of quick app switches — exactly
the situation ("what did I just switch to?") the chip exists for. It recovers
on the next focus change that lands outside a fade window, which makes it read
as flaky rather than broken.

**Fix:** drive the fade from a timer, the way `PingWindow` already does, so the
generation counter governs the animation and not just its tail. (The
alternative — a zero-duration `runAnimationGroup` to replace the in-flight
animation before assigning — works, but leaves two animation mechanisms in a
file that already has a timer-based one.)

**Resolution:** ✅ Implemented → PR 1 (`claude/opus-transient-overlays`).

### BUG-10 · The same fade race in `GhostBorderWindow`
*sev low / conf high*

**Where:** `HighlightWindow.swift` — `GhostBorderWindow.flash(at:reduceMotion:)`.

**Problem:** identical mechanism to BUG-9, reached by fast alt-tabbing with
"Focus trail" on: a trail flashed during the previous trail's 0.8 s fade
inherits the old animation and shows dimmer, shorter, or not at all. Lower
severity only because the trail is decorative and its duration is long enough
that the overlap window is proportionally smaller.

**Fix:** same timer-driven fade.

**Resolution:** ✅ Implemented → PR 1.

### BUG-11 · The focus trail is painted in the *incoming* app's color
*sev medium / conf high*

**Where:** `FocusHighlighter.maybeShowFocusTrail(focusChanged:newFrame:)` →
`GhostBorderWindow.flash` → `HighlightView.draw` → `currentBorderColor()`.

**Problem:** `GhostBorderWindow`'s content view is a plain `HighlightView`,
which resolves its color at *draw* time from
`HighlightView.currentBorderColor()`. By the time the trail is flashed, focus
has already moved: `NSWorkspace.shared.frontmostApplication` is the **new**
app. With "Per-app border colors" on, the ghost that exists to say *"you came
from over there"* is drawn in the color of where you just *went* — the one
piece of information it must not carry. (Party mode has a milder version of the
same issue: the ghost samples the live hue rather than the hue the outgoing
border wore.)

The whole point of per-app colors is that the color *is* the app's identity, so
this isn't cosmetic: the trail actively misinforms.

**Fix:** remember the color the border was last drawn with and hand it to the
ghost. The ordering makes this clean and requires no new bookkeeping about
"previous app": `maybeShowFocusTrail` runs *before* `showHighlight`, so a
`lastBorderColor` captured at the top of `showHighlight` is still the outgoing
app's color when the trail reads it. Give `HighlightView` an optional
`overrideColor` (nil = today's behavior) that `drawBorder` honors, and pass the
captured color through `flash(at:color:reduceMotion:)`.

**Resolution:** ✅ Implemented → PR 1.

### BUG-12 · `disableFrameTimer` isn't scheduled in `.common` run-loop mode
*sev low / conf high*

**Where:** `FocusHighlighter.temporarilyDisableFrameDrawing()`.

**Problem:** every other timer in `FocusHighlighter` — the settle chain, the
resolution retry, the observer retry, the flash, the drag poll, the glide — is
explicitly added to `RunLoop.current` in `.common` mode. This one is not, so it
only fires in `.default`. Whenever the main run loop is in a tracking mode at
the moment it should fire (a menu is open, a modal panel is up, an
`NSEventTrackingRunLoopMode` gesture is in progress), the re-enable is deferred
until the loop leaves that mode.

The visible symptom, with "Show border while dragging" **off**: move a window,
then open a menu within 250 ms — the border stays gone for as long as the menu
is open. Small, but it's the one timer in the file that can strand the app in a
"no border" state, and the fix is one line that makes the file uniform.

**Resolution:** ✅ Implemented → PR 1.

### BUG-13 · "Show overlays in screenshots" doesn't reach the trail or the chip
*sev low / conf high*

**Where:** `GhostBorderWindow.init` and `FocusChipWindow.init` both hardcode
`sharingType = .none`; `FocusHighlighter.forceUpdate()` fans
`applyOverlaySharingType()` over only `highlightWindow` and `dimWindows`.

**Problem:** `Key.showInScreenshots` is presented as a single switch —
"Show overlays in screenshots and recordings" — but two of the five overlays
opt out of it unconditionally. A user who turns it on to record a demo of the
app gets the border and the dim, and a border-shaped *hole* where the focus
trail should be. The chip's exemption is defensible on privacy grounds
(app names in a screen share), but it is undocumented, and the user has already
made the "yes, capture my overlays" choice explicitly.

**Fix:** route both through `applyOverlaySharingType()` and include them in the
live fan-out in `forceUpdate()`. (`PingWindow` already does this correctly and
is the model.)

**Resolution:** ✅ Implemented → PR 1.

### BUG-14 · Vestigial `lastCornerRadius` in `DimWindow`'s skip check
*sev trivial / conf high*

**Where:** `HighlightWindow.swift` — `DimWindow.update(screenFrame:cutout:)`.

**Problem:** the repaint-skip check reads `Key.cornerRadius` and stores it, but
`DimView.draw` stopped using it when the cut-out moved to
`Defaults.windowCornerRadius` (the window's own ~10 pt glass radius). The
comparison now only causes *extra* repaints: changing the border's corner
radius forces a full-screen dim repaint per display that cannot change a pixel.

**Resolution:** ⏸️ Deferred — genuinely harmless and one line, but it belongs
with whoever next touches that skip check; folding it into PR 1 (which touches
a different region of the same file) would blur that PR's story for no benefit.

### BUG-15 · The Settings preview shows Alan's *own* per-app color
*sev low / conf high*

**Where:** `BorderPreviewView.draw` → `HighlightView.currentBorderColor()`.

**Problem:** the per-app branch reads `NSWorkspace.shared.frontmostApplication`.
While the Settings window is open and key, that is Alan. So the preview of
"Per-app border colors" is a live, accurate rendering of the color assigned to
`studio.retina.Alan` — a color the user will essentially never see, since Alan
has no ordinary windows other than this one. The checkbox therefore appears to
do something arbitrary.

**Fix (design call):** either render the preview against a representative
sample bundle ID with a caption ("each app gets its own hue"), or — better —
show a small strip of swatches for the user's currently running apps, which
doubles as the legend that makes per-app colors learnable on day one instead of
day two (see IDEA-21).

**Resolution:** ⏸️ Deferred — the fix is a design decision about what the
preview should *claim*, not a mechanical correction, and the swatch-strip
version is a feature in its own right.

---

## B. Performance

### PERF-8 · The Settings preview repaints 30×/s regardless of what's on it
*sev medium / conf high*

**Where:** `BorderPreviewView.startRedrawTimer()` /
`updateRedrawTimer(visible:)`.

**Problem:** the previous round fixed the *real* bug here (the timer used to
run forever after Settings was opened once) by gating it on the window's
occlusion state. But while the window is visible, the timer is unconditional at
30 Hz — and each tick redraws the mock desktop, the mock window, the traffic
lights, and then the *real* `HighlightView.drawBorder`. With "Glowing border"
or "Stronger shadow" enabled, that last call runs one or two CPU `NSShadow`
Gaussian blurs over the preview's backing store, thirty times a second, on the
main thread.

Nothing in the preview is time-varying unless party mode is on or the border
style is marching ants / hand-drawn. Everything else — width, inset, radius,
colors, glow, shadow, spotlight dim — changes only on a defaults write, and
`syncDynamicUI()` already sets `previewView.needsDisplay = true` on every one
of those. So in the default configuration, 30 identical repaints per second are
pure waste for as long as the Settings window is open, which is precisely when
the user is most likely to notice a fan.

**Fix:** start the timer only when the preview actually animates — `partyMode`,
or `BorderStyle.current ∈ {ants, handDrawn}` — and not under Reduce Motion
(where both render statically anyway, matching
`FocusHighlighter.borderStyleNeedsAnimation()`). Re-evaluate the gate from
`syncDynamicUI()`, which already runs on every defaults change, and keep the
occlusion start/stop as the outer gate. The hand-drawn seed only advances ~3×/s,
so the 30 Hz tick can additionally skip repaints when the seed hasn't moved —
the same optimization `HighlightWindow.setBorderStyleAnimating` already applies
to the live overlay.

**Resolution:** ✅ Implemented → PR 2 (`claude/opus-preview-idle`).

### PERF-9 · Excluded-apps rows hit LaunchServices on every cell pass
*sev low / conf high*

**Where:** `PrefsWindowController.tableView(_:viewFor:row:)`.

**Problem:** every cell configuration calls
`NSWorkspace.urlForApplication(withBundleIdentifier:)`,
`FileManager.displayName(atPath:)` and `NSWorkspace.icon(forFile:)` — three
LaunchServices/disk lookups per row, repeated on every `reloadData` and on
scrolling. `syncDynamicUI` reloads the table whenever the stored list differs,
and the status menu's "Exclude …" makes that happen while the window is open.

**Fix:** a `[String: (name: String, icon: NSImage)]` cache keyed by bundle ID,
invalidated never (an app's name/icon changing mid-session is not worth
handling) or on `NSWorkspace.didLaunchApplicationNotification`.

**Resolution:** ⏸️ Deferred — real, but the list is typically 0–10 rows and the
cost is only paid while Settings is open; it is not worth a PR of its own, and
it wants to land with the UX-8 `Settings` facade cleanup.

### PERF-10 · Shake detection calls `NSEvent.mouseLocation` per mouse-move event
*sev trivial / conf high*

**Where:** `FocusHighlighter.updateShakeMonitor()` — the global `.mouseMoved`
monitor calls `self?.detectShake(at: NSEvent.mouseLocation.x)`.

**Problem:** the monitor already *has* the event; for a global monitor with no
window, `event.locationInWindow` is already in screen coordinates.
`NSEvent.mouseLocation` is an extra window-server query per mouse-move event,
and mouse-move events arrive at the pointer's full sample rate.

**Resolution:** ⏸️ Deferred — micro-optimization on an opt-in feature; noted so
whoever touches shake detection next can fold it in. (The inherent cost of the
feature — waking the process on every mouse move — is not fixable without
dropping the gesture.)

### PERF-1, PERF-2, PERF-4, PERF-7
Carried unchanged from `ANALYSIS.md`; independently re-reached the same
conclusions this pass. In particular PERF-2/PERF-4 (display link +
`CAShapeLayer`) remains the single highest-leverage performance change in the
codebase, and it is also the prerequisite for a good-looking soft-edged
spotlight (IDEA-12).

---

## C. Visual & layout

### VIS-8 · The Behavior tab is a flat wall of eighteen checkboxes
*sev medium / conf high*

**Where:** `PrefsWindowController.makeBehaviorTab()` — one `NSStackView` with
16 checkboxes, two indented slider rows, a shortcut row, a picker row and a
divider, all at uniform 12 pt spacing.

**Problem:** the tab has grown a row per feature for five rounds and has no
structure left. "Show border while dragging", "Spotlight mode", "Shake mouse to
find window", "Show overlays in screenshots and recordings" and "Launch Alan at
login" are five unrelated concerns presented as one undifferentiated list; the
only visual hierarchy is the indentation of the two sliders and the shortcut
row, which reads as inconsistent rather than intentional (the find-related
checkboxes below the shortcut row are *not* indented, though they belong to the
same feature). Scanning for a setting means reading all eighteen labels.

This is also what drives the window's height, since UX-11 sizes the window to
the tallest tab.

**Fix:** group into four labelled sections — **Border**, **Spotlight**,
**Find my window**, **General** — with small bold secondary-color headers,
tighter intra-group spacing and larger inter-group spacing. Purely additive to
the existing stack; the auto-height mechanism absorbs the change. Tightening
intra-group spacing from 12 pt to 6 pt roughly pays for the headers, so the
window's height barely moves.

**Resolution:** ✅ Implemented → PR 3 (`claude/opus-settings-ui`).

### VIS-9 · The Settings window can outgrow a small display
*sev medium / conf medium / [dev]*

**Where:** `PrefsWindowController.buildUI()` — the shortfall computation; the
window's `styleMask` (no `.resizable`); no scroll view in any tab.

**Problem:** UX-11 (shipped last round) fixed clipping by growing the window to
the tallest tab, with no ceiling. The Behavior tab's content is currently on
the order of 600 pt; a 13″ MacBook Air at its default scaled resolution has
roughly 740 pt of `visibleFrame` height. Two or three more rows and the window
is taller than the screen — and because it is neither resizable nor scrollable
and is centered, the overflow is split between the top and bottom edges with no
way to reach it. The failure mode is the same one UX-11 fixed, just further out.

**Fix:** clamp the computed height to `NSScreen.main?.visibleFrame.height`
minus a margin, and put each tab's content inside a borderless, non-drawing
`NSScrollView` (document view pinned to the clip view's width, so only vertical
scrolling is possible). The `fittingSize` measurement then has to be taken from
the document view rather than the tab view. Making the window `.resizable` with
a sensible minimum size is a cheaper half-measure that at least gives the user
an escape hatch.

**Resolution:** ⏸️ Deferred — the scroll-view rework interacts directly with the
just-shipped auto-height measurement, and getting the clip-view/document-view
constraint pair wrong produces a subtly broken window that only a build reveals.
VIS-8's tighter spacing buys headroom in the meantime.

### VIS-10 · The color-source precedence is invisible in Settings
*sev medium / conf high*

**Where:** `HighlightView.currentBorderColor()` (party → per-app → accent →
light/dark wells); `PrefsWindowController.syncDynamicUI()` (only the wells are
disabled, and only for accent).

**Problem:** four controls on the Appearance tab feed one value through a strict
precedence chain, and the UI shows exactly one link of it. Turn on "Per-app
border colors" and the "Use system accent color" checkbox and both color wells
stay fully enabled while doing nothing. Turn on "Party mode 🌈" and all three
below it are inert. There is no visual signal, no tooltip, and no ordering cue
in the layout — the checkboxes are simply listed. A user who ticks accent,
sees nothing change (because per-app was already on), and unticks it again has
been told nothing true.

**Fix:** extend the pattern the code already uses for `focusPulseCheckbox`
under spotlight mode — disable the subordinate controls and give each a tooltip
naming the setting that outranks it. A "Color source" popup would be cleaner
still, but it changes the stored schema (four booleans → one enum) and the
migration isn't worth it.

**Resolution:** ✅ Implemented → PR 3.

### VIS-11 · Reduce Motion silently neuters several settings
*sev low / conf high*

**Where:** guards in `moveBorder`/`moveSpotlight`, `HighlightWindow.pulse()`,
`setPartyMode`, `borderStyleNeedsAnimation()`, `GhostBorderWindow.flash`,
`PingWindow.ping`.

**Problem:** the Reduce Motion support is thorough and correct — and completely
invisible in Settings. With the system setting on, "Animate movement between
windows" and its duration slider, "Pulse border on focus change", the marching
ants and hand-drawn animation and party mode's hue cycle all become no-ops, but
every control stays enabled and unannotated. From the user's side the app looks
broken in exactly the way an accessibility setting should not make it look.

**Fix:** a single secondary-color note at the foot of the Behavior tab, shown
only while `accessibilityDisplayShouldReduceMotion` is true, and refreshed on
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` (the highlighter
already observes it; the prefs window needs its own observation).

**Resolution:** ✅ Implemented → PR 3.

### VIS-12 · The app icon set has one slot filled
*sev low / conf high / [dev]*

**Where:** `Alan/Assets.xcassets/AppIcon.appiconset/Contents.json` — nine
entries with no `filename`, one 512×512@2x pointing at `Icon.png`.

**Problem:** the catalog declares the full mac icon ladder and supplies only the
1024 px bitmap, which produces "unassigned children" build warnings and leaves
macOS to downsample a single image for the 16 pt Dock/Finder/About sizes. A
1024→16 px box filter of a detailed icon is usually mush. (This is separate from
the *status item* icon, which is a template SF Symbol and is fine.)

**Fix:** export the ladder from the source artwork (16/32/128/256/512, @1x and
@2x) or reduce the catalog to a single-size icon entry so Xcode stops warning.

**Resolution:** ⏸️ Deferred — needs the source artwork and a look at the result
at 16 pt; not something to change blind.

### VIS-1, VIS-3, VIS-5, VIS-6, VIS-7
VIS-6 and VIS-7 shipped last round and are gone. VIS-1 (per-display border
window pool), VIS-3 (halo over the menu bar/Dock) and VIS-5 (square corners
overhanging the glass) carry forward unchanged; independently re-reached the
same conclusions.

---

## D. Interface & UX

### UX-12 · The contrast casing has no UI and no documentation
*sev medium / conf high*

**Where:** `Key.contrastCasing` (`Constants.swift`),
`HighlightView.contrastCasingActive` (`HighlightWindow.swift`). Grep the tree:
it appears in exactly those two files. Not in `PrefsWindowController`, not in
the README.

**Problem:** the feature ships, works, is in `allObservedKeys` (so it applies
live), and is reachable only by someone who reads the source and runs
`defaults write studio.retina.Alan contrastCasing -bool true`. It is the app's
answer to the single most common failure of a colored border — a wallpaper or
window content the same tone as the border — and nobody will find it. The
automatic path (system "Increase Contrast" on) covers users who have already
configured macOS for contrast, not users who just have a busy desktop.

**Fix:** an Appearance-tab checkbox next to the glow/shadow ones, plus a README
scripting line. No behavioral change; the default stays off.

**Resolution:** ✅ Implemented → PR 3.

### UX-13 · The status menu is thinner than the feature set
*sev medium / conf high*

**Where:** `AppDelegate.setupStatusItem()` / `menuNeedsUpdate(_:)`.

**Problem:** the status item is the app's primary — and in hidden-Dock mode,
only — interface, and it exposes seven items for a feature set that has roughly
tripled since it was written. Concretely:

- **Paused state is invisible.** The icon is the same `macwindow` glyph whether
  Alan is running or paused. The only feedback that Alan is paused is opening
  the menu and reading "Resume Alan" — which means the natural user reaction to
  "my borders disappeared" (look at the menu bar) tells them nothing.
- **Exclusion is one-way from the menu.** "Exclude 'Safari'" greys out once
  Safari is excluded; there is no "Include 'Safari'". Undoing a one-click action
  costs opening Settings, finding the Excluded Apps tab, finding the row, and
  clicking Remove.
- **Spotlight mode is buried.** It is one of the app's two headline modes and
  the one users toggle situationally (presenting, screenshotting, focusing),
  and it lives four clicks deep in a tab.
- **"Find my window" is unreachable without the hotkey.** The feature is off by
  default and needs a learned chord; a menu item makes it discoverable and gives
  the hotkey checkbox a reason to exist.
- **No link to the project page.** For a GitHub-distributed app whose update
  story is "download the zip", there is nowhere to go from inside the app.

**Fix:** dim the status item (`button.appearsDisabled`) and set an explanatory
tooltip while paused; make the exclude item a toggle that reads "Include 'X'"
when the app is already excluded; add a checkmarked "Spotlight Mode" item and a
"Find My Window" item; add "Alan on GitHub…" beside "Check for Updates…".

**Resolution:** ✅ Implemented → PR 4 (`claude/opus-status-menu`).

### UX-14 · "Check for Updates…" gives no in-flight feedback
*sev low / conf high*

**Where:** `AppDelegate.checkForUpdates(_:)` → `UpdateChecker.check` (15 s
`timeoutInterval`).

**Problem:** the menu closes and nothing happens — for up to fifteen seconds on
a bad network, then an alert appears out of nowhere. Meanwhile every extra click
starts another request, and each completion runs its own modal alert, so three
impatient clicks queue three alerts.

**Fix:** an `isCheckingForUpdates` flag: retitle the item to "Checking for
Updates…" and disable it while a request is in flight (`menuNeedsUpdate` already
runs on every menu open, so the title is free), and drop re-entrant calls.

**Resolution:** ✅ Implemented → PR 4.

### UX-15 · The Dock icon flashes at login when "Hide Dock Icon" is on
*sev low / conf medium / [dev]*

**Where:** `AppDelegate.applicationDidFinishLaunching` calls
`applyActivationPolicy()`; the generated Info.plist has no `LSUIElement`.

**Problem:** the app is born `.regular` and only becomes `.accessory` inside
`didFinishLaunching`, by which point AppKit has already put it in the Dock and
given it the menu bar. For a login item — the intended configuration for this
app — that is a Dock icon that appears and vanishes on every boot.

**Fix:** move the call to `applicationWillFinishLaunching`, which runs before
the app is presented. (`LSUIElement` in the plist is not an option: the policy
has to stay switchable at runtime, which is the whole point of the live toggle.)

**Resolution:** ✅ Implemented → PR 4.

### UX-16 · `hideDock` written externally doesn't apply until relaunch
*sev low / conf high*

**Where:** `Key.hideDock` is deliberately excluded from `Key.allObservedKeys`
("the activation policy is AppDelegate's business"); the README documents the
caveat as `# applies on relaunch when set externally`.

**Problem:** the reasoning is right — the highlighter shouldn't own the
activation policy — but the conclusion isn't. Every other key in the domain
applies live, which is the whole selling point of the "Scripting" section; this
one silently doesn't, and the README has to apologize for it. A Shortcuts action
or Stream Deck button that hides the Dock icon appears to do nothing.

**Fix:** `AppDelegate` observes `hideDock` itself (KVO on `UserDefaults`, the
same mechanism `DefaultsObservationBridge` uses) and re-applies the policy on
change, guarded so a write of the same value is a no-op. Keeps ownership where
it belongs and removes the asterisk from the README.

**Resolution:** ✅ Implemented → PR 4.

### UX-17 · `applicationSupportsSecureRestorableState` isn't implemented
*sev trivial / conf high*

**Problem:** on macOS 14+, an `NSApplicationDelegate` that doesn't implement it
logs `WARNING: Secure coding is not enabled for restorable state!` on every
launch. Alan restores no state, so the answer is unambiguously `true`.

**Resolution:** ✅ Implemented → PR 4.

### UX-18 · Regular mode ships a stock File/Edit/Window menu of no-ops
*sev low / conf high*

**Where:** `Alan/Base.lproj/MainMenu.xib`.

**Problem:** with the Dock icon shown, Alan has a full menu bar containing
File ▸ Close, Edit ▸ Undo/Redo/Cut/Copy/Paste/Delete/Select All, and
Window ▸ Minimize/Zoom/Bring All to Front. The app has exactly one ordinary
window (Settings, which has no text editing beyond three number fields and no
document model), so almost every one of those items is permanently greyed or
inert. It is the Xcode template's menu bar, not Alan's.

**Fix:** trim the xib to Alan ▸ (About, Settings…, Services, Hide, Quit),
Window ▸ (Minimize, Close), and add a Help ▸ "Alan Help"/GitHub item.

**Resolution:** ⏸️ Deferred — editing a xib by hand off-device is exactly the
kind of change where a mistake shows up as a missing menu at runtime rather than
a build failure, and the payoff is cosmetic. Worth doing with Interface Builder
open.

### UX-19 · The About panel has no copyright line
*sev trivial / conf high*

**Where:** `INFOPLIST_KEY_NSHumanReadableCopyright = ""` in both build configs.

**Problem:** `orderFrontStandardAboutPanel` renders the version and nothing
else. For a fork of an MIT-licensed project, the About panel is the natural
place to carry "© 2025 Tyler Hall · MIT".

**Resolution:** ⏸️ Deferred — a two-line `project.pbxproj` edit, but attribution
wording is the maintainer's call, not a reviewer's.

### UX-20 · Only one action is bindable to a global shortcut
*sev medium / conf high*

**Where:** `FocusHighlighter.registerFindMyWindowHotkey` (a single
`EventHotKeyID(signature: 'ALAN', id: 1)`, a single `hotKeyRef`, and a handler
that ignores the incoming hotkey ID and always calls `flashBorder`);
`ShortcutRecorderButton` (hardcoded to the three `findMyWindow*` defaults keys).

**Problem:** "find my window" is the *least* likely of Alan's actions to want a
chord. Pausing (before a screen share) and toggling spotlight (before a demo)
are the situational actions, and neither can be bound. The machinery is 90% of
the way there — it already handles registration failure, reserved combos,
recording suspension and function keys — but every piece of it is singular.

**Fix:** parameterize. Give `ShortcutRecorderButton` its three defaults keys via
`init`; keep a `[EventHotKeyID.id: () -> Void]` table in the highlighter; read
the fired ID in the Carbon handler with
`GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)`
and dispatch; register/unregister each entry independently.

**Resolution:** ⏸️ Deferred — the Carbon dispatch idiom and a
three-recorder-row Behavior tab are both things I'd want a compiler and a
keyboard for. Documented in enough detail to implement directly. This is my
pick for the highest-value *next* feature.

### UX-6, UX-7, UX-8, UX-10, UX-11
UX-6 and UX-11 shipped last round. UX-7 (no test target), UX-8 (`Settings`
facade) and UX-10 (localization) carry forward. Note that UX-7 gained two
more obvious candidates this pass: `UpdateChecker.compareVersions` (pure,
already has documented edge cases like `2.10.0` vs `2.9.0` and `-beta`
suffixes) and `isTopEdgeChrome` (pure geometry with six tuned constants and a
long comment explaining why each one is what it is — precisely the kind of
thing that regresses silently).

---

## E. Missing features

### FEAT-3 · Automatic update check
*sev medium / conf high*

**Where:** `UpdateChecker.swift` (documented as the FEAT-2 follow-up),
`AppDelegate`.

**Problem:** the manual check shipped, but nothing prompts a user who never
opens the menu. That matters more for Alan than for most apps, because of the
interaction with UX-6: an ad-hoc-signed update can reset the Accessibility
grant, so the population most likely to be on a stale build overlaps with the
population that once saw Alan stop working and never diagnosed it. A background
utility with a hidden Dock icon can run a year-old build indefinitely.

**Fix:** an opt-in weekly check. `Key.autoCheckUpdates` (registered `false`),
`Key.lastUpdateCheck` (a `Date` in defaults) and `Key.skippedUpdateVersion` (a
tag the user chose to ignore). On launch — after a short delay so it never
competes with the permission flow — and on a slow repeating timer, if the
feature is on and more than `Defaults.updateCheckInterval` has elapsed, run the
same `UpdateChecker.check`. Announce only `.updateAvailable`, and only for a
version that isn't the skipped one; `.upToDate` and `.failed` stay silent
(that's the difference from the manual check, whose whole point is explicit
feedback). The alert offers Download / Skip This Version / Later. Record the
check timestamp regardless of outcome so a flaky network can't turn into a
request loop.

**Resolution:** ✅ Implemented → PR 5 (`claude/opus-auto-update`).

### FEAT-4 · No way to restore default settings
*sev low / conf high*

**Problem:** the app has ~25 stored settings, several of which (party mode, an
extreme dim level, a wide glowing border) can leave it looking broken, and a
tri-state color precedence a user can talk themselves into a corner with. The
only recovery is `defaults delete studio.retina.Alan` in a terminal — which
also, silently, erases the excluded-apps list.

**Fix:** a "Restore Defaults…" status-menu item that confirms first, naming what
it will discard, then removes every `Key.*` from the domain (so the values
registered in `applicationDidFinishLaunching` take over again) and forces an
update. Excluded apps are the one thing worth calling out by name in the
confirmation.

**Resolution:** ✅ Implemented → PR 4.

### FEAT-5 · No inclusion list
*sev low / conf medium*

**Problem:** exclusions can't express "only highlight my editor and my
terminal". For a user who wants Alan for two apps, the list is the wrong shape
and has to be maintained forever as they install things.

**Fix:** a mode switch on the Excluded Apps tab — "Never highlight these apps" /
"Only highlight these apps" — reusing the same list and the same
`refresh()` check with the sense inverted. Cheap; the tab already has the
table, the drag-and-drop and the add/remove buttons.

**Resolution:** ⏸️ Deferred — small and self-contained, but it changes the
meaning of an existing stored list, so it wants a migration story
(`Key.appListMode` defaulting to `exclude`) and a maintainer's opinion on the
tab's copy.

### FEAT-6 · Per-app settings beyond color
*sev low / conf low*

**Problem:** per-app *colors* exist; per-app style/width/spotlight don't. "Thick
red border on the production terminal, thin grey everywhere else" is the
canonical ask.

**Resolution:** ⏸️ Deferred — a genuine feature with a real settings-UI design
problem behind it (per-app override tables are hard to make simple). Noted, not
specified.

### FEAT-2
Shipped last round.

---

## F. Ideas — novel, delightful, quirky

### IDEA-12 · Soft-edged "stage light" spotlight
*conf high that it would look better / conf high that the naïve implementation is too slow*

Spotlight mode currently cuts a hard-edged rounded rectangle out of a flat
dim — closer to a mask than a light. A feathered edge (the dim ramping to zero
over ~20 pt around the window) would turn it into an actual stage light, which
is the metaphor the code's own comments reach for ("the stage light swinging
across the screen").

**Why it isn't in this pass:** doing it with the current CPU drawing means
either N stacked annuli (≈14 even-odd fills over a full-screen backing store,
per display, per glide frame) or one `NSShadow` Gaussian over a full-screen
shape — and the existing comment in `DimWindow.update` already identifies
refilling a 5K backing store at 60 Hz as "the app's single largest cost". The
right implementation is a layer-backed dim with a `CAGradientLayer` /
`CALayer.mask`, which is the same rewrite PERF-2/PERF-4 want. **File it as the
first thing to build on top of that rewrite** — it's the change that would most
visibly improve the app.

### IDEA-13 · Double-tap a modifier to find the window
*conf medium*

macOS itself trains this gesture (double-tap ⌘ in some apps, double-tap ⌃ for
various utilities): press and release a bare modifier twice inside ~400 ms with
no other key in between, and the border flashes. It costs no chord to memorize,
can't collide with another app's shortcut (nothing is *consumed*), and is
strictly additive to the existing hotkey.

**Sketch:** a global `.flagsChanged` monitor (the Accessibility grant is already
held) gated on `Key.doubleTapModifier` (off by default; a picker for
⌃/⌥/⌘/⇧). Track transitions of the chosen flag; require press→release→press
within the window, and abort the sequence on any `.keyDown` or on any *other*
modifier appearing. Reuse the shake cooldown to prevent repeats. The false-
positive risk is real (⌘ is tapped constantly), which is exactly why it's
opt-in and why ⌃ is the sensible default.

### IDEA-14 · A focus-switch counter in the status menu
*conf high · pure whimsy, near-zero cost*

Alan already knows every time focus changes — it's the event the whole app is
built on. A disabled menu item reading "142 switches today" costs one counter
incremented in the `focusChanged` branch, one date stamp to roll it over at
midnight, and one line in `menuNeedsUpdate`. It's a genuinely interesting
number nobody has, it makes the menu feel alive, and it fits the app's premise
(*where is your attention going?*) exactly. Optional escalation: a
"most-visited app today" line, or a tiny sparkline. Keep it local, keep it
unsent, keep it resettable.

### IDEA-17 · Idle "breathing"
*conf medium / [dev]*

After N minutes with no keyboard or mouse input, the border begins a very slow,
low-amplitude width breathe (say ±1 pt over 4 s), stopping on the first event.
Coming back to the machine, your eye is drawn to where you left off before you
have to think about it. Cheap (the pulse machinery already exists and the
animation only runs while idle, which is exactly when the CPU is free), and it
degrades to nothing under Reduce Motion. The risk is that it reads as a
distraction rather than a welcome — which is a taste call best made on a device.

### IDEA-19 · "Where was I?" — ghost the last few windows
*conf medium*

`GhostBorderWindow` already draws a fading copy of the border at an arbitrary
rect. Keep a small ring buffer of the last 3–4 focused frames and, on a long
press of the find hotkey, flash all of them at once at decreasing opacity — a
visual "recently here" map across the screen. It's the focus trail generalized
from one step to a short history, and it reuses everything except the buffer.
Depends on UX-20's press/release handling (or IDEA-7's, which is the same
mechanism).

### IDEA-21 · A per-app color legend
*conf high*

Per-app colors are pitched in the README as "you learn the colors within a day".
A legend makes it an hour: a small panel (a Settings tab, or a status-menu item)
listing currently running apps with their derived swatch. It also fixes BUG-15
— the Appearance preview would have something honest to show for the per-app
checkbox — and it's the natural place to hang FEAT-6's per-app overrides later.
Cost: one `NSTableView` over `NSWorkspace.shared.runningApplications` filtered
to `.regular` activation policy, using the existing `NSColor.perAppColor(for:)`.

### IDEA-4, IDEA-8, IDEA-9
Shipped last round (sonar ping, cursor warp, focus chip).

### IDEA-5, IDEA-6, IDEA-7, IDEA-10, IDEA-11
Carry forward unchanged.

---

## G. Project & infrastructure

- **No test target** (UX-7). The pure seams keep multiplying;
  `compareVersions` and `isTopEdgeChrome` are the two best new candidates.
- **CI builds but doesn't lint or analyze.** `xcodebuild analyze` on the same
  runner, or a SwiftLint step, would catch the class of thing a human reviewer
  spends attention on. Warnings are currently not errors, so a warning
  introduced by a PR is invisible unless someone reads the log.
- **No CHANGELOG.** Releases use `--generate-notes`, which produces a commit
  list; for an app whose updates require a manual Accessibility re-grant, a
  human-written "what changed / do you need to re-authorize" note has real value.
- **`ENABLE_USER_SCRIPT_SANDBOXING = YES` and `ENABLE_HARDENED_RUNTIME = YES`**
  with `ENABLE_APP_SANDBOX = NO` — correct for an app that needs the
  Accessibility API. No entitlements file exists, which is right; worth keeping
  in mind if anything ever wants one.
- **The release notes' quarantine instructions are good** and the README's
  "Updating" section (UX-6, shipped) is the right shape. The long-term fix
  remains Developer ID + notarization, which would delete UX-6, FEAT-3's
  urgency, and half the install friction in one move.

---

## What I'd do next, in order

1. **PERF-2 + PERF-4** — the display-link / `CAShapeLayer` rewrite. It is the
   only change that makes the app *feel* different, it deletes the main-thread
   Gaussians, and it unlocks IDEA-12 and VIS-1.
2. **UX-20** — bindable Pause and Spotlight shortcuts. The highest-value
   feature the existing machinery is already 90% of the way to.
3. **UX-7** — a test target, before the pure-geometry helpers grow any more
   tuned constants.
4. **VIS-9** — scrollable/clamped Settings, before the Behavior tab outgrows a
   laptop screen again.
5. **IDEA-12** — the stage light, once (1) makes it affordable.
