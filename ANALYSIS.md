# Alan — consolidated analysis & work list

This document consolidates the two standing review notes — `awesome.md`
(round two, v2.1) and `fable-is-awesome.md` (round five, `bb0cbe8`) — into a
single deduplicated, actionable list. Everything that shipped in rounds
one–four (Reduce Motion support, the live-Dock toggle, the pause toggle, the
always-on status item, marching-ants and hand-drawn styles, the recordable
hotkey, spotlight/shake/space-flash, the round-four merges, …) has been
removed; duplicate entries across the two documents are merged; and each
entry keeps enough detail to implement from directly.

Every entry carries a **Resolution** line. Entries implemented in this pass
ship each on their own branch off `main`; entries deliberately deferred say
why (usually: a rewrite too large to land safely without a macOS build, or a
maintainer taste call).

Legend: **sev** = severity · **conf** = static confidence · **[dev]** =
needs on-device confirmation.

---

## A. Bugs

### BUG-1 · Copy-window headline: raw-bounds last resort
*sev high (if it hits the Finder case) / conf high / [dev]*
**Where:** `FocusHighlighter.swift:1038` (`currentFocusedWindow`), `:1081`,
`:663`/`:700`/`:723` (`refresh`).
**Problem:** Round four resolves the frontmost window from the window-server
z-order (`topmostWindowBounds`) and matches it to an `AXWindow` via
`appWindowMatching`. When that match fails — the panel is a sheet reached via
`AXSheets` not `kAXWindowsAttribute`; its `AXFrame` differs from CGWindow
bounds by >4pt; it is past the `.prefix(20)` cap; or the `AXFrame` read times
out — control falls through to `:1090` and returns the **keyboard-focus
window behind the panel**, discarding the correct `topBounds`. No retry is
armed (the resolution is non-nil, just wrong), so the border stays on the
wrong window until an unrelated event. This is the still-open core of the
"copy window sometimes gets no border" report.
**Fix:** The border is a visual overlay — it needs a frame, not a handle.
1. Change the signature to `-> (element: AXUIElement?, frame: CGRect)?`.
2. In the z-order block, after the `appWindowMatching` attempt (`:1081-1084`),
   add `return (nil, topBounds)` as the final fallback (with a comment).
   `topBounds` is already in `AXFrame` top-left global space, so
   `cocoaRect(fromAXRect:)` converts it correctly.
3. Thread the optional element through `refresh()`: guard the full-screen
   skip at `:700` on `if let windowElement, isFullScreen(windowElement), …`
   (a raw-bounds panel is never full-screen; `hideBorderWhenMaximized` at
   `:712` already uses only `windowFillsScreen(cocoaFrame)`); `isSameWindow`
   (`:918-921`) is already nil-safe so dedup/`focusChanged` degrade to frame
   comparison; `lastFocusedWindow = windowElement` stores the optional.
4. `flashBorder()` (`:375`) already ignores the element — unchanged.
Leave the cross-process branch (`:1048`) and drag gate (`:1059`) untouched.
This removes the wrong-window outcome for **all** nil-return causes at once,
which is why BUG-3/BUG-4 below are only hardening on top of it.
**Resolution:** _Pending._

### BUG-2 · Copy-window: single 0.25s settle-refresh, no retry on wrong-but-non-nil
*sev medium / conf high / [dev]*
**Where:** `FocusHighlighter.swift:434` (`scheduleSettleRefresh`), `:425`.
**Problem:** `AXWindowCreated` fires before `CGWindowListCopyWindowInfo`
lists the new panel as topmost, so the synchronous `refresh()` samples stale
z-order. The only net is a **single** non-repeating 0.25s timer, coalesced to
one retry per burst. If the window server hasn't caught up by 0.25s the lone
retry also misses, and `scheduleResolutionRetry` is only reached on a nil
resolution (this returns non-nil). Net: the copy-panel case gets exactly one
0.25s retry — hence the intermittency.
**Fix:** Turn the single shot into a short bounded chain. Add
`private var settleRefreshRemaining = 0`; in `handleAXNotification()` set it
to `3` before `scheduleSettleRefresh()`; rewrite `scheduleSettleRefresh()` to
re-arm while budget remains at back-offs `[0.12, 0.3, 0.6]` (index
`min(3 - settleRefreshRemaining, 2)`), decrementing and chaining the next
attempt in the timer body. Self-terminating (stops at 0), no polling (AX
posts no continuous notifications during a drag). Gives the case ~3 retries
out to ~1s.
**Resolution:** _Pending._

### BUG-3 · Copy-window: `appWindowMatching` cap
*sev low / conf medium / [dev]*
**Where:** `FocusHighlighter.swift:1137-1150`, cap at `:1144`.
**Problem:** The loop returns on the first frame match, so the `.prefix(20)`
cap only limits how many windows are *examined* — a match past index 20 is
never seen (window-hoarder apps).
**Fix:** Raise the cap to ~40. **Do not** loosen the 4pt `framesRoughlyEqual`
tolerance (AXFrame and CGWindow bounds are the same frame in the same space;
loosening risks matching a wrong same-size window). Sheets via
`kAXSheetsAttribute` are optional/low-value (a focused sheet is already
resolved upstream via `kAXTopLevelUIElementAttribute`). Largely subsumed by
BUG-1's fallback, which handles every nil-return cause.
**Resolution:** _Pending._

### BUG-4 · Copy-window: `topmostWindowBounds` layer ceiling
*sev low / conf medium / [dev]*
**Where:** `FocusHighlighter.swift:1167`.
**Problem:** The filter admits CGWindow layers `0...3`, excluding
modal-panel level (`kCGModalPanelWindowLevel` = 8). A frontmost dialog at
that level is skipped, and the function may then return a *lower* window that
coincidentally frame-matches a background window.
**Fix:** Raise the ceiling to `<= 8` (still skips utility 19 / Dock 20 /
menu 24 / statusBar 25 / popUpMenu 101). Low risk — the bounds are
cross-validated downstream by the three matchers. **Do not** lower the 40×40
size floor. Verify on device that real modal panels report layer 8.
**Resolution:** _Pending._

### BUG-5 · Copy-window: no signal for a re-ordered pre-existing window
*sev low / conf low / [dev]*
**Where:** `FocusHighlighter.swift:482-492` (observer registrations).
**Problem:** A window that already exists and is merely `orderFront()`-ed
(neither key nor main, not newly created) posts none of the observed
notifications, and AX has no reliable z-order-change signal — so re-showing a
cached palette/progress window gets no border until something unrelated
fires. Partly masked by the global `leftMouseUp` monitor (`:132-141`).
**Fix:** Recommended resolution is to **document as a platform limitation** —
a poll would fight this file's deliberate idle-wakeup minimization. If ever
wanted, a bounded frontmost-and-idle-gated ~1.5s reconciliation timer that
pre-checks `topmostWindowBounds` against a cached value and only calls
`refresh()` on a change (never during a drag; reset on screen-param change).
**Resolution:** _Pending._

### BUG-6 · Glide timers resurrect a hidden overlay
*sev medium / conf medium / [dev]*
**Where:** `FocusHighlighter.swift:753` (`showHighlight`), `:373`
(`flashBorder`).
**Problem:** `showHighlight()` hides one overlay but doesn't cancel the
*other* mode's in-flight glide timer (spotlight branch never invalidates
`borderAnimationTimer`; border branch never invalidates
`spotlightAnimationTimer`). Toggling `spotlightMode` within ~0.25s of a
focus/frame change (while `animateMovement` is on) leaves the opposite mode's
glide running, and each tick's `orderFrontRegardless` (`:64`, `:422`) flickers
the just-hidden overlay back on. Separately, `flashBorder()` guards only
`flashTimer == nil` and never cancels a running glide, so a glide still
running when the flash starts (e.g. the space-change flash 0.2s after a
switch) keeps re-fronting and defeats the flash's off-phase `orderOut`.
**Fix:** In `showHighlight`, cancel the *opposite* timer before drawing (do
**not** clear `displayedBorderFrame`/`displayedCutout` — a later switch-back
needs a glide-from position). In `flashBorder`, right after the `flashTimer`
guard, invalidate both `borderAnimationTimer` and `spotlightAnimationTimer`
so the flash is the sole overlay driver. `hideHighlight` already cancels both.
**Resolution:** _Pending._

### BUG-7 · Permission-alert `abortModal()` outside a modal session
*sev low / conf medium / [dev]*
**Where:** `AppDelegate.swift:226-230` (poll timer), loop `:237-247`.
**Problem:** The poll timer runs on `.common` for the whole function and
calls `NSApp.abortModal()` whenever trust turns true. Between `runModal()`
iterations (each "Open System Settings" click, which pumps the run loop via
`openAccessibilitySettings()`) there is no modal session; a grant landing in
that gap fires `abortModal()` with no session — raising
`NSAbortModalException` (lost/duplicated response, or a crash under
`NSApplicationCrashOnExceptions`) on the first-launch path.
**Fix (two lines):** guard the callout —
`if AXIsProcessTrusted(), NSApp.modalWindow != nil { NSApp.abortModal() }`.
During `runModal()` the alert is `modalWindow` so the abort still dismisses;
in the gaps `modalWindow` is nil so no stray exception.
**Resolution:** _Pending._

### BUG-8 · `flashBorder` replays a stale frame
*sev low / conf high*
**Where:** `FocusHighlighter.swift:375-376`, replayed at `:411`/`:379`.
**Problem:** The flash reads the focused window once and replays that rect
for every "on" phase of the ~0.7s strobe; a window that moves/closes mid-flash
is flashed at its old location.
**Fix:** Add
`private func currentFocusCocoaFrame() -> CGRect? { currentFocusedWindow().map { cocoaRect(fromAXRect: $0.frame) } }`;
make `frame` a `var` seeded from it; in the strobe on-phase (`:411`) re-query
(`if let live = currentFocusCocoaFrame() { frame = live }`) before
`updateFrame(to: frame)`, falling back to the retained value on transient
nil. Keep drawing via `highlightWindow.updateFrame` directly (don't touch
`displayedBorderFrame`). ~3 extra IPCs across the strobe.
**Resolution:** _Pending._

### BUG-9 · `AXObserverCreate` failure with no retry
*sev low / conf medium*
**Where:** `FocusHighlighter.swift:460-464`.
**Problem:** `observeFrontmostApp()` stops observation then attempts
`AXObserverCreate`; if the create itself fails it returns early with **no**
`scheduleObserverRetry()` — unlike the partial-registration path — so while
that app stays frontmost none of its window notifications arrive until the
user switches away and back.
**Fix:** In the create-failure `guard else`, call
`scheduleObserverRetry(pid: pid)` before returning. Self-limiting (per-app
budget caps at 5; retry only fires while that pid is still frontmost).
**Resolution:** _Pending._

---

## B. Performance

### PERF-1 · `CGWindowListCopyWindowInfo` on every non-drag refresh (doubled by settle)
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.swift:1060`/`:1157`, called at `:663` before the
steady-state early-out (`:691-694`).
**Problem:** `topmostWindowBounds` materializes a CFDictionary for **every
on-screen window in the system** on every AX notification, every workspace
activation, and every settle refresh — and `handleAXNotification()` runs
`refresh()` immediately *and* 0.25s later, so one event pays for two full
snapshots. The z-order check is only needed to catch a frontmost-but-not-key/
main window; on a plain move it's pure overhead, but the callback discards
the notification name (`:420`) so `refresh()` can't tell a move from a
create/focus event.
**Fix:** Stop discarding the notification name; classify into "can change
which window is frontmost" (`WindowCreated`/`FocusedWindowChanged`/
`MainWindowChanged` + app-activation + `forceUpdate`) vs "same known window"
(moved/resized/miniaturized/hidden/shown); track `lastFocusedWindowPid`; in
`currentFocusedWindow()` add a fast path *before* the z-order block that, when
the last event can't have changed frontmost and `lastFocusedWindow`'s owning
pid == `frontPid` and its `axFrame` reads, returns it directly (1 IPC, no
snapshot). Default unclassified notifications to the full path. Also skip the
settle-refresh for move/resize.
**Resolution:** _Pending._

### PERF-2 · Wall-clock animation timers instead of a display link
*sev low / conf high / [dev]*
**Where:** glide `FocusHighlighter.swift:874`; pulse `HighlightWindow.swift:130`;
party `:82`; ants/hand-drawn `:103`; preview `PrefsWindowController.swift:765`.
**Problem:** All five are `Timer.scheduledTimer`, unaligned to vsync — on
60Hz they beat against refresh (glide stutter); on 120Hz/ProMotion they're
capped at 60 and unsynced.
**Fix:** Replace with a single main-thread display link — prefer
`NSView.displayLink(target:selector:)` (macOS 14+; target is 15.7) so it
re-targets when the window moves between displays (120Hz for free). The
interpolation math already parametrizes on elapsed time — substitute
`link.targetTimestamp` for `Date()`; feed that timestamp into the
clock-derived party hue / ants phase / hand-drawn seed; keep an
active-animation refcount and pause the link at zero. Keep every Reduce Motion
guard and the drag-bypass untouched. Endgame: a render-server-animated
`CAShapeLayer` would make it vsync-locked for free and delete the CPU
Gaussian passes (PERF-4).
**Deferred rationale:** a five-site animation-architecture rewrite that can't
be build/behavior-verified without macOS.
**Resolution:** _Pending._

### PERF-3 · Settings-preview 30Hz timer never stops after close
*sev medium / conf high*
**Where:** `PrefsWindowController.swift:759-775`.
**Problem:** The preview installs a repeating 30Hz timer in
`viewDidMoveToWindow` and never invalidates it; the window is
`isReleasedWhenClosed = false` and only ordered out, so `window` never becomes
nil, `viewDidMoveToWindow` isn't called again, and the timer ticks 30×/s
forever (doing only the `isVisible` guard). 30 idle wakeups/s for the process
lifetime after Settings is opened once.
**Fix:** Drive the timer from `NSWindow.didChangeOcclusionStateNotification`
(fires on close/reopen/miniaturize). In `viewDidMoveToWindow`: remove any
prior observer; `guard let window else { stopTimer(); return }`; observe with
`object: window`; sync via
`updateTimer(visible: window.occlusionState.contains(.visible))`. Callback +
`updateTimer` start/stop the 30Hz timer; `deinit` removes observer + stops.
**Resolution:** _Pending._

### PERF-4 · Glow/stronger-shadow Gaussian passes redrawn per animation tick
*sev medium / conf high / [dev]*
**Where:** `HighlightWindow.swift:257-289` (shadow blur 25), `:296-306`
(glow blur 12), invalidated by the 60Hz glide/pulse and 30Hz style timers.
**Problem:** Up to two CPU `NSShadow` Gaussians over the full overlay backing
store (up to (W+140)×(H+140) at backing scale) recomputed 30–60×/s on the
main thread — the single most expensive per-frame cost.
**Fix (sound):** layer-back the overlay; express stroke + halo as a
`CAShapeLayer` with `shadowColor`/`shadowRadius`/`shadowPath`, updating only
the changed property per tick, so the render server re-rasterizes off the
main thread. **Interim mitigations** if a full rewrite is too big: cache the
*black* stronger-shadow image across party hue ticks (hue-invariant) and only
recolor the glow; render the shadow at lower resolution and upscale; or skip
the halo during an active glide (plain stroke while moving, restore on the
final frame). **Do not** build a geometry+color NSImage cache for
party/ants/pulse — those change the blur inputs every frame.
**Deferred rationale:** best done as part of the PERF-2 layer rewrite;
risky to land blind. PERF-5 removes a chunk of this cost cheaply in the
meantime.
**Resolution:** _Pending._

### PERF-5 · Hand-drawn border redraws 30×/s though the wobble changes ~3×/s
*sev low / conf high*
**Where:** `HighlightWindow.swift:103` (timer), seed `:230`.
**Problem:** The 30Hz style timer marks the whole view dirty every tick, but
the hand-drawn seed is `Int(Date()… * 3)` — 27 of every 30 redraws regenerate
a pixel-identical `wobblePath` (a per-point double-hash loop) and re-stroke it
(plus Gaussians if enabled).
**Fix:** Extract the seed into a shared static `currentWobbleSeed()` used at
`:230`; in the timer branch on `BorderStyle.current` — `.ants` keeps
`needsDisplay = true` every tick (its phase advances continuously);
`.handDrawn` computes the seed and only sets `needsDisplay` when it differs
from a cached `lastAnimatedSeed`. Keep the 30Hz timer so the change is
observed within ~33ms. Live settings/geometry changes still repaint via the
`updateFrame` path; under Reduce Motion no timer runs.
**Resolution:** _Pending._

### PERF-6 · Live-drag re-runs the whole focus chain per 30Hz tick
*sev low / conf medium / [dev]*
**Where:** `FocusHighlighter.swift:566-569`, resolution at `:1043`/`:1119`/`:1090`.
**Problem:** During a drag the timer calls `refresh()` →
`currentFocusedWindow()` every tick; the z-order block is skipped, but the
window is still re-derived from scratch (~3 IPC) though it's already in
`lastFocusedWindow` and can't change focus mid-drag. ~90 AX IPC/s where ~30
would do.
**Fix:** In `refresh()`, before the resolution at `:662-663`, add a drag
fast-path: `if dragTimer != nil, let dragged = lastFocusedWindow, let frame = axFrame(of: dragged) { resolved = (dragged, frame) }` else fall through to
the full `currentFocusedWindow()`. A window-closed nil or stalled read (sets
`lastResolutionTimedOut`) falls back; mouse-up re-syncs. Downstream untouched.
**Resolution:** _Pending._

### PERF-7 · `forceUpdate()` does an AX round-trip on every defaults change
*sev low / conf medium · carried from round two*
**Where:** `FocusHighlighter.swift:210` (`forceUpdate`) via the defaults KVO
bridge; a color-well or slider drag fires it continuously.
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
**Resolution:** _Pending._

---

## C. Visual

### VIS-1 · Border can't straddle two displays
*sev low / conf high / [dev] · round two #1, carried*
**Where:** `FocusHighlighter.swift:17` (single `highlightWindow`),
`HighlightWindow.swift:53`.
**Problem:** One `NSWindow` has one backing store at one `backingScaleFactor`
(the display it's mostly on). A frame spanning a Retina (2×) and non-Retina
(1×) display renders the mismatched half at the wrong scale and resamples it —
soft/blurry, 1px stroke off the pixel grid. Spotlight already solves this with
a per-screen `DimWindow` pool (`:893-910`); the border never got it.
**Fix:** Mirror the pool. Replace `highlightWindow` with
`borderWindows: [HighlightWindow]`; reconcile to `NSScreen.screens.count`
(screen attach/detach already routes through `didChangeScreenParameters` →
`forceUpdate`); add `placeBorder(fullFrame:)` that pins each window to
`screen.frame` (so AppKit assigns that screen's scale) and hands it the full
padded target frame, ordering out windows the frame doesn't touch. Subtlety
the DimWindow case avoids: `HighlightView` can no longer assume
`bounds == padded rect`, so give it a `globalBorderRect` (padded target in
global Cocoa coords) and in `draw` translate it into the window's local space
by the window origin, letting the window bounds clip each slice. Fan
setPartyMode/setBorderStyleAnimating/orderOut/pulse and the three `moveBorder`
paths over the pool (redraw timers only on visible windows); the glide already
drives from one `displayedBorderFrame`, so each tick fans one rect over the
pool.
**Deferred rationale:** a core drawing rework touching many call sites,
unbuildable/unverifiable off-device; the single-window path is correct on the
overwhelmingly common single-display and single-screen-window cases.
**Resolution:** _Pending._

### VIS-2 · Spotlight dim covers the menu bar and Dock
*sev low / conf high*
**Where:** `FocusHighlighter.swift:904-909` passes `screen.frame`;
`HighlightWindow.swift:24`/`:384` `level = .statusBar`.
**Problem:** Each `DimWindow` is sized to the full `screen.frame`, not
`visibleFrame`, and sits at `.statusBar` (25) above the menu bar (24) and Dock
(20) — so the black dim covers and dims both.
**Fix:** In `updateDimWindows`, pass `screen.visibleFrame` and test
`cutout.intersects(screen.visibleFrame)`. `DimWindow.update` already offsets
the cutout by the window origin, so the local math stays correct. **Do not**
lower the dim window's level (it must stay above app windows to dim them);
frame size is the right lever. (If dimming chrome is intended, keep it and
document it, optionally behind a preference defaulting on.)
**Resolution:** _Pending._

### VIS-3 · Border halo paints over the menu bar / Dock at a screen edge
*sev low / conf high*
**Where:** `HighlightWindow.swift:24` (`.statusBar`), halo up to 70pt
(`:46-51`).
**Problem:** With opt-in glow/stronger-shadow, the halo extends the overlay
well past the frame and paints over Dock icons / the menu bar when the focused
window is near that edge.
**Fix (judgment call):** either lower **only** the border window to a level in
(3, 20) so the halo can't reach the Dock(20)/menu(24) — verify it still floats
over normal app windows and any floating panels you care about — or, more
surgically, clip the stroke/glow/shadow out of the menu-bar/Dock rects in
`HighlightView.draw` (intersect the screen's `frame` minus `visibleFrame`).
Only bites with opt-in effects at an edge.
**Resolution:** _Pending._

### VIS-4 · A border matching the background is invisible — contrast casing + Increase Contrast
*sev medium / conf high · merges round-five visual bug and the "contrast casing" idea*
**Where:** `HighlightWindow.swift:194-208` (`currentBorderColor`), stroke at
`:254`/`:304-311`.
**Problem:** One flat color, no contrasting hairline — a black border over a
dark title bar, white over white chrome, or a per-app hash matching content,
and the border vanishes. Separately,
`accessibilityDisplayShouldIncreaseContrast` is read nowhere, so that
accessibility setting changes nothing.
**Fix:** Add a contrasting casing under the main stroke. Add a
`perceptualLuminance()` helper on `NSColor` (convert via
`usingColorSpace(.sRGB)` first — required, a party HSB / catalog color would
trap on `redComponent`). Read `increaseContrast` once; pick
`casingColor = NSColor(white: luminance > 0.5 ? 0 : 1, alpha: increaseContrast ? 0.85 : 0.45)`;
casing width 2 (3 under Increase Contrast); stroke a copy of the path
`effectiveWidth + casingWidth` wide immediately *under* each of the three
main strokes (keep it out of the stronger-shadow even-odd clip; for
dashed/ants apply the same `setLineDash`). Bump `shadowMargin`'s base from 25
to 27 so the wider casing can't clip at the extreme. The accessibility
observer at `:154-160` already repaints on toggle, so it applies live.
Optionally add a user-facing `Key.contrastCasing` toggle so the casing can be
on even without Increase Contrast; or gate the whole thing on `increaseContrast`
to preserve the exact default look (maintainer taste).
**Resolution:** _Pending._

### VIS-5 · Default square corners overhang the window's ~10pt rounded corners
*sev low / conf high · maintainer taste call*
**Where:** `AppDelegate.swift:31` (registers `cornerRadius` 0),
`HighlightWindow.swift:234` (square path when radius 0).
**Problem:** At default inset 4 / width 5 the square border's corner tips
float ~2pt past the glass at all four corners.
**Fix (opt-in, don't silently change the registered default):** add a "Corner
style" control (Auto / Square / Custom) beside the radius stepper. In
`drawBorder`, Auto computes `radius = max(0, Defaults.windowCornerRadius -
inset)` so the border's corner arc is concentric with the glass and never
overhangs; apply the same computed radius to the stronger-shadow inner-exclude
path. Defensible to leave as-is given the overhang is only ~2pt.
**Resolution:** _Pending._

### VIS-6 · Appearance preview clips glow/shadow halos
*sev low / conf medium*
**Where:** `PrefsWindowController.swift:159` (`masksToBounds`), `:785`
(`insetBy(dx: 90, dy: 38)`), `:225` (height 150).
**Problem:** With only 38pt vertical margin, a stronger shadow at large widths
reaches ~38pt past the frame and is hard-clipped — the preview shows a
squared-off halo the user won't actually see.
**Fix:** Enlarge the vertical inset (e.g. `dy: 52`) and bump the height anchor
from 150 to ~190. **Correction:** removing `masksToBounds` does *not* help —
a layer-backed view can only paint into its bounds-sized backing store, so the
halo clips regardless; that flag only controls the 6pt corner rounding. Only
enlarging the room eliminates the clip. Faint ~1pt tail, low priority.
**Resolution:** _Pending._

### VIS-7 · Stronger shadow drops the wrong way (flipped view) vs the preview
*sev low / conf low / [dev]*
**Where:** `HighlightWindow.swift:283` (`height: -3`), flipped view `:164`.
**Problem:** `HighlightView` is flipped, so `-3` pushes the shadow *upward*
on-screen (unnatural); `BorderPreviewView` isn't flipped, so the same code
drops it downward. The two sites cast on opposite sides; the 3pt offset under
a 25pt blur keeps it subtle.
**Fix:** Derive the sign from the context —
`let flipped = NSGraphicsContext.current?.isFlipped ?? false; shadow.shadowOffset = NSSize(width: 0, height: flipped ? 3 : -3)` —
so both cast a natural downward drop. Leave the glow (offset 0,0) alone.
Confirm direction visually on device.
**Resolution:** _Pending._

---

## D. Interface & UX

### UX-1 · ⌘W can't close the Settings window
*sev low / conf high · round-four carryover*
**Where:** `Base.lproj/MainMenu.xib` — App/Edit/Window menus, no File menu and
no Close item (Window has only Minimize/Zoom/Bring-All-to-Front).
**Problem:** ⌘W has no key equivalent, so Settings can only be closed with the
mouse.
**Fix:** Add a File menu with a "Close" item (`keyEquivalent="w"`, action
`performClose:` to First Responder) — ~10 lines of xib — or add "Close" to the
Window menu. The window is already `.closable`.
**Resolution:** _Pending._

### UX-2 · App menu says "Preferences…" while the rest says "Settings"
*sev low / conf high*
**Where:** `MainMenu.xib:28` vs `AppDelegate.swift:107` /
`PrefsWindowController.swift:70`.
**Problem:** In `.regular` mode the user sees both terms for the same window.
**Fix:** Change the xib title to "Settings…" (keep `keyEquivalent=","`, the
id, and the `showPrefs:` connection). Pure string edit; pairs with UX-1 (same
file).
**Resolution:** _Pending._

### UX-3 · Hotkey recorder: reserved combos accepted, bare F-keys rejected
*sev medium / conf high*
**Where:** `PrefsWindowController.swift:894-916` (`beginRecording` monitor),
guard `:903`, `keyName` `:964-975`.
**Problem:** No deny-list, so ⌘Q/⌘W/⌘C/⌘V/⌘X/⌘A/⌘Z can be recorded and then
swallowed system-wide (record ⌘C → flash fires on every copy); the "— in use"
title only shows *after* registration fails. And bare F-keys (valid global
hotkeys; `keyName` already renders them) are rejected by the modifier guard.
**Fix:** In the monitor closure: (A) an `isReserved(keyCode:flags:)` check —
`flags == [.command]` for Q/W/C/V/X/A/Z, plus `[.command,.shift]` Z (Redo),
using exact `==` on the already-intersected `flags`; on a hit, beep, set the
title to "Reserved by macOS" with a tooltip, `return nil` **without**
`endRecording()` so the monitor stays live to retry. (B) allow bare F-keys via
a `Set<Int>` of `kVK_F1…kVK_F12` (explicit set, **not** a range — `F1...F20`
is `122...90` and traps) that bypasses the modifier guard; `carbonModifiers`
already yields 0 and `RegisterEventHotKey` accepts it. (On media-key hardware
a bare F-key may need Fn — worth an on-device check; (A) is the priority.)
**Resolution:** _Pending._

### UX-4 · Launch-at-login failure is a silent beep
*sev medium / conf high*
**Where:** `PrefsWindowController.swift:601-603`.
**Problem:** `NSSound.beep()` only. The most common cause of
`SMAppService.register()` failing is Gatekeeper app translocation (run from
~/Downloads → randomized read-only path); the checkbox flips back with no
explanation.
**Fix:** Replace the bare beep with an `NSAlert` (sheet on the prefs window)
that always surfaces `error.localizedDescription`, and *additively* detects
translocation / non-`/Applications` install
(`Bundle.main.bundlePath.contains("/AppTranslocation/")` or not under
Applications) to append "Move Alan to your Applications folder, relaunch, then
try again" plus a "Reveal in Finder" button wired to
`NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])`.
Keep the `refreshLaunchAtLoginStatus()` call. Guard the button-index handling
so "Reveal in Finder" only exists when the translocation branch added it.
**Resolution:** _Pending._

### UX-5 · Deprecated `NSApp.activate(ignoringOtherApps:)` ×3
*sev low / conf high*
**Where:** `AppDelegate.swift:172` (toggleHideDock), `:177` (showAbout),
`:263` (showPrefs).
**Problem:** Deprecated as of macOS 14; with a 15.7 target the no-arg
`activate()` is always available.
**Fix:** Replace all three with `NSApp.activate()`. Each is user-initiated and
paired with `makeKeyAndOrderFront`, so the system honors the switch. Bundle
with BUG-7 (same file).
**Resolution:** _Pending._

### UX-6 · Ad-hoc signed updates re-break the Accessibility grant — undocumented
*sev medium / conf medium / [dev]*
**Where:** `README.md:52-57`; `release.yml` (`CODE_SIGN_IDENTITY=-`);
`AppDelegate.swift:197` (permission alert).
**Problem:** macOS TCC keys the grant to the code-signing identity; an ad-hoc
signature isn't a stable Developer ID, so a freshly downloaded version can
present as a different app and require re-granting Accessibility. Undocumented,
so on the first update the app silently stops drawing borders.
**Fix:** (1) **Docs** — add an "Updating" subsection to the README (and a line
to `release.yml`'s `--notes`) telling the user to remove the old "Alan" row in
System Settings → Privacy & Security → Accessibility and re-add
`/Applications/Alan.app`, and stating Developer ID + notarization is the
long-term fix. (2) **Runtime** (recommended) — remember a prior grant with a
`Key.hadAccessibilityGrant` flag; if trust is currently false but the flag is
true, branch the permission alert's `informativeText` to an update-specific
message. Flag transitions false→true only; wording change only.
**Resolution:** _Pending._

### UX-7 · No test target despite pure, permission-free seams
*sev low / conf high*
**Where:** `perAppColor` `Extensions.swift:14`; `cocoaRect`
`FocusHighlighter.swift:1237`; `windowFillsScreen`/`framesRoughlyEqual`
`:941`/`:1194`; smoothstep glide `:866`; shake `:347`; `carbonModifiers`
`PrefsWindowController.swift:930`; `wobbleNoise` `HighlightWindow.swift:352`.
**Problem:** No test target (verified in `project.pbxproj`), yet these pure
functions encode invariants that regress silently (hash stability across
launches, coordinate math, clamping) and would run headless on the existing
macOS CI runner.
**Fix:** Add an `AlanTests` XCTest bundle (logic tests, no app host) and a
`xcodebuild test` CI step (`ENABLE_TESTABILITY=YES` already set). `@testable`
doesn't expose `private`, so lift the `private` seams to internal (or refactor
the two NSScreen-dependent ones to take injected geometry). Start with the
four unambiguously pure ones: `perAppColor`, `carbonModifiers`, `wobbleNoise`,
`framesRoughlyEqual`.
**Deferred rationale:** hand-editing `project.pbxproj` to add a target is
error-prone and unbuildable off-device; best done with Xcode in hand.
**Resolution:** _Pending._

### UX-8 · Scattered `UserDefaults` reads / no `Settings` facade
*sev low / conf high · round two, carried · refactor*
**Where:** clamps duplicated in `drawBorder` (width/inset/radius), `DimView`
and `BorderPreviewView` (dim level), `makeGlideTimer` (duration), plus raw
reads across three classes at draw time.
**Problem:** Keys, default values, and clamping are duplicated at many read
sites (30–60×/s during drags), and the observed-keys list is easy to forget to
update.
**Fix:** A small `Settings` facade centralizing keys, clamping, and defaults
in one place; removes the duplicated clamps and makes `allObservedKeys`
authoritative. Pure internal cleanup; pairs well with UX-7 (so the clamps are
covered) and enables PERF-7.
**Deferred rationale:** broad cross-file refactor with wide merge surface;
higher value once the test target (UX-7) exists to catch regressions.
**Resolution:** _Pending._

### UX-9 · CI doesn't pin an Xcode version
*sev low / conf high*
**Where:** `.github/workflows/ci.yml:23`, `release.yml:28` (`macos-26`).
**Problem:** Builds use whatever Xcode the rolling image ships; a toolchain
bump can break the build with no code change.
**Fix:** Add a `Select Xcode` step before the build in **both** files, plus an
`xcodebuild -version` log line so a future image change fails loudly. **Pick a
version actually present in the `macos-26` manifest** (the image ships Xcode
26.x, so `16.x` is wrong); prefer `maxim-lobanov/setup-xcode` with
`xcode-version: latest-stable` to avoid hard-coding a folder name. CI-hygiene
only.
**Resolution:** _Pending._

### UX-10 · No localization
*sev low / conf high*
**Where:** no `.strings`/`.xcstrings`; literals in `AppDelegate.swift:95-121`
/ `:207-218`, all of `PrefsWindowController`, the recorder.
**Problem:** The app can't be localized without editing source.
**Fix:** Add a `Localizable.xcstrings` catalog; route literals through
`String(localized:)` (positional format args for interpolated app names, e.g.
the `Exclude "…"` title); enable Base Internationalization on `MainMenu.xib`.
Mechanical, stageable, no runtime impact for the English build.
**Deferred rationale:** lowest priority; large mechanical churn with no
behavior change, better staged with Xcode's catalog tooling.
**Resolution:** _Pending._

---

## E. Missing features

### FEAT-1 · "Show overlays in screenshots" toggle
*sev low / conf high*
**Where:** `HighlightWindow.swift:33`, DimWindow `:384` (`sharingType = .none`).
**Problem:** `.none` is the right default but an absolute ceiling — no one can
capture the border/dim to document, file a bug, or present Alan itself.
**Fix:** Add `Key.showInScreenshots` (default off; add to `allObservedKeys`);
replace the hard-coded `.none` with `applySharingType()` in both window
`init()`s (sets `.readOnly` when on — **not** `.readWrite` — else `.none`);
call `applySharingType()` on the border and each dim window from
`forceUpdate()` so it applies live; add a Behavior-tab checkbox.
**Resolution:** _Pending._

### FEAT-2 · Update mechanism
*sev low / conf high*
**Where:** none today; `README.md:12` links `releases/latest`.
**Problem:** Nothing checks for a newer build; a Dock-hiding background utility
can run a months-old version forever. Sparkle needs a stable Developer ID the
ad-hoc pipeline lacks.
**Fix:** A dependency-free `UpdateChecker` — GET
`https://api.github.com/repos/L-K-M/Alan/releases/latest`
(`Accept: application/vnd.github+json`) on a background `URLSession`, fail
silently on any error; decode `tag_name`/`html_url`; **compare versions
component-wise numeric, not string** (split on `.`, pad, map to Int — a string
compare mis-orders "2.10.0" vs "2.9.0") against `CFBundleShortVersionString`.
Ship the **manual** "Check for Updates…" status-menu item first (bypasses any
gate, gives explicit "up to date" feedback). Optional automatic weekly check
(gated on a `lastUpdateCheck` date, a `skippedVersion`, and an opt-in
preference defaulting off) can follow.
**Resolution:** _Pending._

---

## F. Ideas — novel, delightful, quirky

### IDEA-1 · Focus trail: a fading ghost border on the window you just left
*sev medium / conf high · also in round two*
**Where:** `FocusHighlighter.swift:723` (`focusChanged`), `:73`
(`displayedBorderFrame`), insertion just before `showHighlight(at:)` (`:740`).
**Fix:** Add `Key.focusTrail` (default off, in `allObservedKeys`) and
`Defaults.ghostTrailDuration` (~0.8). Create `GhostBorderWindow` cloning
`HighlightWindow`'s setup, contentView a `HighlightView` drawing a static
border. Just before `showHighlight`, guard on `focusTrail`, `focusChanged`,
`dragTimer == nil`, `animateMovement`, and — **critical** —
`highlightVisible == true` (else a stale `displayedBorderFrame` flies the
ghost in from a phantom spot), capture
`outgoing = spotlightMode ? displayedCutout : displayedBorderFrame` (require
non-nil, ≠ `cocoaFrame`), position the ghost there, fade `alphaValue` 1→0 over
the duration via `NSAnimationContext`, order out on completion, restart on a
mid-fade change. Whole-window alpha fade needs no per-frame redraw. Under
Reduce Motion, a single static reveal.
**Resolution:** _Pending._

### IDEA-2 · Match the system accent color as a zero-config border source
*sev medium / conf high*
**Where:** `HighlightWindow.swift:194` (`currentBorderColor`).
**Fix:** Add `Key.useAccentColor` (default off, in `allObservedKeys`); insert
a branch after party and per-app, before the wells:
`if useAccentColor { return NSColor.controlAccentColor }` (dynamic catalog
color, resolves light/dark automatically). Add an Appearance-tab checkbox that
greys out the two wells + per-app checkbox when on. **Load-bearing:** an accent
change does *not* fire `viewDidChangeEffectiveAppearance`, so register a
`NSColor.systemColorsDidChangeNotification` observer in `start()` calling
`forceUpdate()` (gate on `useAccentColor` to avoid churn).
**Resolution:** _Pending._

### IDEA-3 · Viewfinder / corner-bracket border style
*sev low / conf high*
**Where:** `Constants.swift:87` (`BorderStyle`), `HighlightWindow.swift:226-236`
(path), `FocusHighlighter.swift:774` (`borderStyleNeedsAnimation`).
**Fix:** Add `case corners` to `BorderStyle` — the `label` switch is exhaustive
so add `case .corners: return "Corner brackets"` (mandatory to compile) — and
to `borderStyleNeedsAnimation`'s exhaustive switch add
`case .corners: return false` (mandatory). In `drawBorder`, before the
handDrawn/radius/rect branch, build one `NSBezierPath` with four disjoint
corner subpaths from `borderBounds` (arm length `max(8, min(w,h)*0.18)`,
clamped per dimension so opposite arms can't overlap), `lineCapStyle = .round`.
The dash block is already style-gated; effectiveWidth / stronger-shadow / glow
/ base stroke / pulse all apply unchanged. Preview renders it live for free.
**Resolution:** _Pending._

### IDEA-4 · Sonar-ping find animation
*sev low / conf high*
**Where:** `FocusHighlighter.swift:373` (`flashBorder`), center from the frame
resolved at `:376`.
**Fix:** A transient `PingWindow` (same click-through, `.none`-sharing setup as
`HighlightWindow`) framed to the focused window's screen; content view draws N
concentric rounded-rects at `radius = progress * maxReach`,
`alpha = 1 - progress`, stroke = `currentBorderColor()`; driven by a
`Defaults.findPingDuration` (~0.5s) timer. Gate on `Key.findAnimation`
("flash" | "ping"; **not** in `allObservedKeys` — only matters when the
gesture fires). Shared by the hotkey, shake, and Space-change flash. Under
Reduce Motion, a single static ring held briefly. Guard overlapping pings with
a `pingTimer` mirroring `flashTimer`.
**Resolution:** _Pending._

### IDEA-5 · Spotlight and border at the same time
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.swift:753` (`showHighlight`), pulse guard
`:742-743`.
**Fix:** `Key.spotlightWithBorder` (default off, in `allObservedKeys`); split
the spotlight branch to call `moveSpotlight` *and* `moveBorder` (with the
border-branch timer setup) when on; elevate the border to `.statusBar + 1` so
it stays above the per-screen dim windows that re-front each glide tick (reset
when off); relax the pulse guard to allow the pulse when `spotlightWithBorder`;
add a Behavior-tab checkbox indented under spotlight and un-gate the pulse
checkbox; draw the border in the preview's spotlight branch too. Verify on
device the border stays above all `DimWindow`s across a full glide.
**Resolution:** _Pending._

### IDEA-6 · Per-app colors sampled from the app icon's dominant color
*sev low / conf high / [dev] · also in round two*
**Where:** `Extensions.swift:14` (`perAppColor`).
**Fix:** Keep the djb2 path as a guaranteed fallback; layer icon sampling in
front, cached per bundle ID (`[String: CGFloat?]`, nil = "failed/monochrome,
use hash" — memoize both; drawBorder runs at 30–60Hz so uncached per-draw
sampling is unacceptable). Sample the 32×32 icon rep into a bitmap context,
build a coarse saturation-weighted hue histogram skipping near-gray/low-alpha
pixels. **Distinctiveness guards:** top hue bin < ~35% of weight
(gradient/rainbow) or max saturation < ~0.3 (Terminal/monochrome) → fall back
to the hash; keep the icon *hue* but render at the hash path's fixed
saturation/brightness so legibility and light/dark behavior match today. Worst
case degrades to the current hash, never a pile of indistinguishable blues.
**Resolution:** _Pending._

### IDEA-7 · Hold-to-spotlight quasimode on the find-my-window hotkey
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.swift:267` (`registerFindMyWindowHotkey`),
handler `:280-284`.
**Fix:** Install the handler for both press and release (2-element
`EventTypeSpec` array, dispatch on `GetEventKind`), gate behind
`Key.holdToSpotlight`; on press start a ~0.25s timer that, if still held,
enters a transient dim; on release invalidate and either `flashBorder` (tap)
or restore. Route dim-vs-border decisions through a `spotlightActive` accessor
(`heldSpotlightActive || Key.spotlightMode`) at the two sites, so the normal
`refresh()` path follows focus for free. **Safety net** (release can drop if
modifiers lift first): a max-hold cap timer and a transient `.flagsChanged`
monitor, both calling the same cleanup. Verify `kEventHotKeyReleased` fires on
device; the safety net makes a dropped release non-fatal.
**Resolution:** _Pending._

### IDEA-8 · Warp the cursor to the focused window on find-my-window
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.swift:375` (`flashBorder`).
**Fix:** `Key.warpCursorOnFind` (default off, *not* in `allObservedKeys`);
right after the resolve at `:375` and **before** the `cocoaRect` flip,
`CGWarpMouseCursorPosition(CGPoint(x: axFrame.midX, y: axFrame.midY))` then
`CGAssociateMouseAndMouseCursorPosition(1)` (so the cursor doesn't stick for
the ~0.25s HID interval after a warp). Use `axFrame` directly — it shares the
top-left global Quartz space with `CGWarpMouseCursorPosition`; applying the
cocoa flip would land the cursor mirrored. Wires up the hotkey, shake, and
Space-change gestures at once. Add a checkbox. Verify on a
secondary/negative-origin display.
**Resolution:** _Pending._

### IDEA-9 · Transient "who has focus" chip (app icon + name)
*sev low / conf high*
**Where:** `FocusHighlighter.swift:723` / `:742-746` (focusChanged branch).
**Fix:** `Key.showFocusChip` (default off, in `allObservedKeys`),
`Defaults.focusChipDuration` (~0.8s); a reusable `FocusChipWindow`
(HighlightWindow setup) with a horizontal stack of icon + truncating label on
a rounded translucent backing. Hook next to the pulse, suppressed while
dragging. **Refinement:** derive identity from the *resolved* window
(`AXUIElementGetPid(windowElement)` → `NSRunningApplication`), not
`frontmostApplication`, to handle the out-of-process panel-service case;
position centered above `cocoaFrame`, clamped into the screen's `visibleFrame`
(flip below if no room). Reuse one instance; hide it in `hideHighlight`/
paused/Space-change. Especially valuable in spotlight mode (the dim hides
every other cue).
**Resolution:** _Pending._

### IDEA-10 · Squash-and-stretch the border as it glides
*sev low / conf high · pure polish*
**Where:** `FocusHighlighter.swift:866` (`makeGlideTimer`, shared with
`moveSpotlight`).
**Fix:** Thread a `stretch: Bool = false` param; pass `true` only from
`moveBorder`. In the else-branch, from the raw `t` (in scope) compute a
`sin(t·π)`-enveloped deform gated on travel distance (> ~80pt) and capped
(~24pt), growing the dominant axis and shrinking the other, re-centered on the
eased rect. `updateFrame` always insets by `-shadowMargin`, so a larger rect
just makes a larger window — no clipping. `moveBorder` bypasses the glide under
Reduce Motion, so the stretch is unreachable there. Tune on device.
**Resolution:** _Pending._

### IDEA-11 · Optional quiet click on focus change
*sev low / conf high · accessibility*
**Where:** `FocusHighlighter.swift:723` / `:742-745`.
**Fix:** `Key.focusSound` (register false; *not* in `allObservedKeys` — read
live); a preloaded `NSSound` (bundle a short asset; guard the optional so a
missing sound is a silent no-op) at low volume; in the `focusChanged` branch,
if on and > 0.3s since last play, `stop()` then `play()`. For genuine
accessibility value, compute a lightweight focus-changed check *before* the
maximized/full-screen returns (`:700-719`) so the cue fires there too. Add a
Behavior-tab checkbox (not gated on spotlight — audio is orthogonal). Optional
`.alignment` haptic sibling. Off by default.
**Resolution:** _Pending._

---

## Assessed and rejected in prior rounds (kept for the record)

- **Menu-bar icon tinted with the frontmost app's color** — the menu bar is
  the one place the system dictates monochrome template images; a colored icon
  reads as broken.
- **"Peek through the dim" mouse-hover for spotlight mode** — fights the
  premise of the mode (the dim is meant to *resist* attention drifting).
- **Helper/agent-process frontmost window not seen by the pid-scoped z-order
  lookup** — the meaningful cross-process case (out-of-process open/save panel
  service) is already handled by the non-pid-scoped
  `kAXFocusedUIElementAttribute` path.
