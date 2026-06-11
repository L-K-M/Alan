//
//  Constants.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import Cocoa

struct Defaults {
    static let lightModeColor = NSColor.black
    static let darkModeColor = NSColor.white
    static let frameDrawingDisableTimeout: TimeInterval = 0.25
    static let screenFillTolerance: CGFloat = 5
    static let focusPulseDuration: TimeInterval = 0.5
    static let focusPulsePeak: CGFloat = 2.5
    static let spotlightDimAlpha: Double = 0.45
    static let partyModeCycleDuration: TimeInterval = 6
    static let spotlightAnimationDuration: TimeInterval = 0.15
    static let shakeMinSwing: CGFloat = 12
    static let shakeWindow: TimeInterval = 0.7
    static let shakeReversalCount = 4
    static let shakeCooldown: TimeInterval = 1.5
    // kVK_ANSI_F with controlKey | optionKey | cmdKey — spelled as numbers
    // so Constants doesn't need Carbon.
    static let findMyWindowDefaultKeyCode = 0x03
    static let findMyWindowDefaultModifiers = 0x1000 | 0x0800 | 0x0100
    static let findMyWindowDefaultLabel = "⌃⌥⌘F"
}

struct Key {
    static let width = "width"
    static let inset = "inset"
    static let cornerRadius = "cornerRadius"
    static let glowingBorder = "glowingBorder"
    static let strongerShadow = "strongerShadow"
    static let hideDock = "hideDock"
    static let lightMode = "lightMode"
    static let darkMode = "darkMode"
    static let showFrameWhileDragging = "showFrameWhileDragging"
    static let excludedApps = "excludedApps"
    static let hideBorderWhenMaximized = "hideBorderWhenMaximized"
    static let focusPulse = "focusPulse"
    static let perAppColors = "perAppColors"
    static let spotlightMode = "spotlightMode"
    static let findMyWindowHotkey = "findMyWindowHotkey"
    static let partyMode = "partyMode"
    static let spotlightDimLevel = "spotlightDimLevel"
    static let findMyWindowKeyCode = "findMyWindowKeyCode"
    static let findMyWindowModifiers = "findMyWindowModifiers"
    static let findMyWindowShortcutLabel = "findMyWindowShortcutLabel"
    static let shakeToFind = "shakeToFind"
}
