import Framer

// XTEST extension dumper. Wire layouts from
// reference/xproto/include/X11/extensions/xtestproto.h.
//
// Four requests, two replies (handled generically by the seq-keyed reply
// path), no events, no errors. The interesting one is FakeInput: 36 bytes
// total carrying a synthesized core-event type + detail + time + root
// window + rootX/Y + deviceId. The server treats it as if the synthesized
// input event had arrived from real hardware.
//
// No captures in our corpus exercise XTEST (it fires from input-injection
// test harnesses, not interactive sessions). Decoder is unit-tested only.

public enum XTestDumper: ExtensionDumper {
    public static let extensionName = "XTEST"
    public static let eventCount = 0

    private enum Minor {
        static let getVersion: UInt8 = 0
        static let compareCursor: UInt8 = 1
        static let fakeInput: UInt8 = 2
        static let grabControl: UInt8 = 3
    }

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 4 else { return nil }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try? r.readUInt8()                  // major
        let minor = (try? r.readUInt8()) ?? 0xFF
        _ = try? r.readUInt16()                 // length

        switch minor {
        case Minor.getVersion:
            let majorVer = (try? r.readUInt8()) ?? 0
            _ = try? r.readUInt8()              // pad
            let minorVer = (try? r.readUInt16()) ?? 0
            return "XTestGetVersion          requested=\(majorVer).\(minorVer)"

        case Minor.compareCursor:
            let window = (try? r.readUInt32()) ?? 0
            let cursor = (try? r.readUInt32()) ?? 0
            return "XTestCompareCursor       window=\(hex(window)) cursor=\(cursor == 0 ? "None" : hex(cursor))"

        case Minor.fakeInput:
            let evType = (try? r.readUInt8()) ?? 0
            let detail = (try? r.readUInt8()) ?? 0
            _ = try? r.readUInt16()             // pad
            let time = (try? r.readUInt32()) ?? 0
            let root = (try? r.readUInt32()) ?? 0
            _ = try? r.readUInt32()             // pad1
            _ = try? r.readUInt32()             // pad2
            let rootX = Int16(bitPattern: (try? r.readUInt16()) ?? 0)
            let rootY = Int16(bitPattern: (try? r.readUInt16()) ?? 0)
            _ = try? r.readUInt32()             // pad3
            _ = try? r.readUInt16()             // pad4
            _ = try? r.readUInt8()              // pad5
            let deviceId = (try? r.readUInt8()) ?? 0
            let timeStr = time == 0 ? "CurrentTime" : "\(time)"
            let rootStr = root == 0 ? "None" : hex(root)
            return "XTestFakeInput           \(fakeEventName(evType)) detail=\(fakeDetailDescription(evType, detail)) time=\(timeStr) root=\(rootStr) at (\(rootX),\(rootY)) device=\(deviceId)"

        case Minor.grabControl:
            let impervious = (try? r.readUInt8()) ?? 0
            return "XTestGrabControl         impervious=\(impervious != 0)"

        default:
            return nil
        }
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        nil
    }

    // MARK: - Helpers

    private static func hex(_ v: UInt32) -> String { String(format: "0x%X", v) }

    /// FakeInput's `type` field reuses the core-event codes: KeyPress(2),
    /// KeyRelease(3), ButtonPress(4), ButtonRelease(5), MotionNotify(6).
    /// Other values would be a wire-level bug; render as raw integer.
    private static func fakeEventName(_ t: UInt8) -> String {
        switch t {
        case 2: return "KeyPress"
        case 3: return "KeyRelease"
        case 4: return "ButtonPress"
        case 5: return "ButtonRelease"
        case 6: return "MotionNotify"
        default: return "type=\(t)"
        }
    }

    /// For Key{Press,Release} the `detail` field is the keycode; for
    /// Button{Press,Release} it's the button number; for MotionNotify
    /// it's a 0/1 boolean (absolute vs relative). Label per type.
    private static func fakeDetailDescription(_ t: UInt8, _ d: UInt8) -> String {
        switch t {
        case 2, 3: return "keycode=\(d)"
        case 4, 5: return "button=\(d)"
        case 6:    return d == 0 ? "absolute" : "relative"
        default:   return "\(d)"
        }
    }
}
