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
    // How long the fading "ghost" border lingers on the window focus just
    // moved away from — long enough to read the direction, short enough not to
    // clutter.
    static let ghostTrailDuration: TimeInterval = 0.8
    // How long the sonar-ping find animation takes to expand and fade.
    static let findPingDuration: TimeInterval = 0.55
    // How long the "who has focus" chip lingers before fading out.
    static let focusChipDuration: TimeInterval = 0.8
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
    static let useAccentColor = "useAccentColor"
    static let showInScreenshots = "showInScreenshots"
    static let contrastCasing = "contrastCasing"
    static let focusTrail = "focusTrail"
    // Read live when a find gesture fires, not observed: warping the cursor is a
    // one-shot action, so there's nothing to apply on toggle — hence it's absent
    // from allObservedKeys below.
    static let warpCursorOnFind = "warpCursorOnFind"
    // Read live when a find gesture fires (not observed): it changes nothing
    // until the next flash/ping, so it's absent from allObservedKeys below.
    static let findAnimation = "findAnimation"
    static let showFocusChip = "showFocusChip"
    // Sticky flag: set true once Accessibility has ever been granted, so a
    // later launch where trust has vanished can tell a first run from an update
    // that reset the grant. Internal state, not a user setting — not observed.
    static let hadAccessibilityGrant = "hadAccessibilityGrant"

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
        flashOnSpaceChange, paused, borderStyle, useAccentColor, showInScreenshots,
        contrastCasing, focusTrail, showFocusChip
    ]
}

// The border's line style. Raw values are the stored defaults strings.
enum BorderStyle: String, CaseIterable {
    case solid
    case dashed
    case ants        // marching ants — dashes whose phase cycles
    case handDrawn   // an xkcd-style wobble
    case corners     // four L-shaped corner brackets — a viewfinder reticle

    // Menu-facing labels, in the order shown in the popup.
    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .ants: return "Marching ants"
        case .handDrawn: return "Hand-drawn"
        case .corners: return "Corner brackets"
        }
    }

    static var current: BorderStyle {
        BorderStyle(rawValue: UserDefaults.standard.string(forKey: Key.borderStyle) ?? "") ?? .solid
    }
}

// How a "find my window" gesture is shown. The classic border strobe fails at
// exactly the moment it's needed — when the border is hard to see — so an
// expanding sonar ping, which points at the window's *location* independent of
// the border's own color/contrast, is offered as an alternative. Raw values are
// the stored defaults strings.
enum FindAnimation: String, CaseIterable {
    case flash
    case ping

    // Menu-facing labels, in the order shown in the popup.
    var label: String {
        switch self {
        case .flash: return "Flash the border"
        case .ping: return "Sonar ping"
        }
    }

    static var current: FindAnimation {
        FindAnimation(rawValue: UserDefaults.standard.string(forKey: Key.findAnimation) ?? "") ?? .flash
    }
}
