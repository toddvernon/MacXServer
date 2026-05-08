import Foundation
import SwiftXServerCore

// UserDefaults-backed preferences. Implements ClipboardPreferencesProvider
// so ServerSession can read live values without dragging AppKit into core.
//
// Reads happen on the read thread (every copy roundtrip); writes happen on
// main from the prefs window. UserDefaults is documented as thread-safe for
// these usages, so no extra locking.

final class Preferences: ClipboardPreferencesProvider, @unchecked Sendable {

    // Notification fired after any setter writes. The prefs window observes
    // it to keep on-screen controls in sync if the model changes from
    // somewhere else (no other writers today, but cheap insurance).
    static let didChange = Notification.Name("SwiftXPreferencesDidChange")

    private enum Key {
        static let clipboardEnabled = "clipboard.enabled"
        static let clipboardMode    = "clipboard.mode"        // "mac" | "xterm"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Register defaults on first launch so .object(forKey:) returns the
        // configured default (Mac-style on) instead of nil.
        defaults.register(defaults: [
            Key.clipboardEnabled: true,
            Key.clipboardMode: "mac",
        ])
    }

    var clipboardEnabled: Bool {
        get { defaults.bool(forKey: Key.clipboardEnabled) }
        set {
            defaults.set(newValue, forKey: Key.clipboardEnabled)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var copyMode: CopyMode {
        get {
            switch defaults.string(forKey: Key.clipboardMode) {
            case "xterm": return .xtermStyle
            default:      return .macStyle
            }
        }
        set {
            let raw: String = (newValue == .xtermStyle) ? "xterm" : "mac"
            defaults.set(raw, forKey: Key.clipboardMode)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    // MARK: - ClipboardPreferencesProvider

    var current: ClipboardPreferences {
        ClipboardPreferences(enabled: clipboardEnabled, mode: copyMode)
    }
}
