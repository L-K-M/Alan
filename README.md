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

Border colors live in **Preferences…**. Width and inset (both clamped to
1–20 points) and the hidden-Dock mode have no UI yet and are set via
`defaults`:

```sh
defaults write studio.retina.Alan width -int 8
defaults write studio.retina.Alan inset -int 2
defaults write studio.retina.Alan hideDock -bool true   # takes effect on relaunch
```

## License

[MIT](LICENSE), © 2025 Tyler Hall.
