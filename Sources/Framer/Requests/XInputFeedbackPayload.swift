// XInput v1 Feedback payload — six variants × two directions.
//
// Phase 3 XInput Session 2 (2026-05-30). Used by:
//   - XInputGetFeedbackControlReply trailer (XInputFeedbackState records)
//   - XInputChangeFeedbackControl request body (XInputFeedbackCtl record)
//
// All variants share a 4-byte header `class(1) + id(1) + length(2)`.
// `length` tells the parser how many bytes the whole record (including
// the header) takes — making forward-skip safe for unknown variants.
//
// Wire layouts from
// reference/X11R6/xc/include/extensions/XIproto.h.

public enum XInputFeedbackClass {
    public static let kbd: UInt8 = 0
    public static let ptr: UInt8 = 1
    public static let string: UInt8 = 2
    public static let integer: UInt8 = 3
    public static let led: UInt8 = 4
    public static let bell: UInt8 = 5
}

// MARK: - FeedbackState variants (read direction)

public struct XInputKbdFeedbackState: Equatable, Sendable {
    public var id: UInt8
    public var pitch: UInt16
    public var duration: UInt16
    public var ledMask: UInt32
    public var ledValues: UInt32
    public var globalAutoRepeat: Bool
    public var click: UInt8
    public var percent: UInt8
    public var autoRepeats: [UInt8]   // 32 bytes
}

public struct XInputPtrFeedbackState: Equatable, Sendable {
    public var id: UInt8
    public var accelNum: UInt16
    public var accelDenom: UInt16
    public var threshold: UInt16
}

public struct XInputStringFeedbackState: Equatable, Sendable {
    public var id: UInt8
    public var maxSymbols: UInt16
    public var numSymsSupported: UInt16
    public var keysyms: [UInt32]
}

public struct XInputIntegerFeedbackState: Equatable, Sendable {
    public var id: UInt8
    public var resolution: UInt32
    public var minValue: Int32
    public var maxValue: Int32
}

public struct XInputLedFeedbackState: Equatable, Sendable {
    public var id: UInt8
    public var ledMask: UInt32
    public var ledValues: UInt32
}

public struct XInputBellFeedbackState: Equatable, Sendable {
    public var id: UInt8
    public var percent: UInt8
    public var pitch: UInt16
    public var duration: UInt16
}

public enum XInputFeedbackState: Equatable, Sendable {
    case kbd(XInputKbdFeedbackState)
    case ptr(XInputPtrFeedbackState)
    case string(XInputStringFeedbackState)
    case integer(XInputIntegerFeedbackState)
    case led(XInputLedFeedbackState)
    case bell(XInputBellFeedbackState)
    case unknown(class: UInt8, id: UInt8, body: [UInt8])

    /// Decode `num_feedbacks` records from the bytes. Each record's
    /// `length` field bounds it; unknown classes are captured raw so
    /// the parser doesn't get stuck.
    public static func decodeList(from bytes: [UInt8], count: Int, byteOrder: ByteOrder) throws -> [XInputFeedbackState] {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        var out: [XInputFeedbackState] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let cls = try r.readUInt8()
            let id = try r.readUInt8()
            let length = Int(try r.readUInt16())
            // bodyLen = length - 4 (header bytes already consumed)
            let bodyLen = length - 4
            switch cls {
            case XInputFeedbackClass.kbd:
                let pitch = try r.readUInt16()
                let duration = try r.readUInt16()
                let ledMask = try r.readUInt32()
                let ledValues = try r.readUInt32()
                let gar = try r.readUInt8() != 0
                let click = try r.readUInt8()
                let percent = try r.readUInt8()
                try r.skip(1)
                let autoRepeats = try r.readBytes(32)
                let consumed = 2+2+4+4+1+1+1+1+32
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.kbd(XInputKbdFeedbackState(
                    id: id, pitch: pitch, duration: duration,
                    ledMask: ledMask, ledValues: ledValues,
                    globalAutoRepeat: gar, click: click, percent: percent,
                    autoRepeats: autoRepeats
                )))
            case XInputFeedbackClass.ptr:
                try r.skip(2)
                let accelNum = try r.readUInt16()
                let accelDenom = try r.readUInt16()
                let threshold = try r.readUInt16()
                let consumed = 2+2+2+2
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.ptr(XInputPtrFeedbackState(
                    id: id, accelNum: accelNum,
                    accelDenom: accelDenom, threshold: threshold
                )))
            case XInputFeedbackClass.string:
                let maxSyms = try r.readUInt16()
                let numSyms = try r.readUInt16()
                var keysyms: [UInt32] = []
                keysyms.reserveCapacity(Int(numSyms))
                for _ in 0..<Int(numSyms) {
                    keysyms.append(try r.readUInt32())
                }
                let consumed = 2+2 + Int(numSyms) * 4
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.string(XInputStringFeedbackState(
                    id: id, maxSymbols: maxSyms,
                    numSymsSupported: numSyms, keysyms: keysyms
                )))
            case XInputFeedbackClass.integer:
                let resolution = try r.readUInt32()
                let minV = Int32(bitPattern: try r.readUInt32())
                let maxV = Int32(bitPattern: try r.readUInt32())
                let consumed = 4*3
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.integer(XInputIntegerFeedbackState(
                    id: id, resolution: resolution,
                    minValue: minV, maxValue: maxV
                )))
            case XInputFeedbackClass.led:
                let ledMask = try r.readUInt32()
                let ledValues = try r.readUInt32()
                let consumed = 4+4
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.led(XInputLedFeedbackState(
                    id: id, ledMask: ledMask, ledValues: ledValues
                )))
            case XInputFeedbackClass.bell:
                let percent = try r.readUInt8()
                try r.skip(3)
                let pitch = try r.readUInt16()
                let duration = try r.readUInt16()
                let consumed = 1+3+2+2
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.bell(XInputBellFeedbackState(
                    id: id, percent: percent, pitch: pitch, duration: duration
                )))
            default:
                let body = try r.readBytes(bodyLen)
                out.append(.unknown(class: cls, id: id, body: body))
            }
        }
        return out
    }

    /// Encode a list of feedbacks. Output is naturally 4-byte aligned
    /// because every variant's body is a multiple of 4.
    public static func encodeList(_ feedbacks: [XInputFeedbackState], byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        for f in feedbacks {
            switch f {
            case .kbd(let s):
                w.writeUInt8(XInputFeedbackClass.kbd); w.writeUInt8(s.id); w.writeUInt16(52)
                w.writeUInt16(s.pitch); w.writeUInt16(s.duration)
                w.writeUInt32(s.ledMask); w.writeUInt32(s.ledValues)
                w.writeUInt8(s.globalAutoRepeat ? 1 : 0)
                w.writeUInt8(s.click); w.writeUInt8(s.percent); w.writePadding(1)
                w.writeBytes(s.autoRepeats)
            case .ptr(let s):
                w.writeUInt8(XInputFeedbackClass.ptr); w.writeUInt8(s.id); w.writeUInt16(12)
                w.writePadding(2)
                w.writeUInt16(s.accelNum); w.writeUInt16(s.accelDenom); w.writeUInt16(s.threshold)
            case .string(let s):
                let len = 8 + s.keysyms.count * 4
                w.writeUInt8(XInputFeedbackClass.string); w.writeUInt8(s.id)
                w.writeUInt16(UInt16(len))
                w.writeUInt16(s.maxSymbols); w.writeUInt16(s.numSymsSupported)
                for ks in s.keysyms { w.writeUInt32(ks) }
            case .integer(let s):
                w.writeUInt8(XInputFeedbackClass.integer); w.writeUInt8(s.id); w.writeUInt16(16)
                w.writeUInt32(s.resolution)
                w.writeUInt32(UInt32(bitPattern: s.minValue))
                w.writeUInt32(UInt32(bitPattern: s.maxValue))
            case .led(let s):
                w.writeUInt8(XInputFeedbackClass.led); w.writeUInt8(s.id); w.writeUInt16(12)
                w.writeUInt32(s.ledMask); w.writeUInt32(s.ledValues)
            case .bell(let s):
                w.writeUInt8(XInputFeedbackClass.bell); w.writeUInt8(s.id); w.writeUInt16(12)
                w.writeUInt8(s.percent); w.writePadding(3)
                w.writeUInt16(s.pitch); w.writeUInt16(s.duration)
            case .unknown(let cls, let id, let body):
                w.writeUInt8(cls); w.writeUInt8(id); w.writeUInt16(UInt16(4 + body.count))
                w.writeBytes(body)
            }
        }
        return w.bytes
    }
}

// MARK: - FeedbackCtl variants (write direction)

public struct XInputKbdFeedbackCtl: Equatable, Sendable {
    public var id: UInt8
    public var key: UInt8
    public var autoRepeatMode: UInt8
    public var click: Int8
    public var percent: Int8
    public var pitch: Int16
    public var duration: Int16
    public var ledMask: UInt32
    public var ledValues: UInt32
}

public struct XInputPtrFeedbackCtl: Equatable, Sendable {
    public var id: UInt8
    public var num: Int16
    public var denom: Int16
    public var thresh: Int16
}

public struct XInputIntegerFeedbackCtl: Equatable, Sendable {
    public var id: UInt8
    public var intToDisplay: Int32
}

public struct XInputStringFeedbackCtl: Equatable, Sendable {
    public var id: UInt8
    public var keysyms: [UInt32]
}

public struct XInputBellFeedbackCtl: Equatable, Sendable {
    public var id: UInt8
    public var percent: Int8
    public var pitch: Int16
    public var duration: Int16
}

public struct XInputLedFeedbackCtl: Equatable, Sendable {
    public var id: UInt8
    public var ledMask: UInt32
    public var ledValues: UInt32
}

public enum XInputFeedbackCtl: Equatable, Sendable {
    case kbd(XInputKbdFeedbackCtl)
    case ptr(XInputPtrFeedbackCtl)
    case string(XInputStringFeedbackCtl)
    case integer(XInputIntegerFeedbackCtl)
    case bell(XInputBellFeedbackCtl)
    case led(XInputLedFeedbackCtl)
    case unknown(class: UInt8, id: UInt8, body: [UInt8])

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        switch self {
        case .kbd(let c):
            w.writeUInt8(XInputFeedbackClass.kbd); w.writeUInt8(c.id); w.writeUInt16(20)
            w.writeUInt8(c.key); w.writeUInt8(c.autoRepeatMode)
            w.writeUInt8(UInt8(bitPattern: c.click)); w.writeUInt8(UInt8(bitPattern: c.percent))
            w.writeUInt16(UInt16(bitPattern: c.pitch))
            w.writeUInt16(UInt16(bitPattern: c.duration))
            w.writeUInt32(c.ledMask); w.writeUInt32(c.ledValues)
        case .ptr(let c):
            w.writeUInt8(XInputFeedbackClass.ptr); w.writeUInt8(c.id); w.writeUInt16(12)
            w.writePadding(2)
            w.writeUInt16(UInt16(bitPattern: c.num))
            w.writeUInt16(UInt16(bitPattern: c.denom))
            w.writeUInt16(UInt16(bitPattern: c.thresh))
        case .integer(let c):
            w.writeUInt8(XInputFeedbackClass.integer); w.writeUInt8(c.id); w.writeUInt16(8)
            w.writeUInt32(UInt32(bitPattern: c.intToDisplay))
        case .string(let c):
            let len = 8 + c.keysyms.count * 4
            w.writeUInt8(XInputFeedbackClass.string); w.writeUInt8(c.id); w.writeUInt16(UInt16(len))
            w.writePadding(2)
            w.writeUInt16(UInt16(c.keysyms.count))
            for ks in c.keysyms { w.writeUInt32(ks) }
        case .bell(let c):
            w.writeUInt8(XInputFeedbackClass.bell); w.writeUInt8(c.id); w.writeUInt16(12)
            w.writeUInt8(UInt8(bitPattern: c.percent)); w.writePadding(3)
            w.writeUInt16(UInt16(bitPattern: c.pitch))
            w.writeUInt16(UInt16(bitPattern: c.duration))
        case .led(let c):
            w.writeUInt8(XInputFeedbackClass.led); w.writeUInt8(c.id); w.writeUInt16(12)
            w.writeUInt32(c.ledMask); w.writeUInt32(c.ledValues)
        case .unknown(let cls, let id, let body):
            w.writeUInt8(cls); w.writeUInt8(id); w.writeUInt16(UInt16(4 + body.count))
            w.writeBytes(body)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputFeedbackCtl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let cls = try r.readUInt8()
        let id = try r.readUInt8()
        let length = Int(try r.readUInt16())
        let bodyLen = length - 4
        switch cls {
        case XInputFeedbackClass.kbd:
            let key = try r.readUInt8()
            let arm = try r.readUInt8()
            let click = Int8(bitPattern: try r.readUInt8())
            let percent = Int8(bitPattern: try r.readUInt8())
            let pitch = Int16(bitPattern: try r.readUInt16())
            let duration = Int16(bitPattern: try r.readUInt16())
            let ledMask = try r.readUInt32()
            let ledValues = try r.readUInt32()
            return .kbd(XInputKbdFeedbackCtl(
                id: id, key: key, autoRepeatMode: arm,
                click: click, percent: percent,
                pitch: pitch, duration: duration,
                ledMask: ledMask, ledValues: ledValues
            ))
        case XInputFeedbackClass.ptr:
            try r.skip(2)
            let num = Int16(bitPattern: try r.readUInt16())
            let denom = Int16(bitPattern: try r.readUInt16())
            let thresh = Int16(bitPattern: try r.readUInt16())
            return .ptr(XInputPtrFeedbackCtl(id: id, num: num, denom: denom, thresh: thresh))
        case XInputFeedbackClass.integer:
            let v = Int32(bitPattern: try r.readUInt32())
            return .integer(XInputIntegerFeedbackCtl(id: id, intToDisplay: v))
        case XInputFeedbackClass.string:
            try r.skip(2)
            let n = Int(try r.readUInt16())
            var keysyms: [UInt32] = []
            keysyms.reserveCapacity(n)
            for _ in 0..<n { keysyms.append(try r.readUInt32()) }
            return .string(XInputStringFeedbackCtl(id: id, keysyms: keysyms))
        case XInputFeedbackClass.bell:
            let percent = Int8(bitPattern: try r.readUInt8())
            try r.skip(3)
            let pitch = Int16(bitPattern: try r.readUInt16())
            let duration = Int16(bitPattern: try r.readUInt16())
            return .bell(XInputBellFeedbackCtl(
                id: id, percent: percent, pitch: pitch, duration: duration
            ))
        case XInputFeedbackClass.led:
            let ledMask = try r.readUInt32()
            let ledValues = try r.readUInt32()
            return .led(XInputLedFeedbackCtl(id: id, ledMask: ledMask, ledValues: ledValues))
        default:
            let body = try r.readBytes(bodyLen)
            return .unknown(class: cls, id: id, body: body)
        }
    }
}
