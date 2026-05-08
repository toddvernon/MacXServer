// User-facing settings for cut/paste behavior. Kept in core so ServerSession
// can read it without depending on AppKit; the SwiftXServer target wires a
// UserDefaults-backed implementation of ClipboardPreferencesProvider.
//
// CopyMode is the only knob the user sees today. Mac mode is the default —
// nothing happens until the user explicitly presses Cmd-C / picks Edit > Copy.
// Xterm mode mirrors X11's select-to-copy idiom: as soon as a client takes
// ownership of the PRIMARY selection (i.e. after a mouse-drag in xterm), we
// pull the text and write it to NSPasteboard automatically.

public enum CopyMode: Sendable, Equatable {
    /// Press Cmd-C (or Edit > Copy) to copy the current X selection to the
    /// Mac clipboard. Default. Matches Mac muscle memory.
    case macStyle

    /// As soon as any X window claims the PRIMARY selection, copy it to the
    /// Mac clipboard. Matches xterm's select-to-copy idiom.
    case xtermStyle
}

public struct ClipboardPreferences: Sendable, Equatable {
    public var enabled: Bool
    public var mode: CopyMode

    public init(enabled: Bool = true, mode: CopyMode = .macStyle) {
        self.enabled = enabled
        self.mode = mode
    }

    public static let `default` = ClipboardPreferences()
}

/// Live source of clipboard preferences. Implementations may back onto
/// UserDefaults or any other store; the session reads `current` whenever it
/// needs the latest value. Conforming types must be safe to read from any
/// thread (the session reads from its read thread; AppKit writes from main).
public protocol ClipboardPreferencesProvider: AnyObject, Sendable {
    var current: ClipboardPreferences { get }
}

/// Default provider used by tests and any path that doesn't wire the real
/// AppKit-backed prefs. Always returns the static defaults.
public final class StaticClipboardPreferencesProvider: ClipboardPreferencesProvider, @unchecked Sendable {
    public let current: ClipboardPreferences
    public init(_ value: ClipboardPreferences = .default) { self.current = value }
}
