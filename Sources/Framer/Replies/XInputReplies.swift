// XInput v1 Tier-A reply wire types.
//
// Phase 3 XInput Session 1 (2026-05-30) lands GetExtensionVersion,
// ListInputDevices (with full device + class trailer), and OpenDevice
// replies. CloseDevice has no reply.
//
// Wire layouts from
// reference/X11R6/xc/include/extensions/XIproto.h.

// MARK: - XInputGetExtensionVersion reply

public struct XInputGetExtensionVersionReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var majorVersion: UInt16
    public var minorVersion: UInt16
    public var present: Bool

    public init(sequenceNumber: UInt16, majorVersion: UInt16,
                minorVersion: UInt16, present: Bool) {
        self.sequenceNumber = sequenceNumber
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.present = present
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(majorVersion); w.writeUInt16(minorVersion)
        w.writeUInt8(present ? 1 : 0); w.writePadding(3)
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetExtensionVersionReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        let present = try r.readUInt8() != 0
        return XInputGetExtensionVersionReply(
            sequenceNumber: seq, majorVersion: major,
            minorVersion: minor, present: present
        )
    }
}

// MARK: - XInputListInputDevices reply

/// 32-byte header + the typed device-info trailer (see
/// XInputDeviceListPayload).
public struct XInputListInputDevicesReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var devices: [XInputDeviceInfo]

    public init(sequenceNumber: UInt16, devices: [XInputDeviceInfo]) {
        self.sequenceNumber = sequenceNumber; self.devices = devices
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let trailer = XInputDeviceListPayload.encode(devices, byteOrder: byteOrder)
        let lenIn4 = UInt32(trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(UInt8(devices.count)); w.writePadding(3)
        w.writePadding(20)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputListInputDevicesReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let ndevices = Int(try r.readUInt8())
        try r.skip(3)
        try r.skip(20)
        let trailerBytes = lenIn4 * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        let devices = try XInputDeviceListPayload.decode(
            from: trailer, ndevices: ndevices, byteOrder: byteOrder
        )
        return XInputListInputDevicesReply(sequenceNumber: seq, devices: devices)
    }
}

// MARK: - XInputOpenDevice reply

/// 32-byte header + num_classes × 2-byte (class, eventTypeBase) records.
/// Distinct from the ListInputDevices class trailer — this is the
/// "which event-type-base maps to which class on this device" map.
public struct XInputOpenDeviceReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var classes: [XInputOpenDeviceClass]

    public init(sequenceNumber: UInt16, classes: [XInputOpenDeviceClass]) {
        self.sequenceNumber = sequenceNumber
        self.classes = classes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        // Each class is 2 bytes; trailer length must be a multiple of 4.
        let trailerBytes = classes.count * 2
        let p = xPad(trailerBytes)
        let lenIn4 = UInt32((trailerBytes + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(UInt8(classes.count)); w.writePadding(3)
        w.writePadding(20)
        for c in classes {
            w.writeUInt8(c.inputClass); w.writeUInt8(c.eventTypeBase)
        }
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputOpenDeviceReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let numClasses = Int(try r.readUInt8())
        try r.skip(3)
        try r.skip(20)
        var classes: [XInputOpenDeviceClass] = []
        classes.reserveCapacity(numClasses)
        for _ in 0..<numClasses {
            let cls = try r.readUInt8()
            let etb = try r.readUInt8()
            classes.append(XInputOpenDeviceClass(inputClass: cls, eventTypeBase: etb))
        }
        // Consume any tail pad.
        let consumed = numClasses * 2
        let totalTrailer = lenIn4 * 4
        if totalTrailer > consumed { try r.skip(totalTrailer - consumed) }
        return XInputOpenDeviceReply(sequenceNumber: seq, classes: classes)
    }
}
