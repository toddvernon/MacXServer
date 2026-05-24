// User-facing settings for the optional Motif window-manager frame. Kept in
// core so CocoaWindowBridge can read it without depending on the GUI target;
// the SwiftXServer target wires a UserDefaults-backed implementation of
// MotifFramePreferencesProvider.
//
// Default is off — the server uses native macOS chrome unless the user
// turns this on. Per Todd's note 2026-05-24: pref changes only affect
// newly-mapped windows; already-mapped windows keep whatever chrome they
// started with.

public struct MotifFramePreferences: Sendable, Equatable {
    public var enabled: Bool
    public var buttonStyle: MotifFrameButtonStyle

    public init(enabled: Bool = false, buttonStyle: MotifFrameButtonStyle = .motif) {
        self.enabled = enabled
        self.buttonStyle = buttonStyle
    }

    public static let `default` = MotifFramePreferences()
}

public protocol MotifFramePreferencesProvider: AnyObject, Sendable {
    var current: MotifFramePreferences { get }
}

public final class StaticMotifFramePreferencesProvider: MotifFramePreferencesProvider, @unchecked Sendable {
    public let current: MotifFramePreferences
    public init(_ value: MotifFramePreferences = .default) { self.current = value }
}
