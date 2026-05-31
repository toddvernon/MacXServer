import Framer

// RECORD extension dumper. Wire layouts from
// /opt/X11/include/X11/extensions/recordproto.h (which matches the X11R6
// Network Computing Devices spec).
//
// Eight requests, three replies (QueryVersion, GetContext, EnableContext —
// handled generically by the seq-keyed reply path), zero events, one error
// (BadContext). The interesting requests are CreateContext / RegisterClients
// which carry trailing LISTofCLIENTSPEC + LISTofRECORDRANGE; we surface the
// counts inline and leave the per-element walk to a later pass if needed.
//
// No captures in our corpus exercise RECORD (it fires from xmacrorec or
// similar macro-recording tools, not interactive client sessions).
// Decoder is unit-tested only.

public enum RecordDumper: ExtensionDumper {
    public static let extensionName = "RECORD"
    public static let eventCount = 0

    private enum Minor {
        static let queryVersion: UInt8 = 0
        static let createContext: UInt8 = 1
        static let registerClients: UInt8 = 2
        static let unregisterClients: UInt8 = 3
        static let getContext: UInt8 = 4
        static let enableContext: UInt8 = 5
        static let disableContext: UInt8 = 6
        static let freeContext: UInt8 = 7
    }

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 4 else { return nil }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try? r.readUInt8()                  // major
        let minor = (try? r.readUInt8()) ?? 0xFF
        _ = try? r.readUInt16()                 // length

        switch minor {
        case Minor.queryVersion:
            let majorVer = (try? r.readUInt16()) ?? 0
            let minorVer = (try? r.readUInt16()) ?? 0
            return "RecordQueryVersion       requested=\(majorVer).\(minorVer)"

        case Minor.createContext:
            let context = (try? r.readUInt32()) ?? 0
            let elementHeader = (try? r.readUInt8()) ?? 0
            _ = try? r.readUInt8()              // pad
            _ = try? r.readUInt16()             // pad0
            let nClients = (try? r.readUInt32()) ?? 0
            let nRanges = (try? r.readUInt32()) ?? 0
            return "RecordCreateContext      context=\(hex(context)) elementHeader=\(hex8(elementHeader)) clients=\(nClients) ranges=\(nRanges)"

        case Minor.registerClients:
            let context = (try? r.readUInt32()) ?? 0
            let elementHeader = (try? r.readUInt8()) ?? 0
            _ = try? r.readUInt8()              // pad
            _ = try? r.readUInt16()             // pad0
            let nClients = (try? r.readUInt32()) ?? 0
            let nRanges = (try? r.readUInt32()) ?? 0
            return "RecordRegisterClients    context=\(hex(context)) elementHeader=\(hex8(elementHeader)) clients=\(nClients) ranges=\(nRanges)"

        case Minor.unregisterClients:
            let context = (try? r.readUInt32()) ?? 0
            let nClients = (try? r.readUInt32()) ?? 0
            return "RecordUnregisterClients  context=\(hex(context)) clients=\(nClients)"

        case Minor.getContext:
            let context = (try? r.readUInt32()) ?? 0
            return "RecordGetContext         context=\(hex(context))"

        case Minor.enableContext:
            let context = (try? r.readUInt32()) ?? 0
            return "RecordEnableContext      context=\(hex(context))"

        case Minor.disableContext:
            let context = (try? r.readUInt32()) ?? 0
            return "RecordDisableContext     context=\(hex(context))"

        case Minor.freeContext:
            let context = (try? r.readUInt32()) ?? 0
            return "RecordFreeContext        context=\(hex(context))"

        default:
            return nil
        }
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        nil
    }

    // MARK: - Helpers

    private static func hex(_ v: UInt32) -> String { String(format: "0x%X", v) }
    private static func hex8(_ v: UInt8) -> String { String(format: "0x%X", v) }
}
