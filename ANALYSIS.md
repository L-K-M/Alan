# Alan — consolidated analysis & work list

This document consolidates the standing review notes — `awesome.md` (round
two, v2.1) and `fable-is-awesome.md` (round five) — with the running work
list into a single deduplicated, actionable file.

**Everything already implemented has been removed.** The previous pass
shipped 22 fixes/features across PRs #46–#61 (the copy-window raw-bounds
headline fix, the glide-timer/flash-frame overlay fixes, the observer-create
retry, the settings-preview idle-wakeup fix, the hand-drawn redraw gate, the
spotlight-chrome dim, the Xcode pin, the shortcut-recorder policy, the
launch-at-login guidance, the deprecated-`activate` sweep, the accent-color
and viewfinder styles, the show-in-screenshots toggle, the contrast casing,
and the focus trail) and those are now merged into `main` — so they are gone
from this list, along with everything that shipped in rounds one–four
(Reduce Motion, live-Dock toggle, pause toggle, always-on status item,
marching-ants/hand-drawn styles, the recordable hotkey, spotlight/shake/
space-flash, …). What remains below is the still-open set: entries that were
deferred last pass, plus the ones this pass implements.

Duplicate entries across the source documents are merged; each entry keeps
enough detail to implement from directly (file/line anchors, the exact
approach, the guards, and the gotchas that bit a naïve fix).

Every entry carries a **Resolution** line. Entries implemented in this pass
ship each on their own branch off `main` with a PR; entries deliberately
deferred say why (usually: a rewrite too large to land safely without a macOS
build, a change that can only be tuned/validated on-device, or a maintainer
taste call).

Legend: **sev** = severity · **conf** = static confidence · **[dev]** =
needs on-device confirmation.

---

## Status of this pass

Of the 24 open entries, **8 are implemented this pass**, each on its own
branch off `main` with a PR; the other 16 remain deferred with a per-entry
rationale. Two of the eight (PERF-6, IDEA-8) were deferred *last* pass only to
avoid colliding with the headline copy-window fix's resolution/`flashBorder`
regions — now that PR #46 (and #56) are merged, that blocker is gone and they
land cleanly. This pass was again authored on Linux with no Xcode, so nothing
was compiled: the changes were verified by close reading, and CI builds each
PR on macOS. Three new self-contained classes ship as **new files**
(`PingWindow.swift`, `FocusChipWindow.swift`, `UpdateChecker.swift`) — the
project uses an Xcode file-system-synchronized group, so a new `.swift` under
`Alan/` joins the build with no `project.pbxproj` edit, and a brand-new file
can't merge-conflict with any other branch.

| PR | Branch | Entry |
|---|---|---|
| #64 | `claude/perf-drag-fastpath` | PERF-6 |
| #63 | `claude/visual-preview-room` | VIS-6 |
| #62 | `claude/visual-shadow-direction` | VIS-7 |
| #65 | `claude/idea-warp-cursor` | IDEA-8 |
| #66 | `claude/idea-sonar-ping` | IDEA-4 |
| #67 | `claude/idea-focus-chip` | IDEA-9 |
| #68 | `claude/update-check` | FEAT-2 |
| #69 | `claude/update-grant-guidance` | UX-6 |

Where several branches touch `FocusHighlighter.swift`,
`PrefsWindowController.swift`, or `Constants.swift`, they were kept to disjoint
functions/regions where possible; the unavoidable overlaps are the shared
lists (`Key.allObservedKeys`, the Behavior-tab stack, `flashBorder`'s head),
each a keep-both one-line resolution at merge time.

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

### PERF-6 · Live-drag re-runs the whole focus chain per 30Hz tick
*sev low / conf medium / [dev]*
**Where:** `FocusHighlighter.swift` — drag timer `startDragTracking` calls
`refresh()`; resolution in `currentFocusedWindow()`.
**Problem:** During a drag the 30Hz timer calls `refresh()` →
`currentFocusedWindow()` every tick; the z-order block is skipped
(`dragTimer != nil`), but the window is still re-derived from scratch
(`focusedWindowElement()` reads `AXFocusedUIElement` then `AXWindow`, plus the
`axFrame` read — ~3 IPC) even though it's already in `lastFocusedWindow` and
can't change focus mid-drag (you're holding its title bar). ~90 AX IPC/s where
~30 would do.
**Fix:** In `refresh()`, just before the `lastResolutionTimedOut = false` /
`currentFocusedWindow()` guard, add a drag fast-path: when `dragTimer != nil`
and `lastFocusedWindow` is non-nil and its `axFrame(of:)` reads, use
`(lastFocusedWindow, frame)` directly; otherwise fall through to the full
`currentFocusedWindow()`. A window-closed nil or a stalled read (which sets
`lastResolutionTimedOut`) falls back; the mouse-up `refresh()` re-syncs.
Everything downstream is untouched.
**Resolution:** ✅ Implemented → `claude/perf-drag-fastpath` (PR #64). Deferred
last pass only to avoid a merge conflict with the headline fix's resolution
region; now that PR #46 is merged, it lands cleanly.

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

---

## C. Visual

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

### VIS-6 · Appearance preview clips glow/shadow halos
*sev low / conf medium*
**Where:** `PrefsWindowController.makeAppearanceTab` — `previewView.heightAnchor`
= 150; `BorderPreviewView.draw` mock window at `bounds.insetBy(dx: 90, dy: 38)`;
the preview layer's `masksToBounds`.
**Problem:** With only 38pt vertical margin, a stronger shadow at large widths
reaches ~38pt past the frame and is hard-clipped — the preview shows a
squared-off halo the user won't actually see.
**Fix:** Enlarge the vertical inset (`dy: 52`) and bump the height anchor from
150 to ~190. **Correction:** removing `masksToBounds` does *not* help — a
layer-backed view can only paint into its bounds-sized backing store, so the
halo clips regardless; that flag only controls the 6pt corner rounding. Only
enlarging the room eliminates the clip.
**Resolution:** ✅ Implemented → `claude/visual-preview-room` (PR #63). A pure
layout change (taller preview + more vertical room around the mock window); no
behavior change. Faint clip, but the fix is safe and cheap.

### VIS-7 · Stronger shadow drops the wrong way (flipped view) vs the preview
*sev low / conf low / [dev]*
**Where:** `HighlightView.drawBorder` stronger-shadow
`shadowOffset = NSSize(width: 0, height: -3)`; `HighlightView.isFlipped` is
true, `BorderPreviewView` is not flipped.
**Problem:** `HighlightView` is flipped, so `-3` pushes the shadow *upward*
on-screen (unnatural); `BorderPreviewView` isn't flipped, so the same code
drops it downward. The two sites cast on opposite sides; the 3pt offset under a
25pt blur keeps it subtle.
**Fix:** Derive the sign from the context —
`let flipped = NSGraphicsContext.current?.isFlipped ?? false; shadow.shadowOffset = NSSize(width: 0, height: flipped ? 3 : -3)` —
so both cast a natural downward drop. Leave the glow (offset 0,0) alone.
**Resolution:** ✅ Implemented → `claude/visual-shadow-direction` (PR #62). The
context-sign fix is logically sound (a drop shadow should fall downward on
screen in both the flipped overlay and the unflipped preview); the exact
perceptual result is still worth a glance on device, but a downward drop is the
universal convention so the change is low-risk.

---

## D. Interface & UX

### UX-6 · Ad-hoc signed updates re-break the Accessibility grant — undocumented
*sev medium / conf medium / [dev]*
**Where:** `README.md` Install section; `release.yml` (`CODE_SIGN_IDENTITY=-`);
`AppDelegate.requestAccessibilityPermissionIfNeeded()` permission alert.
**Problem:** macOS TCC keys the grant to the code-signing identity; an ad-hoc
signature isn't a stable Developer ID, so a freshly downloaded version can
present as a different app and require re-granting Accessibility. Undocumented,
so on the first update the app silently stops drawing borders.
**Fix:** (1) **Docs** — add an "Updating" subsection to the README telling the
user to remove the old "Alan" row in System Settings → Privacy & Security →
Accessibility and re-add `/Applications/Alan.app`, and stating Developer ID +
notarization is the long-term fix. (2) **Runtime** — remember a prior grant
with a `Key.hadAccessibilityGrant` flag (set true whenever trust is observed
true); if trust is currently false but the flag is true, branch the permission
alert's `informativeText` to an update-specific message ("A recent update may
have reset Alan's Accessibility permission…"). Flag transitions false→true only;
wording change only, no behavior change.
**Resolution:** ✅ Implemented → `claude/update-grant-guidance` (PR #69). The
docs half is device-independent; the runtime half is a defaults flag
(`Key.hadAccessibilityGrant`) plus alert wording, low-risk. The underlying
TCC-vs-signature behavior still ultimately wants a device to confirm, but the
guidance is correct regardless and does no harm if the reset never happens.

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

---

## E. Missing features

### FEAT-2 · Update mechanism
*sev low / conf high*
**Where:** none today; `README.md` links `releases/latest`.
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
(gated on a `lastUpdateCheck` date, a `skippedVersion`, and an opt-in preference
defaulting off) can follow.
**Resolution:** ✅ Implemented → `claude/update-check` (PR #68) — the manual
"Check for Updates…" status-menu item, backed by a dependency-free
`UpdateChecker` (new file) with a component-wise numeric version compare and
silent failure. The optional automatic weekly check is left as a documented
follow-up. Network behavior can't be exercised off-device, but the check is
user-initiated and fails silently, so the downside is bounded.

---

## F. Ideas — novel, delightful, quirky

### IDEA-4 · Sonar-ping find animation
*sev low / conf high*
**Where:** `FocusHighlighter.flashBorder()`, center from the resolved frame.
**Problem/why:** `flashBorder()` only strobes the existing border — which fails
at exactly the moment it's needed, when the border is hard to see. One or two
stroked rings expanding from the window center and fading over ~0.5s draw the
eye to the *location* independent of border color/contrast.
**Fix:** A transient `PingWindow` (same click-through, out-of-capture setup as
`HighlightWindow`/`GhostBorderWindow`) framed to the focused window's screen;
content view draws N concentric rounded-rects at `radius = progress * maxReach`,
`alpha = 1 - progress`, stroke = `currentBorderColor()`; driven by a
`Defaults.findPingDuration` (~0.5s) timer. Gate on `Key.findAnimation`
("flash" | "ping"; **not** in `allObservedKeys` — only matters when the gesture
fires). Shared by the hotkey, shake, and Space-change flash (all route through
`flashBorder`). Under Reduce Motion, a single static ring held briefly. Guard
overlapping pings with an internal generation counter (like `GhostBorderWindow`).
**Resolution:** ✅ Implemented → `claude/idea-sonar-ping` (PR #66). `PingWindow`
ships as a new file (no pbxproj edit, no merge surface); `flashBorder` gets a
small early-return branch when `findAnimation == .ping`, plus a Behavior-tab
picker (Flash / Sonar ping). Follows the proven `GhostBorderWindow` window/
generation/fade pattern.

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

### IDEA-8 · Warp the cursor to the focused window on find-my-window
*sev low / conf high / [dev]*
**Where:** `FocusHighlighter.flashBorder()`.
**Fix:** `Key.warpCursorOnFind` (default off, *not* in `allObservedKeys`); right
after the frame resolve in `flashBorder` and using the **AX** frame (top-left
global Quartz space, shared with `CGWarpMouseCursorPosition`),
`CGWarpMouseCursorPosition(CGPoint(x: axFrame.midX, y: axFrame.midY))` then
`CGAssociateMouseAndMouseCursorPosition(1)` (so the cursor doesn't stick for the
~0.25s HID interval after a warp). Use the AX frame directly — applying the
cocoa flip would land the cursor mirrored. Wires up the hotkey, shake, and
Space-change gestures at once. Add a checkbox. Verify on a secondary/
negative-origin display.
**Resolution:** ✅ Implemented → `claude/idea-warp-cursor` (PR #65). Deferred
last pass only to avoid colliding with the (now-merged) `flashBorder` frame-live
fix; opt-in and default off, so even an odd multi-display warp is harmless until
the user enables it. Uses a dedicated `currentFocusAXFrame()` helper so the warp
reads the unflipped AX frame.

### IDEA-9 · Transient "who has focus" chip (app icon + name)
*sev low / conf high*
**Where:** `FocusHighlighter.refresh()` focusChanged branch.
**Problem/why:** On focus change, briefly float a small app-icon + name chip
near the focused window's top edge for ~0.8s, then fade — answers "what did I
just switch to?" at a glance, and is especially valuable in spotlight mode where
the dim hides every other cue.
**Fix:** `Key.showFocusChip` (default off, in `allObservedKeys`),
`Defaults.focusChipDuration` (~0.8s); a reusable `FocusChipWindow`
(HighlightWindow-style setup) with a horizontal stack of icon + truncating label
on a rounded translucent backing. Hook next to the pulse, suppressed while
dragging. **Refinement:** derive identity from the *resolved* window
(`AXUIElementGetPid(windowElement)` → `NSRunningApplication`), not
`frontmostApplication`, to handle the out-of-process panel-service case (fall
back to `frontmostApplication` when the element is nil, e.g. the raw-bounds
panel); position centered above `cocoaFrame`, clamped into the screen's
`visibleFrame` (flip below if no room). Reuse one instance; hide it in
`hideHighlight`/paused.
**Resolution:** ✅ Implemented → `claude/idea-focus-chip` (PR #67).
`FocusChipWindow` ships as a new file (built on the proven generation/fade
pattern); the `refresh()` hook is a single call in the focusChanged block plus a
helper. Layout kept deliberately robust (fixed height, width from the label's
fitting size, conservative screen-clamping) since it can't be visually verified
off-device; opt-in and default off, so any positioning nit is bounded.

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
