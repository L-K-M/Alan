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
    // Fraction of the pulse spent ramping up to the peak (~4 frames at
    // 60 Hz) before the ease-out takes over; a single-frame attack reads
    // as a flicker.
    static let focusPulseAttackFraction: Double = 0.12
    static let spotlightDimAlpha: Double = 0.45
    // The corner radius of a standard macOS window (~10 pt since Big Sur).
    // There's no public API for it; used to round the spotlight cut-out so
    // it hugs the focused window instead of leaving bright square corners.
    static let windowCornerRadius: CGFloat = 10
    static let partyModeCycleDuration: TimeInterval = 6
    static let moveAnimationDuration: TimeInterval = 0.25
    static let shakeMinSwing: CGFloat = 12
    static let shakeWindow: TimeInterval = 0.7
    static let shakeReversalCount = 4
    static let shakeCooldown: TimeInterval = 1.5
    // Wait for the Space-switch animation to land and focus to settle
    // before flashing, so the flash samples the arriving Space's window.
    static let spaceChangeFlashDelay: TimeInterval = 0.2
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
    static let animateMovement = "animateMovement"
    static let moveAnimationDuration = "moveAnimationDuration"
    static let findMyWindowKeyCode = "findMyWindowKeyCode"
    static let findMyWindowModifiers = "findMyWindowModifiers"
    static let findMyWindowShortcutLabel = "findMyWindowShortcutLabel"
    static let shakeToFind = "shakeToFind"
    static let flashOnSpaceChange = "flashOnSpaceChange"
    static let paused = "paused"
    static let borderStyle = "borderStyle"
    static let contrastCasing = "contrastCasing"

    // Every key the highlighter reacts to. FocusHighlighter installs a KVO
    // observer per key so that external writes — `defaults write` from
    // Terminal, Shortcuts, a dotfiles sync — apply immediately, exactly like
    // a change made in the Preferences window. (hideDock is absent: the
    // activation policy is AppDelegate's business; the shortcut label is
    // UI-only.)
    static let allObservedKeys: [String] = [
        width, inset, cornerRadius, glowingBorder, strongerShadow, lightMode,
        darkMode, showFrameWhileDragging, excludedApps, hideBorderWhenMaximized,
        focusPulse, perAppColors, spotlightMode, findMyWindowHotkey, partyMode,
        spotlightDimLevel, animateMovement, moveAnimationDuration,
        findMyWindowKeyCode, findMyWindowModifiers, shakeToFind,
        flashOnSpaceChange, paused, borderStyle, contrastCasing
    ]
}

// The border's line style. Raw values are the stored defaults strings.
enum BorderStyle: String, CaseIterable {
    case solid
    case dashed
    case ants        // marching ants — dashes whose phase cycles
    case handDrawn   // an xkcd-style wobble

    // Menu-facing labels, in the order shown in the popup.
    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .ants: return "Marching ants"
        case .handDrawn: return "Hand-drawn"
        }
    }

    static var current: BorderStyle {
        BorderStyle(rawValue: UserDefaults.standard.string(forKey: Key.borderStyle) ?? "") ?? .solid
    }
}
