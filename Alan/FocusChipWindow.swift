//
//  FocusChipWindow.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

// A transient "who has focus" chip — the frontmost app's icon and name — that
// floats above the focused window for a beat on a focus change, then fades.
// Answers "what did I just switch to?" at a glance, and is especially valuable
// in spotlight mode, where the dim hides every other cue. Same click-through,
// out-of-capture, all-Spaces setup as the other overlays; one instance is
// reused across focus changes.
class FocusChipWindow: NSWindow {

    // Bumped on each show so a superseded run's fade or hold timer can't order
    // out — or keep fading — a newer chip.
    private var generation = 0
    private var holdTimer: Timer?
    private var fadeTimer: Timer?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    private static let height: CGFloat = 30
    private static let iconSize: CGFloat = 18
    private static let hPadding: CGFloat = 11
    private static let gap: CGFloat = 8
    private static let maxTextWidth: CGFloat = 240
    private static let chipFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    // How long the chip takes to fade once its hold has elapsed.
    private static let fadeDuration: TimeInterval = 0.25

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        self.isOpaque = false
        // A soft system shadow makes the chip read as a floating card.
        self.hasShadow = true
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        // Out of screenshots, recordings and screen shares by default, like
        // every other overlay — and, like them, following Key.showInScreenshots
        // when the user has explicitly asked for overlays to be captured. It
        // used to be pinned to .none, which meant turning that switch on left a
        // chip-shaped gap in a recording of the very feature being recorded.
        applyOverlaySharingType()

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = FocusChipWindow.chipFont
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBezeled = false

        effect.addSubview(iconView)
        effect.addSubview(label)
        self.contentView = effect
    }

    // Float the chip centered above `windowRect` (window frame in global Cocoa
    // coordinates) for the chip duration, then fade out. Re-entrant: a new call
    // repositions and restarts.
    func show(icon: NSImage?, name: String, above windowRect: CGRect) {
        generation += 1
        let gen = generation
        holdTimer?.invalidate()
        holdTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        applyOverlaySharingType()

        let h = FocusChipWindow.height
        let iconSize = FocusChipWindow.iconSize
        let pad = FocusChipWindow.hPadding
        let gap = FocusChipWindow.gap

        label.stringValue = name
        iconView.image = icon

        // Measure through the field's own cell, not a raw NSString: the cell
        // pads the glyphs by a couple of points beyond the string width, so a
        // frame sized to the bare measurement came up those points short and
        // the truncating line-break mode ate the tail of every name. The
        // frame set by sizeToFit is discarded — layout below re-derives it
        // from the clamped width.
        label.sizeToFit()
        let textWidth = ceil(label.frame.width)
        let clampedText = min(textWidth, FocusChipWindow.maxTextWidth)
        let width = pad + iconSize + gap + clampedText + pad

        // The visual-effect content view isn't flipped (y grows up), so vertical
        // centering counts from the bottom.
        iconView.frame = NSRect(x: pad, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        label.frame = NSRect(x: pad + iconSize + gap, y: (h - 18) / 2, width: clampedText, height: 18)

        // Center above the window's top edge, clamped into the screen's
        // visible frame. A window riding close to the top of the screen
        // leaves only a sliver up there, and a chip wedged between the window
        // and the menu bar reads as stuck to the screen edge rather than
        // floating over the window — so the above placement is used only
        // when the chip gets at least its own height of clear air above it.
        // Otherwise the chip drops just below the window's top edge,
        // badge-style over the title bar, where it plainly belongs to the
        // window. (The min guards a window extending past the visible top,
        // and the final clamp keeps either placement on screen.)
        let screen = screenContaining(windowRect) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? windowRect
        var x = windowRect.midX - width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
        var y = windowRect.maxY + 8
        if y + h + h > visible.maxY {
            y = min(windowRect.maxY, visible.maxY) - h - 8
        }
        y = max(visible.minY + 8, min(y, visible.maxY - h - 4))

        setFrame(NSRect(x: x, y: y, width: width, height: h), display: true)
        alphaValue = 1
        orderFrontRegardless()

        let timer = Timer.scheduledTimer(withTimeInterval: Defaults.focusChipDuration, repeats: false) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.holdTimer = nil
            self.startFade(generation: gen)
        }
        RunLoop.current.add(timer, forMode: .common)
        holdTimer = timer
    }

    // Fade out over `fadeDuration`, then order out.
    //
    // Driven by a timer rather than `animator().alphaValue`, because assigning
    // alphaValue directly does *not* cancel an animation already in flight:
    // NSWindow's animator proxy keeps stepping alphaValue toward its own target
    // and simply overwrites the assignment on its next step. A chip shown while
    // its predecessor was mid-fade was therefore dragged back to zero by that
    // predecessor's animation — and the completion handler's generation guard,
    // doing its job, then declined to order the window out, leaving it on
    // screen at alpha 0. The chip stopped appearing at all for a run of quick
    // app switches: exactly the moment it is most useful. With a timer the
    // generation counter governs the animation itself, not just its tail.
    private func startFade(generation gen: Int) {
        let start = Date()
        let duration = FocusChipWindow.fadeDuration
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, self.generation == gen else {
                timer.invalidate()
                return
            }
            let t = Date().timeIntervalSince(start) / duration
            if t >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
                self.orderOut(nil)
                self.alphaValue = 1
            } else {
                self.alphaValue = CGFloat(1 - t)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // Order the chip out now (a hide/pause/Space-change), superseding any
    // pending fade so it can't briefly reappear.
    func hide() {
        generation += 1
        holdTimer?.invalidate()
        holdTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        orderOut(nil)
        // Leave the window at full opacity so the next show() starts clean even
        // if it interrupted a fade.
        alphaValue = 1
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = rect.intersection(screen.frame)
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? NSScreen.main
    }
}
