// XInput v1 DeviceControl payload — only one variant in R6
// (DEVICE_RESOLUTION = 1). Used by GetDeviceControl reply and
// ChangeDeviceControl request.
//
// Shared header: control(2) + length(2). `length` bounds the record
// for safe forward-skip on unknown variants.

public enum XInputDeviceControlType {
    public static let resolution: UInt16 = 1
}

// MARK: - State (read direction)

public struct XInputDeviceResolutionState: Equatable, Sendable {
    /// Total `num_valuators` (CARD32 in the header), then 3 parallel
    /// CARD32 arrays: resolution_values, resolution_min_values,
    /// resolution_max_values — each `num_valuators` long.
    public var resolutions: [UInt32]
    public var minResolutions: [UInt32]
    public var maxResolutions: [UInt32]

    public init(resolutions: [UInt32], minResolutions: [UInt32], maxResolutions: [UInt32]) {
        precondition(resolutions.count == minResolutions.count &&
                     minResolutions.count == maxResolutions.count,
                     "resolution arrays must be same length")
        self.resolutions = resolutions
        self.minResolutions = minResolutions
        self.maxResolutions = maxResolutions
    }
}

public enum XInputDeviceState: Equatable, Sendable {
    case resolution(XInputDeviceResolutionState)
    case unknown(control: UInt16, body: [UInt8])

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        switch self {
        case .resolution(let s):
            let n = s.resolutions.count
            let len = 8 + n * 12          // header(4) + numValuators(4) + 3 arrays of n CARD32
            w.writeUInt16(XInputDeviceControlType.resolution)
            w.writeUInt16(UInt16(len))
            w.writeUInt32(UInt32(n))
            for v in s.resolutions { w.writeUInt32(v) }
            for v in s.minResolutions { w.writeUInt32(v) }
            for v in s.maxResolutions { w.writeUInt32(v) }
        case .unknown(let control, let body):
            w.writeUInt16(control); w.writeUInt16(UInt16(4 + body.count))
            w.writeBytes(body)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceState {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let control = try r.readUInt16()
        let length = Int(try r.readUInt16())
        let bodyLen = length - 4
        switch control {
        case XInputDeviceControlType.resolution:
            let n = Int(try r.readUInt32())
            var res: [UInt32] = []; res.reserveCapacity(n)
            for _ in 0..<n { res.append(try r.readUInt32()) }
            var minR: [UInt32] = []; minR.reserveCapacity(n)
            for _ in 0..<n { minR.append(try r.readUInt32()) }
            var maxR: [UInt32] = []; maxR.reserveCapacity(n)
            for _ in 0..<n { maxR.append(try r.readUInt32()) }
            return .resolution(XInputDeviceResolutionState(
                resolutions: res, minResolutions: minR, maxResolutions: maxR
            ))
        default:
            let body = try r.readBytes(bodyLen)
            return .unknown(control: control, body: body)
        }
    }
}

// MARK: - Ctl (write direction)

public struct XInputDeviceResolutionCtl: Equatable, Sendable {
    public var firstValuator: UInt8
    /// Trailing `num_valuators × CARD32` resolutions to set.
    public var resolutions: [UInt32]

    public init(firstValuator: UInt8, resolutions: [UInt32]) {
        self.firstValuator = firstValuator; self.resolutions = resolutions
    }
}

public enum XInputDeviceCtl: Equatable, Sendable {
    case resolution(XInputDeviceResolutionCtl)
    case unknown(control: UInt16, body: [UInt8])

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        switch self {
        case .resolution(let c):
            let n = c.resolutions.count
            let len = 8 + n * 4           // header(4) + firstValuator+numValuators+pad(4) + n CARD32
            w.writeUInt16(XInputDeviceControlType.resolution)
            w.writeUInt16(UInt16(len))
            w.writeUInt8(c.firstValuator); w.writeUInt8(UInt8(n)); w.writePadding(2)
            for v in c.resolutions { w.writeUInt32(v) }
        case .unknown(let control, let body):
            w.writeUInt16(control); w.writeUInt16(UInt16(4 + body.count))
            w.writeBytes(body)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceCtl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let control = try r.readUInt16()
        let length = Int(try r.readUInt16())
        let bodyLen = length - 4
        switch control {
        case XInputDeviceControlType.resolution:
            let firstValuator = try r.readUInt8()
            let n = Int(try r.readUInt8())
            try r.skip(2)
            var res: [UInt32] = []; res.reserveCapacity(n)
            for _ in 0..<n { res.append(try r.readUInt32()) }
            return .resolution(XInputDeviceResolutionCtl(
                firstValuator: firstValuator, resolutions: res
            ))
        default:
            let body = try r.readBytes(bodyLen)
            return .unknown(control: control, body: body)
        }
    }
}
