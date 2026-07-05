# Alan

Alan draws a colored border around the active window on macOS — or, in
spotlight mode, dims everything except it — so you can always see where
your input is going.

![screenshot](screenshot.png)

> [!IMPORTANT]
> LLM Disclosure: Much of this code base was written by or with the help of large language models.

**Latest release:** v<!-- version -->2.6.1<!-- /version --> · [Download](https://github.com/L-K-M/Alan/releases/latest)

**Requires:** macOS 15.7 (Sequoia) or later, and the Accessibility
permission (Alan walks you through granting it on first launch).

## About this fork

This is a fork of [tylerhall/Alan](https://github.com/tylerhall/Alan).
The fix for windows on secondary displays was contributed back upstream
([tylerhall/Alan#10](https://github.com/tylerhall/Alan/pull/10)); beyond
that, this fork adds:

- Border styling: width, inset, corner radius, light/dark colors, and a
  style picker — solid, dashed, marching ants, or an xkcd-style
  hand-drawn wobble.
- An optional stronger drop shadow behind the active window, and an
  optional glow on the border itself.
- Optional per-app border colors, with each app's hue derived from its
  bundle identifier — you learn the colors within a day.
- Spotlight mode, the inverse-Alan: instead of a border, everything
  except the focused window is dimmed (with a dim-level slider).
- A "find my window" hotkey (⌃⌥⌘F by default, recordable) that flashes
  the border, and an optional shake-the-mouse gesture that does the
  same.
- An always-available status menu: pause/resume Alan, exclude the
  frontmost app in one click, open Settings, and hide or show the Dock
  icon — live, no relaunch.
- An excluded-apps list, for apps that should never get a border.
- Behavior settings: hide the border while dragging, hide it when a
  window fills its screen, pulse on focus change, and an eased glide
  when the border moves between windows (with a duration slider).
  Native full-screen windows never get a border.
- Reduce Motion support across every animation, and overlays that stay
  out of screenshots, screen recordings, and screen shares.
- Event-driven window tracking via `AXObserver` (replacing the original
  10 Hz polling), with a short-lived timer to follow live drags.
- Launch at login, a live settings preview, party mode 🌈, and CI that
  builds every push and publishes releases from version tags.

## Install

Grab `Alan-<version>.zip` from the
[Releases page](../../releases), unzip, and move `Alan.app` to
`/Applications`. The releases are built on CI and are only ad-hoc signed,
so on first launch right-click the app and choose **Open** (or run
`xattr -d com.apple.quarantine /Applications/Alan.app`).

Or build it yourself — open `Alan.xcodeproj` in Xcode and hit Run, or
from the command line:

```sh
xcodebuild build -project Alan.xcodeproj -scheme Alan -configuration Release
```

(`./scripts/build.sh` wraps the same build with conveniences —
incremental Release build, reveal in Finder, `--clean`, `--run`,
`--install` — but depends on the external
[lkm-build](https://github.com/L-K-M/release-tool) tool; plain
`xcodebuild` needs nothing.)

## Configuration

Everything lives in the status-bar item (the little window icon):
**Settings…** opens the three-tab settings window (Appearance, Behavior,
Excluded Apps), and the menu also has **Pause Alan**, **Exclude
“<frontmost app>”**, and a live **Hide Dock Icon** toggle.

### Scripting

Every setting is stored in the `studio.retina.Alan` defaults domain, so
all of it is scriptable — handy for Shortcuts, Stream Deck buttons, or
shell aliases. A few useful ones:

```sh
defaults write studio.retina.Alan paused -bool true        # pause Alan
defaults write studio.retina.Alan paused -bool false       # resume
defaults write studio.retina.Alan borderStyle handDrawn    # solid | dashed | ants | handDrawn
defaults write studio.retina.Alan spotlightMode -bool true
defaults write studio.retina.Alan hideDock -bool true      # applies on relaunch when set externally
```

External changes are picked up automatically on the next refresh.

## License

[MIT](LICENSE), original © 2025 Tyler Hall.
