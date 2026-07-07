//
//  PingWindow.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

// A transient "sonar ping": rounded-rect rings that expand outward from the
// focused window and fade, drawn on top of everything. Where the border strobe
// only makes an already-hard-to-see border blink, the ping draws the eye to the
// window's *location* independent of the border's color or contrast — which is
// exactly what can fail at the moment "find my window" is needed. Shared by the
// hotkey, shake, and Space-change gestures (all route through flashBorder). Same
// click-through, out-of-capture setup as HighlightWindow / GhostBorderWindow.
class PingWindow: NSWindow {

    // Bumped on each ping so a superseded run's timer callback can't keep
    // driving — or order out — a newer ping.
    private var generation = 0
    private var pingTimer: Timer?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        // Same opt-in capture visibility as the other overlays.
        applyOverlaySharingType()
        self.contentView = PingView(frame: .zero)
    }

    // Ping around `windowRect` (window frame in global Cocoa coordinates) with
    // `color`, then order out. Re-entrant: a new ping supersedes any in flight.
    func ping(around windowRect: CGRect, color: NSColor, reduceMotion: Bool) {
        generation += 1
        let gen = generation
        pingTimer?.invalidate()
        pingTimer = nil

        // Cover the window's own screen so the rings can expand past the frame
        // without being clipped to the frame itself.
        guard let screen = screenContaining(windowRect), let view = contentView as? PingView else { return }
        applyOverlaySharingType()
        setFrame(screen.frame, display: false)
        view.color = color
        // The rect to ping, in this window/view's screen-local coordinates.
        view.windowRect = windowRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        view.progress = 0
        view.needsDisplay = true
        alphaValue = 1
        orderFrontRegardless()

        if reduceMotion {
            // A single static ring held briefly, instead of an expanding pulse.
            view.progress = 0.4
            view.needsDisplay = true
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self, self.generation == gen else { return }
                self.orderOut(nil)
            }
            RunLoop.current.add(timer, forMode: .common)
            pingTimer = timer
            return
        }

        let start = Date()
        let duration = Defaults.findPingDuration
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, self.generation == gen else {
                timer.invalidate()
                return
            }
            let t = Date().timeIntervalSince(start) / duration
            if t >= 1 {
                timer.invalidate()
                self.pingTimer = nil
                self.orderOut(nil)
            } else {
                view.progress = CGFloat(t)
                view.needsDisplay = true
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        pingTimer = timer
    }

    // The screen the window mostly sits on (fallback: the main screen), so the
    // ping is drawn where the window actually is on a multi-display setup.
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

final class PingView: NSView {

    var color: NSColor = .controlAccentColor
    var windowRect: CGRect = .zero      // in this view's (screen-local) coordinates
    var progress: CGFloat = 0           // 0…1 over the ping duration

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard windowRect.width > 0, windowRect.height > 0 else { return }

        // Two rings, staggered a quarter-cycle apart, each a rounded-rect
        // outset from the window edge that grows and fades as progress advances
        // — a pair of pulses radiating from the window. The corner radius grows
        // with the outset so the rings stay concentric with the window's own
        // ~10 pt rounded corners.
        let maxReach: CGFloat = 90
        let baseRadius = Defaults.windowCornerRadius
        for i in 0..<2 {
            let phase = progress + CGFloat(i) * 0.25
            guard phase > 0, phase < 1 else { continue }
            let outset = phase * maxReach
            let ringRect = windowRect.insetBy(dx: -outset, dy: -outset)
            guard ringRect.width > 0, ringRect.height > 0 else { continue }
            let ringRadius = baseRadius + outset
            let path = NSBezierPath(roundedRect: ringRect, xRadius: ringRadius, yRadius: ringRadius)
            path.lineWidth = 3
            color.withAlphaComponent((1 - phase) * 0.8).setStroke()
            path.stroke()
        }
    }
}
