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
        static let motifFrameEnabled     = "motifFrame.enabled"     // bool
        static let motifFrameButtonStyle = "motifFrame.buttonStyle" // "motif" | "trafficLights"
        static let displayScale          = "display.scale"          // "auto" | "comfortable" | "compact"
        // Mouse-button mapping. Values are the X wire-button number (1, 2,
        // or 3) each Mac physical button emits. Defaults are identity for
        // a standard 3-button mouse.
        static let pointerLeftClick      = "pointer.leftClick"      // int
        static let pointerWheelClick     = "pointer.wheelClick"     // int
        static let pointerRightClick     = "pointer.rightClick"     // int
        static let xtermScrollbarThumbOverride = "xterm.scrollbarThumbOverride" // bool
        static let sparcDiskImagePath = "sparcplug.diskImagePath"   // string; LEGACY, migration-read only
    }

    /// Where server-side captures land when capture is enabled. /tmp is
    /// the deliberate choice — it wipes on reboot so captures never
    /// accumulate invisibly, and it's a short path the user can type.
    /// See DECISIONS.md 2026-05-23 for the alternatives.
    static let defaultCaptureDirectory = "/tmp/macxcapture"

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
            Key.motifFrameEnabled: false,
            Key.motifFrameButtonStyle: "motif",
            Key.displayScale: "auto",
            Key.pointerLeftClick: 1,
            Key.pointerWheelClick: 1,
            Key.pointerRightClick: 3,
            Key.xtermScrollbarThumbOverride: true,
            Key.sparcDiskImagePath: "",
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

    /// Capture output directory. Default `/tmp/macxcapture`. Not
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

    /// Whether new top-level X windows should be wrapped in the optional
    /// Motif-style window-manager frame (drawn by us) instead of using
    /// native macOS chrome. Changes only affect windows mapped after the
    /// toggle; already-on-screen windows keep whatever chrome they had.
    var motifFrameEnabled: Bool {
        get { defaults.bool(forKey: Key.motifFrameEnabled) }
        set {
            defaults.set(newValue, forKey: Key.motifFrameEnabled)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Display size at server startup. `.auto` defers to the picker
    /// (which prefers 3x today). `.comfortable` forces 3x; `.compact`
    /// forces 2x. CLI `--scale {2,3}` overrides this for one process.
    /// Read once at startup; change takes effect on next launch.
    var displayScale: DisplayScalePreference {
        get {
            switch defaults.string(forKey: Key.displayScale) {
            case "comfortable": return .comfortable
            case "compact":     return .compact
            default:            return .auto
            }
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.displayScale)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// When the Motif frame is on, controls whether the three title-bar
    /// buttons render as Motif raised glyphs or as Mac-style colored dots.
    var motifFrameButtonStyle: MotifFrameButtonStyle {
        get {
            switch defaults.string(forKey: Key.motifFrameButtonStyle) {
            case "trafficLights": return .trafficLights
            default:              return .motif
            }
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.motifFrameButtonStyle)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    // MARK: - Mouse button mapping

    /// X wire-button number to emit when the user clicks the Mac primary
    /// (left) button. Clamped to 1...3 on read.
    var pointerLeftClick: UInt8 {
        get { Self.clampedButton(defaults.integer(forKey: Key.pointerLeftClick), fallback: 1) }
        set {
            defaults.set(Int(newValue), forKey: Key.pointerLeftClick)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// X wire-button number for the Mac wheel/middle button.
    var pointerWheelClick: UInt8 {
        get { Self.clampedButton(defaults.integer(forKey: Key.pointerWheelClick), fallback: 1) }
        set {
            defaults.set(Int(newValue), forKey: Key.pointerWheelClick)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// X wire-button number for the Mac secondary (right) button.
    var pointerRightClick: UInt8 {
        get { Self.clampedButton(defaults.integer(forKey: Key.pointerRightClick), fallback: 3) }
        set {
            defaults.set(Int(newValue), forKey: Key.pointerRightClick)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Server-side xterm hack: when on, every click on an xterm scrollbar
    /// widget is force-rewritten to wire button 2 (grab thumb) regardless
    /// of which Mac button the user pressed. Doesn't affect xterm content
    /// area or non-xterm clients. The mechanism is "macXserver knows what
    /// it's hosting" — the first of a planned line of server-side
    /// app-specific extensions.
    var xtermScrollbarThumbOverride: Bool {
        get { defaults.bool(forKey: Key.xtermScrollbarThumbOverride) }
        set {
            defaults.set(newValue, forKey: Key.xtermScrollbarThumbOverride)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// LEGACY (read-only since P2): the pre-machine-registry disk-image path.
    /// Machines carry their own `imagePath` in `~/.macxserver-machines.json`
    /// now; this key is only consulted by the one-shot launcher-file migration
    /// (`MachineRegistry.load`) so an existing install's image lands on the
    /// migrated machine. Nothing writes it anymore. (The old per-machine
    /// auto-backup toggle also moved onto the machine: `Machine.autoBackup`,
    /// edited in the Machines window's Settings tab. The old "Claude
    /// development" /tmp/sparkplug secret file is retired outright -- the image
    /// lock next to the qcow2 carries the running guest's secret, and the MCP
    /// bridge is the coming hand-off to Claude.)
    var sparcDiskImagePath: String {
        defaults.string(forKey: Key.sparcDiskImagePath) ?? ""
    }

    /// Build a `PointerConfig` snapshot of the current values and install
    /// it as the live mapping. Call at startup AND from `didChange`
    /// observers in the Preferences UI so a settings change takes effect
    /// on the very next click.
    func applyPointerConfig() {
        PointerConfig.install(PointerConfig(
            leftClickWireButton: pointerLeftClick,
            wheelClickWireButton: pointerWheelClick,
            rightClickWireButton: pointerRightClick,
            xtermScrollbarThumbOverride: xtermScrollbarThumbOverride,
            // The xterm right-click Copy/Paste menu is a consequence of the
            // right-click role being "Menu" (button 3): on xterm we pop the
            // native menu; non-xterm clients still get button 3 for their own.
            // Derived, not a separate setting, so the two can't drift.
            xtermRightClickMenu: pointerRightClick == 3,
            // The xterm scrollbar's Motif skin follows the Motif window frame:
            // if you're running the Motif look, the scrollbar matches. Derived,
            // so there's no separate toggle to drift from the frame setting.
            xtermScrollbarMotifSkin: motifFrameEnabled
        ))
    }

    private static func clampedButton(_ raw: Int, fallback: UInt8) -> UInt8 {
        switch raw {
        case 1, 2, 3: return UInt8(raw)
        default: return fallback
        }
    }

    /// One-time migration: if the user's `~/.macxserver-resources` still
    /// has a `[pointer]` section (from the 2026-06-14 first cut), read
    /// any `swapButtons23` value, translate it into the new three
    /// UserDefaults keys, and strip the section out of the file so the
    /// dialog is the sole UX going forward. Idempotent.
    static func migratePointerResourceSection(defaults: UserDefaults = .standard) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".macxserver-resources")
        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard original.range(of: "\n[pointer]\n") != nil
                || original.hasPrefix("[pointer]\n") else { return }

        // Parse just enough to read swapButtons23.
        var swap = false
        var inPointer = false
        for raw in original.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line == "[pointer]" { inPointer = true; continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { inPointer = false; continue }
            if !inPointer { continue }
            if line.isEmpty || line.hasPrefix("!") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if k == "swapButtons23" {
                switch v.lowercased() {
                case "true", "yes", "on", "1": swap = true
                default: swap = false
                }
            }
        }

        // Translate to the three new keys. swap=true was: left=1, wheel=3,
        // right=2. swap=false was identity 1/2/3 (= the registered default).
        if swap {
            defaults.set(1, forKey: Key.pointerLeftClick)
            defaults.set(3, forKey: Key.pointerWheelClick)
            defaults.set(2, forKey: Key.pointerRightClick)
        }

        // Strip the [pointer] block from the file. Find the section header
        // and the next blank-or-bracket-header line that ends the block,
        // and excise that range (including the trailing newline).
        let stripped = Self.stripPointerSection(original)
        if stripped != original {
            try? stripped.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Excise the `[pointer] ... ` block from the resource-file text.
    /// Handles the section starting at line 1 or anywhere later. Whitespace-
    /// only lines that immediately precede / follow the block are
    /// collapsed so the surrounding file doesn't accumulate blank gaps
    /// from successive migrations.
    private static func stripPointerSection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[pointer]" {
                skipping = true
                // Drop trailing whitespace already in `out`.
                while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.removeLast()
                }
                continue
            }
            if skipping {
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    skipping = false
                    // fall through to append this header line
                } else {
                    continue
                }
            }
            out.append(line)
        }
        // Trim trailing empty lines.
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeLast()
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - ClipboardPreferencesProvider

    var current: ClipboardPreferences {
        ClipboardPreferences(enabled: clipboardEnabled, mode: copyMode)
    }

    // MARK: - MotifFramePreferencesProvider

    /// MotifFramePreferencesProvider expects a `current` of its own type;
    /// our top-level `current` already returns ClipboardPreferences, so we
    /// vend a thin adapter that reads through to the live keys here.
    var motifFrameProvider: MotifFramePreferencesProvider { MotifFrameProviderAdapter(prefs: self) }
}

/// User-facing scale choice. `.auto` lets `DisplayConfig.pick` decide
/// (today the picker prefers 3x). `.comfortable` and `.compact` force a
/// scale on every display; if the chosen scale doesn't fit, the picker
/// falls back per its usual rules. SCALE_PICKER.md is the design doc.
enum DisplayScalePreference: String, CaseIterable {
    case auto
    case comfortable
    case compact

    /// Scale to pass to `DisplayConfig.forMainDisplay(forcedScale:)`.
    /// `nil` means "no override — let the picker choose."
    var forcedScale: Double? {
        switch self {
        case .auto:        return nil
        case .comfortable: return 3
        case .compact:     return 2
        }
    }
}

/// Forwards the protocol's `current` requirement to live reads of the
/// matching Preferences keys, so every call sees the latest value without
/// snapshotting at adapter-creation time.
private final class MotifFrameProviderAdapter: MotifFramePreferencesProvider, @unchecked Sendable {
    private let prefs: Preferences
    init(prefs: Preferences) { self.prefs = prefs }
    var current: MotifFramePreferences {
        MotifFramePreferences(
            enabled: prefs.motifFrameEnabled,
            buttonStyle: prefs.motifFrameButtonStyle
        )
    }
}

/// Pins `enabled` to a CLI-passed value while still reading `buttonStyle`
/// from live Preferences. Used by `--motif-frame` / `--no-motif-frame` so
/// two macxserver processes can be running side-by-side with different
/// chrome (UserDefaults is shared across processes by bundle ID).
final class MotifFrameCLIOverrideProvider: MotifFramePreferencesProvider, @unchecked Sendable {
    private let underlying: MotifFramePreferencesProvider
    private let enabledOverride: Bool
    init(underlying: MotifFramePreferencesProvider, enabledOverride: Bool) {
        self.underlying = underlying
        self.enabledOverride = enabledOverride
    }
    var current: MotifFramePreferences {
        let base = underlying.current
        return MotifFramePreferences(enabled: enabledOverride, buttonStyle: base.buttonStyle)
    }
}
