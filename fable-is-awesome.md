# Alan — code review notes, round three

A third full read-through, done at v2.6.1 (`5b07a96`), this time with the
express brief of root-causing the *"a copy dialog sometimes doesn't get
the border"* report. Follows the format of `awesome.md` (round two);
items from that round that are still open are folded in below rather
than duplicated there. Everything here was checked against the actual
code with file:line references; claims that depend on runtime behavior
I couldn't observe (this review ran on Linux) are marked *needs
on-device confirmation*.

Items marked **[implemented → `branch`]** ship as their own PR alongside
this document.

---

## The headline bug: frontmost windows that never get a border

The report: when macOS opens a window like a copy window, it sometimes
doesn't receive the focus border despite being the frontmost window.
Commit `900360c` (v2.6.1) already added `kAXWindowCreated` observation,
which helps dialogs that open *focused* — but the bug persists because
there are three deeper, independent mechanisms. Ranked by likelihood:

### 1. Window resolution is keyed to *keyboard focus*, so a frontmost window that never becomes key is structurally unreachable

`currentFocusedWindow()` (`FocusHighlighter.swift:728`) starts from the
system-wide `kAXFocusedUIElementAttribute` — the element that receives
*keyboard* input — and every fallback in the chain preserves those
semantics: `AXWindow` resolves the window *containing the focused
element*, `focusedWindowOfProcess` queries the app's `AXFocusedWindow`
(which AppKit maps to the **key** window), and
`nearestWindowLikeAncestor` climbs from the same stale element.

Finder's copy-progress window is ordered front but typically does
**not** become key and contains no keyboard-focusable element (a
progress bar and a stop button). The first responder never leaves the
previous window, so the system-wide focused element still points *into
the old window*, and every fallback re-resolves that same old window.
The border stays glued to the window behind the dialog.

The "sometimes" flavor falls out naturally: dialogs that *do* take key
status (Finder's "replace the existing file?" prompt accepts ⏎/⎋
immediately, so it is key) work fine; pure ordered-front-but-never-key
windows always fail. Clicking the dialog makes it key, which is why the
bug appears to self-heal when poked. Full Keyboard Access being on can
also change whether the Stop button is focusable — more "sometimes".

One subtlety (verified against AppKit semantics): `orderFront` alone
never makes a window main either — a window becomes main by becoming
key, by explicit `makeMain`, or by promotion when the old main closes,
and `NSPanel`s can never be main. So "prefer `AXMainWindow`" is *not*
sufficient for the worst case; a robust fix needs a z-order check.
The window server knows what's frontmost even when AX's focus concept
doesn't: `CGWindowListCopyWindowInfo` (no extra permissions beyond what
Alan has) gives the frontmost app's topmost layer-0 window, which can be
matched to an AX window by frame.

**Fix (layered):** keep the existing element chain for the
out-of-process open/save panel case it was built for; otherwise resolve
from the frontmost app element: `AXFocusedWindow` → `AXMainWindow` →
cross-check against the topmost on-screen layer-0 window from
`CGWindowListCopyWindowInfo` and prefer that when it differs. There's a
buried product decision here — the README says the border shows "where
your keyboard input is going", and by *that* spec the old behavior is
arguably correct — but the bug report shows users read the border as
"the frontmost window", and that's the better spec. It should be the
documented one. **[implemented → `claude/fix-frontmost-window-resolution`]**

### 2. A single timed-out AX call hides the border, and nothing retries

`start()` sets `AXUIElementSetMessagingTimeout(systemWideElement, 0.5)`
(`FocusHighlighter.swift:59`; on the system-wide element this applies
process-wide, as the comment says). AX attribute reads are serviced by
the *target app's main run loop* — and an app that is busy mid-copy is
exactly the kind of app that takes >0.5 s to reply. On timeout,
`AXUIElementCopyAttributeValue` returns `.cannotComplete`,
`currentFocusedWindow()` collapses every non-success to `nil`
(`:736-741`), and `refresh()` responds by *hiding the border and
clearing all state* (`:402-409`). Tracking is event-driven — the code's
own comment at `:631` says "Nothing re-runs refresh() on its own" — so
after one timed-out sample the border stays gone until the next
observed event or user click. A transient hiccup becomes an
indefinitely missing border during passive watching.

**Fix:** distinguish error codes: genuine "no focused window" hides the
border as today; `.cannotComplete`/timeout keeps the currently displayed
border (the window most likely hasn't moved) and arms a short retry
with backoff. **[implemented → `claude/fix-frontmost-window-resolution`]**

### 3. AX observer registration failures are silently latched

In `observeFrontmostApp()`, every `AXObserverAddNotification` result is
discarded (`:309-311`) and `observedPid = pid` is set unconditionally
(`:317`). Registration returns `.cannotComplete` when the target app is
still launching (its AX server isn't up — the classic race when an app
is activated the instant it launches and immediately shows a window) or
when a busy app times out. When that happens, the `pid != observedPid`
guard (`:278`) then suppresses every future re-registration attempt for
as long as that app stays frontmost: its window events simply never
arrive, and any dialog it opens gets no refresh at all — border stuck
wherever it was, degraded to click-driven correction only.

**Fix:** check the `AXError`, don't latch `observedPid` until
registration fully succeeds, retry with a short backoff.
**[implemented → `claude/fix-frontmost-window-resolution`]**

### 4. (Hardening, not a proven root cause) `kAXMainWindowChanged` isn't observed, and `AXWindowCreated` samples early

The notification set (`:299-308`) lacks `kAXMainWindowChangedNotification`.
Adversarial verification talked me out of calling this a root cause —
`AXWindowCreated` + key-window transitions cover the common cases, and a
main-changed refresh wouldn't change what the *query* resolves anyway
(that's item 1's job) — but it is cheap, standard hardening: mature
window tools observe both because not every app posts every
notification, and AX trees can settle *after* `AXWindowCreated` fires,
making the synchronous refresh in the callback sample stale state. A
coalesced re-refresh ~0.25 s after window-creation events papers over
every settling race at once.
**[implemented → `claude/fix-frontmost-window-resolution`]**

---

## Other bugs

- **The shortcut recorder can't re-record the active combo.**
  `beginRecording()` installs a local `.keyDown` monitor
  (`PrefsWindowController.swift:692`), but the Carbon hotkey stays
  registered during recording, and Carbon consumes the keystroke
  system-wide before it can become an `NSEvent` — the code's own comment
  at `FocusHighlighter.swift:140` relies on exactly that. Press the
  current combo (default ⌃⌥⌘F) while recording and the border flashes
  instead; the button stays in "Type shortcut…" mode swallowing
  keystrokes. Standard recorders unregister while recording, for
  exactly this reason. Also: closing the prefs window mid-recording
  leaks the monitor — it keeps eating unmodified keys whenever Alan is
  active. **[implemented → `claude/hotkey-robustness`]**
- **A negative hotkey value in defaults crashes the app — on every
  launch.** `UInt32(UserDefaults.standard.integer(forKey:))`
  (`FocusHighlighter.swift:129-130`) traps on negative values. The
  recorder only writes valid ones, but defaults are user-editable state
  (`defaults write … findMyWindowKeyCode -- -1`), and the crash fires
  from `start()` — a crash loop until the user figures out the plist is
  the cause (requires the hotkey feature to be enabled).
  **[implemented → `claude/hotkey-robustness`]**
- **The permission alert doesn't auto-dismiss when access is granted.**
  The poll timer calls `NSApp.stopModal()` (`AppDelegate.swift:98`),
  but Apple's docs are explicit that `stopModal()` doesn't work from a
  timer callout — the flag is only checked after the modal loop
  dequeues a *real event*, and the user is off in System Settings
  generating none for Alan. `abortModal()` is the documented tool for
  exactly this case. The advertised "Alan will start by itself — no
  relaunch needed" flow currently requires a click to wake the alert.
  **[implemented → `claude/fix-permission-alert`]**
- **On a fresh install, Preferences shows wrong values until any
  setting is touched.** `AppDelegate`'s stored property builds the
  whole prefs UI during nib load, *before*
  `applicationDidFinishLaunching` calls `register(defaults:)`.
  Pre-registration, every `bool(forKey:)` is false and bound number
  fields resolve to nil: "Show border while dragging" and "Animate
  movement" render unchecked though they're on, the number fields
  render blank. `register(defaults:)` posts no notification, so nothing
  corrects the UI until an unrelated write. (Verified nuance: moving
  `register` into `AppDelegate.init` is *not* enough — stored
  properties initialize before the init body runs. The fix is a `lazy
  var` and/or registering before `NSApplicationMain`.)
  **[implemented → `claude/menu-bar-and-pause`]**
- **The "settings apply instantly from Terminal" mechanism doesn't
  exist.** The comment at `FocusHighlighter.swift:66-68` says the
  `UserDefaults.didChangeNotification` observer makes `defaults write`
  from Terminal apply immediately — but that notification is only
  posted for *in-process* changes (Apple's docs say so explicitly).
  External writes are picked up incidentally on the next redraw; the
  hotkey/shake listeners, reconciled only in `forceUpdate()`, may not
  notice until a light/dark mode switch. KVO on the specific keys is
  the documented alternative and does fire cross-process.
- **Missing `.fullScreenAuxiliary` silently defeats the Split View
  carve-out.** `refresh()` deliberately keeps the border on Split View
  tiles (`FocusHighlighter.swift:414-417`), but a Split View tile lives
  on a full-screen Space, and windows with only `.canJoinAllSpaces`
  (`HighlightWindow.swift:25`, `:237`) can't join full-screen Spaces.
  The carefully-preserved border most likely never appears there; in
  spotlight mode, a second display showing a full-screen app stays
  bright. *(Verification also killed a related claim: `.stationary` is
  unnecessary — at non-normal window levels the default behavior is
  already `.transient`, hidden by Mission Control.)*
  **[implemented → `claude/overlay-capture-and-fullscreen`]**
- **No `didChangeScreenParametersNotification` observer.** Attach or
  detach a display and the spotlight window pool stays reconciled
  against the *old* screen list until an unrelated refresh; cached
  frames in old coordinates cause a one-shot wrong-origin glide or a
  spurious border hide. **[implemented → `claude/perf-quick-wins`]**
- **Excluded-apps and per-app-color checks race
  `frontmostApplication` against the AX element's owning process**
  (`FocusHighlighter.swift:388` vs `:402`). Transient and
  self-correcting (the activation notification re-runs refresh), so
  low severity — but note for any fix: deriving the bundle ID from the
  AX window's pid *alone* would regress the open/save-panel path,
  whose windows belong to the panel-service process, not the host app.
- **`.gitignore` line 17 ignores the shared Xcode scheme CI depends
  on.** `*.xcodeproj/xcshareddata/xcschemes/*` matches
  `Alan.xcscheme`, which only survives because it was tracked before
  being ignored. Anyone who regenerates the scheme will see git
  silently ignore it — and CI fails with "scheme Alan not found" on
  the next fork or rename. Shared schemes are exactly the files that
  *should* be committed. **[implemented → `claude/repo-hygiene`]**

## General issues

- **Committed `xcuserdata`** (including a 168 KB binary
  `UserInterfaceState.xcuserstate` that Xcode rewrites every session,
  and the maintainer's username). The `.gitignore` patterns match but
  gitignore has no effect on already-tracked files.
  **[implemented → `claude/repo-hygiene`]**
- **Zero tests; CI is a compile check.** No test target exists. The
  pure logic is one small refactor from testable: the djb2 hue hash
  (pin it — users' learned colors shouldn't shift in a refactor), the
  `cocoaRect` flip, `windowFillsScreen`, the smoothstep glide math, the
  shake detector's reversal/cooldown logic, the Carbon modifier
  mapping. None of it needs AX permission, so it runs on CI.
- **CI hygiene:** no `concurrency` cancellation (five force-pushes =
  five queued macOS builds at 10× billing), no `paths-ignore` (README
  edits trigger full Xcode builds), unpinned Xcode on a rolling
  `macos-26` image, `CFBundleVersion` frozen at 1 across all releases
  (LaunchServices can launch a stale copy; update mechanisms have
  nothing to compare). `release.yml` splices the workflow-dispatch
  version input into shell without validation — write-access-only, but
  it's the exact pattern GitHub's hardening guide flags, and `1.1 beta`
  silently produces a broken tag. **[implemented → `claude/repo-hygiene`]**
- **Ad-hoc signing likely invalidates the Accessibility grant on every
  update.** Ad-hoc signatures have no stable identity, and TCC ties the
  grant to the code signature — after replacing Alan.app with the next
  release, the checkbox can look on but be dead until removed and
  re-added. Neither the README nor the release notes mention it; for an
  app that is 100% AX, every update looks like total breakage. *(Needs
  on-device confirmation; the mechanism is standard TCC behavior.)*
  Long term, a real Developer ID fixes both this and the quarantine
  dance.
- **`scripts/build.sh`/`release.sh` hard-depend on an external,
  unpinned `lkm-build` tool** that the README's build instructions
  never mention. A fresh contributor hits the error path immediately;
  the plain `xcodebuild` incantation CI uses would make a fine
  documented fallback.
- **README omits the minimum macOS version**, and the 15.7 floor is an
  odd point-release cutoff (nothing in the sources uses `#available`
  at all — it looks like an Xcode default, and it forces CI onto
  `macos-26`). Sequoia users on 15.0–15.6 download a dead app with no
  warning.
- **The scriptable-defaults surface is a real feature and completely
  undocumented** — every key in `Constants.swift` works via `defaults
  write` (albeit lazily; see the KVO bug above), yet the README
  documents exactly one key and calls it "the one remaining
  defaults-only setting".

## Performance

- **Spotlight mode repaints every screen's full backing store on the
  CPU, per frame.** `DimWindow.update` unconditionally does
  `setFrame(display: true)` + `setNeedsDisplay(.infinite)` +
  `orderFrontRegardless()` for *every screen* on every glide tick
  (60 Hz) and drag tick (30 Hz) — even screens whose content didn't
  change at all. A 5K display's backing store is ~59 MB; refilling it
  60×/s per display is the single largest cost in the app, a genuine
  battery/thermal hit. The cheap fix is skipping unchanged screens; the
  right fix is a `CAShapeLayer` with `.evenOdd` fill whose path
  animates on the render server (which also fixes ProMotion judder for
  free). **[cheap tier implemented → `claude/perf-quick-wins`]**
- **Any left-drag anywhere — text selection, scrollbars, canvas
  painting — starts 30 Hz AX polling.** The global monitor can't
  distinguish window drags from any other drag, so every tick pays
  3–4 synchronous AX IPCs into the frontmost app, and in spotlight
  mode triggers the full-screen repaint above, for the entire duration
  of, say, selecting text on a 5K display. A "stop after N unchanged
  ticks" gate keeps the feature and kills the waste.
- **`HighlightWindow.updateFrame` draws twice per tick** —
  `setFrame(display: true)` synchronously draws, then
  `setNeedsDisplay(.infinite)` schedules a second full draw, then
  `orderFrontRegardless()` posts an ordering transaction — at up to
  60 Hz, where each draw can run two Gaussian shadow passes (blur 25
  and 12) on the CPU. **[implemented → `claude/perf-quick-wins`]**
- **The Preferences preview timer runs from launch, forever, even if
  Preferences is never opened.** The prefs window is built eagerly at
  startup; `viewDidMoveToWindow` fires on window *association*, not
  visibility, so the 30 Hz timer starts at launch and survives closing
  the window (quirk: switching to another tab before closing stops it,
  because `NSTabView` detaches the view). AppKit skips actual drawing
  off-screen, so the cost is 30 zero-tolerance wakeups/s of pure
  bookkeeping — permanent, for every install, visible in Activity
  Monitor's idle wakeups. **[implemented → `claude/perf-quick-wins`]**
- **Every defaults write fans out to two blanket observers** —
  `forceUpdate()` (hotkey + shake re-registration + full refresh; a
  full AX round-trip when another app is frontmost) *and*
  `syncDynamicUI()`, which performs an `SMAppService.mainApp.status`
  XPC query per write. The sliders bind with `.continuouslyUpdatesValue`
  and color wells fire continuously, so drags produce dozens of writes
  per second. Debounce to one refresh per runloop turn; cache the
  SMAppService status. **[implemented → `claude/perf-quick-wins`]**
- **All animations are wall-clock `Timer`s** — not display-linked: the
  60 Hz glide beats against vsync (intermittent dropped/doubled
  frames), and ProMotion panels get half-rate glides next to native
  window animations. `NSView.displayLink(target:selector:)` (macOS 14+)
  is the modern answer; if the overlays move to `CAShapeLayer`, the
  render server animates and the timers disappear entirely.
- **Main-thread synchronous AX with a hung frontmost app**: dragging a
  beachballing app's window (the window server allows it) makes each
  0.5 s-capped AX call block Alan's main thread while the 30 Hz timer
  re-enters — border frozen, prefs unresponsive, for the duration.
  Per-pid failure backoff, or moving AX to a worker thread, fixes it.
- **`refresh()` pays the `AXFullScreen` IPC before its early-out** —
  hoisting the "same window, same frame, already drawn" check above
  the full-screen/maximized checks saves one IPC per tick in the
  steady state.

## Visual issues

- **Glow and stronger-shadow halos clip in a hard straight edge.** The
  stroke fits inside `shadowMargin` (verified: ≤25 pt vs ≥26 pt of
  room — the comment at `HighlightWindow.swift:161` is honest for the
  stroke), but the *soft effects* aren't budgeted: glow needs stroke
  + 12 pt of blur, stronger shadow + 28 pt (and up to ~53 pt during a
  pulse) against 25 + inset available. The Gaussian halo terminates in
  a perfect rectangle 25 pt + inset outside the window. Tellingly, the
  shadow pass clips at `insetBy(-50)` — someone budgeted 50 pt of room
  the view doesn't have. Fix: compute the margin from the enabled
  effects instead of a constant 25.
- **Default square corners overhang the window's real rounded
  corners.** With `cornerRadius` defaulting to 0 and modern macOS
  windows at ~10 pt radius, the border's corner tips (at default
  inset 4, width 5: √(8.5²+8.5²) ≈ 12.0 > 10) float outside the glass
  at all four corners, over whatever is behind. Defaulting the radius
  to ~6–8, or an "auto" mode that tracks `max(0, 10 − inset)`, fixes
  the out-of-box look.
- **The spotlight cutout borrows the border's `cornerRadius` — a
  category error.** The cutout hugs the window frame exactly (no
  inset), yet reads a knob tuned for a path inset 1–20 pt *inside* the
  frame, defaulting to 0: four bright undimmed wedges glow at the
  focused window's corners, and a decorative radius of 50 would clip
  the window's own corners. The cutout wants its own fixed ~10 pt
  radius. **[implemented → `claude/overlay-capture-and-fullscreen`]**
- **The overlays sit *above* the menu bar and Dock.**
  `.statusBar` = level 25; the menu bar is 24, the Dock 20 (verified
  arithmetic). With factory defaults nothing pokes out (stroke stays
  1.5 pt inside the frame), but enable glow or stronger shadow and the
  halo paints over the menu bar's lower edge and Dock icons; in
  spotlight mode the dim covers the menu bar outright (defensible for
  a spotlight — but then it's a choice worth documenting, not an
  accident).
- **Glow double-strokes the border**: the path is stroked once inside
  the glow's shadow state and again as the main stroke, so translucent
  border colors composite twice (50% alpha renders at 75%) — toggling
  glow visibly changes the border color, not just the halo. The
  stronger-shadow pass already solves this exact problem with an
  even-odd clip; the glow pass should borrow it.
- **The focus pulse attacks in a single frame** — scale jumps 1 → ~2.4
  on the first tick (and the configured 2.5 peak is never actually
  rendered; the first 60 Hz tick already lands past it). Reads as a
  flicker, not a swell. Two or three frames of ramp-up fix it. (The
  suspected end-snap does *not* exist — the ease-out settles smoothly;
  verified against the math.)
- **The find-my-window flash sits exactly at the WCAG 2.3.1
  three-flashes-per-second boundary** and is a binary
  `orderOut`/`orderFront` strobe — harsh next to the app's otherwise
  eased animations. A slower alpha fade reads as a beacon rather than
  a strobe. **[softened under Reduce Motion → `claude/reduce-motion`]**
- **The border still can't straddle two displays** (round two's #1,
  still open) — and two additions: the overlay crosses the display
  seam 25 pt *before* the window does (the shadow margin), and a
  single window also picks up a single display's *color space*, so a
  saturated border can visibly shift hue at the seam of a P3/sRGB
  pair. The `DimWindow` pool is the ready-made template; note the
  glide now feeds `displayedBorderFrame`, so per-screen windows must
  be driven from that single animated rect.
- **`HighlightView.isFlipped = true` is inert and only sets a trap** —
  nothing drawn depends on flippedness today, but any future
  asymmetric drawing will silently render upside-down in the overlay
  versus the (unflipped) preview that shares `drawBorder`.
- **A border the same color as what's behind it is invisible** — white
  border, dark mode, white webpage: the cue vanishes exactly when
  it's needed. A hairline "casing" in the perceptual opposite at low
  alpha (the road-rendering trick) guarantees legibility, and gives
  Increase Contrast a natural stronger setting.

## Interface & UX

- **In the default configuration there is no way into the app.** The
  status item only exists in hidden-Dock mode; clicking the Dock icon
  does nothing (no `applicationShouldHandleReopen`); the README's
  "Open Preferences from the menubar icon" instruction is wrong for
  the shipped default. **[implemented → `claude/menu-bar-and-pause`]**
- **No pause toggle.** Screenshots, screen sharing, presentations —
  the only off switch is Quit. As a defaults key it's automatically
  scriptable (Stream Deck, Shortcuts) once the KVO fix lands.
  **[implemented → `claude/menu-bar-and-pause`]**
- **`hideDock` still has no UI and demands a relaunch** — the
  activation policy flips fine at runtime; the relaunch requirement is
  self-imposed. **[implemented → `claude/menu-bar-and-pause`]**
- **"Exclude this app" takes four steps and a file dialog.** The status
  menu can offer "Exclude <frontmost app>" in one click.
  **[implemented → `claude/menu-bar-and-pause`]**
- **The first-run permission alert's only button is "Quit" — bound to
  Return.** A new user's reflexive ⏎ terminates the app on its very
  first launch, while *three* overlapping prompts fight for attention
  (the system AX dialog, System Settings opening, and the modal). And
  after the grant, nothing marks the moment — no flash, no prefs
  window, no "you're all set".
  **[implemented → `claude/fix-permission-alert`]**
- **Number fields accept 999 and −5** while the draw code silently
  clamps to 1–20 — the field, the stepper beside it, and the live
  preview all end up disagreeing.
  **[implemented → `claude/prefs-polish`]**
- **Hotkey registration failure is silent.** Record a combo another
  app owns and the recorder proudly displays a shortcut that will
  never fire — the previous working combo is already gone.
  **[implemented → `claude/hotkey-robustness`]**
- **Launch-at-login failure is a bare beep** — and the most common
  cause (running from ~/Downloads under app translocation) has a
  specific, tellable fix: "move Alan to /Applications".
- **The excluded-apps list**: Remove stays enabled with no selection,
  the Delete key does nothing, everything is single-select, and
  uninstalled apps render as raw bundle IDs with a blank icon gap.
  **[implemented → `claude/prefs-polish`]**
- **Spotlight mode disables the focus-pulse checkbox (with a lovely
  tooltip) but leaves party mode, glow, shadow, width, and both color
  wells enabled** — all equally dead in spotlight mode — and the
  Appearance preview keeps showing a border that never appears.
- **Window/menu conventions**: the settings window is titled just
  "Alan", the status menu says "Preferences…" where macOS 13+ says
  "Settings…", ⌘W closes nothing (no File menu), and the window isn't
  resizable though the app list would use it.
  **[title fixed → `claude/prefs-polish`]**
- **No update mechanism at all** — a login-item background utility
  parks on whatever version was downloaded, forever. Full Sparkle is
  disproportionate for ad-hoc-signed zips, but a weekly
  `releases/latest` check surfacing "v2.7 available" in the status
  menu is ~80 dependency-free lines.
- **All strings are hard-coded English** — fine for a hobby utility,
  but it forecloses the community translations this kind of app tends
  to attract. Worth doing before someone submits one, not after.

## Missing features (carried or new)

- **Reduce Motion is ignored by every animation** (glide, pulse,
  party, flash) — for an accessibility-adjacent utility, the audience
  most likely to have it on. One guard in `makeGlideTimer` covers both
  glides; Increase Contrast should thicken the stroke and drop the
  translucent glow. **[implemented → `claude/reduce-motion`]**
- **The overlays appear in screenshots, recordings, and screen
  shares** (`sharingType` defaults to `.readOnly`). For presenters
  this is the difference between a personal focus aid and a
  distraction broadcast to the whole meeting — spotlight mode is
  effectively unusable on a call today. `sharingType = .none` is two
  lines. **[implemented → `claude/overlay-capture-and-fullscreen`]**
- **A test target** (see General issues — the seams are already
  there).
- **Update check**, **localization** (above).

## Ideas — novel, delightful, quirky

- **Border styles: dashed, marching ants, hand-drawn.** `drawBorder`
  is the single shared routine for the overlay *and* the preview, so
  one switch statement lights up both. Ants get their phase from the
  wall clock exactly the way party mode gets its hue — the pattern is
  already in the codebase. Hand-drawn is an xkcd-style wobble from
  deterministic noise re-seeded a few times a second: the Comic Sans
  of window borders, and therefore perfect for this app. (Under
  Reduce Motion, ants freeze into a static dash.)
  **[implemented → `claude/border-styles`]**
- **Focus trail.** A ghost border on the previously focused window
  fading out over ~1 s — you see where focus *came from*. The trigger
  point and source rect are already computed in `refresh()`'s
  `focusChanged` branch; it needs its own window (the real one leaves
  immediately) and suppression during drags and Reduce Motion.
- **Per-app colors from the app icon** instead of the bundle-ID hash —
  Terminal-black, Finder-blue; the colors start *meaning* something.
  Two constraints the earlier note missed: it must be cached per
  bundle ID (icon sampling is milliseconds and `currentBorderColor()`
  runs at draw time), and "dominant color" collides badly (half of all
  icons are blue/gray) — pick the most-saturated histogram bin and
  fall back to the hash below ~0.3 saturation.
- **Spotlight + border together.** They're needlessly exclusive — the
  combined effect (dim everything else *and* ring the window) is the
  strongest possible cue, and `flashBorder` already proves the border
  composites fine over the dim. Would also un-strand the focus pulse,
  which spotlight mode currently disables.
- **Flash on Space change.** Space switches cause exactly the
  disorientation shake-to-find solves, but demand a deliberate
  gesture. `NSWorkspace.activeSpaceDidChangeNotification` + the
  existing `flashBorder()` (already `.canJoinAllSpaces`) ≈ 15 lines;
  needs a ~150 ms settle delay.
- **"Match system accent color"** as a third color source —
  `NSColor.controlAccentColor` is dynamic, tasteful, and
  zero-configuration.
- **Contrast casing** (see Visual issues) — invisible when unneeded,
  legible over anything when needed.
- **A quiet click on focus change** — an audible cue for low-vision
  users who can't hunt for the border at all. Opt-in, debounced.
- **Menu bar icon tinted with the frontmost app's per-app color** —
  the menu bar becomes a persistent legend for the color scheme.
- **Warp the cursor on find-my-window** — shake answers "where is my
  window?"; nothing answers "where did my mouse go?" after you find
  it. `CGWarpMouseCursorPosition` to the window center, opt-in.
- **Assessed and rejected**: night-hours scheduling (dark-mode colors
  + a pause toggle cover it; DST edge cases forever), focus
  history/jump-back (drifts toward rebuilding ⌘-Tab; stale
  `AXUIElement` liveness is a tar pit — the focus trail delivers the
  passive half for a fraction of the cost).

---

## What ships alongside this document

Each on its own branch, partitioned to keep PR diffs disjoint where
possible (`Constants.swift` and the Behavior-tab control list are
shared append-points; conflicts there, if any, are one-liners):

| Branch | Contents |
|---|---|
| `claude/fix-frontmost-window-resolution` | Headline bug: frontmost-app window resolution with z-order cross-check, timeout retry, observer-registration retry, `kAXMainWindowChanged` + settle re-refresh |
| `claude/overlay-capture-and-fullscreen` | `sharingType = .none`, `.fullScreenAuxiliary`, spotlight cutout corner fix |
| `claude/reduce-motion` | Honor Reduce Motion across glide/pulse/party/flash, live re-check on toggle |
| `claude/menu-bar-and-pause` | Always-available status item, Pause, "Exclude <app>", live hide-Dock checkbox, reopen handler, first-launch prefs-state fix |
| `claude/prefs-polish` | Clamped number fields, Remove-button state + Delete key, uninstalled-app rows, window title |
| `claude/fix-permission-alert` | `abortModal`, sane alert buttons, post-grant flash |
| `claude/hotkey-robustness` | No-trap defaults parsing, hotkey suspended while recording, failure feedback |
| `claude/perf-quick-wins` | Defaults-change debounce, SMAppService cache, preview-timer visibility gate, single-draw `updateFrame`, unchanged-screen skip, screen-reconfiguration observer |
| `claude/repo-hygiene` | Untrack `xcuserdata`, fix the shared-scheme ignore, CI concurrency + paths, release-input validation |
| `claude/border-styles` | Solid / dashed / marching-ants / hand-drawn border style picker |

*Round three reviewed at v2.6.1 (`5b07a96`). Findings were
adversarially cross-checked; where verification killed or narrowed a
claim (the `.stationary` Mission Control theory, `kAXMainWindowChanged`
as a root cause, the pulse end-snap), the text above says what
survived.*
