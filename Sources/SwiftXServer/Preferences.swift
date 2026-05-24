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
        static let captureSessions  = "capture.sessions"      // bool
        static let captureDirectory = "capture.directory"     // string
    }

    /// Where server-side captures land when capture is enabled. /tmp is
    /// the deliberate choice — it wipes on reboot so captures never
    /// accumulate invisibly, and it's a short path the user can type.
    /// See DECISIONS.md 2026-05-23 for the alternatives.
    static let defaultCaptureDirectory = "/tmp/swift-x-captures"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Register defaults on first launch so .object(forKey:) returns the
        // configured default instead of nil.
        defaults.register(defaults: [
            Key.clipboardEnabled: true,
            Key.clipboardMode: "mac",
            Key.captureSessions: false,
            Key.captureDirectory: Self.defaultCaptureDirectory,
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

    /// When true, every accepted X client gets its own `.xtap` file in
    /// `captureDirectory`. CLI `--capture` / `--no-capture` overrides
    /// this at server startup; the resolved value is fixed for the
    /// lifetime of that server process.
    var captureSessions: Bool {
        get { defaults.bool(forKey: Key.captureSessions) }
        set {
            defaults.set(newValue, forKey: Key.captureSessions)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Capture output directory. Default `/tmp/swift-x-captures`. Not
    /// surfaced in the Preferences UI today (the path is part of the
    /// "your captures live in /tmp" contract); kept as a UserDefaults
    /// key so power users can override via `defaults write`.
    var captureDirectory: String {
        get { defaults.string(forKey: Key.captureDirectory) ?? Self.defaultCaptureDirectory }
        set {
            defaults.set(newValue, forKey: Key.captureDirectory)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    // MARK: - ClipboardPreferencesProvider

    var current: ClipboardPreferences {
        ClipboardPreferences(enabled: clipboardEnabled, mode: copyMode)
    }
}
