//
//  AppDelegate.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import Cocoa
import ApplicationServices

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // Lazy so it is built on first use — after register(defaults:) has run,
    // which matters because the controller reads defaults to populate its
    // controls. Building it eagerly (a stored property) ran before
    // registration and showed every control in its unregistered state.
    lazy var prefsWindowController = PrefsWindowController()

    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var excludeMenuItem: NSMenuItem?
    private var hideDockMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Colors aren't registered here: NSColor isn't a property-list type,
        // so they are defaulted at the read sites instead.
        UserDefaults.standard.register(defaults: [
            Key.width: 5,
            Key.inset: 4,
            Key.cornerRadius: 0,
            Key.showFrameWhileDragging: true,
            Key.hideBorderWhenMaximized: false,
            Key.focusPulse: false,
            Key.perAppColors: false,
            Key.spotlightMode: false,
            Key.findMyWindowHotkey: false,
            Key.findMyWindowKeyCode: Defaults.findMyWindowDefaultKeyCode,
            Key.findMyWindowModifiers: Defaults.findMyWindowDefaultModifiers,
            Key.findMyWindowShortcutLabel: Defaults.findMyWindowDefaultLabel,
            Key.shakeToFind: false,
            Key.spotlightDimLevel: Defaults.spotlightDimAlpha,
            Key.animateMovement: true,
            Key.moveAnimationDuration: Defaults.moveAnimationDuration,
            Key.partyMode: false,
            Key.hideDock: false,
            Key.paused: false,
            Key.borderStyle: BorderStyle.solid.rawValue
        ])

        applyActivationPolicy()

        // The status item now exists in every mode, not just hidden-Dock —
        // it's the home for Pause, "Exclude this app", and Settings, and the
        // only way to reach them when the Dock icon is hidden.
        setupStatusItem()

        let permissionJustGranted = requestAccessibilityPermissionIfNeeded()

        FocusHighlighter.shared.start()

        // The border appearing is the whole "you're all set" moment a
        // background utility like this needs. If we just blocked on the
        // permission grant, announce it by flashing the focused window's
        // border — otherwise the user is left staring at System Settings
        // wondering whether anything happened.
        if permissionJustGranted {
            FocusHighlighter.shared.flashBorder()
        }
    }

    // In accessory mode the app has no Dock icon or menu bar; in regular mode
    // it has both (plus the status item). Read once at launch, re-applied live
    // by toggleHideDock.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: Key.hideDock) ? .accessory : .regular)
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Alan")
        }

        let menu = NSMenu()
        menu.delegate = self
        // Titles/enabled state are set in menuNeedsUpdate, so don't let AppKit
        // auto-disable the items we manage by hand.
        menu.autoenablesItems = false

        let pause = NSMenuItem(title: "Pause Alan", action: #selector(togglePause(_:)), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause

        let exclude = NSMenuItem(title: "Exclude Frontmost App", action: #selector(excludeFrontmostApp(_:)), keyEquivalent: "")
        exclude.target = self
        menu.addItem(exclude)
        excludeMenuItem = exclude

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showPrefs(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let hideDock = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleHideDock(_:)), keyEquivalent: "")
        hideDock.target = self
        menu.addItem(hideDock)
        hideDockMenuItem = hideDock

        let about = NSMenuItem(title: "About Alan", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Alan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseMenuItem?.title = UserDefaults.standard.bool(forKey: Key.paused) ? "Resume Alan" : "Pause Alan"

        // The frontmost app is the one the user was in before clicking the
        // status item (opening a status menu doesn't change frontmost).
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let bundleID = app.bundleIdentifier {
            let name = app.localizedName ?? bundleID
            let excluded = UserDefaults.standard.stringArray(forKey: Key.excludedApps) ?? []
            excludeMenuItem?.title = "Exclude “\(name)”"
            excludeMenuItem?.isEnabled = !excluded.contains(bundleID)
            excludeMenuItem?.representedObject = bundleID
        } else {
            excludeMenuItem?.title = "Exclude Frontmost App"
            excludeMenuItem?.isEnabled = false
            excludeMenuItem?.representedObject = nil
        }

        hideDockMenuItem?.state = UserDefaults.standard.bool(forKey: Key.hideDock) ? .on : .off
    }

    @objc private func togglePause(_ sender: Any?) {
        let paused = UserDefaults.standard.bool(forKey: Key.paused)
        UserDefaults.standard.set(!paused, forKey: Key.paused)
        // FocusHighlighter observes the defaults change and hides/restores.
    }

    @objc private func excludeFrontmostApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var excluded = UserDefaults.standard.stringArray(forKey: Key.excludedApps) ?? []
        guard !excluded.contains(bundleID) else { return }
        excluded.append(bundleID)
        UserDefaults.standard.set(excluded, forKey: Key.excludedApps)
    }

    @objc private func toggleHideDock(_ sender: Any?) {
        let hidden = !UserDefaults.standard.bool(forKey: Key.hideDock)
        UserDefaults.standard.set(hidden, forKey: Key.hideDock)
        applyActivationPolicy()
        // Returning to a Dock icon (.regular) needs an explicit activate for
        // the menu bar to take and the app not to drop behind others.
        if !hidden {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // Clicking the Dock icon with no window open should open Settings —
    // otherwise the click appears to do nothing. hasVisibleWindows can't
    // make that call: the border overlay (and the spotlight dim windows)
    // are visible NSWindows nearly all of the time, so the flag reads true
    // even when there is nothing the user could actually interact with.
    // Decide off the Settings window itself instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if prefsWindowController.window?.isVisible != true {
            showPrefs(nil)
        }
        return true
    }

    // Returns true if we had to block on the user granting permission and it
    // was then granted (so the caller can announce the app is live).
    @discardableResult
    func requestAccessibilityPermissionIfNeeded() -> Bool {
        // prompt:false — we present our own guided alert below and open System
        // Settings ourselves, so the system's built-in prompt would just be a
        // second dialog stacked on top. Querying trust still lists Alan under
        // Accessibility, giving the user a checkbox to flip.
        guard !AXIsProcessTrusted() else { return false }

        openAccessibilitySettings()

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Alan needs Accessibility permission to highlight the focused window.

        Enable “Alan” in System Settings → Privacy & Security → Accessibility \
        and Alan will start by itself — no relaunch needed.
        """
        // First button is the default (bound to Return). It must NOT be a
        // destructive action: a new user's reflexive Return should open
        // Settings, not quit the app on its first launch.
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit Alan")

        // Poll while the alert runs (.common covers the modal panel run loop
        // mode) and dismiss it the moment permission is granted. This must be
        // abortModal, not stopModal: Apple's docs are explicit that stopModal
        // from a timer callout only sets a flag the modal loop checks after
        // its next event — and a background app sitting behind System Settings
        // receives none, so the alert would never close on its own.
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if AXIsProcessTrusted() {
                NSApp.abortModal()
            }
        }
        RunLoop.current.add(pollTimer, forMode: .common)
        defer { pollTimer.invalidate() }

        // Keep the alert up until permission is granted (poll fires
        // abortModal) or the user quits. Clicking "Open System Settings" just
        // re-opens the pane and re-presents — it is not a dismissal.
        while !AXIsProcessTrusted() {
            let response = alert.runModal()
            if response == .abort {
                break
            }
            if response == .alertSecondButtonReturn {
                NSApp.terminate(nil)
                return false
            }
            openAccessibilitySettings()
        }

        // The panel doesn't close itself when dismissed via abortModal.
        alert.window.orderOut(nil)
        return true
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @IBAction func showPrefs(_ sender: AnyObject?) {
        // In accessory mode the app is never active, so the window would
        // otherwise appear behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        prefsWindowController.showWindow(nil)
        prefsWindowController.window?.makeKeyAndOrderFront(nil)
    }
}
