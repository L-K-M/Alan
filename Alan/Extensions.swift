//
//  Extensions.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

extension NSColor {
    // A color derived from the app's bundle identifier, stable across
    // launches (String.hashValue is randomized per process, so a classic
    // djb2 hash picks the hue instead). Terminal is always Terminal-colored.
    static func perAppColor(for bundleID: String, darkMode: Bool) -> NSColor {
        var hash: UInt64 = 5381
        for byte in bundleID.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(hue: hue, saturation: 0.68, brightness: darkMode ? 0.9 : 0.6, alpha: 1)
    }
}

extension NSAppearance {
    static var isDarkMode: Bool {
        switch NSApp.effectiveAppearance.name {
        case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
            return true
        default:
            return false
        }
    }

    static var isLightMode: Bool {
        return !isDarkMode
    }
}

extension UserDefaults {
    func setColor(_ color: NSColor, forKey key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) else { return }
        self.set(data, forKey: key)
    }

    func color(forKey key: String) -> NSColor? {
        guard let data = self.data(forKey: key) else { return nil }
        // Reads archives written by the old non-secure API too.
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }
}
