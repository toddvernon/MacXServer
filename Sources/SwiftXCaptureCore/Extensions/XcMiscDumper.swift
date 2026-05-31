import Framer

// XC-MISC extension dumper. Wire layouts from
// reference/X11R6/xc/include/extensions/xcmiscstr.h.
//
// Three requests, three replies (handled generically by the seq-keyed
// reply path), no events, no errors.
//
// XC-MISC fires when a client exhausts its resource-id pool (long-running
// session, lots of windows + pixmaps + GCs churned). None of the short
// vintage captures in our corpus exercise it; the decoder is still worth
// having for completeness and for the captures users will produce.

public enum XcMiscDumper: ExtensionDumper {
    public static let extensionName = "XC-MISC"
    public static let eventCount = 0

    private enum Minor {
        static let getVersion: UInt8 = 0
        static let getXIDRange: UInt8 = 1
        static let getXIDList: UInt8 = 2
    }

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 4 else { return nil }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try? r.readUInt8()                  // major (the extension's opcode)
        let minor = (try? r.readUInt8()) ?? 0xFF
        _ = try? r.readUInt16()                 // length

        switch minor {
        case Minor.getVersion:
            let major = (try? r.readUInt16()) ?? 0
            let minorVer = (try? r.readUInt16()) ?? 0
            return "XCMiscGetVersion         requested=\(major).\(minorVer)"
        case Minor.getXIDRange:
            return "XCMiscGetXIDRange"
        case Minor.getXIDList:
            let count = (try? r.readUInt32()) ?? 0
            return "XCMiscGetXIDList         count=\(count)"
        default:
            return nil
        }
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        nil
    }
}
