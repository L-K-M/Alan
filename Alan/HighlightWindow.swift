//
//  HighlightWindow.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

class HighlightWindow: NSWindow {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        self.isReleasedWhenClosed = false
        
        self.contentView = HighlightView(frame: .zero)
    }
    
    static let shadowMargin: CGFloat = 25

    func updateFrame(to rect: CGRect) {
        let margin = HighlightWindow.shadowMargin
        let newRect = rect.insetBy(dx: -margin, dy: -margin)
        setFrame(newRect, display: true)
        self.contentView?.setNeedsDisplay(.infinite)
        orderFrontRegardless()
    }

    // MARK: - Party mode

    private var partyTimer: Timer?

    // The hue comes from the wall clock at draw time, so all the timer has
    // to do is keep the view redrawing while the border is on screen.
    func setPartyMode(_ enabled: Bool) {
        if enabled {
            guard partyTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.contentView?.needsDisplay = true
            }
            RunLoop.current.add(timer, forMode: .common)
            partyTimer = timer
        } else {
            partyTimer?.invalidate()
            partyTimer = nil
        }
    }

    // MARK: - Animated border styles

    private var styleAnimationTimer: Timer?

    // Marching ants and the hand-drawn wobble derive their phase/seed from the
    // wall clock at draw time (like party mode), so the timer just keeps the
    // view repainting while such a style is on screen.
    func setBorderStyleAnimating(_ enabled: Bool) {
        if enabled {
            guard styleAnimationTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.contentView?.needsDisplay = true
            }
            timer.tolerance = (1.0 / 30.0) * 0.1
            RunLoop.current.add(timer, forMode: .common)
            styleAnimationTimer = timer
        } else {
            styleAnimationTimer?.invalidate()
            styleAnimationTimer = nil
        }
    }

    // MARK: - Focus pulse

    private var pulseTimer: Timer?
    private var pulseStart: Date?

    // Briefly thicken the border, then ease back to the configured width.
    func pulse() {
        guard let view = contentView as? HighlightView else { return }

        pulseTimer?.invalidate()
        pulseStart = Date()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let start = self.pulseStart else {
                timer.invalidate()
                return
            }
            let progress = Date().timeIntervalSince(start) / Defaults.focusPulseDuration
            if progress >= 1 {
                view.pulseScale = 1
                timer.invalidate()
                self.pulseTimer = nil
            } else {
                // Ease-out: start thick, settle quickly.
                let eased = pow(1 - progress, 2)
                view.pulseScale = 1 + (Defaults.focusPulsePeak - 1) * CGFloat(eased)
            }
            view.needsDisplay = true
        }
        RunLoop.current.add(timer, forMode: .common)
        pulseTimer = timer
    }
}

class HighlightView: NSView {
    override var isFlipped: Bool { true }

    // Stroke width multiplier, animated by HighlightWindow.pulse().
    var pulseScale: CGFloat = 1

    // The stroke color depends on the current appearance, so the border must be
    // redrawn when the system switches between light and dark mode.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        // The window frame sits shadowMargin inside this view's bounds.
        let margin = HighlightWindow.shadowMargin
        HighlightView.drawBorder(
            around: bounds.insetBy(dx: margin, dy: margin),
            pulseScale: pulseScale
        )
    }

    // The configured border color: party mode outranks everything
    // (obviously), then per-app colors, then the light/dark wells. The
    // border is always drawn for the frontmost app's focused window, so
    // the frontmost app is the right source for the per-app hue.
    static func currentBorderColor() -> NSColor {
        if UserDefaults.standard.bool(forKey: Key.partyMode) {
            let phase = Date().timeIntervalSinceReferenceDate / Defaults.partyModeCycleDuration
            let hue = CGFloat(phase.truncatingRemainder(dividingBy: 1))
            return NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
        }
        if UserDefaults.standard.bool(forKey: Key.perAppColors),
           let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            return NSColor.perAppColor(for: bundleID, darkMode: NSAppearance.isDarkMode)
        }
        if NSAppearance.isLightMode {
            return UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        }
        return UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor
    }

    // Draws the configured border around a window's rect into the current
    // graphics context — shared by the overlay and the Preferences preview.
    static func drawBorder(around windowRect: CGRect, pulseScale: CGFloat = 1) {
        var inset = UserDefaults.standard.integer(forKey: Key.inset)
        inset = max(1, min(20, inset))

        var width = UserDefaults.standard.integer(forKey: Key.width)
        width = max(1, min(20, width))

        var cornerRadius = UserDefaults.standard.integer(forKey: Key.cornerRadius)
        cornerRadius = max(0, min(50, cornerRadius))

        let style = BorderStyle.current
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let borderBounds = windowRect.insetBy(dx: CGFloat(inset), dy: CGFloat(inset))
        let path: NSBezierPath
        if style == .handDrawn {
            // Re-seed a few times a second for the wobble; a fixed seed under
            // Reduce Motion renders a static hand-drawn look.
            let seed = reduceMotion ? 0 : Int(Date().timeIntervalSinceReferenceDate * 3)
            path = wobblePath(around: borderBounds, seed: seed)
        } else if cornerRadius > 0 {
            path = NSBezierPath(roundedRect: borderBounds, xRadius: CGFloat(cornerRadius), yRadius: CGFloat(cornerRadius))
        } else {
            path = NSBezierPath(rect: borderBounds)
        }
        // At the maximum width (20) and pulse peak (2.5) the stroke extends
        // 25 pt past the path, which still fits inside margin + inset.
        let effectiveWidth = CGFloat(width) * pulseScale
        path.lineWidth = effectiveWidth

        // Dashed and marching-ants share a dash pattern; ants additionally
        // advance the phase over time (frozen under Reduce Motion).
        if style == .dashed || style == .ants {
            let dash = [effectiveWidth * 2.2, effectiveWidth * 1.8]
            var phase: CGFloat = 0
            if style == .ants, !reduceMotion {
                let period = dash[0] + dash[1]
                phase = CGFloat(Date().timeIntervalSinceReferenceDate * 24).truncatingRemainder(dividingBy: period)
            }
            path.setLineDash(dash, count: dash.count, phase: phase)
        }

        let color = currentBorderColor()

        // Draw stronger shadow if enabled (outer shadow only)
        if UserDefaults.standard.bool(forKey: Key.strongerShadow) {
            NSGraphicsContext.current?.saveGraphicsState()

            // Clip to the region outside the border so the shadow doesn't
            // darken the window itself.
            let outerClipPath = NSBezierPath(rect: windowRect.insetBy(dx: -50, dy: -50))

            let innerExcludePath: NSBezierPath
            let halfWidth = effectiveWidth / 2.0
            let innerBounds = borderBounds.insetBy(dx: -halfWidth, dy: -halfWidth)
            if cornerRadius > 0 {
                let innerRadius = CGFloat(cornerRadius) + halfWidth
                innerExcludePath = NSBezierPath(roundedRect: innerBounds, xRadius: innerRadius, yRadius: innerRadius)
            } else {
                innerExcludePath = NSBezierPath(rect: innerBounds)
            }

            outerClipPath.append(innerExcludePath)
            outerClipPath.windingRule = .evenOdd
            outerClipPath.addClip()

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.99)
            shadow.shadowBlurRadius = 25
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.set()

            color.setStroke()
            path.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Draw glow if enabled
        if UserDefaults.standard.bool(forKey: Key.glowingBorder) {
            NSGraphicsContext.current?.saveGraphicsState()
            let glowShadow = NSShadow()
            glowShadow.shadowColor = color.withAlphaComponent(0.8)
            glowShadow.shadowBlurRadius = 12
            glowShadow.shadowOffset = NSSize(width: 0, height: 0)
            glowShadow.set()
            color.setStroke()
            path.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // The main border stroke
        color.setStroke()
        path.stroke()
    }

    // MARK: - Hand-drawn wobble

    // A closed path tracing the rect with each sampled point nudged by
    // deterministic per-point noise — an xkcd-style hand-drawn wobble.
    // Deterministic in `seed`, so a fixed seed renders a static sketch and a
    // clock-derived seed animates. Corner radius is intentionally ignored:
    // a wobbly outline reads as hand-drawn regardless.
    static func wobblePath(around rect: CGRect, seed: Int) -> NSBezierPath {
        let amplitude: CGFloat = 1.6
        let perimeter = 2 * (rect.width + rect.height)
        let count = max(12, Int((perimeter / 16).rounded()))
        let path = NSBezierPath()
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count)
            var p = pointOnPerimeter(of: rect, at: t)
            p.x += wobbleNoise(i, seed) * amplitude
            p.y += wobbleNoise(i &+ 977, seed) * amplitude
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    // Walk the rectangle perimeter clockwise from the top-left; t in [0, 1).
    private static func pointOnPerimeter(of rect: CGRect, at t: CGFloat) -> NSPoint {
        let w = rect.width, h = rect.height
        var d = t * (2 * (w + h))
        if d <= w { return NSPoint(x: rect.minX + d, y: rect.minY) }
        d -= w
        if d <= h { return NSPoint(x: rect.maxX, y: rect.minY + d) }
        d -= h
        if d <= w { return NSPoint(x: rect.maxX - d, y: rect.maxY) }
        d -= w
        return NSPoint(x: rect.minX, y: rect.maxY - d)
    }

    // Deterministic noise in [-1, 1] from an integer key — a cheap integer
    // hash, so no dependence on the process-random Hasher.
    private static func wobbleNoise(_ i: Int, _ seed: Int) -> CGFloat {
        var h = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(seed)) &* 0xC2B2_AE3D_27D4_EB4F
        h = (h ^ (h >> 29)) &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        return CGFloat(h % 2000) / 1000.0 - 1.0
    }
}

// Spotlight mode: one of these per screen dims everything except the
// focused window, which stays visible through a cut-out.
class DimWindow: NSWindow {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        self.isReleasedWhenClosed = false

        self.contentView = DimView(frame: .zero)
    }

    // cutout is in global Cocoa coordinates; nil dims the whole screen.
    func update(screenFrame: CGRect, cutout: CGRect?) {
        setFrame(screenFrame, display: true)
        if let view = contentView as? DimView {
            view.cutout = cutout?.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        }
        contentView?.setNeedsDisplay(.infinite)
        orderFrontRegardless()
    }
}

class DimView: NSView {

    // The focused window's frame in this view's coordinates.
    var cutout: CGRect?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Filling screen + cut-out with the even-odd rule dims everything
        // except the cut-out, without any compositing tricks.
        let path = NSBezierPath(rect: bounds)
        if let cutout {
            var cornerRadius = UserDefaults.standard.integer(forKey: Key.cornerRadius)
            cornerRadius = max(0, min(50, cornerRadius))
            if cornerRadius > 0 {
                path.append(NSBezierPath(roundedRect: cutout, xRadius: CGFloat(cornerRadius), yRadius: CGFloat(cornerRadius)))
            } else {
                path.append(NSBezierPath(rect: cutout))
            }
            path.windingRule = .evenOdd
        }

        var dimLevel = UserDefaults.standard.double(forKey: Key.spotlightDimLevel)
        if dimLevel == 0 {
            dimLevel = Defaults.spotlightDimAlpha
        }
        dimLevel = max(0.05, min(0.9, dimLevel))

        NSColor.black.withAlphaComponent(CGFloat(dimLevel)).setFill()
        path.fill()
    }
}
