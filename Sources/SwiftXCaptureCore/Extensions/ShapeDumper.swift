import Framer

// SHAPE extension dumper. Migrated 2026-05-30 from inline formatters in
// ChronoDumper.swift so SHAPE plugs in via the generic
// ExtensionDumperRegistry like any other extension.

public enum ShapeDumper: ExtensionDumper {
    public static let extensionName = "SHAPE"
    public static let eventCount = 1   // ShapeNotify (offset 0)

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {
        case ShapeMinor.queryVersion:
            return "ShapeQueryVersion"
        case ShapeMinor.rectangles:
            if let r = try? ShapeRectangles.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeRectangles          dest=\(hex(r.dest)) \(kindName(r.destKind)) \(opName(r.op)) off=(\(r.xOff),\(r.yOff)) rects=\(r.rectangles.count)"
            }
        case ShapeMinor.mask:
            if let r = try? ShapeMask.decode(from: bytes, byteOrder: byteOrder) {
                let src = r.src == 0 ? "None" : hex(r.src)
                return "ShapeMask                dest=\(hex(r.dest)) \(kindName(r.destKind)) \(opName(r.op)) off=(\(r.xOff),\(r.yOff)) src=\(src)"
            }
        case ShapeMinor.combine:
            if let r = try? ShapeCombine.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeCombine             dest=\(hex(r.dest)) \(kindName(r.destKind)) \(opName(r.op)) off=(\(r.xOff),\(r.yOff)) src=\(hex(r.src)) \(kindName(r.srcKind))"
            }
        case ShapeMinor.offset:
            if let r = try? ShapeOffset.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeOffset              dest=\(hex(r.dest)) \(kindName(r.destKind)) off=(\(r.xOff),\(r.yOff))"
            }
        case ShapeMinor.queryExtents:
            if let r = try? ShapeQueryExtents.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeQueryExtents        window=\(hex(r.window))"
            }
        case ShapeMinor.selectInput:
            if let r = try? ShapeSelectInput.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeSelectInput         window=\(hex(r.window)) enable=\(r.enable)"
            }
        case ShapeMinor.inputSelected:
            if let r = try? ShapeInputSelected.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeInputSelected       window=\(hex(r.window))"
            }
        case ShapeMinor.getRectangles:
            if let r = try? ShapeGetRectangles.decode(from: bytes, byteOrder: byteOrder) {
                return "ShapeGetRectangles       window=\(hex(r.window)) \(kindName(r.kind))"
            }
        default:
            break
        }
        return nil
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        let code = bytes[0] & 0x7F
        guard code == firstEvent else { return nil }   // only ShapeNotify
        guard let ev = try? ShapeNotifyEvent.decode(from: bytes, byteOrder: byteOrder) else {
            return nil
        }
        return "ShapeNotify              window=\(hex(ev.window)) \(kindName(ev.kind)) at (\(ev.x),\(ev.y)) \(ev.width)x\(ev.height) shaped=\(ev.shaped)"
    }

    // MARK: - Helpers

    private static func hex(_ v: UInt32) -> String { "0x\(String(v, radix: 16))" }
    private static func kindName(_ k: UInt8) -> String {
        switch k { case 0: return "Bounding"; case 1: return "Clip"; default: return "kind=\(k)" }
    }
    private static func opName(_ o: UInt8) -> String {
        switch o {
        case 0: return "Set"; case 1: return "Union"; case 2: return "Intersect"
        case 3: return "Subtract"; case 4: return "Invert"; default: return "op=\(o)"
        }
    }
}
