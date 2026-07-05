//
//  AppDelegate.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import Cocoa
import ApplicationServices

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    let prefsWindowController = PrefsWindowController()

    private var statusItem: NSStatusItem?

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
            Key.hideDock: false
        ])

        if UserDefaults.standard.bool(forKey: Key.hideDock) == true {
            NSApp.setActivationPolicy(.accessory)
            // An accessory app has no menu bar or Dock icon, so without this
            // there would be no way to reach Preferences or quit.
            setupStatusItem()
        }

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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Alan")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Preferences…", action: #selector(showPrefs(_:)), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Alan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        statusItem = item
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
