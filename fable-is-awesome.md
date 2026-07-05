# Alan — code review notes, round four

A fourth full read-through, done at `daa46de` — v2.6.1 plus the ten
round-three PRs, all merged. The brief again leads with the *"a copy
dialog sometimes doesn't get the border"* report, which survives
round three's fix for a reason the round-three analysis itself
predicted but the implementation didn't finish. Round-three items that
shipped are gone from this document; what's below is new findings,
regressions or gaps in the merged fixes, and the still-open carryovers,
re-verified against the current code. Everything was checked with
file:line references; claims that depend on runtime behavior (this
review ran on Linux, no macOS to hand) are marked *needs on-device
confirmation*.

Items marked **[implemented → `branch`]** ship as their own PR
alongside this document.

---

## The headline bug, still: a frontmost window that is neither key *nor* main

Round three's fix (`claude/fix-frontmost-window-resolution`) added
`frontmostMainWindowIfInFront()` (`FocusHighlighter.swift:1045`): if the
frontmost app's `AXMainWindow` frame matches the topmost app-owned
window in the window server's z-order, prefer it. That rescues a dialog
that became **main without becoming key** — and it genuinely fixes some
of the report.

But round three's own analysis (see the git history of this file)
called the worst case: *"`orderFront` alone never makes a window main
either… and `NSPanel`s can never be main. So 'prefer `AXMainWindow`' is
not sufficient for the worst case; a robust fix needs a z-order
check."* The implemented fix uses the z-order check only to **confirm
the main window** — never as a resolution source of its own. Walk the
chain for a progress panel that is ordered front but becomes neither
key nor main (panel-style windows are the canonical case — an
`NSPanel` *cannot* become main, and plain `orderFront` promotes
nothing):

1. Keyboard focus (`focusedWindowElement()`, `:1006`) still points into
   the window *behind* the panel — same process as the frontmost app,
   so the cross-process trust branch (`:974-980`) doesn't fire.
2. `frontmostMainWindowIfInFront(pid:)` reads `AXMainWindow` — still
   the window behind — and compares its frame to the topmost CG window,
   which is the panel. `framesRoughlyEqual` fails (`:1053`), the
   function returns nil.
3. The fallback (`:995-997`) returns the keyboard-focus window: the
   window behind. Border glued to the wrong window; no retry is armed
   because nothing failed.

The window server *knows* the panel is frontmost the whole time — we
even fetched its bounds in step 2 and then threw them away. The
"sometimes" texture of the report matches exactly: dialogs that take
key work (round-three fix not even needed), dialogs that become main
work (round-three fix), panels that do neither — Finder's copy-progress
window being the usual suspect — never work until clicked.

**Fix:** treat the topmost window server bounds as a first-class
resolution source. Compute `topmostWindowBounds(pid:)` once per
resolution; if the keyboard-focus window or the main window matches it,
done (cheap, common case). Otherwise enumerate the app element's
`kAXWindowsAttribute` and return the AX window whose `AXFrame` matches
the topmost bounds — that *is* the frontmost window, whatever AX thinks
focus is. Keep the existing cross-process branch (open/save panels) and
the drag-path gate (`dragTimer == nil`) exactly as they are. *(Needs
on-device confirmation that Finder's copy window reports through
`kAXWindowsAttribute` — it should; it's a regular AX window with a
close button.)* **[implemented → `claude/fix-never-main-windows`]**

Two adjacent robustness gaps in the same subsystem, found while
tracing:

- **The AX-observer retry budget is global, not per-app.**
  `observerRetryCount` is reset only when registration fully succeeds
  (`FocusHighlighter.swift:481`). If one slow-launching app burns its
  five retries and never registers, the *next* app that hits a partial
  registration failure is denied retries entirely — the
  `observerRetryCount < 5` guard (`:493`) still sees the old count, and
  with `observedPid` left at −1 nothing re-attempts until the user
  switches apps again. Window events from that app (including any
  dialog it opens) silently never arrive.
  **[implemented → `claude/fix-never-main-windows`]**
- **A pending retry for the *old* app blocks the new app's retry.**
  `stopObservingApp()` (`:508-515`) doesn't invalidate
  `observerRetryTimer`, and `scheduleObserverRetry` bails while any
  timer is pending (`:493`). Switch from a failing app to another app
  that also needs a retry, and the new app gets none: the old timer
  fires, notices its pid is no longer frontmost, and simply expires.
  **[implemented → `claude/fix-never-main-windows`]**

## Other bugs

- **"Exclude this app" from the status menu can be silently undone by
  the Preferences window — data loss.** `PrefsWindowController` copies
  the excluded-apps list into a private array once, at init
  (`PrefsWindowController.swift:428`), and never re-reads it: the
  status menu's Exclude item writes straight to defaults
  (`AppDelegate.swift:156-162`), the prefs table doesn't reload
  (`syncDynamicUI` never touches `excludedApps`), and the next Remove
  click in Preferences writes the **stale array** back over defaults
  (`:591`) — deleting the exclusion the user just added from the menu,
  with no visible sign. Fix: re-read the array in `syncDynamicUI` and
  reload the table when it differs.
  **[implemented → `claude/fix-stale-exclusions`]**
- **The Dock-click-opens-Preferences fix is defeated by Alan's own
  overlay.** `applicationShouldHandleReopen` (`AppDelegate.swift:182`)
  only opens Preferences when `hasVisibleWindows` is false — but the
  border overlay is a visible `NSWindow` almost all of the time (and in
  spotlight mode there's one dim window per screen), so the flag is
  true, and clicking the Dock icon goes back to doing… nothing. The
  flag can't distinguish "windows the user can interact with" from
  Alan's click-through overlays; decide off the Preferences window's
  own visibility instead. *(Needs on-device confirmation of exactly
  which windows AppKit counts; the overlay is a standard visible window,
  so it should count.)* **[implemented → `claude/fix-dock-reopen`]**
- **`defaults write` from Terminal still doesn't apply — the comment
  claiming it does survived round three.** `start()` observes
  `UserDefaults.didChangeNotification` and says settings "changed from
  Terminal via `defaults write` apply immediately"
  (`FocusHighlighter.swift:94-96`) — but that notification is posted
  for *in-process* changes only (Apple's documentation is explicit).
  External writes are picked up incidentally, whenever something else
  triggers a redraw. Round three found this; no branch implemented it.
  KVO on the specific keys *does* fire cross-process and turns every
  setting — including `paused` — into a live scripting surface
  (Shortcuts, Stream Deck). **[implemented →
  `claude/external-defaults-kvo`]**
- **The permission alert's poll timer can call `abortModal()` outside
  any modal session.** The timer (`AppDelegate.swift:221-227`) runs on
  `.common` for the whole life of `requestAccessibilityPermissionIfNeeded`,
  but between `runModal()` iterations (the user clicked "Open System
  Settings", the loop re-opens the pane and re-presents) there is a
  window with no modal session running. If the grant lands exactly
  there, `abortModal` has no session to abort — depending on timing the
  response can be lost and the alert re-presented once more after
  permission was already granted. Low severity, two-line fix: guard
  with `NSApp.modalWindow != nil`.
- **The shortcut recorder will happily record ⌘Q or ⌘W.** The local
  monitor (`PrefsWindowController.swift:835-857`) accepts any keystroke
  with ⌘/⌃/⌥ — including combos the system and every app reserve.
  Record ⌘Q and quitting still works everywhere *except* that pressing
  it now also flashes the border; more confusingly, recording ⌘C makes
  the flash fire on every copy. A short deny-list (⌘Q, ⌘W, ⌘C, ⌘V,
  ⌘X, ⌘A, ⌘Z, ⌘Tab) with a beep would prevent the footgun.
- **Bare function keys can't be recorded.** F1–F12 without modifiers
  are rejected with a beep (`:844`), but a bare F-key is a perfectly
  standard global hotkey (macOS itself binds F11 to Show Desktop) and
  the recorder's own `keyName` already renders them. The modifier
  requirement makes sense for letter keys, not for F-keys.
- **`flashBorder` replays a stale frame.** It captures the window frame
  once (`FocusHighlighter.swift:346-347`) and replays it for the
  ~0.7 s flash; a window that moves or closes mid-flash gets flashed at
  its old location. Cosmetic, self-healing, but worth a re-query per
  "on" phase given the frame read is one IPC.

## General issues

- **Zero tests, still.** The refactor seams round three listed (djb2
  hue hash, `cocoaRect` flip, `windowFillsScreen`, smoothstep, shake
  reversal logic, Carbon modifier mapping) all still exist, and two new
  ones joined them: `framesRoughlyEqual` and the wobble noise. None
  need AX permission; all would run on CI.
- **Ad-hoc signing likely still invalidates the Accessibility grant on
  every update** (carried; standard TCC-vs-signature behavior, *needs
  on-device confirmation*). Undocumented in README and release notes.
  A real Developer ID remains the long-term fix.
- **`scripts/build.sh`/`release.sh` still hard-depend on the external
  `lkm-build` tool.** The README's build section mentions the scripts
  but not the plain `xcodebuild` incantation CI uses — the natural
  documented fallback for contributors without the tool.
  **[README part → `claude/readme-refresh`]**
- **`NSApp.activate(ignoringOtherApps:)` is deprecated as of macOS 14**
  (three call sites in `AppDelegate.swift`); with a 15.7 deployment
  target the replacement `activate()` is always available. Compile
  warning today, breakage someday.
- **CI:** now has concurrency-cancel and `paths-ignore` (good), but
  still builds with whatever Xcode the rolling `macos-26` image ships —
  a toolchain bump can break the build with no code change. Pinning
  via `maxim-lobanov/setup-xcode` (or at least `xcode-select` with a
  known version) makes failures mean something.

## Performance

- **The copy-window fix bills every refresh for a window-server
  snapshot.** `currentFocusedWindow()` now performs, per non-drag
  refresh, on top of the focus chain: one `AXMainWindow` read + one
  `AXFrame` read + `CGWindowListCopyWindowInfo` (which materializes CF
  dictionaries for *every on-screen window in the system*) — even when
  the keyboard-focus window is already the frontmost thing, which is
  nearly always. Refreshes are event-driven so this is bounded, but
  settle-refreshes double it (`:405`), and the right shape for the
  round-four fix above is to consult `topmostWindowBounds` once and
  *confirm the cheap answer first*: if the keyboard-focus window's
  frame matches the topmost bounds, skip the main-window queries
  entirely. **[folded into → `claude/fix-never-main-windows`]**
- **Any left-drag anywhere still starts 30 Hz AX polling** — text
  selection, scrollbars, canvas strokes. The monitor can't tell a
  window drag from any other drag (`FocusHighlighter.swift:120-128`),
  so every tick pays the full resolution chain into the frontmost app
  for the duration. The fix round three sketched still works: count
  consecutive ticks where the resolved frame didn't move and stop the
  timer after ~10, suppressing re-arm until the next mouse-up.
  **[implemented → `claude/perf-drag-and-steady-state`]**
- **The steady state pays an `AXFullScreen` IPC per refresh for
  nothing.** `isFullScreen(windowElement)` (`:628`) runs before the
  "same window, same frame, already drawn" bookkeeping concludes
  there's nothing to do (`:666`). Hoisting a steady-state early-out
  above the full-screen and fills-screen checks saves one round-trip
  per event in the by-far-most-common case.
  **[implemented → `claude/perf-drag-and-steady-state`]**
- **All animations are still wall-clock `Timer`s** (glide 60 Hz, pulse
  60 Hz, party/ants/preview 30 Hz) — not display-linked; vsync beat and
  ProMotion half-rate remain (carried). The endgame is still
  `CAShapeLayer` paths animated by the render server, which would also
  delete the CPU Gaussian passes below.
- **The preview timer now draws nothing off-screen but still ticks.**
  `BorderPreviewView`'s 30 Hz timer keeps waking the process after the
  Preferences window closes, doing only the `isVisible` check
  (`PrefsWindowController.swift:725-731`). Harmless per tick; it's
  30 idle wakeups/s in Activity Monitor forever after the first prefs
  open. Invalidate on close, re-arm on show.
- **Glow + stronger shadow redraw two CPU Gaussian passes per party/ants
  tick** (30 Hz) over the full overlay backing store (carried, now with
  more animated styles able to trigger it). The margin fix below at
  least keeps the store from growing when effects are off.

## Visual issues

- **Glow still double-strokes the border.** The glow pass strokes the
  path (`HighlightWindow.swift:273-274`) and the main pass strokes it
  again (`:279-280`) — a 50 %-alpha border renders at ~75 % the moment
  glow is toggled on. Round three flagged it; the border-styles branch
  didn't touch it. Since the glow pass already strokes in the final
  color, the minimal fix is to skip the main stroke when glow is on —
  one composite, identical halo. **[implemented →
  `claude/visual-polish`]**
- **Glow and shadow halos still clip in a hard straight edge.** The
  25 pt `shadowMargin` (`:38`) budgets the stroke (comment at
  `:215-216` is honest for the stroke alone) but not the soft effects:
  stronger shadow needs stroke-reach + 25 blur + 3 offset ≈ up to
  ~53 pt of room against 26–45 available (the shadow pass even clips at
  `insetBy(-50)` — someone budgeted room the view doesn't have); glow
  at pulse peak needs up to ~37 pt. Compute the margin from the enabled
  effects instead of a constant, and the window only grows when the
  user opts into the halo. **[implemented → `claude/visual-polish`]**
- **The focus pulse still attacks in a single frame.** With
  `eased = (1−t)²` the first 60 Hz tick lands at ≈2.40× (the configured
  2.5 peak is never rendered); the border teleports thick, then eases
  down — reads as a flicker, not a swell. Three or four frames of
  smoothstep ramp-in fix it. **[implemented → `claude/visual-polish`]**
- **The Appearance preview lies while spotlight mode is on.** Spotlight
  replaces the border entirely, but the preview keeps rendering a
  border (which now appears only during find-my-window flashes), and
  every appearance knob looks live. The preview is the perfect place to
  tell the truth: render the mock desktop dimmed with the mock window
  cut out — the real spotlight look, driven by the real dim level — and
  say the border settings apply to the flash.
  **[implemented → `claude/spotlight-preview`]**
- **Default square corners still overhang the window's real rounded
  corners** (carried) — `cornerRadius` defaults to 0 while every modern
  macOS window sits at ~10 pt; at default inset 4/width 5 the corner
  tips float ~12 pt from the corner center, past the glass. Still worth
  defaulting to ~6–8 or an "auto" that tracks `max(0, 10 − inset)`;
  left unimplemented here because it changes every existing install's
  look — a maintainer call, one line when made.
- **The overlays still sit above the menu bar and Dock** (carried) —
  `.statusBar` = 25 vs 24/20. Invisible at factory settings; halos and
  the spotlight dim paint over both. If the dim covering the menu bar
  is a choice, document it; the border halo over Dock icons is harder
  to defend.
- **The border still can't straddle two displays** (carried; round
  two's #1). The `DimWindow`-per-screen pool remains the ready-made
  template; the glide already funnels through a single
  `displayedBorderFrame`, so per-screen border windows would all be
  driven from one animated rect.
- **A border the same color as what's behind it is invisible**
  (carried) — the contrast-casing idea below remains the cleanest
  answer, and Increase Contrast still changes nothing anywhere in the
  app.

## Interface & UX

- **Excluded-apps list and status menu disagree** — the data-loss bug
  above, but it's also just confusing UI: the two surfaces for the same
  list don't sync while both are visible.
  **[implemented → `claude/fix-stale-exclusions`]**
- **README is stale in five places.** It still says the status item
  exists "in hidden-Dock mode" (it's always there since round three),
  that `hideDock` is "the one remaining defaults-only setting" and
  "takes effect on relaunch" (it's a live menu toggle now), the fork
  bullet list stops at v2.1-era features (no border styles, pause,
  shake-to-find, Reduce Motion, screenshot exclusion), the minimum
  macOS version (15.7 per the deployment target) appears nowhere, and
  the build section doesn't mention the plain `xcodebuild` fallback.
  The defaults surface — every key in `Constants.swift` works with
  `defaults write` — is a real, undocumented feature.
  **[implemented → `claude/readme-refresh`]**
- **⌘W still closes nothing** — `MainMenu.xib` has App/Edit/Window
  menus but no File menu, so the Settings window can only be closed
  with the mouse (carried). Fifteen lines of xib or a
  `performKeyEquivalent` on the window.
- **Launch-at-login failure is still a bare beep** (carried) — and the
  likeliest cause (app translocation from ~/Downloads) has a specific,
  tellable fix: "move Alan to /Applications".
- **The hotkey recorder gives no hint about reserved combos** (see the
  ⌘Q bug above) and can't take bare F-keys — both ends of the same
  policy gap.
- **No update mechanism, no localization** (carried; the weekly
  `releases/latest` check remains ~80 dependency-free lines and the
  strings are all still hard-coded English).

## Missing features

- **A test target** — the seams are listed under General issues; CI
  has a macOS runner sitting right there.
- **Update check** and **localization** (above, carried).
- **A "show overlays in screenshots" toggle.** Round three made
  `sharingType = .none` unconditional — right default, wrong ceiling:
  anyone *documenting* their setup (or presenting Alan itself) now
  can't capture the border at all. One checkbox, two lines of window
  config.

## Ideas — novel, delightful, quirky

- **Flash the border on Space switch.** Space changes cause exactly the
  disorientation shake-to-find cures, minus the deliberate gesture.
  `NSWorkspace.activeSpaceDidChangeNotification` + the existing
  `flashBorder()` + a short settle delay, opt-in.
  **[implemented → `claude/space-change-flash`]**
- **Focus trail** (carried) — a ghost border on the previously focused
  window fading over ~1 s. The trigger and source rect already exist in
  `refresh()`'s `focusChanged` branch; needs its own window and
  suppression during drags/Reduce Motion.
- **Per-app colors from the app icon** (carried) — cache per bundle ID,
  pick the most-saturated histogram bin, fall back to the hash below
  ~0.3 saturation.
- **Spotlight + border together** (carried) — still needlessly
  exclusive; `flashBorder` already proves the border composites over
  the dim.
- **"Match system accent color"** (carried) — `NSColor.controlAccentColor`
  as a third color source; dynamic, tasteful, zero-config.
- **Contrast casing** (carried) — a hairline in the perceptual opposite
  at low alpha; invisible until the border color collides with the
  content behind it, and a natural response to Increase Contrast.
- **Hold-to-spotlight.** The find-my-window hotkey is a tap; make
  *holding* it dim everything else for as long as it's held (Carbon
  delivers `kEventHotKeyReleased` too). A quasimode: "where am I?" —
  press, see, release, back to work. No new settings, composes with
  spotlight mode being otherwise off.
- **A transient "who has focus" tag.** On focus change, a small
  app-icon + name chip near the border's top edge for ~0.8 s, then
  fade. In spotlight mode it doubles as the answer to "what did I just
  switch to?" — the dim hides every other cue. Reduce Motion renders it
  static; opt-in.
- **A quiet click on focus change** (carried) — opt-in, debounced,
  for low-vision users who can't hunt for the border at all.
- **Warp the cursor on find-my-window** (carried) —
  `CGWarpMouseCursorPosition` to window center, opt-in.
- **Assessed and rejected this round:** menu-bar icon tinted with the
  frontmost app's color (cute, but the menu bar is the one place the
  system dictates monochrome template images; a colored icon reads as
  broken), and a "peek through the dim" mouse-hover effect for
  spotlight mode (fights the entire premise of the mode — the dim is
  supposed to *resist* attention drifting to other windows).

---

## What ships alongside this document

Each on its own branch off `daa46de`. Three branches touch
`FocusHighlighter.swift` and two touch `PrefsWindowController.swift`,
but in disjoint functions — conflicts, if any, are one-liners.

| Branch | Contents |
|---|---|
| `claude/fix-never-main-windows` | Headline: resolve the frontmost window from the window-server z-order when it is neither key nor main (AXWindows frame-match), confirm-cheap-answer-first ordering, per-app observer retry budget, retry-timer cleanup |
| `claude/fix-stale-exclusions` | Preferences ⇄ status-menu exclusion sync; fixes the silent data loss |
| `claude/fix-dock-reopen` | Dock-icon click opens Settings even though the overlay counts as a visible window |
| `claude/external-defaults-kvo` | Cross-process defaults observation (KVO per key), so `defaults write` — including `paused` — applies instantly; fixes the misleading comment |
| `claude/visual-polish` | Glow single-stroke, effect-aware overlay margin (no more clipped halos), pulse ramp-in |
| `claude/spotlight-preview` | Appearance preview renders the actual spotlight look while spotlight mode is on |
| `claude/perf-drag-and-steady-state` | Stop 30 Hz polling for drags that move no window; steady-state early-out before the `AXFullScreen` IPC |
| `claude/space-change-flash` | Opt-in border flash on Space switch |
| `claude/readme-refresh` | README accuracy pass: current features, min macOS, scriptable-defaults table, `xcodebuild` fallback |

*Round four reviewed at `daa46de`. The multi-agent verification pass
used in round three was unavailable this session (capacity limits), so
every claim above was verified by direct code tracing instead, twice
where it's load-bearing; the two findings that depend on AppKit runtime
behavior are explicitly marked needs-on-device-confirmation.*
