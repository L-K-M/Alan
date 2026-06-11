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

        requestAccessibilityPermissionIfNeeded()

        FocusHighlighter.shared.start()
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
