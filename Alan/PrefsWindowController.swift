//
//  PrefsWindowController.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

class PrefsWindowController: NSWindowController {
    
    @IBOutlet weak var lightModeColorWell: NSColorWell!
    @IBOutlet weak var darkModeColorWell: NSColorWell!
    @IBOutlet weak var showFrameWhileDraggingCheckbox: NSButton!
    @IBOutlet weak var glowingBorderCheckbox: NSButton!
    @IBOutlet weak var strongerShadowCheckbox: NSButton!

    override func windowDidLoad() {
        super.windowDidLoad()

        lightModeColorWell.color = UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        darkModeColorWell.color = UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor

        let showFrameWhileDragging = UserDefaults.standard.object(forKey: Key.showFrameWhileDragging) as? Bool ?? true
        showFrameWhileDraggingCheckbox.state = showFrameWhileDragging ? .on : .off

        let glowingBorder = UserDefaults.standard.bool(forKey: Key.glowingBorder)
        glowingBorderCheckbox.state = glowingBorder ? .on : .off

        let strongerShadow = UserDefaults.standard.bool(forKey: Key.strongerShadow)
        strongerShadowCheckbox.state = strongerShadow ? .on : .off

        NotificationCenter.default.addObserver(self, selector: #selector(PrefsWindowController.userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @IBAction func lightModeChanged(_ sender: NSColorWell) {
        UserDefaults.standard.setColor(sender.color, forKey: Key.lightMode)
    }
    
    @IBAction func darkModeChanged(_ sender: NSColorWell) {
        UserDefaults.standard.setColor(sender.color, forKey: Key.darkMode)
    }

    @IBAction func showFrameWhileDraggingChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.showFrameWhileDragging)
    }

    @IBAction func glowingBorderChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.glowingBorder)
    }

    @IBAction func strongerShadowChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.strongerShadow)
    }

    @objc func userDefaultsChanged() {
        FocusHighlighter.shared.forceUpdate()
    }
}
