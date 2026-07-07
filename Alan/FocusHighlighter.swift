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
    private var frameIsDrawn = false
    private var drawFrame = true
    private var disableFrameTimer: Timer?

    private var axObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedPid: pid_t = -1
    private var observerRetryTimer: Timer?
    private var observerRetryCount = 0
    // The pid the retry budget belongs to: retries are per-app, so one
    // stubborn app exhausting its budget must not starve the next one.
    private var observerRetryPid: pid_t = -1

    // Set true when an AX read during resolution timed out (busy/hung app)
    // rather than genuinely finding no window; refresh() uses it to keep the
    // current border and retry instead of hiding on a transient stall.
    private var lastResolutionTimedOut = false
    private var resolutionRetryTimer: Timer?
    private var resolutionRetryCount = 0

    // Re-refresh shortly after an AX notification, since a just-created
    // window's AX tree (main status, final frame) can settle a beat later.
    private var settleRefreshTimer: Timer?

    private var flashTimer: Timer?
    private var flashCount = 0
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var registeredKeyCode: UInt32 = 0
    private var registeredModifiers: UInt32 = 0
    // While the shortcut recorder is capturing, the Carbon hotkey must be
    // suspended — a registered hotkey is consumed system-wide before it can
    // reach the recorder's local key monitor, so the current combo could
    // never otherwise be re-recorded (it would just fire the hotkey).
    private var hotkeyRecordingSuspended = false
    // True when the last RegisterEventHotKey attempt failed — the combo is
    // taken by another app. Observed by Preferences to flag the dead shortcut.
    private(set) var hotkeyRegistrationFailed = false

    // Posted when the hotkey registration outcome changes, so Preferences can
    // reflect a failed (in-use) shortcut without polling.
    static let hotkeyRegistrationDidChange = Notification.Name("AlanHotkeyRegistrationDidChange")

    private var shakeMonitor: Any?
    private var shakeLastX: CGFloat?
    private var shakeDirection: CGFloat = 0
    private var shakeReversals: [TimeInterval] = []
    private var shakeCooldownUntil: TimeInterval = 0

    private var displayedCutout: CGRect?
    private var spotlightAnimationTimer: Timer?
    private var displayedBorderFrame: CGRect?
    private var borderAnimationTimer: Timer?

    private var workspaceObserver: NSObjectProtocol?
    private var defaultsObservation: DefaultsObservationBridge?
    private var accessibilityObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var dragMonitor: Any?
    private var dragTimer: Timer?
    // Ticks of drag polling that saw no window movement; once enough pile
    // up, this drag isn't a window drag (text selection, a scrollbar) and
    // polling stops until the next mouse-up.
    private var dragUnchangedTicks = 0
    private var dragSuppressedUntilMouseUp = false
    private var forceUpdateScheduled = false

    func start() {
        // Bound every AX call: the default messaging timeout is several
        // seconds per call, which can wedge the main thread behind a busy
        // or hung process. Set on the system-wide element, this applies to
        // all of the process's AX messaging.
        AXUIElementSetMessagingTimeout(systemWideElement, 0.5)

        updateHotkeyRegistration()
        updateShakeMonitor()
        refresh()
        observeFrontmostApp()

        // Observed here rather than in the prefs controller, so settings
        // apply even if the Preferences window has never been opened. KVO on
        // the individual keys, not UserDefaults.didChangeNotification: the
        // notification is only posted for writes made by this process, while
        // KVO also fires for external ones — which is what actually makes
        // `defaults write` from Terminal (or Shortcuts, or a Stream Deck
        // script toggling `paused`) apply immediately.
        defaultsObservation = DefaultsObservationBridge(keys: Key.allObservedKeys) { [weak self] in
            // Coalesce bursts of writes — a slider or color-well drag fires
            // continuously — into one forceUpdate per run-loop turn. External
            // changes can be delivered off the main thread; hop over.
            DispatchQueue.main.async {
                self?.scheduleForceUpdate()
            }
        }

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
                self.dragSuppressedUntilMouseUp = false
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

        // Apply a Reduce Motion (or other accessibility display) change the
        // moment it's toggled, so the glide/pulse/party guards below take
        // effect without waiting for the next window event.
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceUpdate()
        }

        // A display attach/detach, resolution, or scaling change leaves the
        // spotlight window pool sized to the old screen set and the cached
        // frames in old coordinates. Reconcile, and drop the remembered
        // positions so the glide doesn't animate from stale ones.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.displayedCutout = nil
            self.displayedBorderFrame = nil
            self.forceUpdate()
        }

        // Switching Spaces causes exactly the disorientation shake-to-find
        // cures, minus the deliberate gesture: optionally flash the border
        // on arrival. The short delay lets the switch animation land and
        // focus settle before the flash samples the focused window; under
        // Reduce Motion flashBorder already degrades to a single reveal.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard UserDefaults.standard.bool(forKey: Key.flashOnSpaceChange) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Defaults.spaceChangeFlashDelay) {
                self?.flashBorder()
            }
        }
    }

    // Honor the system Reduce Motion setting across every animation. Read live
    // (not cached) so the accessibility observer above needs only to repaint.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func scheduleForceUpdate() {
        guard !forceUpdateScheduled else { return }
        forceUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.forceUpdateScheduled = false
            self.forceUpdate()
        }
    }

    func forceUpdate() {
        // Defaults may have changed, so reconcile the global listeners.
        updateHotkeyRegistration()
        updateShakeMonitor()

        // Re-evaluate from scratch rather than redrawing the remembered
        // frame, so settings that decide *whether* the border shows (hide
        // when maximized, excluded apps) apply the moment they're toggled.
        frameIsDrawn = false
        refresh()
    }

    // MARK: - Find my window

    private func updateHotkeyRegistration() {
        // Keep the hotkey unregistered while a recording is in progress, so the
        // combo being typed reaches the recorder rather than firing the hotkey.
        guard !hotkeyRecordingSuspended else {
            unregisterFindMyWindowHotkey()
            return
        }
        guard UserDefaults.standard.bool(forKey: Key.findMyWindowHotkey) else {
            unregisterFindMyWindowHotkey()
            return
        }

        // integer(forKey:) returns an Int that a corrupt or hand-edited plist
        // could make negative or oversized; UInt32(_:) would trap on those, so
        // fall back to the defaults instead of crashing at launch.
        let keyCode = UInt32(exactly: UserDefaults.standard.integer(forKey: Key.findMyWindowKeyCode))
            ?? UInt32(Defaults.findMyWindowDefaultKeyCode)
        let modifiers = UInt32(exactly: UserDefaults.standard.integer(forKey: Key.findMyWindowModifiers))
            ?? UInt32(Defaults.findMyWindowDefaultModifiers)

        // Re-register when the recorded shortcut changed.
        if hotKeyRef != nil, keyCode == registeredKeyCode, modifiers == registeredModifiers {
            return
        }
        unregisterFindMyWindowHotkey()
        registerFindMyWindowHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    // Suspend/resume the hotkey around a Preferences shortcut recording.
    func suspendHotkeyForRecording() {
        hotkeyRecordingSuspended = true
        unregisterFindMyWindowHotkey()
    }

    func resumeHotkeyAfterRecording() {
        hotkeyRecordingSuspended = false
        updateHotkeyRegistration()
    }

    // A Carbon hotkey consumes the keystroke (unlike a passive event
    // monitor, which would let it through to the focused app) and needs no
    // extra permissions. The combo comes from the defaults, recorded in
    // Preferences; ⌃⌥⌘F out of the box.
    private func registerFindMyWindowHotkey(keyCode: UInt32, modifiers: UInt32) {
        // The event handler is installed once and kept for the app's
        // lifetime; it does nothing while no hotkey is registered. It must
        // not be reinstalled per attempt: registration is retried on every
        // defaults or appearance change, so a persistently failing
        // RegisterEventHotKey (the combo taken by another app, say) would
        // otherwise stack a new handler each time.
        if hotKeyEventHandler == nil {
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
        }

        guard hotKeyRef == nil else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x414C_414E) /* 'ALAN' */, id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            // The out parameter is not defined on failure; make sure the
            // next attempt isn't fooled into thinking we're registered.
            // Failure here is almost always eventHotKeyExistsErr — the combo
            // is already claimed by another app — so record it for the UI.
            hotKeyRef = nil
            setHotkeyRegistrationFailed(true)
        } else {
            registeredKeyCode = keyCode
            registeredModifiers = modifiers
            setHotkeyRegistrationFailed(false)
        }
    }

    private func setHotkeyRegistrationFailed(_ failed: Bool) {
        guard failed != hotkeyRegistrationFailed else { return }
        hotkeyRegistrationFailed = failed
        NotificationCenter.default.post(name: Self.hotkeyRegistrationDidChange, object: self)
    }

    private func unregisterFindMyWindowHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        // Nothing is registered now, so there's no failure to report.
        setHotkeyRegistrationFailed(false)
    }

    // MARK: - Shake to find

    private func updateShakeMonitor() {
        let enabled = UserDefaults.standard.bool(forKey: Key.shakeToFind)
        if enabled, shakeMonitor == nil {
            shakeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                self?.detectShake(at: NSEvent.mouseLocation.x)
            }
        } else if !enabled, let shakeMonitor {
            NSEvent.removeMonitor(shakeMonitor)
            self.shakeMonitor = nil
            shakeLastX = nil
            shakeDirection = 0
            shakeReversals.removeAll()
        }
    }

    // A shake is a quick horizontal scrub: several direction reversals of
    // decent amplitude within a short window — the same gesture macOS uses
    // for shake-to-enlarge-cursor.
    private func detectShake(at x: CGFloat) {
        defer { shakeLastX = x }
        guard let lastX = shakeLastX else { return }

        let dx = x - lastX
        guard abs(dx) > Defaults.shakeMinSwing else { return }

        let direction: CGFloat = dx > 0 ? 1 : -1
        if direction != shakeDirection, shakeDirection != 0 {
            let now = Date().timeIntervalSinceReferenceDate
            shakeReversals.append(now)
            shakeReversals.removeAll { now - $0 > Defaults.shakeWindow }

            if shakeReversals.count >= Defaults.shakeReversalCount, now > shakeCooldownUntil {
                shakeCooldownUntil = now + Defaults.shakeCooldown
                shakeReversals.removeAll()
                flashBorder()
            }
        }
        shakeDirection = direction
    }

    // Flash the border three times around the focused window, regardless
    // of any setting that currently hides it — that's the point: finding
    // the window you can't see the border of. In spotlight mode the border
    // flashes on top of the dimming.
    func flashBorder() {
        guard flashTimer == nil else { return }
        // Own the overlay exclusively for the flash. A border or spotlight
        // glide still running would keep re-fronting the window on its own
        // schedule — the flashOnSpaceChange path fires this 0.2 s after a Space
        // switch, inside the ~0.25 s glide window — and defeat the off-phase
        // orderOut below, so the border wouldn't visibly blink.
        borderAnimationTimer?.invalidate()
        borderAnimationTimer = nil
        spotlightAnimationTimer?.invalidate()
        spotlightAnimationTimer = nil

        guard var frame = currentFocusCocoaFrame() else { return }

        flashCount = 0
        highlightWindow.updateFrame(to: frame)

        // Under Reduce Motion, a ~4 Hz on/off strobe is exactly what to avoid.
        // Reveal the border once and hold it, then restore what the settings
        // say. Still finds the window; just without the flashing.
        if Self.reduceMotion {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.flashTimer = nil
                self.frameIsDrawn = false
                self.refresh()
            }
            RunLoop.current.add(timer, forMode: .common)
            flashTimer = timer
            return
        }

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
                // Re-sample the focused window's live position each reveal, so
                // a window that moved mid-flash is flashed where it is now.
                // Fall back to the last-known frame on a transient AX stall so
                // a hiccup doesn't blank an on-phase.
                if let live = self.currentFocusCocoaFrame() { frame = live }
                self.highlightWindow.updateFrame(to: frame)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        flashTimer = timer
    }

    // The focused window's frame in Cocoa coordinates right now, or nil if it
    // can't be resolved. Used by the flash to point at where the window is on
    // each reveal instead of replaying a rect captured once.
    private func currentFocusCocoaFrame() -> CGRect? {
        guard let (_, axFrame) = currentFocusedWindow() else { return nil }
        return cocoaRect(fromAXRect: axFrame)
    }

    // MARK: - AX notifications

    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        Unmanaged<FocusHighlighter>.fromOpaque(refcon).takeUnretainedValue().handleAXNotification()
    }

    private func handleAXNotification() {
        refresh()
        // AXWindowCreated in particular fires before the new window has fully
        // settled (become main, taken its final frame), so the synchronous
        // refresh above can sample stale state. A coalesced re-refresh a beat
        // later catches the settled window.
        scheduleSettleRefresh()
    }

    private func scheduleSettleRefresh() {
        guard settleRefreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.settleRefreshTimer = nil
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .common)
        settleRefreshTimer = timer
    }

    private func scheduleResolutionRetry() {
        guard resolutionRetryTimer == nil, resolutionRetryCount < 3 else { return }
        resolutionRetryCount += 1
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.resolutionRetryTimer = nil
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .common)
        resolutionRetryTimer = timer
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
        //
        // kAXWindowCreated is what catches a window that opens already
        // focused — a dialog like Finder's "an item named … already exists,
        // do you want to replace it?" prompt, say. AXFocusedWindowChanged
        // fires when focus moves between windows that already exist, but a
        // brand-new window that becomes active the instant it appears often
        // posts only AXWindowCreated; without it that window, though active,
        // never triggers a refresh and so never gets a border.
        // kAXMainWindowChanged covers a window that becomes the app's main
        // window without becoming key — a frontmost dialog that never takes
        // keyboard focus posts this but not AXFocusedWindowChanged.
        let notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification
        ]
        var allRegistered = true
        for notification in notifications {
            let err = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if err != .success && err != .notificationAlreadyRegistered {
                allRegistered = false
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        axObserver = observer
        observedAppElement = appElement

        if allRegistered {
            // Only latch observedPid once registration fully succeeded, so a
            // partial failure isn't frozen in by the pid guard above.
            observedPid = pid
            observerRetryCount = 0
        } else {
            // The app's AX server is likely still coming up (it was activated
            // the instant it launched) or is momentarily busy. Leave
            // observedPid unset and retry, so its window events aren't
            // permanently missed.
            observedPid = -1
            scheduleObserverRetry(pid: pid)
        }
    }

    private func scheduleObserverRetry(pid: pid_t) {
        // A fresh app gets a fresh budget — and any timer still pending for
        // a previous app is moot (its callback no-ops once that app is no
        // longer frontmost, but while pending it would block this one).
        if pid != observerRetryPid {
            observerRetryPid = pid
            observerRetryCount = 0
            observerRetryTimer?.invalidate()
            observerRetryTimer = nil
        }
        guard observerRetryTimer == nil, observerRetryCount < 5 else { return }
        observerRetryCount += 1
        let delay = min(2.0, 0.25 * pow(2.0, Double(observerRetryCount - 1)))
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.observerRetryTimer = nil
            // Only worth retrying while this app is still frontmost.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                self.observeFrontmostApp()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        observerRetryTimer = timer
    }

    private func stopObservingApp() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        observedAppElement = nil
        observedPid = -1
        // A retry still pending for the app we just stopped observing would
        // only fire into the void — and, worse, block the next app's retry
        // from being scheduled.
        observerRetryTimer?.invalidate()
        observerRetryTimer = nil
    }

    // MARK: - Live drag tracking

    private func startDragTracking() {
        guard dragTimer == nil, !dragSuppressedUntilMouseUp else { return }
        dragUnchangedTicks = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frameBefore = self.lastFrame
            self.refresh()
            // Most drags never move a window — text selection, scrollbars,
            // brush strokes. Once a third of a second of polling has seen no
            // window movement, this drag isn't a window drag: stop paying
            // 30 Hz of AX round-trips (and, in spotlight mode, repaints) for
            // it, and stand down until the mouse button goes back up.
            if self.lastFrame == frameBefore {
                self.dragUnchangedTicks += 1
                if self.dragUnchangedTicks >= 10 {
                    self.stopDragTracking()
                    self.dragSuppressedUntilMouseUp = true
                }
            } else {
                self.dragUnchangedTicks = 0
            }
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

        // Paused: hide everything and stop. flashBorder is intentionally left
        // working, so the find-my-window hotkey can still peek at the window
        // while paused. Toggled from the status menu or `defaults write`.
        if UserDefaults.standard.bool(forKey: Key.paused) {
            if highlightVisible {
                hideHighlight()
                lastFrame = nil
            }
            lastFocusedWindow = nil
            return
        }

        // Never point the AX machinery at ourselves. We know where our own
        // windows are without asking, and — worse — when our open/save
        // panel is up, the focused element belongs to the panel service,
        // which blocks on Alan over XPC while Alan blocks on its AX
        // replies: both processes froze. (The panel also writes its state
        // into our defaults, retriggering refresh continuously.)
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           frontmostApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  window.isVisible,
                  !(window is HighlightWindow),
                  !(window is DimWindow)
            else {
                if highlightVisible {
                    hideHighlight()
                    lastFrame = nil
                }
                lastFocusedWindow = nil
                return
            }

            lastFocusedWindow = nil
            let cocoaFrame = window.frame
            if lastFrame != cocoaFrame {
                lastFrame = cocoaFrame
                frameIsDrawn = false
            }
            if !frameIsDrawn && drawFrame {
                frameIsDrawn = true
                showHighlight(at: cocoaFrame)
            }
            return
        }

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

        lastResolutionTimedOut = false
        guard let (windowElement, axFrame) = currentFocusedWindow() else {
            if lastResolutionTimedOut {
                // A transient AX stall (a busy or mid-operation frontmost app),
                // not a genuine "no focused window". Keep whatever border is up
                // — the window almost certainly hasn't moved — and retry
                // shortly, rather than hiding on a hiccup and staying hidden
                // until the next unrelated event.
                scheduleResolutionRetry()
                return
            }
            if highlightVisible {
                hideHighlight()
                lastFrame = nil
            }
            lastFocusedWindow = nil
            return
        }
        resolutionRetryCount = 0

        let cocoaFrame = cocoaRect(fromAXRect: axFrame)

        // Steady state: same window, same frame, border already drawn —
        // nothing below can change the outcome. Return before the
        // AXFullScreen read, an IPC round-trip into the frontmost app that
        // notification storms and drag ticks would otherwise pay every time.
        // (Anything that invalidates the outcome also clears one of these
        // flags: settings changes go through forceUpdate, which drops
        // frameIsDrawn; frame and focus changes miss the comparisons.)
        if frameIsDrawn, drawFrame, lastFrame == cocoaFrame,
           isSameWindow(windowElement, lastFocusedWindow) {
            return
        }

        // Native full-screen windows never get a border: nothing else is
        // visible on their Space to tell focus apart from. Split View tiles
        // also report AXFullScreen, so only windows that actually cover the
        // screen are skipped — tiled windows keep their border.
        if isFullScreen(windowElement), windowFillsScreen(cocoaFrame) {
            if highlightVisible {
                hideHighlight()
                lastFrame = nil
            }
            lastFocusedWindow = nil
            return
        }

        // A window that fills its whole screen doesn't need a border to be
        // found, so optionally skip it. With full screen handled above, this
        // governs zoomed/"maximized" windows.
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
            frameIsDrawn = false

            if !UserDefaults.standard.bool(forKey: Key.showFrameWhileDragging) {
                temporarilyDisableFrameDrawing()
                return
            }
        }
        if !frameIsDrawn && drawFrame {
            frameIsDrawn = true
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
            highlightWindow.setPartyMode(false)
            highlightWindow.setBorderStyleAnimating(false)
            highlightWindow.orderOut(nil)
            // Cancel any border glide still in flight: each of its ticks calls
            // updateFrame → orderFrontRegardless and would flicker the
            // just-hidden border back on over the dim for the rest of the
            // glide. (moveSpotlight invalidates only its own timer.) The
            // remembered displayedBorderFrame is left intact so a switch back
            // to border mode still has a position to glide from.
            borderAnimationTimer?.invalidate()
            borderAnimationTimer = nil
            moveSpotlight(to: frame)
        } else {
            hideDimWindows()
            // Symmetrically, cancel any spotlight glide still in flight — its
            // ticks re-front the dim windows and would resurrect the dimming
            // over the border.
            spotlightAnimationTimer?.invalidate()
            spotlightAnimationTimer = nil
            moveBorder(to: frame)
            // The party and animated-style redraw timers only need to run
            // while the border is actually on screen.
            highlightWindow.setPartyMode(UserDefaults.standard.bool(forKey: Key.partyMode))
            highlightWindow.setBorderStyleAnimating(borderStyleNeedsAnimation())
        }
        highlightVisible = true
    }

    // Marching ants and the hand-drawn wobble animate (unless Reduce Motion is
    // on, where they render statically and need no redraw timer).
    private func borderStyleNeedsAnimation() -> Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        switch BorderStyle.current {
        case .ants, .handDrawn: return true
        case .solid, .dashed: return false
        }
    }

    private func hideHighlight() {
        highlightWindow.setPartyMode(false)
        highlightWindow.setBorderStyleAnimating(false)
        highlightWindow.orderOut(nil)
        hideDimWindows()
        highlightVisible = false
        spotlightAnimationTimer?.invalidate()
        spotlightAnimationTimer = nil
        borderAnimationTimer?.invalidate()
        borderAnimationTimer = nil
        // displayedCutout is deliberately kept: app switches routinely pass
        // through a transient "no focused window" moment that hides the
        // spotlight for a frame, and forgetting the position here meant the
        // next reveal had nothing to animate from — it snapped. Remembering
        // it lets the stage light swing over from wherever it last was.
    }

    // The highlight glides from where it is to the new window over a few
    // frames — a stage light swinging across the screen — instead of
    // teleporting. Re-targeting mid-flight restarts from the current
    // position. Both glides skip the easing while a drag is tracked at
    // 30 Hz (the updates themselves are the animation; easing would only
    // add lag) and when the animate-movement preference is off.

    private func moveSpotlight(to target: CGRect) {
        if dragTimer != nil || Self.reduceMotion || !UserDefaults.standard.bool(forKey: Key.animateMovement) {
            spotlightAnimationTimer?.invalidate()
            spotlightAnimationTimer = nil
            displayedCutout = target
            updateDimWindows(cutout: target)
            return
        }

        guard let from = displayedCutout, from != target else {
            // First reveal, or a redraw with an unchanged frame (settings
            // like the dim level still need the windows repainted).
            spotlightAnimationTimer?.invalidate()
            spotlightAnimationTimer = nil
            displayedCutout = target
            updateDimWindows(cutout: target)
            return
        }

        spotlightAnimationTimer?.invalidate()
        spotlightAnimationTimer = makeGlideTimer(from: from, to: target) { [weak self] rect, finished in
            guard let self else { return }
            self.displayedCutout = rect
            self.updateDimWindows(cutout: rect)
            if finished {
                self.spotlightAnimationTimer = nil
            }
        }
    }

    private func moveBorder(to target: CGRect) {
        if dragTimer != nil || Self.reduceMotion || !UserDefaults.standard.bool(forKey: Key.animateMovement) {
            borderAnimationTimer?.invalidate()
            borderAnimationTimer = nil
            displayedBorderFrame = target
            highlightWindow.updateFrame(to: target)
            return
        }

        guard let from = displayedBorderFrame, from != target else {
            // First reveal, or a settings-change repaint in place.
            borderAnimationTimer?.invalidate()
            borderAnimationTimer = nil
            displayedBorderFrame = target
            highlightWindow.updateFrame(to: target)
            return
        }

        borderAnimationTimer?.invalidate()
        borderAnimationTimer = makeGlideTimer(from: from, to: target) { [weak self] rect, finished in
            guard let self else { return }
            self.displayedBorderFrame = rect
            self.highlightWindow.updateFrame(to: rect)
            if finished {
                self.borderAnimationTimer = nil
            }
        }
    }

    // Drives a smoothstep interpolation between two rects at 60 Hz; the
    // closure receives each intermediate rect and finally the target with
    // finished == true.
    private func makeGlideTimer(from: CGRect, to target: CGRect, apply: @escaping (CGRect, Bool) -> Void) -> Timer {
        var duration = UserDefaults.standard.double(forKey: Key.moveAnimationDuration)
        if duration <= 0 {
            duration = Defaults.moveAnimationDuration
        }
        duration = min(1.0, max(0.05, duration))

        let start = Date().timeIntervalSinceReferenceDate
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let t = (Date().timeIntervalSinceReferenceDate - start) / duration
            if t >= 1 {
                timer.invalidate()
                apply(target, true)
            } else {
                let e = CGFloat(t * t * (3 - 2 * t))
                apply(CGRect(
                    x: from.minX + (target.minX - from.minX) * e,
                    y: from.minY + (target.minY - from.minY) * e,
                    width: from.width + (target.width - from.width) * e,
                    height: from.height + (target.height - from.height) * e
                ), false)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        return timer
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

    // Native full screen is reported through the window's AXFullScreen
    // attribute; there is no public constant for it, the raw string is the
    // documented value. Anything but a readable true means "not full screen".
    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        guard err == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if err == .cannotComplete || err == .apiDisabled {
            lastResolutionTimedOut = true
        }
        guard err == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func focusedWindowOfProcess(owning element: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        return elementAttribute(appElement, kAXFocusedWindowAttribute as String)
    }

    // Last resort of the window resolution: climb the parent chain until
    // something window-like turns up. Patchy accessibility trees sometimes
    // omit AXWindow and AXTopLevelUIElement on descendants while the chain
    // of AXParents still reaches the window. Capped, because every hop is
    // an IPC round-trip into the focused app and a malformed tree could
    // even cycle; the application element at the top has no parent, so
    // well-formed trees exit early on their own.
    private func nearestWindowLikeAncestor(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<25 {
            if isWindowLike(current) {
                return current
            }
            guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private func isWindowLike(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String
        else { return false }
        return role == kAXWindowRole as String
            || role == kAXSheetRole as String
            || role == kAXDrawerRole as String
    }

    // Hello, darkness, my old friend. I'm still really bad at this API.
    //
    // Resolve the window the border should hug. The hard case this is built
    // around: a window that is frontmost but never became key *or main* —
    // Finder's copy-progress panel is the canonical example. The system-wide
    // focused (keyboard) element still points into the window behind it, and
    // AXMainWindow can point there too (panels are never main; orderFront
    // alone promotes nothing), so any focus-derived resolution glues the
    // border to the wrong window. The window server's z-order knows better:
    // when neither the keyboard-focus window nor the main window matches the
    // topmost app-owned window, resolve that window directly by frame.
    private func currentFocusedWindow() -> (element: AXUIElement, frame: CGRect)? {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Keyboard-focus resolution: right in the common case, and the only
        // thing that resolves the out-of-process save/open panel service.
        let focusWindow = focusedWindowElement()

        // If keyboard focus lives in a different process than the frontmost
        // app (the panel service, a non-activating accessory), trust it —
        // that's the window the user is actually working in.
        if let focusWindow, let frontPid {
            var pid: pid_t = 0
            if AXUIElementGetPid(focusWindow, &pid) == .success, pid != frontPid,
               let frame = axFrame(of: focusWindow) {
                return (focusWindow, frame)
            }
        }

        // Cross-check against the window server's z-order. Skipped during a
        // live drag — the dragged window is key, so keyboard focus is already
        // right, saving IPC per 30 Hz tick.
        if dragTimer == nil, let frontPid,
           let topBounds = topmostWindowBounds(pid: frontPid) {
            // Cheapest first: the keyboard-focus window already is the
            // topmost window — the overwhelmingly common case.
            if let focusWindow, let frame = axFrame(of: focusWindow),
               framesRoughlyEqual(frame, topBounds) {
                return (focusWindow, frame)
            }

            // A dialog that became the app's main window without taking
            // keyboard focus.
            let appElement = AXUIElementCreateApplication(frontPid)
            if let mainWindow = elementAttribute(appElement, kAXMainWindowAttribute as String),
               let frame = axFrame(of: mainWindow),
               framesRoughlyEqual(frame, topBounds) {
                return (mainWindow, frame)
            }

            // Neither key nor main matches what's actually in front — the
            // copy-progress panel case. AX can't *name* the window, but its
            // geometry gives it away: find the app's AX window sitting at
            // the topmost bounds.
            if let topWindow = appWindowMatching(topBounds, appElement: appElement),
               let frame = axFrame(of: topWindow) {
                return (topWindow, frame)
            }
        }

        // Fall back to the keyboard-focus resolution: floating palettes
        // (never the topmost layer-0 window), windows the z-order snapshot
        // missed, and the drag path all land here.
        if let focusWindow, let frame = axFrame(of: focusWindow) {
            return (focusWindow, frame)
        }

        return nil
    }

    // The window resolved from the system-wide keyboard-focused element, via
    // the same chain as before: AXWindow, then AXTopLevelUIElement (sheets and
    // drawers), then the owning process's focused window (the out-of-process
    // panel service), then the nearest window-like ancestor.
    private func focusedWindowElement() -> AXUIElement? {
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        if err == .cannotComplete || err == .apiDisabled {
            lastResolutionTimedOut = true
        }
        guard err == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = focusedElement as! AXUIElement

        if let window = elementAttribute(element, kAXWindowAttribute as String) {
            return window
        } else if let topLevel = elementAttribute(element, kAXTopLevelUIElementAttribute as String) {
            return topLevel
        } else if let focusedWindow = focusedWindowOfProcess(owning: element) {
            return focusedWindow
        } else if let ancestor = nearestWindowLikeAncestor(of: element) {
            // The walk starts at the element itself, so this also covers apps
            // that report the bare window as the focused element.
            return ancestor
        }
        return nil
    }

    // Find the app's AX window whose frame matches the given window-server
    // bounds — the resolution of last resort for a window that is neither
    // key nor main. Capped: the array read is one IPC but every AXFrame read
    // is another, and a window-hoarder app shouldn't stall a refresh.
    private func appWindowMatching(_ bounds: CGRect, appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        if err == .cannotComplete || err == .apiDisabled {
            lastResolutionTimedOut = true
        }
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }
        for window in windows.prefix(20) {
            if let frame = axFrame(of: window), framesRoughlyEqual(frame, bounds) {
                return window
            }
        }
        return nil
    }

    // Bounds of the frontmost app-owned window in the window server's
    // front-to-back order. AXFrame and CGWindow bounds share the top-left
    // global coordinate space, so the result is comparable to an AXFrame.
    private func topmostWindowBounds(pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // First reasonably-sized window owned by this app on a normal window
        // layer. Menus, pop-ups, and status windows sit on higher layers and
        // are skipped; floating tool panels (layer 3) are kept.
        for info in infoList {
            guard let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerNumber.int32Value == pid else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0, layer <= 3 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard bounds.width > 40, bounds.height > 40 else { continue }
            return bounds
        }
        return nil
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var frameValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue)
        if err == .cannotComplete || err == .apiDisabled {
            lastResolutionTimedOut = true
        }
        guard err == .success,
              let cfValue = frameValue,
              CFGetTypeID(cfValue) == AXValueGetTypeID(),
              AXValueGetType(cfValue as! AXValue) == .cgRect
        else {
            return nil
        }
        var rect = CGRect.zero
        AXValueGetValue(cfValue as! AXValue, .cgRect, &rect)
        return rect
    }

    private func framesRoughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }
}

// Turns changes to a fixed set of defaults keys into a callback.
// UserDefaults is documented KVO-compliant for defaults keys, and unlike
// UserDefaults.didChangeNotification the KVO notifications also fire for
// changes made by other processes. FocusHighlighter isn't an NSObject, so
// this small bridge hosts the observation for it.
private final class DefaultsObservationBridge: NSObject {
    private let keys: [String]
    private let onChange: () -> Void

    init(keys: [String], onChange: @escaping () -> Void) {
        self.keys = keys
        self.onChange = onChange
        super.init()
        for key in keys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    deinit {
        for key in keys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        onChange()
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
