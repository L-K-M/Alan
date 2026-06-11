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

    let prefsWindowController: PrefsWindowController = {
        return PrefsWindowController(windowNibName: String(describing: PrefsWindowController.self))
    }()

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Colors aren't registered here: NSColor isn't a property-list type,
        // so they are defaulted at the read sites instead.
        UserDefaults.standard.register(defaults: [
            Key.width: 5,
            Key.inset: 4,
            Key.cornerRadius: 0,
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

            // Give the user a clear message and quit so they can enable it
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
            Alan needs Accessibility permission to highlight the focused window.

            Please open System Settings → Privacy & Security → Accessibility
            and enable “Alan”.

            Then relaunch Alan.
            """
            alert.addButton(withTitle: "Quit")
            alert.runModal()

            NSApp.terminate(nil)
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
