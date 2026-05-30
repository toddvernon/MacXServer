import Framer

// MIT-SHM extension dumper.
//
// Six requests + one event (ShmCompletion). Replies (QueryVersion,
// GetImage) are handled by ChronoDumper's per-opcode reply lookup
// when it sees a matching sequence number; this file is just for
// per-request and per-event line generation.

public enum ShmDumper: ExtensionDumper {
    public static let extensionName = "MIT-SHM"
    public static let eventCount = 1   // ShmCompletion at offset 0

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {
        case ShmMinor.queryVersion:
            return "ShmQueryVersion"
        case ShmMinor.attach:
            if let r = try? ShmAttach.decode(from: bytes, byteOrder: byteOrder) {
                return "ShmAttach                shmseg=\(hex(r.shmseg)) shmid=\(hex(r.shmid)) readOnly=\(r.readOnly)"
            }
        case ShmMinor.detach:
            if let r = try? ShmDetach.decode(from: bytes, byteOrder: byteOrder) {
                return "ShmDetach                shmseg=\(hex(r.shmseg))"
            }
        case ShmMinor.putImage:
            if let r = try? ShmPutImage.decode(from: bytes, byteOrder: byteOrder) {
                return "ShmPutImage              drawable=\(hex(r.drawable)) gc=\(hex(r.gc)) total=\(r.totalWidth)x\(r.totalHeight) src=(\(r.srcX),\(r.srcY)) \(r.srcWidth)x\(r.srcHeight) → dst=(\(r.dstX),\(r.dstY)) depth=\(r.depth) format=\(r.format) sendEvent=\(r.sendEvent) shmseg=\(hex(r.shmseg)) offset=\(r.offset)"
            }
        case ShmMinor.getImage:
            if let r = try? ShmGetImage.decode(from: bytes, byteOrder: byteOrder) {
                return "ShmGetImage              drawable=\(hex(r.drawable)) at (\(r.x),\(r.y)) \(r.width)x\(r.height) planeMask=\(hex(r.planeMask)) format=\(r.format) shmseg=\(hex(r.shmseg)) offset=\(r.offset)"
            }
        case ShmMinor.createPixmap:
            if let r = try? ShmCreatePixmap.decode(from: bytes, byteOrder: byteOrder) {
                return "ShmCreatePixmap          pid=\(hex(r.pid)) drawable=\(hex(r.drawable)) \(r.width)x\(r.height) depth=\(r.depth) shmseg=\(hex(r.shmseg)) offset=\(r.offset)"
            }
        default:
            break
        }
        return nil
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        let code = bytes[0] & 0x7F
        guard code == firstEvent else { return nil }   // only ShmCompletion
        guard let ev = try? ShmCompletionEvent.decode(from: bytes, byteOrder: byteOrder) else {
            return nil
        }
        return "ShmCompletion            drawable=\(hex(ev.drawable)) majorEvent=\(ev.majorEvent) minorEvent=\(ev.minorEvent) shmseg=\(hex(ev.shmseg)) offset=\(ev.offset)"
    }

    private static func hex(_ v: UInt32) -> String { "0x\(String(v, radix: 16))" }
}
