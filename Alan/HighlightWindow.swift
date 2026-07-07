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
        // .fullScreenAuxiliary lets the border appear on other apps' full-screen
        // Spaces — notably Split View tiles, which refresh() deliberately keeps a
        // border on; .canJoinAllSpaces alone excludes full-screen Spaces.
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        // Keep the border out of screenshots, screen recordings, and screen
        // shares by default — a pulsing border broadcast to a whole meeting is
        // a distraction, not a focus aid. Opt-in via Key.showInScreenshots for
        // anyone documenting their setup or presenting the border itself.
        applyOverlaySharingType()

        self.contentView = HighlightView(frame: .zero)
    }
    
    // Room the overlay leaves around the window frame for drawing that
    // extends past it. The stroke alone needs at most 25 pt (width 20 at the
    // 2.5× pulse peak → half-width 25, less the ≥1 pt inset). The soft
    // effects need more — the glow's 12 pt blur, the stronger shadow's
    // 25 pt blur + 3 pt offset — and used to clip against the constant
    // margin in a hard straight edge. Computed from the enabled effects so
    // the halo gets its room, and the backing store only grows when the
    // user opted into one.
    static var shadowMargin: CGFloat {
        var margin: CGFloat = 25
        if UserDefaults.standard.bool(forKey: Key.glowingBorder) { margin += 15 }
        if UserDefaults.standard.bool(forKey: Key.strongerShadow) { margin += 30 }
        // The contrast casing strokes ~1.5 pt wider than the border, which at
        // the extreme (max width × pulse peak) would otherwise clip against the
        // 25 pt base. Only grow the backing store when the casing is active.
        if HighlightView.contrastCasingActive { margin += 2 }
        return margin
    }

    func updateFrame(to rect: CGRect) {
        let margin = HighlightWindow.shadowMargin
        let newRect = rect.insetBy(dx: -margin, dy: -margin)
        // display: false + a single needsDisplay coalesces to one draw per
        // run-loop pass; setFrame(display: true) would draw synchronously and
        // the explicit invalidation would then schedule a second full redraw.
        setFrame(newRect, display: false)
        contentView?.needsDisplay = true
        // The overlay sits at .statusBar level, above all normal windows, so it
        // stays on top without re-ordering every glide tick; only re-front when
        // it isn't already showing.
        if !isVisible {
            orderFrontRegardless()
        }
    }

    // MARK: - Party mode

    private var partyTimer: Timer?

    // The hue comes from the wall clock at draw time, so all the timer has
    // to do is keep the view redrawing while the border is on screen.
    func setPartyMode(_ enabled: Bool) {
        // Party mode's animation is a continuous hue cycle. Under Reduce Motion
        // keep the color (still sampled from the clock at draw time) but don't
        // run the redraw timer, so the border wears a party hue without
        // strobing through the wheel.
        if enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
    // The last wobble seed we actually repainted for, so hand-drawn ticks that
    // wouldn't change the sketch can skip the redraw.
    private var lastAnimatedSeed: Int?

    // Marching ants and the hand-drawn wobble derive their phase/seed from the
    // wall clock at draw time (like party mode), so the timer just keeps the
    // view repainting while such a style is on screen.
    func setBorderStyleAnimating(_ enabled: Bool) {
        if enabled {
            guard styleAnimationTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Marching ants advances its dash phase every tick, so it needs
                // every redraw. The hand-drawn wobble only re-seeds ~3×/s
                // (Int(time * 3)), so 27 of every 30 ticks would regenerate a
                // pixel-identical path and re-stroke it (plus the CPU Gaussian
                // passes if glow/shadow are on). Gate its invalidation on the
                // seed actually changing; keep the 30 Hz timer so a seed change
                // is still observed within ~33 ms.
                if BorderStyle.current == .handDrawn {
                    let seed = HighlightView.currentWobbleSeed()
                    guard seed != self.lastAnimatedSeed else { return }
                    self.lastAnimatedSeed = seed
                }
                self.contentView?.needsDisplay = true
            }
            timer.tolerance = (1.0 / 30.0) * 0.1
            RunLoop.current.add(timer, forMode: .common)
            styleAnimationTimer = timer
        } else {
            styleAnimationTimer?.invalidate()
            styleAnimationTimer = nil
            lastAnimatedSeed = nil
        }
    }

    // MARK: - Focus pulse

    private var pulseTimer: Timer?
    private var pulseStart: Date?

    // Briefly thicken the border, then ease back to the configured width.
    func pulse() {
        // The pulse is decorative motion; skip it entirely under Reduce Motion
        // (the border is already at its configured width).
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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
                // A few frames of smoothstep ramp-in, then the ease-out.
                // Landing at ~2.4× on the very first tick read as a flicker,
                // not a swell — and the configured peak was never actually
                // rendered.
                let attack = Defaults.focusPulseAttackFraction
                let eased: Double
                if progress < attack {
                    let a = progress / attack
                    eased = a * a * (3 - 2 * a)
                } else {
                    let decay = (progress - attack) / (1 - attack)
                    eased = pow(1 - decay, 2)
                }
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

    // Whether to draw the contrasting under-stroke: on when the user opts in
    // via Key.contrastCasing, or automatically whenever the system Increase
    // Contrast accessibility setting is on. Kept off at factory settings so the
    // default border look is unchanged.
    static var contrastCasingActive: Bool {
        UserDefaults.standard.bool(forKey: Key.contrastCasing)
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

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
    // (obviously), then per-app colors, then the system accent color, then the
    // light/dark wells. The border is always drawn for the frontmost app's
    // focused window, so the frontmost app is the right source for the per-app
    // hue.
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
        // A dynamic catalog color — it resolves against the overlay view's
        // effective appearance during draw(_:), so light/dark is automatic and
        // it tracks the user's accent choice in System Settings for free.
        if UserDefaults.standard.bool(forKey: Key.useAccentColor) {
            return NSColor.controlAccentColor
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
            // Reduce Motion renders a static hand-drawn look. Shared with the
            // animation timer so it can skip redraws between seed changes.
            path = wobblePath(around: borderBounds, seed: HighlightView.currentWobbleSeed())
        } else if style == .corners {
            path = cornerBracketPath(around: borderBounds)
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
            // darken the window itself. The outer rect only needs to cover
            // everything drawable; -100 comfortably exceeds the largest
            // shadowMargin.
            let outerClipPath = NSBezierPath(rect: windowRect.insetBy(dx: -100, dy: -100))

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

        // Contrast casing: a wider under-stroke in the perceptual opposite, so
        // the border stays visible even when its color matches the content
        // behind it — and a live response to the Increase Contrast accessibility
        // setting. Drawn after the stronger-shadow pass (so it isn't caught by
        // that pass's clip/shadow) and before the visible stroke below (so it
        // sits underneath, leaving a thin contrasting halo on both edges). Off
        // by factory default: the exact look is unchanged unless Increase
        // Contrast is on or Key.contrastCasing is set.
        if HighlightView.contrastCasingActive {
            NSGraphicsContext.current?.saveGraphicsState()
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let casingWidth: CGFloat = increaseContrast ? 3 : 2
            let casingAlpha: CGFloat = increaseContrast ? 0.85 : 0.45
            // Copy the path so it keeps the border's dash/cap but strokes wider.
            let casingPath = path.copy() as! NSBezierPath
            casingPath.lineWidth = effectiveWidth + casingWidth
            NSColor(white: color.perceptualLuminance() > 0.5 ? 0 : 1, alpha: casingAlpha).setStroke()
            casingPath.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Draw glow if enabled. The glow pass strokes the path in the final
        // border color (the shadow needs the stroke's alpha to bloom from),
        // so it doubles as the main stroke: stroking again below would
        // composite translucent colors twice — a 50 % alpha border rendered
        // at ~75 % the moment glow was toggled on.
        let glowOn = UserDefaults.standard.bool(forKey: Key.glowingBorder)
        if glowOn {
            NSGraphicsContext.current?.saveGraphicsState()
            let glowShadow = NSShadow()
            glowShadow.shadowColor = color.withAlphaComponent(0.8)
            glowShadow.shadowBlurRadius = 12
            glowShadow.shadowOffset = NSSize(width: 0, height: 0)
            glowShadow.set()
            color.setStroke()
            path.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            // The main border stroke
            color.setStroke()
            path.stroke()
        }
    }

    // MARK: - Corner brackets

    // Four L-shaped corner brackets — a camera-focus / viewfinder reticle — as
    // one path of four disjoint subpaths (stroke() strokes them all). Covers
    // far less of the window than a full outline, and is on-the-nose for an app
    // about focus. Corner radius is intentionally ignored, like the wobble.
    static func cornerBracketPath(around rect: CGRect) -> NSBezierPath {
        let arm = max(8, min(rect.width, rect.height) * 0.18)
        // Clamp per dimension so opposite arms can't overlap on a small or thin
        // window (they meet in the middle at worst, never cross).
        let armX = min(arm, rect.width / 2)
        let armY = min(arm, rect.height / 2)
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY

        let path = NSBezierPath()
        // Each corner: run in along one edge, to the corner, out along the
        // other. The miter join at the corner keeps the elbow crisp.
        path.move(to: NSPoint(x: minX, y: minY + armY))
        path.line(to: NSPoint(x: minX, y: minY))
        path.line(to: NSPoint(x: minX + armX, y: minY))

        path.move(to: NSPoint(x: maxX - armX, y: minY))
        path.line(to: NSPoint(x: maxX, y: minY))
        path.line(to: NSPoint(x: maxX, y: minY + armY))

        path.move(to: NSPoint(x: maxX, y: maxY - armY))
        path.line(to: NSPoint(x: maxX, y: maxY))
        path.line(to: NSPoint(x: maxX - armX, y: maxY))

        path.move(to: NSPoint(x: minX + armX, y: maxY))
        path.line(to: NSPoint(x: minX, y: maxY))
        path.line(to: NSPoint(x: minX, y: maxY - armY))

        // Round the free ends of the arms; the elbows keep the default miter.
        path.lineCapStyle = .round
        return path
    }

    // MARK: - Hand-drawn wobble

    // The wobble's animation seed, re-derived a few times a second from the
    // wall clock (a fixed 0 under Reduce Motion → a static sketch). Shared by
    // the draw path and the animation timer so the timer can skip a redraw
    // whenever the seed hasn't advanced.
    static func currentWobbleSeed() -> Int {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        return Int(Date().timeIntervalSinceReferenceDate * 3)
    }

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
        // See HighlightWindow: full-screen Spaces (incl. a second display showing
        // a full-screen app) otherwise stay undimmed, breaking the effect.
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        // The dim shouldn't be captured either by default — spotlight mode
        // would black out the whole shared screen otherwise. Same opt-in as the
        // border (Key.showInScreenshots).
        applyOverlaySharingType()

        self.contentView = DimView(frame: .zero)
    }

    // The inputs the DimView actually draws from, so an unchanged update can
    // be skipped without missing a live settings change (dim level, radius).
    private var lastCutout: CGRect?
    private var lastDimLevel: Double = .nan
    private var lastCornerRadius: Int = .min

    // cutout is in global Cocoa coordinates; nil dims the whole screen.
    func update(screenFrame: CGRect, cutout: CGRect?) {
        let localCutout = cutout?.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let dimLevel = UserDefaults.standard.double(forKey: Key.spotlightDimLevel)
        let cornerRadius = UserDefaults.standard.integer(forKey: Key.cornerRadius)

        // During a glide most screens are untouched frame to frame; skip the
        // full-screen repaint and window-ordering transaction when none of the
        // draw inputs changed. Refilling a 5K backing store 60×/s per display
        // for no reason was the app's single largest cost. The dim-level and
        // radius checks keep a live settings change from being skipped.
        if isVisible,
           frame == screenFrame,
           lastCutout == localCutout,
           lastDimLevel == dimLevel,
           lastCornerRadius == cornerRadius {
            return
        }
        lastCutout = localCutout
        lastDimLevel = dimLevel
        lastCornerRadius = cornerRadius

        setFrame(screenFrame, display: false)
        if let view = contentView as? DimView {
            view.cutout = localCutout
        }
        contentView?.needsDisplay = true
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
            // The cut-out sits on the window frame itself, so it needs to hug
            // the window's own ~10 pt rounded corners — not the border's
            // cornerRadius knob, which is tuned for a path inset *inside* the
            // frame and defaults to 0 (square wedges glowing at the corners).
            let radius = Defaults.windowCornerRadius
            path.append(NSBezierPath(roundedRect: cutout, xRadius: radius, yRadius: radius))
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

extension NSWindow {
    // The overlay windows' capture visibility. `.none` (the default) hides the
    // window from screenshots, recordings, and screen shares; `.readOnly`
    // exposes it to capture without granting write access. Not `.readWrite` —
    // capture never needs to write to the overlay.
    func applyOverlaySharingType() {
        sharingType = UserDefaults.standard.bool(forKey: Key.showInScreenshots) ? .readOnly : .none
    }
}

// A one-shot fading copy of the border, left on the window focus just moved
// away *from* — you see where your attention came from, not only where it went.
// Same click-through, out-of-capture setup as HighlightWindow.
class GhostBorderWindow: NSWindow {
    // Bumped on each flash so a stale completion handler (from an earlier,
    // superseded fade) doesn't order the window out mid-animation.
    private var generation = 0
    private var holdTimer: Timer?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.sharingType = .none
        self.contentView = HighlightView(frame: .zero)
    }

    // Reveal a static border at `frame` (window frame in global Cocoa
    // coordinates) and fade it out over the trail duration, ordering out when
    // done. Re-entrant: a new call repositions and restarts.
    func flash(at frame: CGRect, reduceMotion: Bool) {
        generation += 1
        let gen = generation
        holdTimer?.invalidate()
        holdTimer = nil

        let margin = HighlightWindow.shadowMargin
        setFrame(frame.insetBy(dx: -margin, dy: -margin), display: false)
        contentView?.needsDisplay = true
        alphaValue = 1
        orderFrontRegardless()

        if reduceMotion {
            // No fade under Reduce Motion — a brief static reveal, then gone.
            let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, self.generation == gen else { return }
                self.orderOut(nil)
            }
            RunLoop.current.add(timer, forMode: .common)
            holdTimer = timer
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Defaults.ghostTrailDuration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == gen else { return }
            self.orderOut(nil)
        })
    }
}
