// XInput v1 event wire types — all 15 events the extension reserves.
//
// Phase 3 XInput Session 1 (2026-05-30). Unlike XKB (one absolute code
// with `xkbType` byte 1 discriminator), XInput v1 reserves a
// CONTIGUOUS 15-event range from `firstEvent`. So XInputDumper.eventCount
// = 15 and absolute code minus firstEvent gives the offset.
//
// Six event offsets (KeyPress/KeyRelease/ButtonPress/ButtonRelease/
// MotionNotify, plus ProximityIn/Out) share one body struct
// (XInputDeviceKeyButtonPointerEvent); the others are one-off.
//
// Wire layouts from
// reference/X11R6/xc/include/extensions/XIproto.h (lines 1255-1421)
// + XI.h.

/// Offsets within XInput's contiguous event range. Used both as
/// discriminator-during-decode and as the `type` byte when encoding.
public enum XInputEventType {
    public static let deviceValuator: UInt8 = 0
    public static let deviceKeyPress: UInt8 = 1
    public static let deviceKeyRelease: UInt8 = 2
    public static let deviceButtonPress: UInt8 = 3
    public static let deviceButtonRelease: UInt8 = 4
    public static let deviceMotionNotify: UInt8 = 5
    public static let deviceFocusIn: UInt8 = 6
    public static let deviceFocusOut: UInt8 = 7
    public static let proximityIn: UInt8 = 8
    public static let proximityOut: UInt8 = 9
    public static let deviceStateNotify: UInt8 = 10
    public static let deviceMappingNotify: UInt8 = 11
    public static let changeDeviceNotify: UInt8 = 12
    public static let deviceKeyStateNotify: UInt8 = 13
    public static let deviceButtonStateNotify: UInt8 = 14
}

// MARK: - DeviceValuator (offset 0)

public struct XInputDeviceValuatorEvent: Equatable, Sendable {
    public var type: UInt8                  // firstEvent + 0
    public var deviceID: UInt8
    public var sequenceNumber: UInt16
    public var deviceState: UInt16
    public var numValuators: UInt8
    public var firstValuator: UInt8
    public var valuators: [Int32]           // exactly 6 entries on the wire

    public init(type: UInt8, deviceID: UInt8, sequenceNumber: UInt16,
                deviceState: UInt16, numValuators: UInt8, firstValuator: UInt8,
                valuators: [Int32]) {
        precondition(valuators.count == 6, "valuators must be 6 entries on the wire")
        self.type = type; self.deviceID = deviceID
        self.sequenceNumber = sequenceNumber; self.deviceState = deviceState
        self.numValuators = numValuators; self.firstValuator = firstValuator
        self.valuators = valuators
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt16(deviceState)
        w.writeUInt8(numValuators); w.writeUInt8(firstValuator)
        for v in valuators { w.writeUInt32(UInt32(bitPattern: v)) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceValuatorEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let deviceState = try r.readUInt16()
        let numValuators = try r.readUInt8()
        let firstValuator = try r.readUInt8()
        var v: [Int32] = []
        for _ in 0..<6 { v.append(Int32(bitPattern: try r.readUInt32())) }
        return XInputDeviceValuatorEvent(
            type: type, deviceID: deviceID, sequenceNumber: seq,
            deviceState: deviceState, numValuators: numValuators,
            firstValuator: firstValuator, valuators: v
        )
    }
}

// MARK: - DeviceKeyButtonPointer (offsets 1-5 + 8-9 — shared struct)

/// Used by DeviceKeyPress/Release, DeviceButtonPress/Release,
/// DeviceMotionNotify, ProximityIn/Out. The dumper routes all six
/// offsets through this single decoder; the `type` byte tells you
/// which flavor.
public struct XInputDeviceKeyButtonPointerEvent: Equatable, Sendable {
    public var type: UInt8
    public var detail: UInt8     // keycode or button number, or motion (=0)
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var root: UInt32
    public var event: UInt32
    public var child: UInt32
    public var rootX: Int16
    public var rootY: Int16
    public var eventX: Int16
    public var eventY: Int16
    public var state: UInt16
    public var sameScreen: Bool
    public var deviceID: UInt8

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(detail); w.writeUInt16(sequenceNumber)
        w.writeUInt32(time)
        w.writeUInt32(root); w.writeUInt32(event); w.writeUInt32(child)
        w.writeUInt16(UInt16(bitPattern: rootX)); w.writeUInt16(UInt16(bitPattern: rootY))
        w.writeUInt16(UInt16(bitPattern: eventX)); w.writeUInt16(UInt16(bitPattern: eventY))
        w.writeUInt16(state)
        w.writeUInt8(sameScreen ? 1 : 0)
        w.writeUInt8(deviceID)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceKeyButtonPointerEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let detail = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let root = try r.readUInt32()
        let event = try r.readUInt32()
        let child = try r.readUInt32()
        let rootX = Int16(bitPattern: try r.readUInt16())
        let rootY = Int16(bitPattern: try r.readUInt16())
        let eventX = Int16(bitPattern: try r.readUInt16())
        let eventY = Int16(bitPattern: try r.readUInt16())
        let state = try r.readUInt16()
        let sameScreen = try r.readUInt8() != 0
        let deviceID = try r.readUInt8()
        return XInputDeviceKeyButtonPointerEvent(
            type: type, detail: detail, sequenceNumber: seq, time: time,
            root: root, event: event, child: child,
            rootX: rootX, rootY: rootY, eventX: eventX, eventY: eventY,
            state: state, sameScreen: sameScreen, deviceID: deviceID
        )
    }
}

// MARK: - DeviceFocus (offsets 6-7)

public struct XInputDeviceFocusEvent: Equatable, Sendable {
    public var type: UInt8
    public var detail: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var window: UInt32
    public var mode: UInt8
    public var deviceID: UInt8

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(detail); w.writeUInt16(sequenceNumber)
        w.writeUInt32(time)
        w.writeUInt32(window)
        w.writeUInt8(mode); w.writeUInt8(deviceID); w.writePadding(2)
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceFocusEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let detail = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let window = try r.readUInt32()
        let mode = try r.readUInt8(); let deviceID = try r.readUInt8()
        try r.skip(2)
        return XInputDeviceFocusEvent(
            type: type, detail: detail, sequenceNumber: seq,
            time: time, window: window, mode: mode, deviceID: deviceID
        )
    }
}

// MARK: - DeviceStateNotify (offset 10)

/// `classesReported` packs three things: two high-order bits are
/// proximity-state + device-mode, six low-order bits are class count.
/// Caller can decode by masking — we just carry the raw byte.
public struct XInputDeviceStateNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var deviceID: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var numKeys: UInt8
    public var numButtons: UInt8
    public var numValuators: UInt8
    public var classesReported: UInt8
    public var buttons: [UInt8]    // 4 bytes
    public var keys: [UInt8]       // 4 bytes
    public var valuator0: Int32
    public var valuator1: Int32
    public var valuator2: Int32

    public init(type: UInt8, deviceID: UInt8, sequenceNumber: UInt16, time: UInt32,
                numKeys: UInt8, numButtons: UInt8, numValuators: UInt8,
                classesReported: UInt8,
                buttons: [UInt8], keys: [UInt8],
                valuator0: Int32, valuator1: Int32, valuator2: Int32) {
        precondition(buttons.count == 4 && keys.count == 4, "buttons/keys must be 4 bytes each")
        self.type = type; self.deviceID = deviceID
        self.sequenceNumber = sequenceNumber; self.time = time
        self.numKeys = numKeys; self.numButtons = numButtons
        self.numValuators = numValuators; self.classesReported = classesReported
        self.buttons = buttons; self.keys = keys
        self.valuator0 = valuator0; self.valuator1 = valuator1; self.valuator2 = valuator2
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(time)
        w.writeUInt8(numKeys); w.writeUInt8(numButtons)
        w.writeUInt8(numValuators); w.writeUInt8(classesReported)
        w.writeBytes(buttons); w.writeBytes(keys)
        w.writeUInt32(UInt32(bitPattern: valuator0))
        w.writeUInt32(UInt32(bitPattern: valuator1))
        w.writeUInt32(UInt32(bitPattern: valuator2))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceStateNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let numKeys = try r.readUInt8(); let numButtons = try r.readUInt8()
        let numValuators = try r.readUInt8(); let classesReported = try r.readUInt8()
        let buttons = try r.readBytes(4)
        let keys = try r.readBytes(4)
        let v0 = Int32(bitPattern: try r.readUInt32())
        let v1 = Int32(bitPattern: try r.readUInt32())
        let v2 = Int32(bitPattern: try r.readUInt32())
        return XInputDeviceStateNotifyEvent(
            type: type, deviceID: deviceID, sequenceNumber: seq, time: time,
            numKeys: numKeys, numButtons: numButtons,
            numValuators: numValuators, classesReported: classesReported,
            buttons: buttons, keys: keys,
            valuator0: v0, valuator1: v1, valuator2: v2
        )
    }
}

// MARK: - DeviceKeyStateNotify (offset 13)

public struct XInputDeviceKeyStateNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var deviceID: UInt8
    public var sequenceNumber: UInt16
    public var keys: [UInt8]    // 28 bytes

    public init(type: UInt8, deviceID: UInt8, sequenceNumber: UInt16, keys: [UInt8]) {
        precondition(keys.count == 28, "keys must be 28 bytes")
        self.type = type; self.deviceID = deviceID
        self.sequenceNumber = sequenceNumber; self.keys = keys
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeBytes(keys)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceKeyStateNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let keys = try r.readBytes(28)
        return XInputDeviceKeyStateNotifyEvent(
            type: type, deviceID: deviceID, sequenceNumber: seq, keys: keys
        )
    }
}

// MARK: - DeviceButtonStateNotify (offset 14)

public struct XInputDeviceButtonStateNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var deviceID: UInt8
    public var sequenceNumber: UInt16
    public var buttons: [UInt8]   // 28 bytes

    public init(type: UInt8, deviceID: UInt8, sequenceNumber: UInt16, buttons: [UInt8]) {
        precondition(buttons.count == 28, "buttons must be 28 bytes")
        self.type = type; self.deviceID = deviceID
        self.sequenceNumber = sequenceNumber; self.buttons = buttons
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeBytes(buttons)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceButtonStateNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let buttons = try r.readBytes(28)
        return XInputDeviceButtonStateNotifyEvent(
            type: type, deviceID: deviceID, sequenceNumber: seq, buttons: buttons
        )
    }
}

// MARK: - DeviceMappingNotify (offset 11)

public struct XInputDeviceMappingNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var deviceID: UInt8
    public var sequenceNumber: UInt16
    public var request: UInt8     // 0=MappingModifier, 1=MappingKeyboard, 2=MappingPointer
    public var firstKeyCode: UInt8
    public var count: UInt8
    public var time: UInt32

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt8(request); w.writeUInt8(firstKeyCode); w.writeUInt8(count); w.writePadding(1)
        w.writeUInt32(time)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceMappingNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let request = try r.readUInt8(); let firstKeyCode = try r.readUInt8()
        let count = try r.readUInt8(); try r.skip(1)
        let time = try r.readUInt32()
        return XInputDeviceMappingNotifyEvent(
            type: type, deviceID: deviceID, sequenceNumber: seq,
            request: request, firstKeyCode: firstKeyCode, count: count, time: time
        )
    }
}

// MARK: - ChangeDeviceNotify (offset 12)

public struct XInputChangeDeviceNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var deviceID: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var request: UInt8    // 0=NewPointer, 1=NewKeyboard, 2=DeviceEnabled

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(time)
        w.writeUInt8(request); w.writePadding(3)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeDeviceNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let request = try r.readUInt8()
        return XInputChangeDeviceNotifyEvent(
            type: type, deviceID: deviceID, sequenceNumber: seq,
            time: time, request: request
        )
    }
}
