# Alan

Alan draws a colored border around the active window on macOS, so you can
always see where your keyboard input is going.

It works by watching the focused window through the macOS Accessibility
API and laying a borderless, click-through overlay window on top of it,
with a stroked rectangle in a color of your choosing — one color for light
mode, one for dark mode.

> 2025-12-03: Thanks to everyone filing bugs, but this app is more
> software satire than useful utility :)

— [Tyler Hall](https://github.com/tylerhall), original author

## About this fork

This is a fork of [tylerhall/Alan](https://github.com/tylerhall/Alan).
The fix for windows on secondary displays was contributed back upstream
([tylerhall/Alan#10](https://github.com/tylerhall/Alan/pull/10)); beyond
that, this fork adds:

- A corner radius setting, so the border can hug modern macOS windows
  instead of poking square corners past them.
- An optional stronger drop shadow behind the active window, and an
  optional glow on the border itself.
- A setting to hide the border while a window is being dragged (it
  returns once the window settles), and one to hide it when a window
  fills its screen — maximized or full-screen, judged against the
  display the window is on, so multi-monitor setups work.
- An excluded-apps list, for apps that should never get a border.
- An optional focus pulse: the border briefly thickens when focus
  changes, then settles.
- Optional per-app border colors, with each app's hue derived from its
  bundle identifier — you learn the colors within a day.
- Event-driven window tracking via `AXObserver` (replacing the original
  10 Hz polling), with a short-lived timer to follow live drags.
- The border recolors immediately when the system switches between light
  and dark mode.
- A status-bar item in hidden-Dock mode, so the app can still be quit and
  configured when it has no Dock icon or menu bar.
- Fixes for the accessibility-permission deep link, `UserDefaults`
  registration, and deprecated `NSColor` archiving.
- CI on every push, and a release workflow that builds and publishes the
  app when a version tag is pushed.
- [`awesome.md`](awesome.md), a code review with remaining known issues
  and ideas.

## Requirements

- macOS 15.7 or later
- Accessibility permission (System Settings → Privacy & Security →
  Accessibility) — this is how Alan finds the focused window

## Install

Grab `Alan-<version>.zip` from the
[Releases page](../../releases), unzip, and move `Alan.app` to
`/Applications`. The releases are built on CI and are only ad-hoc signed,
so on first launch right-click the app and choose **Open** (or run
`xattr -d com.apple.quarantine /Applications/Alan.app`).

Or build it yourself: open `Alan.xcodeproj` in Xcode and hit Run.

## Configuration

**Preferences…** covers just about everything:

- Border width and inset (1–20 points), corner radius (0–50 points)
- One border color for light mode, one for dark mode
- **Stronger Shadow** and **Glowing Border**
- **Show border while dragging** — untick to hide the border while a
  window is moving; it reappears once the window has settled
- **Hide border when window fills the screen** — skips maximized and
  full-screen windows, decided per display
- **Pulse border on focus change** — briefly thickens the border when
  focus moves, then settles
- **Per-app border colors** — each app gets a stable hue hashed from its
  bundle ID (the light/dark color wells are ignored while this is on)
- **Excluded Apps** — apps in this list never get a border

The hidden-Dock mode is the one remaining `defaults`-only setting:

```sh
defaults write studio.retina.Alan hideDock -bool true   # takes effect on relaunch
```

## License

[MIT](LICENSE), © 2025 Tyler Hall.
