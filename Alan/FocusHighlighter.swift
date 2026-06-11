//
//  FocusHighlighter.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

class FocusHighlighter {

    static let shared = FocusHighlighter()

    private let systemWideElement = AXUIElementCreateSystemWide()
    private let highlightWindow = HighlightWindow()
    private var dimWindows: [DimWindow] = []
    private var highlightVisible = false
    private var lastFrame: CGRect?
    private var lastFocusedWindow: AXUIElement?
    private var frameIsDrawn = false;
    private var drawFrame = true
    private var disableFrameTimer: Timer?

    private var axObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedPid: pid_t = -1

    private var flashTimer: Timer?
    private var flashCount = 0
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?

    private var workspaceObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var dragMonitor: Any?
    private var dragTimer: Timer?

    func start() {
        updateHotkeyRegistration()
        refresh()
        observeFrontmostApp()

        // Re-attach the AX observer whenever another app becomes frontmost
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.observeFrontmostApp()
            self?.refresh()
        }

        // AX delivers window moved/resized notifications when the gesture
        // ends, not continuously during a live drag, so follow the window
        // with a short-lived timer while the mouse button is down.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDragged {
                self.startDragTracking()
            } else {
                self.stopDragTracking()
                self.refresh()
            }
        }

        // Recolor the border when the system switches between light and dark
        // mode; otherwise the old color lingers until a window moves.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.forceUpdate()
            }
        }
    }

    func forceUpdate() {
        // Defaults may have changed, so reconcile the hotkey registration.
        updateHotkeyRegistration()

        // Re-evaluate from scratch rather than redrawing the remembered
        // frame, so settings that decide *whether* the border shows (hide
        // when maximized, excluded apps) apply the moment they're toggled.
        frameIsDrawn = false
        refresh()
    }

    // MARK: - Find my window

    private func updateHotkeyRegistration() {
        if UserDefaults.standard.bool(forKey: Key.findMyWindowHotkey) {
            registerFindMyWindowHotkey()
        } else {
            unregisterFindMyWindowHotkey()
        }
    }

    // Control-Option-Command-F. A Carbon hotkey consumes the keystroke
    // (unlike a passive event monitor, which would let it through to the
    // focused app) and needs no extra permissions.
    private func registerFindMyWindowHotkey() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<FocusHighlighter>.fromOpaque(userData).takeUnretainedValue().flashBorder()
            return noErr
        }, 1, &eventType, refcon, &hotKeyEventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x414C_414E) /* 'ALAN' */, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregisterFindMyWindowHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
            self.hotKeyEventHandler = nil
        }
    }

    // Flash the border three times around the focused window, regardless
    // of any setting that currently hides it — that's the point: finding
    // the window you can't see the border of. In spotlight mode the border
    // flashes on top of the dimming.
    func flashBorder() {
        guard flashTimer == nil else { return }
        guard let (_, axFrame) = currentFocusedWindow() else { return }
        let frame = cocoaRect(fromAXRect: axFrame)

        flashCount = 0
        highlightWindow.updateFrame(to: frame)

        let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.flashCount += 1
            if self.flashCount >= 6 {
                timer.invalidate()
                self.flashTimer = nil
                // Put whatever the settings say back on screen.
                self.frameIsDrawn = false
                self.refresh()
            } else if self.flashCount % 2 == 1 {
                self.highlightWindow.orderOut(nil)
            } else {
                self.highlightWindow.updateFrame(to: frame)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        flashTimer = timer
    }

    // MARK: - AX notifications

    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        Unmanaged<FocusHighlighter>.fromOpaque(refcon).takeUnretainedValue().refresh()
    }

    private func observeFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != observedPid else { return }

        stopObservingApp()

        var observer: AXObserver?
        guard AXObserverCreate(pid, FocusHighlighter.axCallback, &observer) == .success,
              let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Registered on the application element, the window notifications
        // are delivered for all of the app's windows.
        let notifications = [
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification
        ]
        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        axObserver = observer
        observedAppElement = appElement
        observedPid = pid
    }

    private func stopObservingApp() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        observedAppElement = nil
        observedPid = -1
    }

    // MARK: - Live drag tracking

    private func startDragTracking() {
        guard dragTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.01
        RunLoop.current.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func stopDragTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    // MARK: - Border placement

    private func refresh() {
        // While the flash is running it owns the highlight window.
        guard flashTimer == nil else { return }

        // Check if the frontmost app is excluded
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           let bundleIdentifier = frontmostApp.bundleIdentifier {

            let excludedApps = UserDefaults.standard.stringArray(forKey: Key.excludedApps) ?? []
            if excludedApps.contains(bundleIdentifier) {
                if highlightVisible {
                    hideHighlight()
                    lastFrame = nil
                }
                lastFocusedWindow = nil
                return
            }
        }

        guard let (windowElement, axFrame) = currentFocusedWindow() else {
            if highlightVisible {
                hideHighlight()
                lastFrame = nil
            }
            lastFocusedWindow = nil
            return
        }

        let cocoaFrame = cocoaRect(fromAXRect: axFrame)

        // A window that fills its whole screen doesn't need a border to be
        // found, so optionally skip it. This covers zoomed/"maximized"
        // windows as well as native full-screen ones.
        if UserDefaults.standard.bool(forKey: Key.hideBorderWhenMaximized), windowFillsScreen(cocoaFrame) {
            if highlightVisible {
                hideHighlight()
                lastFrame = nil
            }
            lastFocusedWindow = nil
            return
        }

        // A focus change invalidates what's drawn even when the newly
        // focused window happens to have the exact same frame.
        let focusChanged = !isSameWindow(windowElement, lastFocusedWindow)
        lastFocusedWindow = windowElement
        if focusChanged {
            frameIsDrawn = false
        }

        if lastFrame != cocoaFrame {
            lastFrame = cocoaFrame
            frameIsDrawn = false;

            let showFrameWhileDragging = UserDefaults.standard.object(forKey: Key.showFrameWhileDragging) as? Bool ?? true
            if !showFrameWhileDragging {
                temporarilyDisableFrameDrawing()
                return;
            }
        }
        if !frameIsDrawn && drawFrame {
            frameIsDrawn = true;
            showHighlight(at: cocoaFrame)
            // The pulse animates the border, which spotlight mode replaces.
            if focusChanged && UserDefaults.standard.bool(forKey: Key.focusPulse),
               !UserDefaults.standard.bool(forKey: Key.spotlightMode) {
                highlightWindow.pulse()
            }
        }
    }

    // MARK: - Showing and hiding

    // In spotlight mode the border is replaced by per-screen dimming
    // windows with the focused window cut out; otherwise it's the border.
    private func showHighlight(at frame: CGRect) {
        if UserDefaults.standard.bool(forKey: Key.spotlightMode) {
            highlightWindow.orderOut(nil)
            updateDimWindows(cutout: frame)
        } else {
            hideDimWindows()
            highlightWindow.updateFrame(to: frame)
        }
        highlightVisible = true
    }

    private func hideHighlight() {
        highlightWindow.orderOut(nil)
        hideDimWindows()
        highlightVisible = false
    }

    private func updateDimWindows(cutout: CGRect) {
        let screens = NSScreen.screens

        // Reconcile the window pool with the current screen arrangement.
        while dimWindows.count < screens.count {
            dimWindows.append(DimWindow())
        }
        while dimWindows.count > screens.count {
            dimWindows.removeLast().orderOut(nil)
        }

        for (window, screen) in zip(dimWindows, screens) {
            // Windows spanning displays get a cut-out on every screen they
            // touch; screens the window isn't on are dimmed entirely.
            let local = cutout.intersects(screen.frame) ? cutout : nil
            window.update(screenFrame: screen.frame, cutout: local)
        }
    }

    private func hideDimWindows() {
        for window in dimWindows {
            window.orderOut(nil)
        }
    }

    private func isSameWindow(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return CFEqual(a, b)
    }

    private func temporarilyDisableFrameDrawing() {
        drawFrame = false
        hideHighlight()
        disableFrameTimer?.invalidate()
        // Nothing re-runs refresh() on its own once the window stops moving
        // (tracking is event-driven, not polled), so the timer has to do it.
        disableFrameTimer = Timer.scheduledTimer(withTimeInterval: Defaults.frameDrawingDisableTimeout, repeats: false) { [weak self] _ in
            self?.drawFrame = true
            self?.refresh()
        }
    }

    // A window counts as filling a screen when it covers that screen's
    // visible frame — the area inside the menu bar and Dock, which is what
    // zooming a window fills. Native full-screen windows cover even more,
    // so they pass the same test. The check is against the screen the
    // window is mostly on, so on multi-monitor setups a window merely
    // spanning displays doesn't qualify unless it really covers one.
    private func windowFillsScreen(_ frame: CGRect) -> Bool {
        var windowScreen: NSScreen?
        var bestOverlap: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = frame.intersection(screen.frame)
            let area = overlap.width * overlap.height
            if area > bestOverlap {
                bestOverlap = area
                windowScreen = screen
            }
        }
        guard let windowScreen else { return false }

        // The tolerance forgives apps that "maximize" a few points short,
        // like grid-rounded terminals.
        let target = windowScreen.visibleFrame.insetBy(
            dx: Defaults.screenFillTolerance,
            dy: Defaults.screenFillTolerance
        )
        return frame.contains(target)
    }

    // Hello, darkness, my old friend. I'm still really bad at this API.
    private func currentFocusedWindow() -> (element: AXUIElement, frame: CGRect)? {
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard err == .success, let element = focusedElement as! AXUIElement? else {
            return nil
        }

        // If focus is a child, ask for its window
        var windowElement: CFTypeRef?
        let windowErr = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowElement
        )

        let targetElement: AXUIElement
        if windowErr == .success, let w = windowElement as! AXUIElement? {
            targetElement = w
        } else {
            targetElement = element
        }

        var frameValue: CFTypeRef?
        let frameErr = AXUIElementCopyAttributeValue(
            targetElement,
            "AXFrame" as CFString,
            &frameValue
        )

        guard frameErr == .success,
              let cfValue = frameValue,
              CFGetTypeID(cfValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var rect = CGRect.zero
        if AXValueGetType(cfValue as! AXValue) == .cgRect {
            AXValueGetValue(cfValue as! AXValue, .cgRect, &rect)
            return (targetElement, rect)
        }

        return nil
    }
}

private func cocoaRect(fromAXRect axRect: CGRect) -> CGRect {
    // AX frames are in global top-left coordinates: the origin is the
    // top-left corner of the primary screen (screens[0], the one with the
    // menu bar) and y grows downward. Cocoa's origin is the bottom-left
    // corner of that same screen, with y growing upward. Both spaces are
    // anchored to the primary screen, so the flip uses its height alone;
    // the rest of the monitor arrangement doesn't factor in.
    let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0

    var rect = axRect
    rect.origin.y = primaryScreenHeight - (axRect.origin.y + axRect.height)

    return rect
}
