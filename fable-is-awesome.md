# Alan — code review notes, round five

A fifth full read-through, done at `bb0cbe8` — v2.6.1 with all ten
round-three PRs and all nine round-four PRs merged. The brief again leads
with the *"when OS X opens a window like a copy window, it sometimes
doesn't get the focus border despite being the frontmost window"* report,
which **survives round four's fix** — for a reason round four's own
implementation left on the table. Items that shipped in earlier rounds are
gone from this document; what's below was re-verified against the current
code, most of it by a fan-out review whose every finding was then
adversarially re-traced against `bb0cbe8`. This review ran on Linux with no
macOS to hand, so claims that depend on runtime behavior are marked *needs
on-device confirmation*.

Items marked **[implemented → `branch`]** ship as their own PR alongside
this document; see the table at the end.

---

## The headline bug, still: the frontmost window whose geometry AX won't confirm

Round four's fix (`claude/fix-never-main-windows`) did the right thing in
spirit: `currentFocusedWindow()` (`FocusHighlighter.swift:1038`) now takes
the window server's z-order as a first-class signal. It reads
`topmostWindowBounds(pid:)` (`:1155`) — the bounds of the frontmost
app-owned window — and, when neither the keyboard-focus window nor
`AXMainWindow` matches those bounds, calls `appWindowMatching(topBounds:)`
(`:1137`) to find the app's `AXWindow` whose `AXFrame` sits there. For a
Finder copy-progress panel that becomes neither key nor main, that *is* the
right window.

**But the fix insists on naming an `AXUIElement`, and throws away the
correct geometry the moment it can't.** Trace the branch at `:1077-1085`:

1. `topBounds` = the copy panel's window-server bounds (correct — the
   window server always knows what's frontmost).
2. The key-window check (`:1063`) and the `AXMainWindow` check (`:1071`)
   both fail, because both point at the browser window *behind* the panel.
3. `appWindowMatching(topBounds:)` (`:1081`) returns nil.
4. Control falls straight through to `:1090` and returns the
   **keyboard-focus window** — the window the two prior checks just proved
   is *behind* the frontmost one. `topBounds` goes out of scope, discarded.

`appWindowMatching` can return nil even though the panel genuinely is
frontmost, for several real reasons:

- the panel is an **attached sheet**, reached through its parent's
  `AXSheets`, not the application's `kAXWindowsAttribute` that
  `appWindowMatching` scans (`:1139`);
- its `AXFrame` differs from the CGWindow bounds by more than the hard 4pt
  tolerance (`framesRoughlyEqual`, `:1194`) — shadow accounting, subpixel
  rounding on Retina;
- it is past the `.prefix(20)` cap (`:1144`) in an app with many windows;
- the `AXFrame` read simply **times out** on a busy app (the 0.5s
  messaging timeout, set at `:96`).

And critically, **nothing arms a retry**: `refresh()` only consults
`lastResolutionTimedOut` and calls `scheduleResolutionRetry()` when
`currentFocusedWindow()` returns *nil* (`:663-679`). Here it returns
non-nil — just *wrong* — so the border stays glued to the window behind the
panel until some unrelated event fires. That is exactly the "sometimes"
texture of the report: dialogs that take key work (round-three fix),
dialogs that become main work (round-four fix), panels that do neither and
aren't cleanly frame-matchable **never** work until you click them.

### Fix — a raw-bounds last resort (the border needs a frame, not a handle)

*severity: high if it strikes the flagship Finder case, medium as a
residual edge · needs on-device confirmation · **[implemented →
`claude/fix-copy-window-raw-bounds`]***

The border is a pure visual overlay. It needs a rectangle, not an
`AXUIElement`. When the z-order block has a real `topBounds` that matches
neither key, main, nor any nameable AX window, **draw at `topBounds`
anyway** instead of discarding it.

1. Change the signature (`:1038`) to
   `-> (element: AXUIElement?, frame: CGRect)?` — element optional, frame
   required.
2. In the z-order block, after the `appWindowMatching` attempt (`:1081`),
   add a final fallback:
   ```swift
   if let topWindow = appWindowMatching(topBounds, appElement: appElement),
      let frame = axFrame(of: topWindow) {
       return (topWindow, frame)
   }
   // AX can't name the frontmost window (a sheet outside kAXWindowsAttribute,
   // an AXFrame off by >4pt or beyond prefix(20), or an AXFrame timeout), but
   // the window server already told us where it is. The border is a visual
   // overlay — it needs a frame, not a handle.
   return (nil, topBounds)
   ```
   `topBounds` is already in `AXFrame`'s top-left global space (comment at
   `:1152-1154`), so `refresh()`'s `cocoaRect(fromAXRect:)` converts it
   correctly with no extra work.
3. Thread the optional element through `refresh()`:
   - `:663` `guard let (windowElement, axFrame) = currentFocusedWindow()`
     — `windowElement` is now `AXUIElement?`; the guard is unchanged.
   - `:700` guard the full-screen skip on a real element:
     `if let windowElement, isFullScreen(windowElement), windowFillsScreen(cocoaFrame)`.
     A raw-bounds panel is never full-screen, and the
     `hideBorderWhenMaximized` check at `:712` already keys off
     `windowFillsScreen(cocoaFrame)` alone, so maximize-hiding still works.
   - `:691` and `:723` call `isSameWindow(windowElement, lastFocusedWindow)`
     — already nil-safe (`:918-921`); with both nil it returns true, so
     dedup/`focusChanged` degrade to pure frame comparison, which is
     exactly right for a stable panel. `:724`
     `lastFocusedWindow = windowElement` assigns the optional in — fine.
4. `flashBorder()` (`:375`) already destructures `let (_, axFrame)` and
   ignores the element — unchanged.

Leave the cross-process branch (`:1048`, the out-of-process open/save
panel service) and the drag gate (`:1059`) exactly as they are. Because the
z-order block already prefers the topmost window over the focus window when
`appWindowMatching` *succeeds*, returning `topBounds` when it *can't* be
named is consistent with the existing design, not a new behavior — and it
removes the wrong-window outcome for **all** the nil-return causes above at
once, which is why the other three copy-window findings below are only
low-severity hardening on top of it.

### Two adjacent robustness gaps in the same subsystem

- **A single 0.25s settle-refresh, with no retry on a wrong-but-non-nil
  resolution.** *(medium · needs on-device confirmation ·
  **[implemented → `claude/fix-copy-window-raw-bounds`]**)*
  `AXWindowCreated` fires *before* `CGWindowListCopyWindowInfo` lists the
  new panel as topmost, so the synchronous `refresh()` in
  `handleAXNotification()` (`:425`) samples stale z-order and resolves the
  window behind. The only safety net is `scheduleSettleRefresh()` (`:434`),
  a **single** non-repeating 0.25s timer, coalesced by
  `guard settleRefreshTimer == nil` (`:435`) to exactly one retry per
  burst. If the window server hasn't caught up by 0.25s, that lone retry
  also misses and nothing else fires (`scheduleResolutionRetry` is only
  reached on a nil resolution, which this isn't). Fix: turn the single shot
  into a short bounded chain. Add `private var settleRefreshRemaining = 0`;
  in `handleAXNotification()` set it to `3` before calling
  `scheduleSettleRefresh()` (so a stream of notifications keeps the budget
  topped up and it self-terminates when they stop); rewrite
  `scheduleSettleRefresh()` to re-arm while budget remains, at increasing
  back-offs `[0.12, 0.3, 0.6]` indexed by
  `min(3 - settleRefreshRemaining, 2)`, decrementing and chaining the next
  attempt in the timer body. This gives the copy-panel/late-z-order case
  ~3 retries out to ~1s instead of a lone 0.25s shot. It never polls: the
  chain stops when the budget hits 0, and AX posts no continuous
  notifications during a drag (drags use their own 30Hz timer), so no
  churn is added there.

- **`appWindowMatching` is fragile past the raw-bounds fallback.** *(low ·
  needs on-device confirmation · not scheduled — folded conceptually into
  the fallback above)* Even with the fallback in place, tightening the
  matcher reduces cases where the *wrong* AX element is matched. The one
  substantive gap is the `.prefix(20)` cap (`:1144`): the loop returns on
  the first frame match, so the cap only limits how many windows are
  *examined* — a match past index 20 is never seen. Raise it to ~40
  (bounds the worst-case `AXFrame` IPC on window-hoarder apps while
  covering realistic cases). **Do not** loosen the 4pt tolerance:
  `AXFrame` and CGWindow bounds are the same frame in the same coordinate
  space, shadows are excluded from both, Retina rounding is sub-point, so
  4pt is already generous and loosening risks matching a wrong same-size
  window. Sheets (via `kAXSheetsAttribute`) are optional and low value
  because a *focused* sheet is already resolved upstream through
  `kAXTopLevelUIElementAttribute`.

- **`topmostWindowBounds` layer ceiling excludes modal-panel-level
  windows.** *(low · needs on-device confirmation)* The filter admits
  CGWindow layers `0...3` (`:1167`), which covers normal (0) and floating
  (3) windows but **not** modal-panel level (`kCGModalPanelWindowLevel` =
  8). A frontmost dialog sitting at that level is skipped, and the function
  then either returns nil or, worse, returns a *lower* normal-layer window
  whose bounds coincidentally frame-match a background window. Raise the
  ceiling to `<= 8`; this still skips menus/pop-ups/status/Dock/menu-bar
  (utility 19, Dock 20, mainMenu 24, statusBar 25, popUpMenu 101, all > 8).
  Low risk because the returned bounds are cross-validated downstream by
  the three matchers, so a spurious elevated window that isn't a real AX
  window is harmlessly discarded. *Do not* lower the 40×40 size floor —
  real focusable windows exceed it, and lowering it only risks catching
  tiny shadow/helper windows; if tiny genuine HUDs ever matter, gate on
  `AXRole`/window name instead of shrinking the geometric floor.

- **No signal for a pre-existing window re-ordered to the front.** *(low ·
  needs on-device confirmation)* The observer registers created / focus /
  main / moved / resized / miniaturized / hidden / shown (`:482-492`). A
  window that already exists and is merely `orderFront()`-ed — becoming
  neither key nor main, not newly created — posts none of these, and AX
  has no reliable z-order-change notification. Re-showing a cached palette
  or reused progress window therefore brings it frontmost with no AX event
  and no border until something unrelated fires. This is an *edge* of the
  headline (the canonical copy window is brand-new, so `AXWindowCreated`
  covers it), and is partly masked already by the global `leftMouseUp`
  monitor (`:132-141`) which refreshes on any click. The honest resolution
  is to **document it as a platform limitation**: a poll to cover it would
  fight this file's deliberate idle-wakeup minimization. If a fix is ever
  wanted, it should be a bounded, frontmost-and-idle-gated ~1.5s
  reconciliation timer that pre-checks `topmostWindowBounds` against a
  cached value and only calls `refresh()` on a change — not an
  unconditional poll.

---

## Other bugs

- **Glide animation timers survive an overlay hide / spotlight switch and
  resurrect the hidden overlay.** *(medium · needs on-device confirmation
  · **[implemented → `claude/fix-glide-timer-leak`]**)*
  `showHighlight()` (`:753`) hides one overlay by ordering it out but does
  not cancel the *other* mode's in-flight glide timer: the spotlight
  branch does `highlightWindow.orderOut(nil)` but never invalidates
  `borderAnimationTimer`; the border branch does `hideDimWindows()` but
  never invalidates `spotlightAnimationTimer`. `moveBorder`/`moveSpotlight`
  each invalidate only their *own* timer. So toggling `spotlightMode`
  within ~0.25s of a focus/frame change (a `defaults`/prefs write →
  `forceUpdate` → `refresh` → `showHighlight`, while `animateMovement` is
  on) leaves the opposite mode's glide running, and each tick calls
  `updateFrame`/`updateDimWindows` → `orderFrontRegardless` (`:64`, `:422`)
  and flickers the just-hidden overlay back on for the rest of the glide.
  Separately, `flashBorder()` (`:373`) guards only `flashTimer == nil` and
  drives `updateFrame` directly, but never cancels a running border/spotlight
  glide — so a glide still running when the flash starts (e.g. the
  `flashOnSpaceChange` path fires `flashBorder` 0.2s after a Space switch,
  inside a 0.25s glide window) keeps re-fronting on its own schedule and
  defeats the flash's off-phase `orderOut`, so the border doesn't visibly
  blink. Fix: in `showHighlight`, cancel the *opposite* timer before
  drawing (spotlight branch: invalidate `borderAnimationTimer`; border
  branch: invalidate `spotlightAnimationTimer`) — but *don't* clear
  `displayedBorderFrame`/`displayedCutout`, so a later switch-back still
  has a position to glide from. In `flashBorder`, right after the
  `flashTimer` guard, invalidate both `borderAnimationTimer` and
  `spotlightAnimationTimer` so the flash is the sole driver of the overlay.
  `hideHighlight` already cancels both, so no other path needs changing.

- **The permission-alert poll timer can call `abortModal()` with no modal
  session active.** *(low · needs on-device confirmation ·
  **[implemented → `claude/fix-appdelegate-modernize`]**)* In
  `requestAccessibilityPermissionIfNeeded()` the poll timer runs on
  `.common` for the whole function lifetime and calls `NSApp.abortModal()`
  whenever `AXIsProcessTrusted()` turns true (`AppDelegate.swift:226-230`).
  The alert is re-presented in a `while` loop (`:237-247`); each "Open
  System Settings" click returns from `runModal()` and the loop calls
  `openAccessibilitySettings()` (which can pump the run loop) before the
  next `runModal()`. If the grant lands in that gap, the timer fires
  `abortModal()` while **no** modal session is running — which raises
  `NSAbortModalException` with no modal loop to catch it: at best a
  lost/duplicated response, at worst an uncaught-exception crash under
  `NSApplicationCrashOnExceptions`, on the first-launch permission path.
  Fix (two lines): guard the callout —
  `if AXIsProcessTrusted(), NSApp.modalWindow != nil { NSApp.abortModal() }`.
  During `runModal()` the alert is `NSApp.modalWindow`, so the abort still
  dismisses on grant; in every gap `modalWindow` is nil, so no stray
  exception, and the loop's own `while !AXIsProcessTrusted()` terminates it.

- **`flashBorder` replays a frame captured once at the start of the
  flash.** *(low · **[implemented → `claude/fix-flashborder-live-frame`]**)*
  It reads the focused window once (`:375-376`) and replays that captured
  `frame` for every "on" phase of the ~0.7s strobe (`:411`) and for the
  Reduce-Motion single reveal (`:379`). A window that moves or closes
  mid-flash is flashed at its stale location — the border blinks around
  empty space. Self-healing (the trailing `refresh()` re-resolves) and
  cosmetic, but the whole point of the flash is to point at where the
  window *is now*. Fix: add
  `private func currentFocusCocoaFrame() -> CGRect? { currentFocusedWindow().map { cocoaRect(fromAXRect: $0.frame) } }`;
  make `frame` a `var` seeded from it, and in the strobe timer's on-phase
  (`:411`) re-query (`if let live = currentFocusCocoaFrame() { frame = live }`)
  before `updateFrame(to: frame)`, falling back to the retained value on a
  transient nil. Keep drawing via `highlightWindow.updateFrame` directly
  (the flash owns the window even in spotlight mode); don't route through
  `moveBorder`/`moveSpotlight` and don't touch `displayedBorderFrame`.
  ~3 extra IPCs across the strobe — the point of the gesture.

- **`AXObserverCreate` failure tears down observation with no retry
  armed.** *(low · **[implemented → `claude/fix-observer-create-retry`]**)*
  `observeFrontmostApp()` calls `stopObservingApp()` (sets `observedPid=-1`,
  invalidates the retry timer) and *then* attempts `AXObserverCreate`
  (`:460-464`). If the create itself fails, the function returns early with
  no observer and — unlike the partial-registration path (`:517`) — **no**
  `scheduleObserverRetry()`. While that app stays frontmost, none of its
  window notifications ever arrive, so the border never follows or appears
  for it until the user switches away and back. `AXObserverCreate` failure
  is rare (invalid pid, or AX momentarily unavailable just after launch —
  the exact condition the existing retry path was built for), but the two
  failure paths are inconsistent. Fix: in the create-failure `guard`'s
  `else`, call `scheduleObserverRetry(pid: pid)` before returning. Safe and
  self-limiting: the per-app budget caps at 5 and the retry callback
  re-attempts only while that pid is still frontmost.

- **Bare function keys (F1–F12) can't be recorded as the hotkey.** *(low ·
  **[implemented → `claude/shortcut-recorder-policy`]**)* The recorder
  rejects any combo without ⌘/⌥/⌃ (`PrefsWindowController.swift:903`). A
  bare F-key is a perfectly valid global hotkey — macOS itself binds F11 —
  and `RegisterEventHotKey` accepts `modifiers = 0`; `keyName()` already
  renders F1–F12 (`:964-975`). See the combined shortcut-recorder fix under
  *Interface & UX* below.

---

## Performance

- **`CGWindowListCopyWindowInfo` enumerates every on-screen window on every
  non-drag refresh, and the settle-refresh doubles it.** *(low · needs
  on-device confirmation)* `currentFocusedWindow()` runs at `:663`
  *before* the steady-state early-out at `:691-694`, so on every non-drag
  refresh `topmostWindowBounds` (`:1060`) calls
  `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`
  (`:1157`), which materializes a CFDictionary for **every on-screen window
  in the whole system** and linearly scans them. That fires on every AX
  notification, every workspace activation, and every settle refresh — and
  because `handleAXNotification()` runs `refresh()` immediately *and*
  schedules a second 0.25s later, one window event pays for two full
  snapshots. The steady-state early-out can't save it because it sits after
  the resolution. The z-order check is only actually needed to catch a
  frontmost-but-not-key/main window; on a plain frame move it's pure
  overhead — but the AX callback discards the notification name (`:420`),
  so `refresh()` can't currently tell a move from a create/focus event.
  Fix: stop discarding the callback's notification name; classify each
  notification into "can change which window is frontmost"
  (`kAXWindowCreated`, `kAXFocusedWindowChanged`, `kAXMainWindowChanged`,
  plus app-activation and `forceUpdate`) vs "same known window"
  (moved/resized/miniaturized/hidden/shown); track `lastFocusedWindowPid`
  alongside `lastFocusedWindow`; and in `currentFocusedWindow()` add a fast
  path *before* the z-order block: if the last event can't have changed the
  frontmost window, `lastFocusedWindow` is non-nil, its owning pid ==
  `frontPid`, and `axFrame(of:)` reads it successfully, return it directly
  (1 IPC, no snapshot). Default any unclassified notification to the safe
  full path. Also skip the settle-refresh for move/resize (nothing settles).

- **All animations run on wall-clock `Timer`s instead of a display link.**
  *(low · needs on-device confirmation)* The glide (60Hz,
  `makeGlideTimer`, `:874`), the pulse (60Hz, `HighlightWindow.swift:130`),
  party (30Hz, `:82`), marching-ants/hand-drawn (30Hz, `:103`), and the
  Settings preview (30Hz, `PrefsWindowController.swift:765`) are all
  `Timer.scheduledTimer`, unaligned to vsync. On a 60Hz panel the 60Hz
  timers beat against refresh and drop/double frames (visible glide
  stutter); on a 120Hz/ProMotion display they're both capped at 60 and
  unsynced. Fix: replace the five timers with a single main-thread display
  link — prefer `NSView.displayLink(target:selector:)` (macOS 14+, target
  is 15.7) because it auto-binds to the view's current display and
  re-targets when the window moves between panels, so a window dragged onto
  a 120Hz screen animates at 120Hz for free. The interpolation math already
  parametrizes on elapsed time, so substitute `link.targetTimestamp` for
  `Date().timeIntervalSinceReferenceDate`; feed that same timestamp into
  the clock-derived party hue / ants phase / hand-drawn seed so they
  advance in lockstep with the presented frame; maintain an
  active-animation refcount and pause the link at zero. Keep every Reduce
  Motion guard and the drag-bypass (the 30Hz drag poll *is* the animation
  there) untouched. Longer term, a `CAShapeLayer` animated by the render
  server would make it vsync-locked for free and also delete the CPU
  Gaussian passes below.

- **`BorderPreviewView`'s 30Hz timer keeps firing forever after the
  Settings window is closed.** *(medium ·
  **[implemented → `claude/fix-preview-idle-wakeups`]**)* The preview
  installs a repeating 30Hz timer in `viewDidMoveToWindow` (`:759-775`) and
  never invalidates it on close. The window is `isReleasedWhenClosed =
  false` and only ordered out on close, so the view stays in the hierarchy,
  its `window` never becomes nil, `viewDidMoveToWindow` isn't called again,
  and the timer ticks 30×/s forever — doing only the `isVisible` guard and
  returning. For a menu-bar utility expected to idle at ~0 wakeups, that's
  30 pointless wakeups/s for the rest of the process's life after the user
  opens Settings once. Fix: drive the timer from
  `NSWindow.didChangeOcclusionStateNotification`, which fires on close
  (loses `.visible`), reopen (gains it), and miniaturize. In
  `viewDidMoveToWindow`: remove any prior observer;
  `guard let window else { stopTimer(); return }`; observe the notification
  with `object: window`; sync via
  `updateTimer(visible: window.occlusionState.contains(.visible))`. The
  observer callback and `updateTimer` start/stop the 30Hz timer; `deinit`
  removes the observer and stops the timer. (Lighter-touch alternative: a
  `stop()` from `prefsWindowWillClose` and `start()` from `showPrefs`, but
  that misses miniaturize/occlusion.)

- **Glow and stronger-shadow Gaussian passes are re-rendered over the full
  overlay backing store on every animation tick.** *(medium · needs
  on-device confirmation)* `drawBorder` runs up to two CPU `NSShadow`
  Gaussians per invalidation — stronger shadow blur 25 (`:257-289`), glow
  blur 12 (`:296-306`) — each stroking the full path through a software
  blur, recomputed on every dirtying frame: the 60Hz glide, the 60Hz pulse,
  and the 30Hz party/ants/hand-drawn timers. With both effects on the
  overlay grows by up to 25+15+30 = 70pt per side (`:46-51`), so it's a
  multi-megapixel Gaussian recomputed 30–60×/s on the main thread — the
  single most expensive per-frame cost in the app. Fix (sound): make the
  overlay layer-backed and express the stroke + halo as a `CAShapeLayer`
  with `shadowColor`/`shadowRadius`/`shadowPath`, updating only the changed
  property per tick (strokeColor for party, lineDashPhase for ants,
  lineWidth for pulse, path for hand-drawn) so the render server
  re-rasterizes off the main thread. Cheaper interim mitigations if a full
  layer rewrite is too big: cache the *black* stronger-shadow image across
  party-mode hue ticks (it's hue-invariant) and only recolor the glow;
  render the shadow into a lower-resolution offscreen and upscale (blur
  hides the loss); or skip the halo during an active glide (plain stroke
  while moving, restore on the final frame). *Do not* build an NSImage
  cache keyed on (geometry, color) for party/ants/pulse — those change the
  blur inputs every frame and the cache would miss on every costly frame.

- **Hand-drawn border redraws at 30Hz although its wobble changes only
  ~3×/s.** *(low · **[implemented → `claude/perf-handdrawn-redraw`]**)* The
  animated-style timer runs at 30Hz for both ants and hand-drawn
  (`:103`), but the hand-drawn seed is
  `Int(Date().timeIntervalSinceReferenceDate * 3)` (`:230`) — it changes
  3×/s. So 27 of every 30 redraws regenerate a pixel-identical
  `wobblePath` (a loop over ~perimeter/16 points, two 64-bit hashes each)
  and re-stroke it (plus the Gaussian passes if glow/shadow are on) for an
  identical frame. Ants genuinely needs ~30Hz (its dash phase advances
  continuously); hand-drawn is paying a 10× redraw tax. Fix (preferred —
  exact 3 redraws/s, no latency): extract the seed into a shared static
  `currentWobbleSeed()` used at `:230`, and in the animation timer branch
  on `BorderStyle.current` — `.ants` keeps `needsDisplay = true` every
  tick; `.handDrawn` computes the seed and only sets `needsDisplay` when it
  differs from a cached `lastAnimatedSeed`. Keep the 30Hz timer so the
  change is observed within ~33ms. Live settings/geometry changes still
  repaint immediately via the existing `updateFrame` path, so the gate
  doesn't delay a slider tweak; under Reduce Motion no timer runs.

- **Live-drag tracking re-runs the whole focus-resolution chain every 30Hz
  tick.** *(low · needs on-device confirmation)* During a drag the timer
  calls `refresh()` → `currentFocusedWindow()` every tick (`:566-569`).
  The z-order block is correctly skipped (`dragTimer != nil`, `:1059`), but
  the code still re-derives the window from scratch — `focusedWindowElement()`
  reads `AXFocusedUIElement` then `AXWindow` (2 IPC) and the fallback reads
  `axFrame` (a 3rd) — to re-discover a window that's already in
  `lastFocusedWindow` and *cannot change focus mid-drag* (you're holding
  its title bar). ~90 AX IPC/s where ~30 would do. Fix: in `refresh()`,
  before the unconditional resolution at `:662-663`, add a drag fast-path:
  `if dragTimer != nil, let dragged = lastFocusedWindow, let frame = axFrame(of: dragged) { resolved = (dragged, frame) }` else fall through to
  the full `currentFocusedWindow()`. A window-closed nil or a stalled read
  (which sets `lastResolutionTimedOut`) falls back to full resolution; the
  mouse-up `refresh()` re-syncs focus. Everything downstream is untouched.

---

## Visual issues

- **The border can't straddle two displays.** *(low · needs on-device
  confirmation)* The border is one `highlightWindow` (`:17`), and every
  placement funnels through its single `setFrame` (`HighlightWindow.swift:53`).
  An `NSWindow` has one backing store at one `backingScaleFactor` — that of
  the display it's mostly on — so when the frame spans a Retina (2×) and a
  non-Retina (1×) display, the half on the mismatched display is rendered
  at the wrong scale and resampled by the window server: soft/blurry, and
  the 1px stroke lands off the pixel grid. Spotlight mode already solves
  exactly this with a per-screen `DimWindow` pool (`:893-910`); the border
  never got the same treatment (round two's #1, round four's carryover).
  Fix: mirror the pool. Replace `highlightWindow` with
  `borderWindows: [HighlightWindow]`; add a reconcile that grows/shrinks to
  `NSScreen.screens.count` (screen attach/detach already routes through
  `didChangeScreenParameters` → `forceUpdate`); add
  `placeBorder(fullFrame:)` that, for each `(window, screen)`, pins the
  window to `screen.frame` (so AppKit assigns that screen's scale) and
  hands it the full padded target frame to draw, ordering out windows the
  frame doesn't touch. The one subtlety the DimWindow case doesn't face:
  `HighlightView` can no longer assume `bounds == padded rect`, so give it
  a `globalBorderRect` (padded target in global Cocoa coords) and in
  `draw` translate it into the window's local space by the window origin,
  letting the window bounds clip each screen's slice. Fan
  setPartyMode/setBorderStyleAnimating/orderOut/pulse and the three
  `moveBorder` paths over the pool (run redraw timers only on visible pool
  windows); the glide already drives from a single `displayedBorderFrame`,
  so each tick just fans one rect across the pool — no new animation state,
  matching the DimWindow precedent.

- **Overlays sit above the menu bar and Dock (`.statusBar` level), so the
  spotlight dim and the halos paint over them.** *(low ·
  **[implemented → `claude/visual-spotlight-chrome`]** for the dim half)*
  Both overlays use `level = .statusBar` (25), above `.mainMenu` (24) and
  the Dock (20). Two consequences: (1) each `DimWindow` is sized to the
  full `screen.frame` (`:908`), not `visibleFrame`, so the black dim
  **covers and dims the menu bar and Dock**; (2) the border's
  glow/stronger-shadow halo (up to 70pt) paints over Dock icons and the
  menu bar when the focused window is near a screen edge. Fix the always-on
  dim half: in `updateDimWindows` (`:904-909`) pass `screen.visibleFrame`
  instead of `screen.frame` and test `cutout.intersects(screen.visibleFrame)`;
  `DimWindow.update` already offsets the cutout by the window origin, so the
  local math stays correct. *Don't* lower the dim window's level — it must
  stay above app windows to dim them; frame size is the right lever. (If
  dimming the chrome is actually intended, keep it and document it, ideally
  behind a "dim menu bar & Dock" preference defaulting on.) The halo-over-
  chrome half is a judgment call for opt-in effects at a screen edge:
  either lower *only* the border window to a level in (3, 20), or clip the
  stroke/glow/shadow out of the menu-bar/Dock rects in `HighlightView.draw`.

- **A border the same color as the content behind it is invisible — no
  contrast casing, and Increase Contrast is ignored everywhere.** *(medium
  · **[implemented → `claude/visual-contrast-casing`]**)*
  `currentBorderColor()` (`:194-208`) returns one flat color and
  `drawBorder` strokes exactly that — no second contrasting hairline. A
  black default border over a dark title bar, a white one over white
  chrome, or a per-app hash color matching app content, and the border
  vanishes, defeating the whole app. Separately,
  `accessibilityDisplayShouldIncreaseContrast` is never read anywhere, so
  the Increase Contrast accessibility setting changes nothing. Fix: add a
  contrasting casing under the main stroke. Add a
  `perceptualLuminance()` helper on `NSColor` (converting via
  `usingColorSpace(.sRGB)` first — required, because the color can be a
  party HSB or catalog color on which `redComponent` would trap); read
  `increaseContrast` once; pick
  `casingColor = NSColor(white: luminance > 0.5 ? 0 : 1, alpha: increaseContrast ? 0.85 : 0.45)`,
  casing width 2 (3 under Increase Contrast); stroke a copy of the path
  `effectiveWidth + casingWidth` wide immediately *under* each of the three
  main strokes (keep it out of the stronger-shadow even-odd clip). Bump
  `shadowMargin`'s base from 25 to 27 so the wider casing can't clip at the
  extreme. The accessibility observer at `:154-160` already repaints on
  toggle, so it applies live. Optionally gate the casing entirely on
  `increaseContrast` to preserve the exact default look. (This is the same
  idea as *Contrast casing* under Ideas — one implementation serves both.)

- **Default square corners (`cornerRadius` 0) overhang the window's real
  ~10pt rounded corners.** *(low)* `Key.cornerRadius` registers to `0`
  (`AppDelegate.swift:31`) and radius-0 takes the square path
  `NSBezierPath(rect:)` (`HighlightWindow.swift:234`). Every modern macOS
  window has ~10pt rounded corners (the app itself hardcodes
  `Defaults.windowCornerRadius = 10` for the spotlight cut-out), so at the
  default inset 4 / width 5 the square border's corner tips float ~2pt
  diagonally past the glass at all four corners. Round four flagged this as
  an explicit maintainer call because changing the registered default
  alters every existing install's look. Fix (opt-in polish, don't silently
  change the default): add a "Corner style" control (Auto / Square /
  Custom) beside the radius stepper; in `drawBorder`, Auto computes a
  concentric `radius = max(0, Defaults.windowCornerRadius - inset)` so the
  border's corner arc is concentric with the glass and never overhangs, and
  apply the same computed radius to the stronger-shadow inner-exclude path.
  Defensible to leave as-is given the overhang is only ~2pt.

- **The Appearance preview clips glow/stronger-shadow halos against its own
  bounds.** *(low)* The preview sets `masksToBounds = true` (`:159`) and
  draws the mock window at `bounds.insetBy(dx: 90, dy: 38)` (`:785`); a
  stronger shadow (25pt blur + 3pt offset) at large widths reaches ~38pt
  past the frame — at/past the preview edge — so the halo is hard-clipped
  top and bottom, showing a squared-off halo the user won't actually see.
  Fix: give the mock window room to clear the halo — enlarge the vertical
  inset (e.g. `dy: 52`) and bump `previewView.heightAnchor` from 150 to
  ~190. **Correction to the naïve fix:** removing `masksToBounds` does
  *not* help — a layer-backed view can only paint into its bounds-sized
  backing store during `draw`, so the halo is clipped regardless; that flag
  only controls the 6pt corner rounding. Only enlarging the room (or
  shrinking the mock window inside a taller preview) eliminates the clip.
  Low priority — the clip is a faint ~1pt tail visible only at
  width 20 / inset 1 with stronger shadow.

- **The stronger shadow drops the wrong way in the real overlay and
  disagrees with the preview.** *(low · needs on-device confirmation)*
  `shadow.shadowOffset = NSSize(width: 0, height: -3)` (`:283`) is
  interpreted in the view's user space. `HighlightView` is flipped
  (`isFlipped { true }`, `:164`) so `-3` pushes the shadow *upward*
  on-screen (an unnatural "drop" going up); `BorderPreviewView` is *not*
  flipped, so the same code drops it downward. Net: the shadow falls on
  opposite sides in preview vs. overlay, and the overlay's is arguably
  upside-down. The 3pt offset under a 25pt blur makes it subtle, which is
  why it survived. Fix: derive the sign from the context —
  `let flipped = NSGraphicsContext.current?.isFlipped ?? false; shadow.shadowOffset = NSSize(width: 0, height: flipped ? 3 : -3)` —
  so both draw sites cast a natural downward drop. Leave the glow (offset
  0,0) alone. Confirm the drop direction visually on device.

---

## Interface & UX

- **⌘W can't close the Settings window.** *(low ·
  **[implemented → `claude/settings-cmd-w`]**)* `MainMenu.xib` has App,
  Edit, and Window menus but **no File menu and no Close item**; the Window
  menu has Minimize (⌘M), Zoom, and Bring All to Front only. So ⌘W has no
  key equivalent and the Settings window can only be closed with the mouse
  (round-four carryover; the round-five naming fix below touches the same
  file). Fix: add a File menu with a "Close" item (`keyEquivalent="w"`,
  action `performClose:` to First Responder) — ~10 lines of xib — or, if a
  File menu is unwanted for a preferences-only app, add "Close" to the
  Window menu. The Settings window is already `.closable`, so
  `performClose:` works.

- **The app menu says "Preferences…" while the rest of the app says
  "Settings".** *(low · **[implemented → `claude/settings-cmd-w`]**, same
  file)* The menu-bar item is titled "Preferences…" (`MainMenu.xib:28`) but
  the status-menu item is "Settings…" (`AppDelegate.swift:107`) and the
  window title is "Alan Settings" (`PrefsWindowController.swift:70`). In
  `.regular` mode the user sees both terms for the same window. Fix: change
  the xib title to "Settings…", keeping `keyEquivalent=","`, the id, and
  the `showPrefs:` connection. Pure string edit. (Folded into the ⌘W branch
  since both edit `MainMenu.xib`.)

- **The hotkey recorder accepts reserved combos and rejects bare F-keys.**
  *(medium · **[implemented → `claude/shortcut-recorder-policy`]**)* The
  local key monitor (`beginRecording`, `:894-916`) requires a modifier and
  otherwise beeps, with **no deny-list** — so the user can record ⌘Q, ⌘W,
  ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z; `RegisterEventHotKey` then swallows that keystroke
  system-wide to flash the border (record ⌘C and the flash fires on every
  copy). The title only shows "— in use" *after* registration already
  failed; it never prevents the footgun. Fix (two additions in the monitor
  closure): (A) a reserved-combo check via
  `isReserved(keyCode:flags:)` — `flags == [.command]` for
  Q/W/C/V/X/A/Z, plus `[.command, .shift]` Z (Redo) — using exact `==` on
  the already-intersected `flags`; on a hit, beep, set the title to
  "Reserved by macOS" with a tooltip, and `return nil` *without* calling
  `endRecording()` so the monitor stays live to retry. (B) allow bare
  F-keys: build a `Set<Int>` of `kVK_F1…kVK_F12` (explicit set, **not** a
  range — `kVK_F1...kVK_F20` is `122...90` and traps), and let a function
  key bypass the modifier guard. `carbonModifiers` already yields 0 for a
  bare key and `RegisterEventHotKey` accepts it; no downstream change. (On
  hardware where F-keys are media keys by default, a bare F-key may need Fn
  — worth an on-device check; keep (A) as the priority.)

- **Launch-at-login failure is a silent beep with no guidance.** *(medium ·
  **[implemented → `claude/launch-login-guidance`]**)*
  `launchAtLoginChanged` does nothing but `NSSound.beep()` on a thrown
  error (`:601-603`). The most common cause of `SMAppService.register()`
  failing is Gatekeeper **app translocation** — the user ran Alan straight
  from ~/Downloads, so it executes from a randomized read-only
  `/private/var/folders/.../AppTranslocation/` path and login-item
  registration is refused; the checkbox flips back with no explanation.
  Fix: replace the bare beep with an `NSAlert` (sheet on the prefs window)
  that always surfaces `error.localizedDescription`, and *additively*
  detects translocation / non-`/Applications` install
  (`Bundle.main.bundlePath.contains("/AppTranslocation/")` or not under
  Applications) to append "Move Alan to your Applications folder, relaunch,
  then try again" with a "Reveal in Finder" button wired to
  `NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])`.
  Keep the `refreshLaunchAtLoginStatus()` call so the checkbox reflects the
  true status. Guard the button-index handling so "Reveal in Finder" only
  exists when the translocation branch added it.

- **Deprecated `NSApp.activate(ignoringOtherApps:)` at three sites.** *(low
  · **[implemented → `claude/fix-appdelegate-modernize`]**)* Deprecated as
  of macOS 14; called at `AppDelegate.swift:172` (toggleHideDock), `:177`
  (showAbout), `:263` (showPrefs). With a 15.7 deployment target the
  no-arg `activate()` is always available. Replace all three; each is
  user-initiated and paired with `makeKeyAndOrderFront`, so the system
  honors the switch. (Bundled with the permission-alert `abortModal` guard
  since both touch `AppDelegate`.)

- **Ad-hoc signed updates re-break the Accessibility grant — undocumented.**
  *(medium · needs on-device confirmation)* Releases are only ad-hoc signed
  (`README.md:52-57`; `release.yml` uses `CODE_SIGN_IDENTITY=-`). macOS TCC
  keys the Accessibility grant to the binary's code-signing identity; an
  ad-hoc signature isn't a stable Developer ID, so a freshly downloaded
  version can present as a different app and require re-granting
  Accessibility. The README's Install section walks the quarantine dance
  but says nothing about this, so on the first update the app silently
  stops drawing borders. Fix (two parts): (1) **Docs** — add an "Updating"
  subsection to the README (and a line to `release.yml`'s `--notes`)
  telling the user to remove the old "Alan" row in System Settings →
  Privacy & Security → Accessibility and re-add `/Applications/Alan.app`,
  and stating that Developer ID signing + notarization is the long-term
  fix. (2) **Runtime** (recommended, since the current alert text is
  misleading on update) — remember a prior grant with a
  `Key.hadAccessibilityGrant` defaults flag; if trust is currently false
  but the flag is true, branch the permission alert's `informativeText` to
  an update-specific message. The flag only transitions false→true; the
  branch changes wording only.

- **No test target despite pure, permission-free seams and a macOS CI
  runner.** *(low)* Single app target, no test target (verified in
  `project.pbxproj`), yet many pure functions would run headless on the
  existing runner: `perAppColor` djb2 hue stability (`Extensions.swift:14`),
  `cocoaRect(fromAXRect:)` flip (`:1237`), `windowFillsScreen` /
  `framesRoughlyEqual` (`:941`, `:1194`), the smoothstep glide (`:866`),
  shake reversal logic (`:347`), `carbonModifiers`
  (`PrefsWindowController.swift:930`), `wobbleNoise` determinism
  (`HighlightWindow.swift:352`). These encode exactly the invariants that
  regress silently (hash stability across launches, coordinate math,
  clamping). Fix: add an `AlanTests` XCTest bundle (logic tests, no app
  host) to the project and a `xcodebuild test` step to CI
  (`ENABLE_TESTABILITY=YES` is already set). `@testable` doesn't expose
  `private`, so lift the `private` seams to internal (or refactor the two
  NSScreen-dependent ones to take injected geometry:
  `cocoaRect(fromAXRect:primaryScreenHeight:)`,
  `windowFillsScreen(_:in screens:)`). Start with the four unambiguously
  pure ones (`perAppColor`, `carbonModifiers`, `wobbleNoise`,
  `framesRoughlyEqual`). *Note:* hand-editing `project.pbxproj` to add a
  target is error-prone and can't be build-verified off-device, so this is
  best done with Xcode in hand.

- **CI doesn't pin an Xcode version.** *(low ·
  **[implemented → `claude/ci-pin-xcode`]**)* Both workflows build on
  `macos-26` (`ci.yml:23`, `release.yml:28`) with whatever Xcode that
  rolling image ships by default; a toolchain bump can break the build with
  no code change, and a failure then means "the image moved" rather than
  "the code broke". Fix: add a `Select Xcode` step (`sudo xcode-select -s
  /Applications/Xcode_<ver>.app`) before the build in **both** files, plus
  an `xcodebuild -version` log line so a future image change fails loudly.
  **Pick a version actually present in the `macos-26` manifest** — the
  image ships Xcode 26.x, so `16.x` is wrong; a safer form that avoids
  hard-coding a folder name is `maxim-lobanov/setup-xcode` with
  `xcode-version: latest-stable`. CI-hygiene only; doesn't affect the
  shipped app.

- **No localization — all user-facing strings are hard-coded English.**
  *(low)* No `.strings`/`.xcstrings`; only `Base.lproj/MainMenu.xib`. Every
  literal is inline: the permission alert (`AppDelegate.swift:207-218`),
  status-menu titles (`:95-121`), all Settings labels/tooltips, the
  shortcut recorder. Fix: add a `Localizable.xcstrings` catalog, route
  literals through `String(localized:)` (use positional format args for
  interpolated app names, e.g. the "Exclude "…"" title), and enable Base
  Internationalization on `MainMenu.xib`. Mechanical, stageable, no runtime
  impact for the English build — lowest priority.

- **Scattered `UserDefaults` reads / no `Settings` facade.** *(low,
  refactor · carried from round two)* Three classes read raw defaults keys
  at draw time (30–60×/s during drags and pulses), each re-clamping inline
  (width/inset/radius clamps in `drawBorder`, dim-level clamps in two
  places, glide-duration clamp in `makeGlideTimer`). A small `Settings`
  facade would centralize the keys, the clamping, and the default values in
  one place, remove the duplicated clamp logic, and make the observed-keys
  list impossible to forget to update. Pure internal cleanup; no behavior
  change; best paired with the test target so the clamping is covered.

---

## Missing features

- **No "show overlays in screenshots" toggle.** *(low ·
  **[implemented → `claude/show-in-screenshots`]**)* Both overlays
  hard-code `sharingType = .none` (`HighlightWindow.swift:33`, DimWindow
  `:384`) — the right default (a pulsing border broadcast to a meeting is
  noise), but an absolute ceiling: anyone documenting their setup, filing a
  bug with a screenshot, or presenting Alan itself literally cannot capture
  the border or the dim. Fix: add `Key.showInScreenshots` (default off; add
  to `allObservedKeys` for live application); replace the hard-coded
  `.none` with `applySharingType()` in both window `init()`s that sets
  `.readOnly` when the key is on, `.none` otherwise (`.readOnly`, not
  `.readWrite`, is the correct capture-visible value); call
  `applySharingType()` on the border window and each dim window from
  `forceUpdate()` so the toggle applies live; add a Behavior-tab checkbox.

- **No update mechanism.** *(low · **[implemented →
  `claude/update-check`]** as a manual menu item)* Nothing checks for a
  newer build; the README links `releases/latest` and expects the user to
  notice. For a Dock-icon-hiding background utility, a user can run a
  months-old version forever. Sparkle needs a stable Developer ID the
  ad-hoc pipeline doesn't have, so a lightweight check is the fit. Fix: a
  dependency-free `UpdateChecker` — GET
  `https://api.github.com/repos/L-K-M/Alan/releases/latest`
  (`Accept: application/vnd.github+json`) on a background `URLSession`,
  fail silently on any error; decode `tag_name`/`html_url`; **compare
  versions component-wise numeric, not string** (split on `.`, pad, map to
  Int — a string compare mis-orders "2.10.0" vs "2.9.0") against
  `CFBundleShortVersionString`. Ship the **manual** "Check for Updates…"
  status-menu item first (bypasses any gate, gives explicit "up to date"
  feedback); an optional automatic weekly check (gated on a
  `lastUpdateCheck` date, a `skippedVersion` to avoid re-nagging, and an
  opt-in `automaticallyCheckForUpdates` preference defaulting off given the
  fork's privacy posture) can follow.

---

## Ideas — novel, delightful, quirky

- **Focus trail: a fading ghost border on the window you just left.**
  *(medium · **[implemented → `claude/idea-focus-trail`]**)* When focus
  moves A→B the border snaps to B with no memory of where it came from. A
  ghost border that lingers on A and fades over ~0.8s shows the *direction*
  of your attention and reinforces spatial memory of your layout — Cmd-Tab
  becomes visible motion. The trigger and both rects already exist:
  `refresh()` computes `focusChanged` (`:723`) and `displayedBorderFrame`
  (`:73`) still holds where the outgoing border is on screen. Fix: add
  `Key.focusTrail` (default off, in `allObservedKeys`) and
  `Defaults.ghostTrailDuration` (~0.8). Create `GhostBorderWindow` cloning
  `HighlightWindow`'s setup, contentView a `HighlightView` drawing a static
  border. In `refresh()`, just before `showHighlight(at:)` (`:740`), guard
  on `focusTrail`, `focusChanged`, `dragTimer == nil`, `animateMovement`,
  and — **critical** — `highlightVisible == true` (else a stale
  `displayedBorderFrame` from before a hide/pause/exclude flies the ghost
  in from a phantom spot), capture
  `outgoing = spotlightMode ? displayedCutout : displayedBorderFrame`
  (require non-nil and ≠ `cocoaFrame`), position the ghost there, and fade
  `alphaValue` 1→0 over the duration via `NSAnimationContext`, ordering out
  on completion; restart on a mid-fade focus change. Whole-window alpha
  fade needs no per-frame redraw. Under Reduce Motion, a single static
  reveal.

- **Match the system accent color as a zero-config border source.**
  *(medium · **[implemented → `claude/idea-accent-color`]**)*
  `currentBorderColor()` has party / per-app / light-dark wells but no "just
  use my Mac's accent color." `NSColor.controlAccentColor` is dynamic,
  tasteful, needs no color-picking, and updates when the user changes their
  accent — the most zero-effort good-looking option the app could offer.
  Fix: add `Key.useAccentColor` (default off, in `allObservedKeys`); in
  `currentBorderColor()` insert a branch after party and per-app, before
  the wells: `if useAccentColor { return NSColor.controlAccentColor }`
  (a dynamic catalog color, resolves light/dark automatically); add an
  Appearance-tab checkbox that greys out the two wells and the per-app
  checkbox when on. **Load-bearing detail:** an accent change does *not*
  fire `viewDidChangeEffectiveAppearance`, so register a
  `NSColor.systemColorsDidChangeNotification` observer in `start()` whose
  handler calls `forceUpdate()` (gate it on `useAccentColor` to avoid
  churn when off).

- **Viewfinder / corner-bracket border style.** *(low ·
  **[implemented → `claude/idea-viewfinder-style`]**)* A new `BorderStyle`
  drawing only four L-shaped corner brackets (a camera-focus reticle)
  instead of a full outline — on-the-nose for an app about *focus*, crisp
  and modern, covers far less content. Fix: add `case corners` to
  `BorderStyle` (`Constants.swift:87`) — the `label` switch is exhaustive,
  so add `case .corners: return "Corner brackets"` (mandatory to compile) —
  and to `borderStyleNeedsAnimation()`'s exhaustive switch
  (`FocusHighlighter.swift:774`) add `case .corners: return false`
  (mandatory). In `drawBorder`, before the handDrawn/radius/rect branch,
  build one `NSBezierPath` with four disjoint corner subpaths from
  `borderBounds` (arm length `max(8, min(w,h) * 0.18)`, clamped per
  dimension so opposite arms can't overlap), `lineCapStyle = .round`. The
  dash block is already style-gated (skipped for `.corners`), and
  effectiveWidth / stronger-shadow / glow / base stroke / pulse all apply
  to the bracket path unchanged. The preview renders it live for free.

- **Contrast casing.** *(low)* Same mechanism and payoff as the *A border
  the same color as the background is invisible* visual bug above — a
  hairline in the perceptual opposite that you never notice until the
  border would otherwise vanish, and the natural response to Increase
  Contrast. Implemented via `claude/visual-contrast-casing`; a
  user-facing `Key.contrastCasing` toggle can gate it in addition to the
  automatic Increase-Contrast trigger.

- **Sonar-ping find animation.** *(low)* `flashBorder()` only strobes the
  existing border — which fails at exactly the moment it's needed, when the
  border is hard to see. One or two stroked rings expanding from the window
  center and fading over ~0.5s draw the eye to the *location* independent of
  border color/contrast. Fix: a transient `PingWindow` (same click-through,
  `sharingType=.none` setup as `HighlightWindow`) framed to the focused
  window's screen; content view draws N concentric rounded-rects at
  `radius = progress * maxReach`, `alpha = 1 - progress`, stroke =
  `currentBorderColor()`; driven by a `Defaults.findPingDuration` (~0.5s)
  timer; center from the frame already resolved in `flashBorder` (`:376`).
  Gate on a `Key.findAnimation` ("flash" | "ping", *not* in
  `allObservedKeys` — it only matters when the gesture fires); shared by the
  hotkey, shake, and Space-change flash since all route through
  `flashBorder`. Under Reduce Motion, a single static ring held briefly.

- **Spotlight and border at the same time.** *(low · needs on-device
  confirmation)* `showHighlight()` treats them as mutually exclusive (the
  spotlight branch `orderOut`s the border), but `flashBorder` already proves
  the border composites cleanly over the dim. Dim-plus-border gives both a
  soft attention funnel and a crisp colored edge, and re-enables the pulse
  (currently disabled in spotlight). Fix: `Key.spotlightWithBorder`
  (default off, in `allObservedKeys`); split the spotlight branch to call
  `moveSpotlight` *and* `moveBorder` (with the border-branch timer setup)
  when on; elevate the border to `.statusBar + 1` so it stays above the
  per-screen dim windows that re-front each glide tick (reset when off);
  relax the pulse guard (`:742-743`) to allow the pulse when
  `spotlightWithBorder`; add a Behavior-tab checkbox indented under
  spotlight and un-gate the pulse checkbox; draw the border in the preview's
  spotlight branch too. Verify on device the border stays above all
  `DimWindow`s across a full glide.

- **Per-app colors sampled from the app icon's dominant color.** *(low ·
  needs on-device confirmation)* `perAppColor` hashes the bundle ID —
  stable but arbitrary (Slack isn't aubergine). Sampling the icon makes the
  color *mean* something the user already associates with the app. Fix:
  keep the djb2 path as a guaranteed fallback; layer icon sampling in front,
  cached per bundle ID (`[String: CGFloat?]`, nil = "sampling failed /
  monochrome, use hash" — memoize both outcomes; drawBorder runs at
  30–60Hz so uncached per-draw sampling is unacceptable). Sample the 32×32
  icon rep into a bitmap context, build a coarse saturation-weighted hue
  histogram skipping near-gray/low-alpha pixels. **Distinctiveness guards
  make it worth shipping:** if the top hue bin is < ~35% of total weight
  (gradient/rainbow icons) or overall max saturation < ~0.3 (Terminal,
  monochrome), fall back to the hash; keep the icon *hue* but render at the
  hash path's fixed saturation/brightness so legibility and light/dark
  behavior are identical to today. Worst case degrades to the current
  well-spread hash, never a pile of indistinguishable blues.

- **Hold-to-spotlight quasimode on the find-my-window hotkey.** *(low ·
  needs on-device confirmation)* The hotkey is a tap that flashes; make
  *holding* it dim everything else for as long as it's held — press to ask
  "where am I?", see it, release, back to work; no persistent setting
  toggled. Carbon delivers `kEventHotKeyReleased` too. Fix: install the
  handler for both press and release (2-element `EventTypeSpec` array,
  dispatch on `GetEventKind`), gate behind `Key.holdToSpotlight`; on press
  start a ~0.25s timer that, if still held, enters a transient dim; on
  release, invalidate and either `flashBorder` (tap) or restore. Route the
  dim through a `spotlightActive` accessor
  (`heldSpotlightActive || Key.spotlightMode`) used at the two sites that
  decide dim-vs-border, so the normal `refresh()` path follows focus for
  free. **Safety net** (release can be dropped if modifiers lift first): a
  max-hold cap timer and a transient `.flagsChanged` monitor that both call
  the same cleanup. Verify `kEventHotKeyReleased` fires on device; the
  safety net makes a dropped release non-fatal regardless.

- **Warp the cursor to the focused window on find-my-window.** *(low ·
  needs on-device confirmation)* Losing the window and losing the pointer
  are the same moment; an opt-in warp brings eye and hand home at once. Fix:
  `Key.warpCursorOnFind` (default off, *not* in `allObservedKeys`); in
  `flashBorder`, right after the resolve at `:375` and **before** the
  `cocoaRect` flip, `CGWarpMouseCursorPosition(CGPoint(x: axFrame.midX, y: axFrame.midY))`
  then `CGAssociateMouseAndMouseCursorPosition(1)` (so the cursor doesn't
  feel stuck for the ~0.25s HID interval after a warp). Use `axFrame`
  directly — it shares the top-left global Quartz space with
  `CGWarpMouseCursorPosition`, so the cocoa flip must be skipped or the
  cursor lands mirrored. Wires up the hotkey, shake, and Space-change
  gestures at once. Verify on a secondary/negative-origin display and
  confirm no post-warp stick during a shake.

- **Transient "who has focus" chip (app icon + name).** *(low)* On focus
  change, briefly float a small app-icon + name chip near the focused
  window's top edge for ~0.8s, then fade — answers "what did I just switch
  to?" at a glance, and is especially valuable in spotlight mode where the
  dim hides every other cue. Fix: `Key.showFocusChip` (default off, in
  `allObservedKeys`), `Defaults.focusChipDuration` (~0.8s); a reusable
  `FocusChipWindow` (HighlightWindow setup) with a horizontal stack of
  icon + truncating label on a rounded translucent backing. Hook in the
  `focusChanged` sub-branch (`:742-746`) next to the pulse, suppressed while
  dragging. **Refinement:** derive identity from the *resolved* window
  (`AXUIElementGetPid(windowElement)` → `NSRunningApplication`), not
  `frontmostApplication`, to handle the out-of-process panel-service case;
  position centered above `cocoaFrame`, clamped into the screen's
  `visibleFrame` (flip below if no room). Reuse one instance; hide it in
  `hideHighlight`/paused/Space-change to avoid a stale chip.

- **Squash-and-stretch the border as it glides.** *(low)* `makeGlideTimer`
  interpolates 1:1 — correct but inert. Letting the rect briefly stretch
  toward the travel direction at mid-glide and settle at the end (a gentle
  comet/momentum feel) turns the "stage light swinging across the screen"
  metaphor into something that reads as motion. Fix: because
  `makeGlideTimer` is shared with `moveSpotlight`, thread a
  `stretch: Bool = false` param and pass `true` only from `moveBorder`; in
  the else-branch, from the raw `t` (already in scope) compute a
  `sin(t·π)`-enveloped deform gated on travel distance (> ~80pt) and capped
  (~24pt), growing the dominant axis and shrinking the other, re-centered on
  the eased rect. `updateFrame` always insets by `-shadowMargin`, so a
  larger rect just makes a larger window — no clipping, no margin-budget
  concern. `moveBorder` already bypasses the glide under Reduce Motion, so
  the stretch code is unreachable there. Pure aesthetic polish; tune on
  device.

- **Optional quiet click on focus change.** *(low)* An opt-in, debounced
  soft click (or `.alignment` haptic) on focus change for low-vision users
  who can't hunt for the border — the audio counterpart to the flash,
  completing the accessibility story alongside Reduce Motion and Increase
  Contrast. Fix: `Key.focusSound` (register false; *not* in
  `allObservedKeys` — read live at play time); a preloaded `NSSound`
  (bundle a short asset; guard the optional so a missing sound is a silent
  no-op) at low volume; in the `focusChanged` branch (`:742-745`), if the
  key is on and > 0.3s since the last play, `stop()` then `play()`. For
  genuine accessibility value, compute a lightweight focus-changed check
  *before* the maximized/full-screen returns (`:700-719`) so the cue still
  fires there. Add a Behavior-tab checkbox (not gated on spotlight — audio
  is orthogonal). Everything off by default.

---

## What ships alongside this document

Each on its own branch off `bb0cbe8`, chosen for **high implementation
confidence, clear value, and low regression risk** (this review ran with no
macOS to build against, so display-link/CAShapeLayer rewrites, the
per-display border pool, the test target, and localization are documented
above but deliberately *not* shipped blind). Branches are grouped to touch
disjoint files/functions so PRs merge cleanly; the few that share a file
(`FocusHighlighter.swift`, `PrefsWindowController.swift`, `MainMenu.xib`)
touch different functions.

| Branch | Contents |
|---|---|
| `claude/fix-copy-window-raw-bounds` | **Headline.** Raw-bounds last resort in `currentFocusedWindow()` (draw at the topmost window-server bounds when AX can't name the window), optional element threaded through `refresh()`, bounded settle-refresh retry chain, raised `appWindowMatching` cap, layer ceiling to modal-panel level |
| `claude/fix-glide-timer-leak` | Cancel the opposite mode's glide timer in `showHighlight`; make `flashBorder` own the overlays so a stray glide can't resurrect a hidden border/dim |
| `claude/fix-flashborder-live-frame` | Re-query the focused window's frame per flash on-phase so the flash points where the window *is now* |
| `claude/fix-observer-create-retry` | Arm a retry on `AXObserverCreate` failure, matching the partial-registration path |
| `claude/fix-appdelegate-modernize` | Guard the permission-alert `abortModal` on `NSApp.modalWindow != nil`; replace three deprecated `activate(ignoringOtherApps:)` calls |
| `claude/fix-preview-idle-wakeups` | Drive the Settings-preview redraw timer from window occlusion so it stops on close instead of ticking 30×/s forever |
| `claude/perf-handdrawn-redraw` | Gate hand-drawn redraws on the wobble seed (~3/s) instead of 30/s |
| `claude/shortcut-recorder-policy` | Reserved-combo deny-list (⌘Q/W/C/V/X/A/Z, ⇧⌘Z) with feedback; allow bare F-keys |
| `claude/launch-login-guidance` | Replace the silent beep with an alert surfacing the real error + translocation guidance + Reveal in Finder |
| `claude/settings-cmd-w` | Add a File▸Close (⌘W) menu item; rename app-menu "Preferences…" → "Settings…" (both in `MainMenu.xib`) |
| `claude/ci-pin-xcode` | Pin the Xcode toolchain in `ci.yml` and `release.yml` |
| `claude/show-in-screenshots` | Opt-in "show overlays in screenshots and recordings" toggle (`.readOnly` vs `.none`) |
| `claude/update-check` | Manual "Check for Updates…" status-menu item (dependency-free GitHub releases/latest check, component-wise version compare) |
| `claude/visual-spotlight-chrome` | Size the spotlight dim to `visibleFrame` so it no longer covers the menu bar and Dock |
| `claude/visual-contrast-casing` | Contrasting casing under the stroke + honor Increase Contrast, so the border never vanishes against matching content |
| `claude/idea-accent-color` | "Use system accent color" as a zero-config border source, live-updating on accent change |
| `claude/idea-focus-trail` | Fading ghost border on the window you just left |
| `claude/idea-viewfinder-style` | New "Corner brackets" viewfinder border style |

*Round five reviewed at `bb0cbe8`. Findings were produced by a
six-dimension fan-out review and every one adversarially re-traced against
the current code before inclusion; the handful that hinge on AppKit/AX
runtime behavior are marked needs-on-device-confirmation. The headline
raw-bounds fix is the one change most worth verifying against a real Finder
copy window.*
