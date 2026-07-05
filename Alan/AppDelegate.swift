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
            Key.paused: false
        ])

        applyActivationPolicy()

        // The status item now exists in every mode, not just hidden-Dock —
        // it's the home for Pause, "Exclude this app", and Settings, and the
        // only way to reach them when the Dock icon is hidden.
        setupStatusItem()

        requestAccessibilityPermissionIfNeeded()

        FocusHighlighter.shared.start()
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

    // Clicking the Dock icon with no window open should open Preferences —
    // otherwise the click appears to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPrefs(nil)
        }
        return true
    }

    func requestAccessibilityPermissionIfNeeded() {
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        let trusted = AXIsProcessTrustedWithOptions(options)

        guard trusted else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }

            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
            Alan needs Accessibility permission to highlight the focused window.

            Enable “Alan” in System Settings → Privacy & Security → Accessibility
            and Alan will start by itself — no relaunch needed.
            """
            alert.addButton(withTitle: "Quit")

            // Poll while the alert runs (.common covers the modal panel run
            // loop mode) and dismiss it the moment permission is granted, so
            // the app springs to life without a relaunch.
            let pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if AXIsProcessTrusted() {
                    NSApp.stopModal()
                }
            }
            RunLoop.current.add(pollTimer, forMode: .common)

            let response = alert.runModal()
            pollTimer.invalidate()

            if response == .alertFirstButtonReturn {
                // The user chose Quit instead of granting permission.
                NSApp.terminate(nil)
            }

            // Dismissed via stopModal: permission was just granted. The
            // panel doesn't close itself in that case.
            alert.window.orderOut(nil)
            return
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
