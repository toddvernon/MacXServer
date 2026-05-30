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

// =============================================================================
// Session 2 (2026-05-30): Tier B + Tier C replies.
// =============================================================================

/// Generic 32-byte single-status-byte reply used by several XInput ops
/// (SetDeviceMode, ChangeKeyboardDevice, ChangePointerDevice, GrabDevice,
/// SetDeviceValuators, ChangeDeviceControl). Each gets its own struct so
/// callsites stay typed.
private func encodeStatusReply(_ seq: UInt16, _ status: UInt8, byteOrder: ByteOrder) -> [UInt8] {
    var w = ByteWriter(byteOrder: byteOrder)
    w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(seq)
    w.writeUInt32(0)
    w.writeUInt8(status); w.writePadding(3)
    w.writePadding(20)
    return w.bytes
}

private func decodeStatusReply(_ bytes: [UInt8], byteOrder: ByteOrder) throws -> (seq: UInt16, status: UInt8) {
    guard bytes.count >= 32 else {
        throw FramerError.truncated(needed: 32, available: bytes.count)
    }
    var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
    _ = try r.readUInt8(); _ = try r.readUInt8()
    let seq = try r.readUInt16()
    _ = try r.readUInt32()
    let status = try r.readUInt8()
    return (seq, status)
}

public struct XInputSetDeviceModeReply: Equatable, Sendable {
    public var sequenceNumber: UInt16; public var status: UInt8
    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        encodeStatusReply(sequenceNumber, status, byteOrder: byteOrder)
    }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceModeReply {
        let (seq, status) = try decodeStatusReply(bytes, byteOrder: byteOrder)
        return XInputSetDeviceModeReply(sequenceNumber: seq, status: status)
    }
}

public struct XInputChangeKeyboardDeviceReply: Equatable, Sendable {
    public var sequenceNumber: UInt16; public var status: UInt8
    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        encodeStatusReply(sequenceNumber, status, byteOrder: byteOrder)
    }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeKeyboardDeviceReply {
        let (seq, status) = try decodeStatusReply(bytes, byteOrder: byteOrder)
        return XInputChangeKeyboardDeviceReply(sequenceNumber: seq, status: status)
    }
}

public struct XInputChangePointerDeviceReply: Equatable, Sendable {
    public var sequenceNumber: UInt16; public var status: UInt8
    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        encodeStatusReply(sequenceNumber, status, byteOrder: byteOrder)
    }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangePointerDeviceReply {
        let (seq, status) = try decodeStatusReply(bytes, byteOrder: byteOrder)
        return XInputChangePointerDeviceReply(sequenceNumber: seq, status: status)
    }
}

public struct XInputGrabDeviceReply: Equatable, Sendable {
    public var sequenceNumber: UInt16; public var status: UInt8
    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        encodeStatusReply(sequenceNumber, status, byteOrder: byteOrder)
    }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGrabDeviceReply {
        let (seq, status) = try decodeStatusReply(bytes, byteOrder: byteOrder)
        return XInputGrabDeviceReply(sequenceNumber: seq, status: status)
    }
}

public struct XInputSetDeviceValuatorsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16; public var status: UInt8
    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        encodeStatusReply(sequenceNumber, status, byteOrder: byteOrder)
    }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceValuatorsReply {
        let (seq, status) = try decodeStatusReply(bytes, byteOrder: byteOrder)
        return XInputSetDeviceValuatorsReply(sequenceNumber: seq, status: status)
    }
}

public struct XInputChangeDeviceControlReply: Equatable, Sendable {
    public var sequenceNumber: UInt16; public var status: UInt8
    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        encodeStatusReply(sequenceNumber, status, byteOrder: byteOrder)
    }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeDeviceControlReply {
        let (seq, status) = try decodeStatusReply(bytes, byteOrder: byteOrder)
        return XInputChangeDeviceControlReply(sequenceNumber: seq, status: status)
    }
}

// MARK: - GetSelectedExtensionEvents reply (two XEventClass trailers)

public struct XInputGetSelectedExtensionEventsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var thisClient: [UInt32]      // XEventClass
    public var allClients: [UInt32]

    public init(sequenceNumber: UInt16, thisClient: [UInt32], allClients: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.thisClient = thisClient
        self.allClients = allClients
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(thisClient.count + allClients.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(thisClient.count))
        w.writeUInt16(UInt16(allClients.count))
        w.writePadding(20)
        for c in thisClient { w.writeUInt32(c) }
        for c in allClients { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetSelectedExtensionEventsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let thisCount = Int(try r.readUInt16())
        let allCount = Int(try r.readUInt16())
        try r.skip(20)
        var thisClient: [UInt32] = []; thisClient.reserveCapacity(thisCount)
        for _ in 0..<thisCount { thisClient.append(try r.readUInt32()) }
        var allClients: [UInt32] = []; allClients.reserveCapacity(allCount)
        for _ in 0..<allCount { allClients.append(try r.readUInt32()) }
        return XInputGetSelectedExtensionEventsReply(
            sequenceNumber: seq, thisClient: thisClient, allClients: allClients
        )
    }
}

// MARK: - GetDeviceDontPropagateList reply

public struct XInputGetDeviceDontPropagateListReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var classes: [UInt32]

    public init(sequenceNumber: UInt16, classes: [UInt32]) {
        self.sequenceNumber = sequenceNumber; self.classes = classes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(classes.count)); w.writePadding(2)
        w.writePadding(20)
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceDontPropagateListReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let n = Int(try r.readUInt16()); try r.skip(2)
        try r.skip(20)
        var classes: [UInt32] = []; classes.reserveCapacity(n)
        for _ in 0..<n { classes.append(try r.readUInt32()) }
        return XInputGetDeviceDontPropagateListReply(sequenceNumber: seq, classes: classes)
    }
}

// MARK: - GetDeviceMotionEvents reply

/// 32-byte header + `nEvents` × `(1 + axes)` INT32s. Each motion sample
/// is one CARD32 timestamp followed by `axes` INT32 valuator readings.
public struct XInputDeviceMotionSample: Equatable, Sendable {
    public var time: UInt32
    public var axes: [Int32]

    public init(time: UInt32, axes: [Int32]) {
        self.time = time; self.axes = axes
    }
}

public struct XInputGetDeviceMotionEventsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var axes: UInt8
    public var mode: UInt8
    public var samples: [XInputDeviceMotionSample]

    public init(sequenceNumber: UInt16, axes: UInt8, mode: UInt8,
                samples: [XInputDeviceMotionSample]) {
        self.sequenceNumber = sequenceNumber
        self.axes = axes; self.mode = mode
        self.samples = samples
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let perSample = 1 + Int(axes)
        let lenIn4 = UInt32(samples.count * perSample)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(UInt32(samples.count))
        w.writeUInt8(axes); w.writeUInt8(mode); w.writePadding(2)
        w.writePadding(16)
        for s in samples {
            precondition(s.axes.count == Int(axes), "sample axes count mismatch")
            w.writeUInt32(s.time)
            for v in s.axes { w.writeUInt32(UInt32(bitPattern: v)) }
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceMotionEventsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let nEvents = Int(try r.readUInt32())
        let axes = try r.readUInt8()
        let mode = try r.readUInt8()
        try r.skip(2)
        try r.skip(16)
        var samples: [XInputDeviceMotionSample] = []
        samples.reserveCapacity(nEvents)
        for _ in 0..<nEvents {
            let time = try r.readUInt32()
            var vals: [Int32] = []
            vals.reserveCapacity(Int(axes))
            for _ in 0..<Int(axes) {
                vals.append(Int32(bitPattern: try r.readUInt32()))
            }
            samples.append(XInputDeviceMotionSample(time: time, axes: vals))
        }
        return XInputGetDeviceMotionEventsReply(
            sequenceNumber: seq, axes: axes, mode: mode, samples: samples
        )
    }
}

// MARK: - GetDeviceFocus reply

public struct XInputGetDeviceFocusReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var focus: UInt32   // Window
    public var time: UInt32
    public var revertTo: UInt8

    public init(sequenceNumber: UInt16, focus: UInt32, time: UInt32, revertTo: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.focus = focus; self.time = time; self.revertTo = revertTo
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(focus); w.writeUInt32(time)
        w.writeUInt8(revertTo); w.writePadding(3)
        w.writePadding(12)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceFocusReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let focus = try r.readUInt32()
        let time = try r.readUInt32()
        let revertTo = try r.readUInt8()
        return XInputGetDeviceFocusReply(
            sequenceNumber: seq, focus: focus, time: time, revertTo: revertTo
        )
    }
}

// MARK: - GetFeedbackControl reply

public struct XInputGetFeedbackControlReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var feedbacks: [XInputFeedbackState]

    public init(sequenceNumber: UInt16, feedbacks: [XInputFeedbackState]) {
        self.sequenceNumber = sequenceNumber; self.feedbacks = feedbacks
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let trailer = XInputFeedbackState.encodeList(feedbacks, byteOrder: byteOrder)
        let lenIn4 = UInt32(trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(feedbacks.count)); w.writePadding(2)
        w.writePadding(20)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetFeedbackControlReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let numFeedbacks = Int(try r.readUInt16()); try r.skip(2)
        try r.skip(20)
        let trailerBytes = lenIn4 * 4
        let trailer = try r.readBytes(trailerBytes)
        let feedbacks = try XInputFeedbackState.decodeList(
            from: trailer, count: numFeedbacks, byteOrder: byteOrder
        )
        return XInputGetFeedbackControlReply(sequenceNumber: seq, feedbacks: feedbacks)
    }
}

// MARK: - GetDeviceKeyMapping reply

public struct XInputGetDeviceKeyMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var keySymsPerKeyCode: UInt8
    public var keysyms: [UInt32]

    public init(sequenceNumber: UInt16, keySymsPerKeyCode: UInt8, keysyms: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.keySymsPerKeyCode = keySymsPerKeyCode
        self.keysyms = keysyms
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(keysyms.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(keySymsPerKeyCode); w.writePadding(3)
        w.writePadding(20)
        for s in keysyms { w.writeUInt32(s) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceKeyMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let kspkc = try r.readUInt8(); try r.skip(3)
        try r.skip(20)
        var keysyms: [UInt32] = []; keysyms.reserveCapacity(lenIn4)
        for _ in 0..<lenIn4 { keysyms.append(try r.readUInt32()) }
        return XInputGetDeviceKeyMappingReply(
            sequenceNumber: seq, keySymsPerKeyCode: kspkc, keysyms: keysyms
        )
    }
}

// MARK: - GetDeviceModifierMapping reply

public struct XInputGetDeviceModifierMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var numKeyPerModifier: UInt8
    public var keycodes: [UInt8]   // 8 × numKeyPerModifier

    public init(sequenceNumber: UInt16, numKeyPerModifier: UInt8, keycodes: [UInt8]) {
        precondition(keycodes.count == 8 * Int(numKeyPerModifier),
                     "keycodes must be 8 × numKeyPerModifier")
        self.sequenceNumber = sequenceNumber
        self.numKeyPerModifier = numKeyPerModifier
        self.keycodes = keycodes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = keycodes.count
        let p = xPad(n)
        let lenIn4 = UInt32((n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(numKeyPerModifier); w.writePadding(3)
        w.writePadding(20)
        w.writeBytes(keycodes)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceModifierMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let per = try r.readUInt8(); try r.skip(3)
        try r.skip(20)
        let keycodes = try r.readBytes(8 * Int(per))
        return XInputGetDeviceModifierMappingReply(
            sequenceNumber: seq, numKeyPerModifier: per, keycodes: keycodes
        )
    }
}

public struct XInputSetDeviceModifierMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var success: UInt8

    public init(sequenceNumber: UInt16, success: UInt8) {
        self.sequenceNumber = sequenceNumber; self.success = success
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt8(success); w.writePadding(3)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceModifierMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let success = try r.readUInt8()
        return XInputSetDeviceModifierMappingReply(sequenceNumber: seq, success: success)
    }
}

// MARK: - GetDeviceButtonMapping reply

public struct XInputGetDeviceButtonMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var map: [UInt8]

    public init(sequenceNumber: UInt16, map: [UInt8]) {
        self.sequenceNumber = sequenceNumber; self.map = map
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = map.count
        let p = xPad(n)
        let lenIn4 = UInt32((n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(UInt8(n)); w.writePadding(3)
        w.writePadding(20)
        w.writeBytes(map)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceButtonMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let nElts = Int(try r.readUInt8()); try r.skip(3)
        try r.skip(20)
        let map = try r.readBytes(nElts)
        return XInputGetDeviceButtonMappingReply(sequenceNumber: seq, map: map)
    }
}

public struct XInputSetDeviceButtonMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var status: UInt8

    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber; self.status = status
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt8(status); w.writePadding(3)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceButtonMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let status = try r.readUInt8()
        return XInputSetDeviceButtonMappingReply(sequenceNumber: seq, status: status)
    }
}

// MARK: - QueryDeviceState reply

public struct XInputQueryDeviceStateReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var classes: [XInputDeviceStateClass]

    public init(sequenceNumber: UInt16, classes: [XInputDeviceStateClass]) {
        self.sequenceNumber = sequenceNumber; self.classes = classes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        var trailerBytes: [UInt8] = []
        for c in classes { trailerBytes.append(contentsOf: c.encode(byteOrder: byteOrder)) }
        let lenIn4 = UInt32(trailerBytes.count / 4)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(UInt8(classes.count)); w.writePadding(3)
        w.writePadding(20)
        w.writeBytes(trailerBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputQueryDeviceStateReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let numClasses = Int(try r.readUInt8()); try r.skip(3)
        try r.skip(20)
        let trailerBytes = try r.readBytes(lenIn4 * 4)
        let classes = try XInputDeviceStateClass.decodeList(
            from: trailerBytes, count: numClasses, byteOrder: byteOrder
        )
        return XInputQueryDeviceStateReply(sequenceNumber: seq, classes: classes)
    }
}

// MARK: - GetDeviceControl reply

public struct XInputGetDeviceControlReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var status: UInt8
    public var state: XInputDeviceState

    public init(sequenceNumber: UInt16, status: UInt8, state: XInputDeviceState) {
        self.sequenceNumber = sequenceNumber; self.status = status; self.state = state
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let stateBytes = state.encode(byteOrder: byteOrder)
        let lenIn4 = UInt32(stateBytes.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(status); w.writePadding(3)
        w.writePadding(20)
        w.writeBytes(stateBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceControlReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let status = try r.readUInt8(); try r.skip(3)
        try r.skip(20)
        let stateBytes = try r.readBytes(lenIn4 * 4)
        let state = try XInputDeviceState.decode(from: stateBytes, byteOrder: byteOrder)
        return XInputGetDeviceControlReply(sequenceNumber: seq, status: status, state: state)
    }
}
