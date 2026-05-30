// XInput v1 QueryDeviceState reply class union — Key, Button, Valuator.
//
// Shared header: class(1) + length(1) — `length` bounds the record for
// safe forward-skip on unknown variants.
//
// Wire layouts: xKeyState (36 bytes), xButtonState (36 bytes),
// xValuatorState (4-byte header + 4 × num_valuators INT32 values).

public enum XInputStateClass {
    public static let key: UInt8 = 0
    public static let button: UInt8 = 1
    public static let valuator: UInt8 = 2
}

public struct XInputKeyState: Equatable, Sendable {
    public var numKeys: UInt8
    public var keys: [UInt8]   // 32 bytes
}

public struct XInputButtonState: Equatable, Sendable {
    public var numButtons: UInt8
    public var buttons: [UInt8]   // 32 bytes
}

public struct XInputValuatorState: Equatable, Sendable {
    public var mode: UInt8
    public var values: [Int32]   // numValuators entries
}

public enum XInputDeviceStateClass: Equatable, Sendable {
    case key(XInputKeyState)
    case button(XInputButtonState)
    case valuator(XInputValuatorState)
    case unknown(class: UInt8, body: [UInt8])

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        switch self {
        case .key(let s):
            precondition(s.keys.count == 32, "keys must be 32 bytes")
            w.writeUInt8(XInputStateClass.key); w.writeUInt8(36)
            w.writeUInt8(s.numKeys); w.writePadding(1)
            w.writeBytes(s.keys)
        case .button(let s):
            precondition(s.buttons.count == 32, "buttons must be 32 bytes")
            w.writeUInt8(XInputStateClass.button); w.writeUInt8(36)
            w.writeUInt8(s.numButtons); w.writePadding(1)
            w.writeBytes(s.buttons)
        case .valuator(let s):
            let len = 4 + s.values.count * 4
            w.writeUInt8(XInputStateClass.valuator); w.writeUInt8(UInt8(len))
            w.writeUInt8(UInt8(s.values.count)); w.writeUInt8(s.mode)
            for v in s.values { w.writeUInt32(UInt32(bitPattern: v)) }
        case .unknown(let cls, let body):
            w.writeUInt8(cls); w.writeUInt8(UInt8(2 + body.count))
            w.writeBytes(body)
        }
        return w.bytes
    }

    public static func decodeList(from bytes: [UInt8], count: Int, byteOrder: ByteOrder) throws -> [XInputDeviceStateClass] {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        var out: [XInputDeviceStateClass] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let cls = try r.readUInt8()
            let length = Int(try r.readUInt8())
            let bodyLen = length - 2
            switch cls {
            case XInputStateClass.key:
                let n = try r.readUInt8()
                try r.skip(1)
                let keys = try r.readBytes(32)
                if bodyLen > 34 { try r.skip(bodyLen - 34) }
                out.append(.key(XInputKeyState(numKeys: n, keys: keys)))
            case XInputStateClass.button:
                let n = try r.readUInt8()
                try r.skip(1)
                let buttons = try r.readBytes(32)
                if bodyLen > 34 { try r.skip(bodyLen - 34) }
                out.append(.button(XInputButtonState(numButtons: n, buttons: buttons)))
            case XInputStateClass.valuator:
                let numV = Int(try r.readUInt8())
                let mode = try r.readUInt8()
                var values: [Int32] = []
                values.reserveCapacity(numV)
                for _ in 0..<numV {
                    values.append(Int32(bitPattern: try r.readUInt32()))
                }
                let consumed = 2 + numV * 4
                if bodyLen > consumed { try r.skip(bodyLen - consumed) }
                out.append(.valuator(XInputValuatorState(mode: mode, values: values)))
            default:
                let body = try r.readBytes(bodyLen)
                out.append(.unknown(class: cls, body: body))
            }
        }
        return out
    }
}
