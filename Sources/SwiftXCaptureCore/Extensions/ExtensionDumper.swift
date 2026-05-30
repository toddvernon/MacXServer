import Framer

// Phase 2 (2026-05-30) — extension dumper registry.
//
// X11 extensions get a dynamic major-opcode + event-base + error-base at
// QueryExtension time. ChronoDumper records the per-session mapping
// (major → name, firstEvent → name) as it watches QueryExtension replies
// fly by, then asks this registry to decode any extension request or
// event into a typed line.
//
// Each extension provides one ExtensionDumper struct that knows how to
// format its own requests and events. The dumper falls back to a
// labeled-undecoded line ("MIT-SHM minor=3 (undecoded)" or
// "MIT-SHM Event#1") when the extension is named but its decoder isn't
// in the registry, and to the generic "(untyped)" line when the
// extension itself is unknown.

/// One extension's dumper. Implementations live alongside the extension's
/// wire types in `Framer/Extensions/` (or, for now, in this directory
/// next to the registry). Adding a new extension is one new file + one
/// new entry in `builtins` below.
public protocol ExtensionDumper {
    /// Extension name as advertised in the QueryExtension reply.
    /// Canonical names match `xc/include/extensions/<ext>str.h` -
    /// "SHAPE", "MIT-SHM", "XKEYBOARD", "XInputExtension", "RENDER".
    static var extensionName: String { get }

    /// Number of event codes this extension reserves contiguously from
    /// `firstEvent`. Used by the dumper to figure out which extension
    /// owns a given event code (firstEvent ≤ code < firstEvent + eventCount).
    static var eventCount: Int { get }

    /// Format an extension request given its raw wire bytes (including
    /// the 4-byte header: major + minor + 2-byte length). The minor
    /// opcode is `bytes[1]`. Return nil if the minor opcode isn't
    /// recognized so the caller can emit a labeled-undecoded fallback.
    static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String?

    /// Format an extension event given the raw 32 bytes and the
    /// `firstEvent` base the server advertised for this extension.
    /// `bytes[0] & 0x7F` is the absolute event code; subtract firstEvent
    /// to get this extension's event offset. Return nil if the offset
    /// isn't recognized.
    static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String?
}

/// Static registry of all built-in extension dumpers. New extensions get
/// added to `builtins` and they become callable from ChronoDumper without
/// any other wiring.
public enum ExtensionDumperRegistry {

    private static let builtins: [String: ExtensionDumper.Type] = [
        ShapeDumper.extensionName: ShapeDumper.self,
        BigRequestsDumper.extensionName: BigRequestsDumper.self,
        ShmDumper.extensionName: ShmDumper.self,
        XkbDumper.extensionName: XkbDumper.self,
    ]

    public static func decoder(forName name: String) -> ExtensionDumper.Type? {
        builtins[name]
    }

    public static func eventCount(forName name: String) -> Int {
        builtins[name]?.eventCount ?? 0
    }

    /// All known extension names. Useful for tests + diagnostics.
    public static var allRegisteredNames: [String] {
        Array(builtins.keys).sorted()
    }
}
