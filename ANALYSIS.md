# Alan — consolidated analysis & work list

This document is the standing work list for the fork. It consolidates the
review passes that came before it — `awesome.md` (round two),
`fable-is-awesome.md` (round five) and `opus.md` (round seven, this pass) —
with the running list of open items, deduplicated into one actionable file.

**Everything already merged into `main` has been removed.** The previous pass
shipped eight entries as PRs #62–#69 (the drag fast-path, the preview room and
shadow direction, the cursor warp, the sonar ping, the focus chip, the manual
update check and the update-grant guidance) plus the Split View, elevated-chrome
and Accessibility-stand-down fixes; those are in `main` and are gone from this
list, as is everything from rounds one to six. What remains is the still-open
set: entries deferred in earlier rounds, plus everything round seven found.

Duplicate entries across the source documents are merged; each entry keeps
enough detail to implement from directly — file/line anchors, the exact
approach, the guards, and the gotchas that bit a naïve fix.

Every entry carries a **Resolution** line. Entries implemented in the current
pass ship each on their own branch off `main` with a PR; entries deliberately
deferred say why (usually: a rewrite too large to land safely without a macOS
build, a change that can only be tuned or validated on-device, or a maintainer
taste call).

Legend: **sev** = severity · **conf** = static confidence · **[dev]** =
needs on-device confirmation.

---

## Status of the current pass (round seven)

Round seven re-read the whole tree — every Swift file, the Xcode project, the
CI/release workflows, the xib and the asset catalog — and raised 34 entries.
**17 ship in this pass** across five branches; the other 17 are documented with
a rationale for deferring. Findings were formed before this document was read and
then reconciled with it, so carried entries are marked as such and the rest are
new.

| PR | Branch | Entries |
|---|---|---|
| [#70](https://github.com/L-K-M/Alan/pull/70) | `claude/opus-transient-overlays` | BUG-9, BUG-10, BUG-11, BUG-12, BUG-13 |
| [#71](https://github.com/L-K-M/Alan/pull/71) | `claude/opus-preview-idle` | PERF-8 |
| [#72](https://github.com/L-K-M/Alan/pull/72) | `claude/opus-settings-ui` | UX-12, VIS-8, VIS-10, VIS-11 |
| [#73](https://github.com/L-K-M/Alan/pull/73) | `claude/opus-status-menu` | UX-13, UX-14, UX-15, UX-16, UX-17, FEAT-4 |
| [#74](https://github.com/L-K-M/Alan/pull/74) | `claude/opus-auto-update` | FEAT-3 |

Only two files are touched by more than one branch:
`PrefsWindowController.swift` (#71, #72, #74 — three disjoint regions: the
`BorderPreviewView` class, the tab builders, and one row appended to the
Behavior stack) and `AppDelegate.swift` (#73, #74 — the menu build vs. one call
added to `applicationDidFinishLaunching`). Both are keep-both resolutions if
they collide at all. Two explicit follow-ups at merge time: if #73 lands before
#74, add `Key.autoCheckUpdates` to `Key.allStoredKeys`; if #72 lands before
#74, move the auto-update checkbox into #72's "General" section.

This pass, like the last, was authored on Linux with no Xcode, so nothing was
compiled locally: changes were verified by close reading, and CI builds every
PR on macOS.

---

## A. Bugs

### BUG-5 · Copy-window: no signal for a re-ordered pre-existing window
*sev low / conf low / [dev]*
**Where:** `FocusHighlighter.swift` observer registrations (the
`kAXWindowCreated`/focus/main/moved/resized/miniaturized/hidden/shown set in
`observeFrontmostApp`).
**Problem:** A window that already exists and is merely `orderFront()`-ed
(neither key nor main, not newly created) posts none of the observed
notifications, and AX has no reliable z-order-change signal — so re-showing a
cached palette/progress window gets no border until something unrelated
fires. Partly masked by the global `leftMouseUp` monitor.
**Fix (if ever wanted):** a bounded frontmost-and-idle-gated ~1.5s
reconciliation timer that pre-checks `topmostWindowBounds` against a cached
value and only calls `refresh()` on a change (never during a drag; reset on
screen-param change).
**Resolution:** ⏸️ Deferred — no clean signal exists (AX exposes no
z-order-change notification, and `kAXWindowsAttribute` doesn't change on a
pure re-order); a poll would fight the app's deliberate idle-wakeup
minimization. The raw-bounds fallback (BUG-1, shipped) plus the existing
`leftMouseUp` refresh already cover the click-driven case. Documented as a
platform limitation.

### BUG-9 · The focus chip can go permanently invisible
*sev medium / conf high · round seven*
**Where:** `FocusChipWindow.show(icon:name:above:)` — the
`NSAnimationContext.runAnimationGroup { animator().alphaValue = 0 }` fade and the
`alphaValue = 1` at the top of the next `show`.
**Problem:** `generation` guarded the *completion handler*, but nothing cancelled
the running animation. `NSWindow`'s animator proxy keeps stepping `alphaValue`
toward its own target, so assigning `alphaValue = 1` is overwritten on the
animation's next step. At t=0 chip A shows (0.8 s hold); at t=0.8 a 0.25 s fade
starts; at t=0.9 focus changes again and `show()` bumps the generation, sets
alpha 1 and orders front — but **A's fade is still running** and drags the new
chip to 0 by t=1.05, at which point A's completion handler sees a stale
generation and, doing its job, declines to `orderOut`. The window is left
ordered in at alpha 0 and never reveals again until a focus change lands outside
a fade window. It recovers eventually, which makes it read as flaky rather than
broken — during a run of quick app switches, exactly what the chip exists for.
**Fix:** drive the fade from a timer, the way `PingWindow` already does, so the
generation counter governs the animation and not just its tail. (A zero-duration
`runAnimationGroup` before the assignment also works, but leaves two animation
mechanisms in a file that already has a timer-based one.)
**Resolution:** ✅ Implemented → `claude/opus-transient-overlays` (PR #70). A
follow-up commit restores smoothstep easing so the rewrite doesn't quietly
change how the fade feels.

### BUG-10 · The same fade race in `GhostBorderWindow`
*sev low / conf high · round seven*
**Where:** `HighlightWindow.swift` — `GhostBorderWindow.flash`.
**Problem:** identical mechanism to BUG-9, reached by fast alt-tabbing with
"Focus trail" on: a trail flashed during the previous trail's 0.8 s fade inherits
that animation and shows dimmer, shorter, or not at all. Lower severity only
because the trail is decorative and its longer duration makes the overlap window
proportionally smaller.
**Fix:** the same timer-driven fade.
**Resolution:** ✅ Implemented → `claude/opus-transient-overlays` (PR #70).

### BUG-11 · The focus trail is painted in the *incoming* app's color
*sev medium / conf high · round seven*
**Where:** `FocusHighlighter.maybeShowFocusTrail(focusChanged:newFrame:)` →
`GhostBorderWindow.flash` → `HighlightView.draw` → `currentBorderColor()`.
**Problem:** the ghost's content view is a plain `HighlightView`, which resolves
its color at *draw* time from `currentBorderColor()` — which reads
`NSWorkspace.shared.frontmostApplication`. By the time the trail is flashed,
focus has already moved. So with per-app colors on, the ghost whose entire job is
to say *"you came from over there"* wore the color of where you just went: the
one piece of information it must not carry. Party mode has a milder version — the
ghost samples the live hue rather than the hue the outgoing border wore.
**Fix:** `HighlightView` gains an optional `overrideColor` (nil = today's
behavior); `FocusHighlighter` captures the border color at the top of
`showHighlight`, and `maybeShowFocusTrail` — which runs *before* `showHighlight`
— reads the previous capture, i.e. the outgoing window's color. No "previous app"
bookkeeping needed; the existing call order does the work.
**Resolution:** ✅ Implemented → `claude/opus-transient-overlays` (PR #70).

### BUG-12 · `disableFrameTimer` isn't scheduled in `.common` run-loop mode
*sev low / conf high · round seven*
**Where:** `FocusHighlighter.temporarilyDisableFrameDrawing()`.
**Problem:** every other timer in `FocusHighlighter` — the settle chain, the
resolution retry, the observer retry, the flash, the drag poll, the glide — is
explicitly added to `RunLoop.current` in `.common` mode. This one was not, so it
only fired in `.default`. With "Show border while dragging" off, a main run loop
sitting in a tracking mode when the re-enable was due (an open menu, a modal
panel) stranded the border hidden until that loop exited. The one timer in the
file that could leave the app in a no-border state.
**Resolution:** ✅ Implemented → `claude/opus-transient-overlays` (PR #70).

### BUG-13 · "Show overlays in screenshots" didn't reach the trail or the chip
*sev low / conf high · round seven*
**Where:** `GhostBorderWindow.init` and `FocusChipWindow.init` hardcoded
`sharingType = .none`; `FocusHighlighter.forceUpdate()` fanned
`applyOverlaySharingType()` over only `highlightWindow` and `dimWindows`.
**Problem:** `Key.showInScreenshots` is presented as a single switch — "Show
overlays in screenshots and recordings" — while two of the five overlays opted
out unconditionally. A user who turned it on to record a demo of the app got the
border and the dim, and a border-shaped *hole* where the focus trail should be.
The chip's exemption was defensible on privacy grounds but undocumented, and the
user has already made the explicit choice.
**Fix:** route both through `applyOverlaySharingType()` and include them in the
live fan-out. (`PingWindow` already did this correctly and was the model.)
**Resolution:** ✅ Implemented → `claude/opus-transient-overlays` (PR #70).

### BUG-14 · Vestigial `lastCornerRadius` in `DimWindow`'s skip check
*sev trivial / conf high · round seven*
**Where:** `HighlightWindow.swift` — `DimWindow.update(screenFrame:cutout:)`.
**Problem:** the repaint-skip check reads and stores `Key.cornerRadius`, but
`DimView.draw` stopped using it when the cut-out moved to
`Defaults.windowCornerRadius` (the window's own ~10 pt glass radius). The
comparison now only causes *extra* repaints: changing the border's corner radius
forces a full-screen dim repaint per display that cannot change a pixel.
**Resolution:** ⏸️ Deferred — genuinely harmless and one line, but it belongs
with whoever next touches that skip check; folding it into PR #70 (a different
region of the same file) would have blurred that PR's story for no benefit.

### BUG-15 · The Settings preview shows Alan's *own* per-app color
*sev low / conf high · round seven*
**Where:** `BorderPreviewView.draw` → `HighlightView.currentBorderColor()`.
**Problem:** the per-app branch reads `NSWorkspace.shared.frontmostApplication`.
While the Settings window is open and key, that is Alan. So the preview of
"Per-app border colors" is a live, accurate rendering of the color assigned to
`studio.retina.Alan` — a color the user will essentially never see, since Alan
has no ordinary windows other than that one. The checkbox therefore appears to do
something arbitrary.
**Fix (design call):** either render the preview against a representative sample
bundle ID with a caption ("each app gets its own hue"), or — better — show a
strip of swatches for the user's currently running apps, which doubles as the
legend that makes per-app colors learnable on day one instead of day two (IDEA-21).
**Resolution:** ⏸️ Deferred — the fix is a decision about what the preview should
*claim*, not a mechanical correction, and the swatch-strip version is a feature in
its own right.

---

## B. Performance

### PERF-1 · `CGWindowListCopyWindowInfo` on every non-drag refresh (doubled by settle)
*sev low / conf high / [dev]*
**Where:** `topmostWindowBounds`, called from `currentFocusedWindow()` before
the steady-state early-out in `refresh()`.
**Problem:** `topmostWindowBounds` materializes a CFDictionary for **every
on-screen window in the system** on every AX notification, every workspace
activation, and every settle refresh — and `handleAXNotification()` runs
`refresh()` immediately *and* again via the settle chain, so one event pays for
multiple full snapshots. The z-order check is only needed to catch a
frontmost-but-not-key/main window; on a plain move it's pure overhead, but the
callback discards the notification name so `refresh()` can't tell a move from a
create/focus event.
**Fix:** Stop discarding the notification name; classify into "can change which
window is frontmost" (`WindowCreated`/`FocusedWindowChanged`/`MainWindowChanged`
+ app-activation + `forceUpdate`) vs "same known window"
(moved/resized/miniaturized/hidden/shown); track `lastFocusedWindowPid`; in
`currentFocusedWindow()` add a fast path *before* the z-order block that, when
the last event can't have changed frontmost and `lastFocusedWindow`'s owning
pid == `frontPid` and its `axFrame` reads, returns it directly (1 IPC, no
snapshot). Default unclassified notifications to the full path. Also skip the
settle-refresh for move/resize.
**Resolution:** ⏸️ Deferred — the notification-classification refactor changes
the AX callback signature and reshapes the resolution fast-path — too broad to
land safely without a macOS build/profile, and it overlaps the resolution path
the shipped headline fix reshaped. Note: the drag half of this idea shipped
separately as PERF-6 this pass.

### PERF-2 · Wall-clock animation timers instead of a display link
*sev low / conf high / [dev]*
**Where:** glide `makeGlideTimer`; pulse, party, ants/hand-drawn in
`HighlightWindow`; preview in `PrefsWindowController` — all
`Timer.scheduledTimer`.
**Problem:** All five are wall-clock timers, unaligned to vsync — on 60Hz they
beat against refresh (glide stutter); on 120Hz/ProMotion they're capped at 60
and unsynced.
**Fix:** Replace with a single main-thread display link — prefer
`NSView.displayLink(target:selector:)` (macOS 14+; target is 15.7) so it
re-targets when the window moves between displays (120Hz for free). The
interpolation math already parametrizes on elapsed time — substitute
`link.targetTimestamp` for `Date()`; feed that timestamp into the clock-derived
party hue / ants phase / hand-drawn seed; keep an active-animation refcount and
pause the link at zero. Keep every Reduce Motion guard and the drag-bypass
untouched. Endgame: a render-server-animated `CAShapeLayer` would make it
vsync-locked for free and delete the CPU Gaussian passes (PERF-4).
**Resolution:** ⏸️ Deferred — a five-site display-link / CAShapeLayer rewrite;
documented in full, not shipped blind without a device to verify vsync
behavior.

### PERF-4 · Glow/stronger-shadow Gaussian passes redrawn per animation tick
*sev medium / conf high / [dev]*
**Where:** `HighlightView.drawBorder` — stronger-shadow blur 25, glow blur 12,
invalidated by the 60Hz glide/pulse and 30Hz style timers.
**Problem:** Up to two CPU `NSShadow` Gaussians over the full overlay backing
store (up to (W+140)×(H+140) at backing scale) recomputed 30–60×/s on the main
thread — the single most expensive per-frame cost.
**Fix (sound):** layer-back the overlay; express stroke + halo as a
`CAShapeLayer` with `shadowColor`/`shadowRadius`/`shadowPath`, updating only the
changed property per tick, so the render server re-rasterizes off the main
thread. **Interim mitigations** if a full rewrite is too big: cache the *black*
stronger-shadow image across party hue ticks (hue-invariant) and only recolor
the glow; render the shadow at lower resolution and upscale; or skip the halo
during an active glide (plain stroke while moving, restore on the final frame).
**Do not** build a geometry+color NSImage cache for party/ants/pulse — those
change the blur inputs every frame.
**Resolution:** ⏸️ Deferred — belongs with the PERF-2 layer rewrite (the
render-server path deletes these CPU Gaussians for free); the shipped PERF-5
hand-drawn redraw gate already removes a chunk of the cost in the meantime.

### PERF-7 · `forceUpdate()` does an AX round-trip on every defaults change
*sev low / conf medium · carried from round two*
**Where:** `FocusHighlighter.forceUpdate()` via the defaults KVO bridge; a
color-well or slider drag fires it continuously.
**Problem:** Each defaults change drops `frameIsDrawn` and re-runs `refresh()`
→ a full resolution, even for a change that only affects *appearance*, not
*placement*. Cheap, and it's what makes toggles apply instantly, but a
continuous drag pays a resolution per tick.
**Fix (only if it shows in a profile):** re-evaluate the full placement path
only for keys that affect *whether/where* the border shows (excluded apps,
maximize-hiding, spotlight mode); for pure-appearance keys (colors, width,
inset, radius, style, glow, shadow) just repaint the current frame
(`highlightWindow.contentView?.needsDisplay = true`) without re-resolving.
Naturally folds into the UX-8 `Settings` facade.
**Resolution:** ⏸️ Deferred — only worth it if it shows in a profile; folds
naturally into the UX-8 Settings facade.

### PERF-8 · The Settings preview repainted 30×/s regardless of what was on it
*sev medium / conf high · round seven*
**Where:** `BorderPreviewView.startRedrawTimer()` / `updateRedrawTimer(visible:)`.
**Problem:** round six fixed the real bug here (the timer used to run forever
after Settings was opened once) by gating it on the window's occlusion state. But
while the window *is* visible the timer was unconditional at 30 Hz, and each tick
redrew the mock desktop, the mock window, the traffic lights and then the real
`HighlightView.drawBorder` — which, with "Glowing border" or "Stronger shadow"
on, runs one or two CPU `NSShadow` Gaussian blurs over the preview's backing
store, on the main thread. Nothing in the preview is time-varying unless party
mode is on or the style is ants/hand-drawn; everything else changes only on a
defaults write, and `syncDynamicUI()` already invalidates the preview for each of
those. So in the default configuration all thirty repaints per second produced an
identical picture, while the Settings window was open — precisely when a user is
watching for the app to feel light.
**Fix:** gate the timer on `partyMode` or an animated `BorderStyle`, and never
under Reduce Motion (all three render statically there), mirroring
`FocusHighlighter.borderStyleNeedsAnimation()` plus `setPartyMode`'s Reduce Motion
branch; re-evaluate from `syncDynamicUI()`; keep occlusion as the outer gate.
Also carry over the hand-drawn seed check from `setBorderStyleAnimating` — the
wobble re-seeds ~3×/s, so 27 of every 30 ticks re-stroke an identical sketch.
**Resolution:** ✅ Implemented → `claude/opus-preview-idle` (PR #71).

### PERF-9 · Excluded-apps rows hit LaunchServices on every cell pass
*sev low / conf high · round seven*
**Where:** `PrefsWindowController.tableView(_:viewFor:row:)`.
**Problem:** every cell configuration calls
`NSWorkspace.urlForApplication(withBundleIdentifier:)`,
`FileManager.displayName(atPath:)` and `NSWorkspace.icon(forFile:)` — three
LaunchServices/disk lookups per row, repeated on every `reloadData` and on
scrolling. `syncDynamicUI` reloads the table whenever the stored list differs,
which the status menu's Exclude item makes happen while the window is open.
**Fix:** a `[String: (name: String, icon: NSImage)]` cache keyed by bundle ID,
invalidated never (an app's name or icon changing mid-session isn't worth
handling) or on `NSWorkspace.didLaunchApplicationNotification`.
**Resolution:** ⏸️ Deferred — real, but the list is typically 0–10 rows and the
cost is only paid while Settings is open; not worth a PR of its own, and it wants
to land with the UX-8 `Settings` facade cleanup.

### PERF-10 · Shake detection calls `NSEvent.mouseLocation` per mouse-move event
*sev trivial / conf high · round seven*
**Where:** `FocusHighlighter.updateShakeMonitor()` — the global `.mouseMoved`
monitor calls `detectShake(at: NSEvent.mouseLocation.x)`.
**Problem:** the monitor already *has* the event, and for a global monitor with
no window `event.locationInWindow` is already in screen coordinates.
`NSEvent.mouseLocation` is an extra window-server query per mouse-move event, and
those arrive at the pointer's full sample rate.
**Resolution:** ⏸️ Deferred — a micro-optimization on an opt-in feature; noted so
whoever touches shake detection next can fold it in. The inherent cost — waking
the process on every mouse move — isn't fixable without dropping the gesture.

---

## C. Visual & layout

### VIS-1 · Border can't straddle two displays
*sev low / conf high / [dev] · round two #1, carried*
**Where:** `FocusHighlighter.swift` single `highlightWindow`;
`HighlightWindow`.
**Problem:** One `NSWindow` has one backing store at one `backingScaleFactor`
(the display it's mostly on). A frame spanning a Retina (2×) and non-Retina
(1×) display renders the mismatched half at the wrong scale and resamples it —
soft/blurry, 1px stroke off the pixel grid. Spotlight already solves this with
a per-screen `DimWindow` pool; the border never got it.
**Fix:** Mirror the pool. Replace `highlightWindow` with
`borderWindows: [HighlightWindow]`; reconcile to `NSScreen.screens.count`
(screen attach/detach already routes through `didChangeScreenParameters` →
`forceUpdate`); add `placeBorder(fullFrame:)` that pins each window to
`screen.frame` (so AppKit assigns that screen's scale) and hands it the full
padded target frame, ordering out windows the frame doesn't touch. Subtlety the
DimWindow case avoids: `HighlightView` can no longer assume
`bounds == padded rect`, so give it a `globalBorderRect` (padded target in
global Cocoa coords) and in `draw` translate it into the window's local space by
the window origin, letting the window bounds clip each slice. Fan
setPartyMode/setBorderStyleAnimating/orderOut/pulse and the three `moveBorder`
paths over the pool (redraw timers only on visible windows); the glide already
drives from one `displayedBorderFrame`, so each tick fans one rect over the
pool.
**Resolution:** ⏸️ Deferred — a per-display border-window pool is a core drawing
rework touching many call sites, unverifiable off-device; the single-window path
is correct on the overwhelmingly common single-display and single-screen-window
cases. Documented as the DimWindow-pool template.

### VIS-3 · Border halo paints over the menu bar / Dock at a screen edge
*sev low / conf high*
**Where:** `HighlightWindow` `.statusBar` level; halo up to 70pt via
`shadowMargin`.
**Problem:** With opt-in glow/stronger-shadow, the halo extends the overlay well
past the frame and paints over Dock icons / the menu bar when the focused
window is near that edge.
**Fix (judgment call):** either lower **only** the border window to a level in
(3, 20) so the halo can't reach the Dock(20)/menu(24) — verify it still floats
over normal app windows and any floating panels you care about — or, more
surgically, clip the stroke/glow/shadow out of the menu-bar/Dock rects in
`HighlightView.draw` (intersect the screen's `frame` minus `visibleFrame`).
Only bites with opt-in effects at an edge.
**Resolution:** ⏸️ Deferred — lowering the border window's level (or clipping to
chrome rects) risks regressing the float-over-app-windows / full-screen-Space
behavior the `.statusBar` level + `.fullScreenAuxiliary` give; it only bites
with opt-in glow/shadow at a screen edge. Left as a documented judgment call.

### VIS-5 · Default square corners overhang the window's ~10pt rounded corners
*sev low / conf high · maintainer taste call*
**Where:** `AppDelegate` registers `cornerRadius` 0; `HighlightView.drawBorder`
takes the square path when radius 0.
**Problem:** At default inset 4 / width 5 the square border's corner tips float
~2pt past the glass at all four corners.
**Fix (opt-in, don't silently change the registered default):** add a "Corner
style" control (Auto / Square / Custom) beside the radius stepper. In
`drawBorder`, Auto computes `radius = max(0, Defaults.windowCornerRadius - inset)`
so the border's corner arc is concentric with the glass and never overhangs;
apply the same computed radius to the stronger-shadow inner-exclude path.
Defensible to leave as-is given the overhang is only ~2pt.
**Resolution:** ⏸️ Deferred — maintainer taste call. Changing the registered
default alters every existing install's look, and the opt-in fix introduces a
new tri-state control a maintainer may want to design deliberately. The
Auto/Square/Custom control and the concentric-radius formula are documented for
a maintainer to add.

### VIS-8 · The Behavior tab was a flat wall of eighteen checkboxes
*sev medium / conf high · round seven*
**Where:** `PrefsWindowController.makeBehaviorTab()`.
**Problem:** the tab had grown a row per feature for five rounds and had no
structure left: sixteen checkboxes, two indented slider rows, a shortcut row, a
picker and a divider, all at uniform 12 pt spacing. "Show border while dragging",
"Spotlight mode", "Shake mouse to find window", "Show overlays in screenshots and
recordings" and "Launch Alan at login" are five unrelated concerns presented as
one undifferentiated list; the only visual hierarchy was the indentation of the
two sliders, and inconsistently so — the find-related checkboxes below the
shortcut row weren't indented although they belong to the same feature. Finding a
setting meant reading all eighteen labels. It is also what drives the window's
height, since UX-11 sizes the window to the tallest tab.
**Fix:** five headed sections — Border, On focus change, Spotlight, Find my
window, General — with tighter intra-group spacing (12 → 6 pt) and generous
spacing before each header (18 pt). The tighter spacing roughly pays for the
headers, so the window barely grows.
**Resolution:** ✅ Implemented → `claude/opus-settings-ui` (PR #72). Worth a
glance on device: that the spacing reads as grouping rather than as gaps.

### VIS-9 · The Settings window can outgrow a small display
*sev medium / conf medium / [dev] · round seven*
**Where:** `PrefsWindowController.buildUI()` — the shortfall computation; the
window's `styleMask` (no `.resizable`); no scroll view in any tab.
**Problem:** UX-11 fixed clipping by growing the window to the tallest tab, with
no ceiling. The Behavior tab's content is on the order of 600 pt; a 13″ MacBook
Air at its default scaled resolution has roughly 740 pt of `visibleFrame` height.
Two or three more rows and the window is taller than the screen — and because it
is neither resizable nor scrollable and is centered, the overflow splits between
the top and bottom edges with no way to reach it. The same failure mode UX-11
fixed, just further out.
**Fix:** clamp the computed height to `NSScreen.main?.visibleFrame.height` minus a
margin, and put each tab's content in a borderless, non-drawing `NSScrollView`
(document view pinned to the clip view's width, so only vertical scrolling is
possible); the `fittingSize` measurement then has to come from the document view.
Making the window `.resizable` with a minimum size is a cheaper half-measure that
at least gives the user an escape hatch.
**Resolution:** ⏸️ Deferred — the scroll-view rework interacts directly with the
auto-height measurement, and getting the clip-view/document-view constraint pair
wrong produces a subtly broken window that only a build reveals. VIS-8's tighter
spacing buys headroom in the meantime, and PR #72 added a targeted re-fit for the
one case that can change the content height after sizing (the Reduce Motion note).
**Worth checking on device** (raised in PR #72's review, not reproducible off it):
open Settings on the Appearance tab, turn Reduce Motion on in System Settings,
then switch to Behavior. `growWindowIfBehaviorTabOverflows` reads
`behaviorStack.fittingSize` while the Behavior tab is *not* the selected one, so
its view is detached from the window and `contentView.layoutSubtreeIfNeeded()`
never reaches it. `fittingSize` solves the constraint system directly rather than
reading a cached layout, and `NSStackView` drops a hidden arranged subview's
spacing constraints as soon as `isHidden` changes, so it should be correct — and
any staleness self-corrects on the next `syncDynamicUI`. If the note does come up
clipped, the fix is `invalidateIntrinsicContentSize()`, **not** the
`needsLayout = true` the review suggested: that schedules a layout pass, which is
not what `fittingSize` reads.

### VIS-10 · The color-source precedence was invisible in Settings
*sev medium / conf high · round seven*
**Where:** `HighlightView.currentBorderColor()` (party → per-app → accent →
light/dark wells); `PrefsWindowController.syncDynamicUI()`.
**Problem:** four controls fed one value through a strict precedence chain, and
the UI showed exactly one link of it — the wells greyed out for accent. Turn on
"Per-app border colors" and the "Use system accent color" checkbox and both wells
stayed fully enabled while doing nothing; turn on "Party mode 🌈" and all three
were inert. No visual signal, no tooltip, no ordering cue. A user who ticks
accent, sees nothing change because per-app was already on, and unticks it again
has been told nothing true.
**Fix:** extend the pattern already used for `focusPulseCheckbox` under spotlight
mode — disable the subordinate controls and give each a tooltip naming the
setting that outranks it. (A "Color source" popup would be cleaner still, but it
swaps four booleans for an enum and the migration isn't worth it.)
**Resolution:** ✅ Implemented → `claude/opus-settings-ui` (PR #72).

### VIS-11 · Reduce Motion silently neutered several settings
*sev low / conf high · round seven*
**Where:** the guards in `moveBorder`/`moveSpotlight`, `HighlightWindow.pulse()`,
`setPartyMode`, `borderStyleNeedsAnimation()`, `GhostBorderWindow.flash`,
`PingWindow.ping`.
**Problem:** the Reduce Motion support is thorough and correct — and was
completely invisible in Settings. With the system setting on, "Animate movement
between windows" and its duration slider, "Pulse border on focus change", the
marching ants and hand-drawn animation and party mode's hue cycle all become
no-ops while every control stays enabled and unannotated. From the user's side
the app looks broken in exactly the way an accessibility setting should not make
it look.
**Fix:** a single secondary-color note at the foot of the Behavior tab, shown only
while `accessibilityDisplayShouldReduceMotion` is true, refreshed on
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
**Resolution:** ✅ Implemented → `claude/opus-settings-ui` (PR #72), including a
window re-fit so a mid-session toggle can't clip the note off the bottom of the
tallest tab.

### VIS-12 · The app icon set has one slot filled
*sev low / conf high / [dev] · round seven*
**Where:** `Alan/Assets.xcassets/AppIcon.appiconset/Contents.json` — nine entries
with no `filename`, one 512×512@2x pointing at `Icon.png`.
**Problem:** the catalog declares the full mac icon ladder and supplies only the
1024 px bitmap, which produces "unassigned children" build warnings and leaves
macOS to downsample a single image for the 16 pt Dock/Finder/About sizes. A
1024→16 px box filter of a detailed icon is usually mush. (Separate from the
*status item* icon, which is a template SF Symbol and is fine.)
**Fix:** export the ladder from the source artwork (16/32/128/256/512, @1x and
@2x), or reduce the catalog to a single-size icon entry so Xcode stops warning.
**Resolution:** ⏸️ Deferred — needs the source artwork and a look at the result at
16 pt; not something to change blind.

---

## D. Interface & UX

### UX-7 · No test target despite pure, permission-free seams
*sev low / conf high*
**Where:** `perAppColor` (`Extensions.swift`); `cocoaRect`, `windowFillsScreen`/
`framesRoughlyEqual`, smoothstep glide, shake (`FocusHighlighter.swift`);
`carbonModifiers` (`PrefsWindowController.swift`); `wobbleNoise`
(`HighlightWindow.swift`).
**Problem:** No test target (verified in `project.pbxproj`), yet these pure
functions encode invariants that regress silently (hash stability across
launches, coordinate math, clamping) and would run headless on the existing
macOS CI runner.
**Fix:** Add an `AlanTests` XCTest bundle (logic tests, no app host) and a
`xcodebuild test` CI step (`ENABLE_TESTABILITY=YES` already set). `@testable`
doesn't expose `private`, so lift the `private` seams to internal (or refactor
the two NSScreen-dependent ones to take injected geometry). Start with the four
unambiguously pure ones: `perAppColor`, `carbonModifiers`, `wobbleNoise`,
`framesRoughlyEqual`.
**Resolution:** ⏸️ Deferred — adding a whole new *target* means hand-editing
`project.pbxproj` (the file-system-synchronized group auto-includes source
*files* but not a new build target), which is error-prone and unbuildable
off-device; best done with Xcode in hand. The pure seams to test and the
private→internal lifts are documented.

### UX-8 · Scattered `UserDefaults` reads / no `Settings` facade
*sev low / conf high · round two, carried · refactor*
**Where:** clamps duplicated in `drawBorder` (width/inset/radius), `DimView` and
`BorderPreviewView` (dim level), `makeGlideTimer` (duration), plus raw reads
across three classes at draw time.
**Problem:** Keys, default values, and clamping are duplicated at many read
sites (30–60×/s during drags), and the observed-keys list is easy to forget to
update.
**Fix:** A small `Settings` facade centralizing keys, clamping, and defaults in
one place; removes the duplicated clamps and makes `allObservedKeys`
authoritative. Pure internal cleanup; pairs well with UX-7 (so the clamps are
covered) and enables PERF-7.
**Resolution:** ⏸️ Deferred — broad cross-file refactor with wide merge surface;
higher value once UX-7's tests exist to catch regressions.

### UX-10 · No localization
*sev low / conf high*
**Where:** no `.strings`/`.xcstrings`; literals in `AppDelegate`, all of
`PrefsWindowController`, the recorder.
**Problem:** The app can't be localized without editing source.
**Fix:** Add a `Localizable.xcstrings` catalog; route literals through
`String(localized:)` (positional format args for interpolated app names, e.g.
the `Exclude "…"` title); enable Base Internationalization on `MainMenu.xib`.
Mechanical, stageable, no runtime impact for the English build.
**Resolution:** ⏸️ Deferred — large mechanical churn with no behavior change,
lowest priority; best staged with Xcode's String Catalog tooling.

### UX-12 · The contrast casing had no UI and no documentation
*sev medium / conf high · round seven*
**Where:** `Key.contrastCasing` (`Constants.swift`),
`HighlightView.contrastCasingActive` (`HighlightWindow.swift`). Those two files
were, before PR #72, the only places it appeared in the whole tree.
**Problem:** the feature shipped, worked, was in `allObservedKeys` (so it applied
live), and was reachable only by someone who read the source and ran
`defaults write studio.retina.Alan contrastCasing -bool true`. It is also the
app's answer to the single most common failure of a colored border — content the
same tone as the border — so the people who need it are the least likely to find
it. The automatic path (system Increase Contrast on) covers users who have
already configured macOS for contrast, not users who just have a busy desktop.
**Fix:** an Appearance-tab checkbox plus a README scripting line. Where Increase
Contrast forces the casing on, the checkbox shows as on and locked with a tooltip
saying why, rather than sitting unchecked beside a visible casing; only the
displayed state is touched, never the stored preference.
**Resolution:** ✅ Implemented → `claude/opus-settings-ui` (PR #72).

### UX-13 · The status menu was thinner than the feature set
*sev medium / conf high · round seven*
**Where:** `AppDelegate.setupStatusItem()` / `menuNeedsUpdate(_:)`.
**Problem:** the status item is the app's primary — and in hidden-Dock mode, only
— interface, and exposed seven items for a feature set that had roughly tripled
since it was written.
- **Paused was invisible.** The icon was the same `macwindow` glyph either way,
  so the natural reaction to "my borders are gone" — glancing at the menu bar —
  told the user nothing.
- **Exclusion was one-way.** "Exclude 'Safari'" greyed out once Safari was
  excluded; there was no "Include", so undoing a one-click action cost a trip
  through Settings to find and remove the row.
- **Spotlight mode was buried.** One of the app's two headline modes, and the one
  toggled situationally (presenting, screenshotting, focusing), four clicks deep.
- **"Find my window" was unreachable** without enabling and learning a chord —
  which is also what left the hotkey preference undiscoverable.
- **No link to the project page**, for an app whose update story is a GitHub zip.
**Fix:** dim the status item (`button.appearsDisabled`) with an explanatory
tooltip while paused, kept in sync by a KVO observation; make the exclude item a
toggle; add checkmarked "Spotlight Mode", "Find My Window" and "Alan on GitHub…".
**Resolution:** ✅ Implemented → `claude/opus-status-menu` (PR #73).

### UX-14 · "Check for Updates…" gave no in-flight feedback
*sev low / conf high · round seven*
**Where:** `AppDelegate.checkForUpdates(_:)` → `UpdateChecker.check` (15 s
`timeoutInterval`).
**Problem:** the menu closed and nothing happened — for up to fifteen seconds on a
bad network — then an alert appeared out of nowhere. Meanwhile every extra click
started another request, and each completion ran its own modal alert, so three
impatient clicks queued three alerts.
**Fix:** an `isCheckingForUpdates` flag: retitle the item to "Checking for
Updates…" and disable it while a request is in flight (`menuNeedsUpdate` already
runs on every menu open, so the title is free), and drop re-entrant calls.
**Resolution:** ✅ Implemented → `claude/opus-status-menu` (PR #73).

### UX-15 · The Dock icon flashed at login when "Hide Dock Icon" was on
*sev low / conf medium / [dev] · round seven*
**Where:** `AppDelegate.applicationDidFinishLaunching` called
`applyActivationPolicy()`; the generated Info.plist has no `LSUIElement`.
**Problem:** the app was born `.regular` and only became `.accessory` inside
`didFinishLaunching`, by which point AppKit had already put it in the Dock and
given it the menu bar. For a login item — the intended configuration for this app
— that is a Dock icon that appears and vanishes on every boot.
**Fix:** move the call (and the defaults registration) to
`applicationWillFinishLaunching`, which runs before the app is presented.
`LSUIElement` is not an option: the policy has to stay switchable at runtime,
which is the whole point of the live toggle.
**Resolution:** ✅ Implemented → `claude/opus-status-menu` (PR #73).

### UX-16 · `hideDock` written externally didn't apply until relaunch
*sev low / conf high · round seven*
**Where:** `Key.hideDock` was deliberately excluded from `Key.allObservedKeys`;
the README documented the caveat as `# applies on relaunch when set externally`.
**Problem:** the reasoning was right — the highlighter shouldn't own the
activation policy — but the conclusion wasn't. Every other key in the domain
applies live, which is the whole selling point of the README's Scripting section;
this one silently didn't, so a Shortcuts action or Stream Deck button that hid the
Dock icon appeared to do nothing.
**Fix:** `AppDelegate` observes the key itself (KVO on `UserDefaults`, the same
mechanism `DefaultsObservationBridge` uses) and re-applies the policy on change.
Ownership stays where it belongs and the README's asterisk goes away.
**Resolution:** ✅ Implemented → `claude/opus-status-menu` (PR #73).

### UX-17 · `applicationSupportsSecureRestorableState` wasn't implemented
*sev trivial / conf high · round seven*
**Problem:** on macOS 14+, an `NSApplicationDelegate` that doesn't implement it
logs `WARNING: Secure coding is not enabled for restorable state!` on every
launch. Alan restores no state, so the answer is unambiguously `true`.
**Resolution:** ✅ Implemented → `claude/opus-status-menu` (PR #73).

### UX-18 · Regular mode ships a stock File/Edit/Window menu of no-ops
*sev low / conf high · round seven*
**Where:** `Alan/Base.lproj/MainMenu.xib`.
**Problem:** with the Dock icon shown, Alan has a full menu bar containing
File ▸ Close, Edit ▸ Undo/Redo/Cut/Copy/Paste/Delete/Select All, and
Window ▸ Minimize/Zoom/Bring All to Front. The app has exactly one ordinary
window — Settings, which has no text editing beyond three number fields and no
document model — so almost every one of those items is permanently greyed or
inert. It is the Xcode template's menu bar, not Alan's.
**Fix:** trim the xib to Alan ▸ (About, Settings…, Services, Hide, Quit),
Window ▸ (Minimize, Close), and add a Help ▸ GitHub item.
**Resolution:** ⏸️ Deferred — editing a xib by hand off-device is exactly where a
mistake surfaces as a missing menu at runtime rather than a build failure, and the
payoff is cosmetic. Worth doing with Interface Builder open.

### UX-19 · The About panel has no copyright line
*sev trivial / conf high · round seven*
**Where:** `INFOPLIST_KEY_NSHumanReadableCopyright = ""` in both build configs.
**Problem:** `orderFrontStandardAboutPanel` renders the version and nothing else.
For a fork of an MIT-licensed project, the About panel is the natural place to
carry "© 2025 Tyler Hall · MIT".
**Resolution:** ⏸️ Deferred — a two-line `project.pbxproj` edit, but the exact
attribution wording is the maintainer's call, not a reviewer's.

### UX-20 · Only one action is bindable to a global shortcut
*sev medium / conf high · round seven*
**Where:** `FocusHighlighter.registerFindMyWindowHotkey` (a single
`EventHotKeyID(signature: 'ALAN', id: 1)`, a single `hotKeyRef`, and a handler
that ignores the incoming hotkey ID and always calls `flashBorder`);
`ShortcutRecorderButton` (hardcoded to the three `findMyWindow*` defaults keys).
**Problem:** "find my window" is the *least* likely of Alan's actions to want a
chord. Pausing (before a screen share) and toggling spotlight (before a demo) are
the situational actions, and neither can be bound. The machinery is 90 % of the
way there — registration failure, reserved combos, recording suspension and
function keys are all handled — but every piece of it is singular.
**Fix:** parameterize. Give `ShortcutRecorderButton` its three defaults keys via
`init`; keep a `[EventHotKeyID.id: () -> Void]` table in the highlighter; read the
fired ID in the Carbon handler with
`GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)`
and dispatch; register/unregister each entry independently.
**Resolution:** ⏸️ Deferred — the Carbon dispatch idiom and a three-recorder-row
Behavior tab both want a compiler and a keyboard. Documented in enough detail to
implement directly; **this is the highest-value next feature.** PR #73's
status-menu Spotlight and Find My Window items cover part of the need in the
meantime.

---

## E. Missing features

### FEAT-3 · Automatic update check
*sev medium / conf high · round seven*
**Where:** `UpdateChecker.swift` (documented as the FEAT-2 follow-up), `AppDelegate`.
**Problem:** the manual check shipped, but nothing prompts a user who never opens
the menu. That matters more for Alan than for most apps because of UX-6: an
ad-hoc-signed update can reset the Accessibility grant, so the population most
likely to be on a stale build overlaps almost exactly with the population that
once watched Alan stop drawing borders and never diagnosed it. A background
utility with a hidden Dock icon can run a year-old build indefinitely.
**Fix:** an opt-in weekly check. `Key.autoCheckUpdates` (registered `false`),
`Key.lastUpdateCheck` and `Key.skippedUpdateVersion`. Announce only
`.updateAvailable`, and only for a version that isn't the skipped one — silence
is the right outcome for "up to date" and for a network failure, since nobody
asked. Alert offers Download / Later / Skip This Version. Record the timestamp
before the request regardless of outcome, so a flaky network can't become a
request loop; treat a future timestamp as due, so a backwards clock can't
suppress checks forever; delay the launch check so it can't compete with the
permission flow, and never open a modal session inside one.
**Resolution:** ✅ Implemented → `claude/opus-auto-update` (PR #74).

### FEAT-4 · No way to restore default settings
*sev low / conf high · round seven*
**Problem:** ~25 stored settings, several of which (party mode, an extreme dim
level, a wide glowing border) can leave the app looking broken, plus a colour
precedence a user can talk themselves into a corner with. The only recovery was
`defaults delete studio.retina.Alan` in a terminal — which also, silently, erases
the excluded-apps list.
**Fix:** a "Restore Defaults…" status-menu item that confirms first, naming what
it will discard, then removes every `Key.*` from the domain so the values
registered at launch take over again. Cancel is the default button. Two
deliberate omissions: `hadAccessibilityGrant` (a record, not a setting — clearing
it makes a re-grant read as a first run) and Launch at Login (it lives in
`SMAppService`, and un-registering a login item isn't something a settings reset
should do behind the user's back).
**Resolution:** ✅ Implemented → `claude/opus-status-menu` (PR #73), together with
a fix for a latent bug it exposed: `syncDynamicUI` never re-read the stored border
colors, so a stale color well would write its old value back over a restored one.

### FEAT-5 · No inclusion list
*sev low / conf medium · round seven*
**Problem:** exclusions can't express "only highlight my editor and my terminal".
For a user who wants Alan for two apps, the list is the wrong shape and has to be
maintained forever as they install things.
**Fix:** a mode switch on the Excluded Apps tab — "Never highlight these apps" /
"Only highlight these apps" — reusing the same list and the same `refresh()`
check with the sense inverted. Cheap: the tab already has the table, the
drag-and-drop and the add/remove buttons.
**Resolution:** ⏸️ Deferred — small and self-contained, but it changes the meaning
of an existing stored list, so it wants a migration story (`Key.appListMode`
defaulting to `exclude`) and a maintainer's opinion on the tab's copy.

### FEAT-6 · Per-app settings beyond color
*sev low / conf low · round seven*
**Problem:** per-app *colors* exist; per-app style, width and spotlight don't.
"Thick red border on the production terminal, thin grey everywhere else" is the
canonical ask.
**Resolution:** ⏸️ Deferred — a genuine feature with a real settings-UI design
problem behind it (per-app override tables are hard to make simple). Noted, not
specified. IDEA-21's colour legend would be the natural place to hang it.

---

## F. Ideas — novel, delightful, quirky

### IDEA-5 · Spotlight and border at the same time
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.showHighlight`, pulse guard.
**Fix:** `Key.spotlightWithBorder` (default off, in `allObservedKeys`); split the
spotlight branch to call `moveSpotlight` *and* `moveBorder` (with the
border-branch timer setup) when on; elevate the border to `.statusBar + 1` so it
stays above the per-screen dim windows that re-front each glide tick (reset when
off); relax the pulse guard to allow the pulse when `spotlightWithBorder`; add a
Behavior-tab checkbox indented under spotlight and un-gate the pulse checkbox;
draw the border in the preview's spotlight branch too. Verify on device the
border stays above all `DimWindow`s across a full glide.
**Resolution:** ⏸️ Deferred — needs on-device confirmation that the elevated
border stays above every per-screen DimWindow across a full glide before
shipping; the z-order-across-glide behavior is exactly what can't be verified
off-device.

### IDEA-6 · Per-app colors sampled from the app icon's dominant color
*sev low / conf high / [dev] · also in round two*
**Where:** `Extensions.perAppColor`.
**Fix:** Keep the djb2 path as a guaranteed fallback; layer icon sampling in
front, cached per bundle ID (`[String: CGFloat?]`, nil = "failed/monochrome, use
hash" — memoize both; drawBorder runs at 30–60Hz so uncached per-draw sampling
is unacceptable). Sample the 32×32 icon rep into a bitmap context, build a
coarse saturation-weighted hue histogram skipping near-gray/low-alpha pixels.
**Distinctiveness guards:** top hue bin < ~35% of weight (gradient/rainbow) or
max saturation < ~0.3 (Terminal/monochrome) → fall back to the hash; keep the
icon *hue* but render at the hash path's fixed saturation/brightness so
legibility and light/dark behavior match today. Worst case degrades to the
current hash, never a pile of indistinguishable blues.
**Resolution:** ⏸️ Deferred — needs on-device tuning of the icon-sampling
distinctiveness thresholds against real app icons.

### IDEA-7 · Hold-to-spotlight quasimode on the find-my-window hotkey
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.registerFindMyWindowHotkey`, handler.
**Fix:** Install the handler for both press and release (2-element
`EventTypeSpec` array, dispatch on `GetEventKind`), gate behind
`Key.holdToSpotlight`; on press start a ~0.25s timer that, if still held, enters
a transient dim; on release invalidate and either `flashBorder` (tap) or
restore. Route dim-vs-border decisions through a `spotlightActive` accessor
(`heldSpotlightActive || Key.spotlightMode`) at the two sites, so the normal
`refresh()` path follows focus for free. **Safety net** (release can drop if
modifiers lift first): a max-hold cap timer and a transient `.flagsChanged`
monitor, both calling the same cleanup. Verify `kEventHotKeyReleased` fires on
device; the safety net makes a dropped release non-fatal.
**Resolution:** ⏸️ Deferred — needs on-device confirmation that
`kEventHotKeyReleased` fires reliably for this registration, plus the
modifier-drop safety net; Carbon release semantics can't be verified off-device.

### IDEA-10 · Squash-and-stretch the border as it glides
*sev low / conf high · pure polish*
**Where:** `FocusHighlighter.makeGlideTimer` (shared with `moveSpotlight`).
**Fix:** Thread a `stretch: Bool = false` param; pass `true` only from
`moveBorder`. In the else-branch, from the raw `t` (in scope) compute a
`sin(t·π)`-enveloped deform gated on travel distance (> ~80pt) and capped
(~24pt), growing the dominant axis and shrinking the other, re-centered on the
eased rect. `updateFrame` always insets by `-shadowMargin`, so a larger rect
just makes a larger window — no clipping. `moveBorder` bypasses the glide under
Reduce Motion, so the stretch is unreachable there. Tune on device.
**Resolution:** ⏸️ Deferred — pure aesthetic polish, and always-on for
`moveBorder`; the stretch envelope can only be tuned on-device, so shipping it
blind risks an off feel.

### IDEA-11 · Optional quiet click on focus change
*sev low / conf high · accessibility*
**Where:** `FocusHighlighter.refresh()` focusChanged branch.
**Fix:** `Key.focusSound` (register false; *not* in `allObservedKeys` — read
live); a preloaded `NSSound` (bundle a short asset; guard the optional so a
missing sound is a silent no-op) at low volume; in the `focusChanged` branch, if
on and > 0.3s since last play, `stop()` then `play()`. For genuine accessibility
value, compute a lightweight focus-changed check *before* the
maximized/full-screen returns so the cue fires there too. Add a Behavior-tab
checkbox (not gated on spotlight — audio is orthogonal). Optional `.alignment`
haptic sibling. Off by default.
**Resolution:** ⏸️ Deferred — needs a bundled short sound asset (named system
sounds aren't guaranteed present, and the review explicitly cautioned against
relying on them); an accessibility nicety for a follow-up.

### IDEA-12 · Soft-edged "stage light" spotlight
*conf high that it would look better / conf high that the naïve implementation is too slow · round seven*
**Where:** `DimView.draw`.
**Why:** spotlight mode cuts a hard-edged rounded rectangle out of a flat dim —
closer to a mask than a light. A feathered edge (the dim ramping to zero over
~20 pt around the window) would make it an actual stage light, which is the
metaphor the code's own comments already reach for.
**Why it isn't done:** with the current CPU drawing that means either N stacked
annuli (~14 even-odd fills over a full-screen backing store, per display, per
glide frame) or one `NSShadow` Gaussian over a full-screen shape — and
`DimWindow.update`'s own comment already identifies refilling a 5K backing store
at 60 Hz as the app's single largest cost. The right implementation is a
layer-backed dim with a `CAGradientLayer` mask, which is the same rewrite
PERF-2/PERF-4 want.
**Resolution:** ⏸️ Deferred — **the first thing to build on top of the PERF-2
layer rewrite.** It is the change that would most visibly improve the app.

### IDEA-13 · Double-tap a modifier to find the window
*conf medium · round seven*
macOS itself trains this gesture: press and release a bare modifier twice inside
~400 ms with no other key in between, and the border flashes. It costs no chord
to memorize and can't collide with another app's shortcut, because nothing is
*consumed* — strictly additive to the existing hotkey.
**Sketch:** a global `.flagsChanged` monitor (the Accessibility grant is already
held) gated on `Key.doubleTapModifier` (off by default; a picker for ⌃/⌥/⌘/⇧).
Track transitions of the chosen flag; require press→release→press inside the
window; abort the sequence on any `.keyDown` or on any *other* modifier
appearing. Reuse the shake cooldown to prevent repeats. The false-positive risk
is real (⌘ is tapped constantly), which is exactly why it's opt-in and why ⌃ is
the sensible default.

### IDEA-14 · A focus-switch counter in the status menu
*conf high · pure whimsy, near-zero cost · round seven*
Alan already knows every time focus changes — it is the event the whole app is
built on. A disabled menu item reading "142 switches today" costs one counter
incremented in the `focusChanged` branch, one date stamp to roll it over at
midnight, and one line in `menuNeedsUpdate`. It's a genuinely interesting number
nobody has, it makes the menu feel alive, and it fits the app's premise exactly:
*where is your attention going?* Optional escalation: a "most-visited app today"
line, or a tiny sparkline. Keep it local, keep it unsent, keep it resettable.

### IDEA-17 · Idle "breathing"
*conf medium / [dev] · round seven*
After N minutes with no keyboard or mouse input, the border begins a very slow,
low-amplitude width breathe (±1 pt over ~4 s), stopping on the first event.
Coming back to the machine, your eye is drawn to where you left off before you
have to think about it. Cheap — the pulse machinery already exists, and the
animation only runs while idle, which is exactly when the CPU is free — and it
degrades to nothing under Reduce Motion. The risk is that it reads as a
distraction rather than a welcome, which is a taste call best made on a device.

### IDEA-19 · "Where was I?" — ghost the last few windows
*conf medium · round seven*
`GhostBorderWindow` already draws a fading copy of the border at an arbitrary
rect. Keep a small ring buffer of the last 3–4 focused frames and, on a long
press of the find hotkey, flash all of them at once at decreasing opacity — a
visual "recently here" map across the screen. The focus trail generalized from
one step to a short history, reusing everything except the buffer. Depends on
UX-20's press/release handling (or IDEA-7's, which is the same mechanism).

### IDEA-21 · A per-app color legend
*conf high · round seven*
Per-app colors are pitched in the README as "you learn the colors within a day".
A legend makes it an hour: a small panel — a Settings tab, or a status-menu item
— listing currently running apps with their derived swatch. It also fixes BUG-15,
since the Appearance preview would finally have something honest to show for the
per-app checkbox, and it is the natural place to hang FEAT-6's per-app overrides
later. Cost: one `NSTableView` over `NSWorkspace.shared.runningApplications`
filtered to `.regular` activation policy, using the existing
`NSColor.perAppColor(for:)`.

---

## G. Project & infrastructure
*round seven*

- **No test target** (UX-7). The pure seams keep multiplying; the two best new
  candidates are `UpdateChecker.compareVersions` (pure, with documented edge
  cases like `2.10.0` vs `2.9.0` and `-beta` suffixes) and `isTopEdgeChrome`
  (pure geometry with six tuned constants and a long comment explaining why each
  one is what it is — precisely the kind of thing that regresses silently).
- **CI builds but doesn't lint or analyze.** `xcodebuild analyze` on the same
  runner, or a SwiftLint step, would catch the class of thing a human reviewer
  spends attention on. Warnings are not errors, so a warning introduced by a PR
  is invisible unless someone reads the log.
- **No CHANGELOG.** Releases use `--generate-notes`, which produces a commit
  list; for an app whose updates can require a manual Accessibility re-grant, a
  human-written "what changed / do you need to re-authorize" note has real value.
- **The automated PR reviewer is rate-limited.** Opening several PRs in quick
  succession exhausts the Z.ai quota and the review job fails with HTTP 429 (seen
  on PR #74). Not a code problem, but worth knowing before judging a red check:
  the `Build Alan.app` job is the one that matters.
- **`ENABLE_USER_SCRIPT_SANDBOXING = YES` and `ENABLE_HARDENED_RUNTIME = YES`**
  with `ENABLE_APP_SANDBOX = NO` — correct for an app that needs the
  Accessibility API. No entitlements file exists, which is right.
- **Developer ID + notarization remains the highest-leverage non-code change.**
  It would delete UX-6, most of FEAT-3's urgency, and half the install friction
  in one move.

---

## What to do next, in order

1. **PERF-2 + PERF-4** — the display-link / `CAShapeLayer` rewrite. The only
   change that makes the app *feel* different, it deletes the main-thread
   Gaussians, and it unlocks IDEA-12 and VIS-1.
2. **UX-20** — bindable Pause and Spotlight shortcuts. The highest-value feature
   the existing machinery is already 90 % of the way to.
3. **UX-7** — a test target, before the pure-geometry helpers grow any more
   tuned constants.
4. **VIS-9** — scrollable or clamped Settings, before the Behavior tab outgrows
   a laptop screen again.
5. **IDEA-12** — the stage light, once (1) makes it affordable.

---

## Assessed and rejected in prior rounds (kept for the record)

- **Menu-bar icon tinted with the frontmost app's color** — the menu bar is the
  one place the system dictates monochrome template images; a colored icon reads
  as broken.
- **"Peek through the dim" mouse-hover for spotlight mode** — fights the premise
  of the mode (the dim is meant to *resist* attention drifting).
- **Helper/agent-process frontmost window not seen by the pid-scoped z-order
  lookup** — the meaningful cross-process case (out-of-process open/save panel
  service) is already handled by the non-pid-scoped
  `kAXFocusedUIElementAttribute` path.
- **A reduce-motion branch for the focus chip's fade** (round seven) — the chip
  appears and fades in place without moving, and cross-fades are what Apple's
  guidance suggests *substituting* for motion, not something to remove. The
  reduce-motion branches in `GhostBorderWindow` and `PingWindow` exist because
  those animations genuinely move.
- **Growing the Settings window's width in the Reduce-Motion re-fit** (round
  seven) — the window's width is a fixed literal that nothing changes, so the
  overflow it guards against can't occur; and it would let a stack's fitting
  width widen the window as a side effect of an unrelated toggle.
