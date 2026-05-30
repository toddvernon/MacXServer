// XInput v1 extension Tier-A request wire types.
//
// Phase 3 XInput Session 1 (2026-05-30) lands the 4 requests every
// Xlib client emits during input-device enumeration:
//   GetExtensionVersion, ListInputDevices, OpenDevice, CloseDevice.
// Session 2 covers Tier B + C (the remaining 31 ops).
//
// XInput is a 35-opcode beast by request count but flatter than XKB.
// Wire layouts from
// reference/X11R6/xc/include/extensions/XIproto.h + XI.h.

public enum XInputMinor {
    public static let getExtensionVersion: UInt8 = 1
    public static let listInputDevices: UInt8 = 2
    public static let openDevice: UInt8 = 3
    public static let closeDevice: UInt8 = 4
    public static let setDeviceMode: UInt8 = 5
    public static let selectExtensionEvent: UInt8 = 6
    public static let getSelectedExtensionEvents: UInt8 = 7
    public static let changeDeviceDontPropagateList: UInt8 = 8
    public static let getDeviceDontPropagateList: UInt8 = 9
    public static let getDeviceMotionEvents: UInt8 = 10
    public static let changeKeyboardDevice: UInt8 = 11
    public static let changePointerDevice: UInt8 = 12
    public static let grabDevice: UInt8 = 13
    public static let ungrabDevice: UInt8 = 14
    public static let grabDeviceKey: UInt8 = 15
    public static let ungrabDeviceKey: UInt8 = 16
    public static let grabDeviceButton: UInt8 = 17
    public static let ungrabDeviceButton: UInt8 = 18
    public static let allowDeviceEvents: UInt8 = 19
    public static let getDeviceFocus: UInt8 = 20
    public static let setDeviceFocus: UInt8 = 21
    public static let getFeedbackControl: UInt8 = 22
    public static let changeFeedbackControl: UInt8 = 23
    public static let getDeviceKeyMapping: UInt8 = 24
    public static let changeDeviceKeyMapping: UInt8 = 25
    public static let getDeviceModifierMapping: UInt8 = 26
    public static let setDeviceModifierMapping: UInt8 = 27
    public static let getDeviceButtonMapping: UInt8 = 28
    public static let setDeviceButtonMapping: UInt8 = 29
    public static let queryDeviceState: UInt8 = 30
    public static let sendExtensionEvent: UInt8 = 31
    public static let deviceBell: UInt8 = 32
    public static let setDeviceValuators: UInt8 = 33
    public static let getDeviceControl: UInt8 = 34
    public static let changeDeviceControl: UInt8 = 35
}

// MARK: - XInputGetExtensionVersion (minor 1)

/// xGetExtensionVersionReq: header(4) + nbytes(2) + pad(2), then the
/// extension name string padded to 4. Clients pass "XInputExtension"
/// here so the server can confirm.
public struct XInputGetExtensionVersion: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getExtensionVersion

    public var name: String

    public init(name: String) { self.name = name }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        let p = xPad(nameBytes.count)
        let lenIn4 = UInt16(2 + (nameBytes.count + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(UInt16(nameBytes.count)); w.writePadding(2)
        w.writeBytes(nameBytes)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetExtensionVersion {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let n = Int(try r.readUInt16())
        try r.skip(2)
        let nameBytes = try r.readBytes(n)
        return XInputGetExtensionVersion(name: String(decoding: nameBytes, as: UTF8.self))
    }
}

// MARK: - XInputListInputDevices (minor 2)

public struct XInputListInputDevices: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.listInputDevices

    public init() {}

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputListInputDevices {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        return XInputListInputDevices()
    }
}

// MARK: - XInputOpenDevice (minor 3)

public struct XInputOpenDevice: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.openDevice

    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputOpenDevice {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        try r.skip(3)
        return XInputOpenDevice(deviceID: deviceID)
    }
}

// MARK: - XInputCloseDevice (minor 4)

public struct XInputCloseDevice: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.closeDevice

    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputCloseDevice {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        try r.skip(3)
        return XInputCloseDevice(deviceID: deviceID)
    }
}

// =============================================================================
// Session 2 (2026-05-30): Tier B + Tier C requests.
// =============================================================================
//
// XEventClass is CARD32 (a server-assigned per-event-class cookie),
// NOT CARD16. Several requests carry `event_count CARD16` followed by
// `XEventClass[count]` at 4 bytes each. Easy off-by-2 risk.
//
// Feedback (req 22/23), DeviceControl (req 34/35), and QueryDeviceState
// (req 30) bodies use shared union codecs defined in
// XInputFeedbackPayload.swift, XInputDeviceControlPayload.swift, and
// XInputDeviceStatePayload.swift.

// MARK: - XInputSetDeviceMode (minor 5)

public struct XInputSetDeviceMode: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.setDeviceMode
    public var deviceID: UInt8
    public var mode: UInt8     // 0=Relative, 1=Absolute

    public init(deviceID: UInt8, mode: UInt8) {
        self.deviceID = deviceID; self.mode = mode
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writeUInt8(mode); w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceMode {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        let mode = try r.readUInt8()
        try r.skip(2)
        return XInputSetDeviceMode(deviceID: deviceID, mode: mode)
    }
}

// MARK: - XInputSelectExtensionEvent (minor 6)

public struct XInputSelectExtensionEvent: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.selectExtensionEvent
    public var window: UInt32
    public var classes: [UInt32]    // XEventClass list

    public init(window: UInt32, classes: [UInt32]) {
        self.window = window; self.classes = classes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(window)
        w.writeUInt16(UInt16(classes.count)); w.writePadding(2)
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSelectExtensionEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        let count = Int(try r.readUInt16()); try r.skip(2)
        var classes: [UInt32] = []
        classes.reserveCapacity(count)
        for _ in 0..<count { classes.append(try r.readUInt32()) }
        return XInputSelectExtensionEvent(window: window, classes: classes)
    }
}

// MARK: - XInputGetSelectedExtensionEvents (minor 7)

public struct XInputGetSelectedExtensionEvents: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getSelectedExtensionEvents
    public var window: UInt32

    public init(window: UInt32) { self.window = window }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetSelectedExtensionEvents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        return XInputGetSelectedExtensionEvents(window: window)
    }
}

// MARK: - XInputChangeDeviceDontPropagateList (minor 8)

public struct XInputChangeDeviceDontPropagateList: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.changeDeviceDontPropagateList
    public var window: UInt32
    public var mode: UInt8       // 0=AddToList, 1=DeleteFromList
    public var classes: [UInt32]

    public init(window: UInt32, mode: UInt8, classes: [UInt32]) {
        self.window = window; self.mode = mode; self.classes = classes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(window)
        w.writeUInt16(UInt16(classes.count))
        w.writeUInt8(mode); w.writePadding(1)
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeDeviceDontPropagateList {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        let count = Int(try r.readUInt16())
        let mode = try r.readUInt8()
        try r.skip(1)
        var classes: [UInt32] = []
        classes.reserveCapacity(count)
        for _ in 0..<count { classes.append(try r.readUInt32()) }
        return XInputChangeDeviceDontPropagateList(window: window, mode: mode, classes: classes)
    }
}

// MARK: - XInputGetDeviceDontPropagateList (minor 9)

public struct XInputGetDeviceDontPropagateList: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceDontPropagateList
    public var window: UInt32

    public init(window: UInt32) { self.window = window }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceDontPropagateList {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        return XInputGetDeviceDontPropagateList(window: window)
    }
}

// MARK: - XInputGetDeviceMotionEvents (minor 10)

public struct XInputGetDeviceMotionEvents: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceMotionEvents
    public var start: UInt32
    public var stop: UInt32
    public var deviceID: UInt8

    public init(start: UInt32, stop: UInt32, deviceID: UInt8) {
        self.start = start; self.stop = stop; self.deviceID = deviceID
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(start); w.writeUInt32(stop)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceMotionEvents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let start = try r.readUInt32()
        let stop = try r.readUInt32()
        let deviceID = try r.readUInt8()
        try r.skip(3)
        return XInputGetDeviceMotionEvents(start: start, stop: stop, deviceID: deviceID)
    }
}

// MARK: - XInputChangeKeyboardDevice (minor 11)

public struct XInputChangeKeyboardDevice: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.changeKeyboardDevice
    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeKeyboardDevice {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        try r.skip(3)
        return XInputChangeKeyboardDevice(deviceID: deviceID)
    }
}

// MARK: - XInputChangePointerDevice (minor 12)

public struct XInputChangePointerDevice: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.changePointerDevice
    public var xAxis: UInt8
    public var yAxis: UInt8
    public var deviceID: UInt8

    public init(xAxis: UInt8, yAxis: UInt8, deviceID: UInt8) {
        self.xAxis = xAxis; self.yAxis = yAxis; self.deviceID = deviceID
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(xAxis); w.writeUInt8(yAxis); w.writeUInt8(deviceID); w.writePadding(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangePointerDevice {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let xAxis = try r.readUInt8()
        let yAxis = try r.readUInt8()
        let deviceID = try r.readUInt8()
        try r.skip(1)
        return XInputChangePointerDevice(xAxis: xAxis, yAxis: yAxis, deviceID: deviceID)
    }
}

// MARK: - XInputGrabDevice (minor 13)

public struct XInputGrabDevice: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.grabDevice
    public var grabWindow: UInt32
    public var time: UInt32
    public var thisDeviceMode: UInt8
    public var otherDevicesMode: UInt8
    public var ownerEvents: Bool
    public var deviceID: UInt8
    public var classes: [UInt32]

    public init(grabWindow: UInt32, time: UInt32,
                thisDeviceMode: UInt8, otherDevicesMode: UInt8,
                ownerEvents: Bool, deviceID: UInt8,
                classes: [UInt32]) {
        self.grabWindow = grabWindow; self.time = time
        self.thisDeviceMode = thisDeviceMode
        self.otherDevicesMode = otherDevicesMode
        self.ownerEvents = ownerEvents
        self.deviceID = deviceID
        self.classes = classes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(5 + classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(grabWindow); w.writeUInt32(time)
        w.writeUInt16(UInt16(classes.count))
        w.writeUInt8(thisDeviceMode); w.writeUInt8(otherDevicesMode)
        w.writeUInt8(ownerEvents ? 1 : 0); w.writeUInt8(deviceID); w.writePadding(2)
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGrabDevice {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let grabWindow = try r.readUInt32()
        let time = try r.readUInt32()
        let count = Int(try r.readUInt16())
        let thisMode = try r.readUInt8()
        let otherMode = try r.readUInt8()
        let owner = try r.readUInt8() != 0
        let deviceID = try r.readUInt8()
        try r.skip(2)
        var classes: [UInt32] = []
        classes.reserveCapacity(count)
        for _ in 0..<count { classes.append(try r.readUInt32()) }
        return XInputGrabDevice(
            grabWindow: grabWindow, time: time,
            thisDeviceMode: thisMode, otherDevicesMode: otherMode,
            ownerEvents: owner, deviceID: deviceID, classes: classes
        )
    }
}

// MARK: - XInputUngrabDevice (minor 14)

public struct XInputUngrabDevice: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.ungrabDevice
    public var time: UInt32
    public var deviceID: UInt8

    public init(time: UInt32, deviceID: UInt8) {
        self.time = time; self.deviceID = deviceID
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputUngrabDevice {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); try r.skip(3)
        return XInputUngrabDevice(time: time, deviceID: deviceID)
    }
}

// MARK: - XInputGrabDeviceKey (minor 15)

public struct XInputGrabDeviceKey: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.grabDeviceKey
    public var grabWindow: UInt32
    public var modifiers: UInt16
    public var modifierDevice: UInt8
    public var grabbedDevice: UInt8
    public var key: UInt8
    public var thisDeviceMode: UInt8
    public var otherDevicesMode: UInt8
    public var ownerEvents: Bool
    public var classes: [UInt32]

    public init(grabWindow: UInt32, modifiers: UInt16,
                modifierDevice: UInt8, grabbedDevice: UInt8,
                key: UInt8, thisDeviceMode: UInt8, otherDevicesMode: UInt8,
                ownerEvents: Bool, classes: [UInt32]) {
        self.grabWindow = grabWindow; self.modifiers = modifiers
        self.modifierDevice = modifierDevice
        self.grabbedDevice = grabbedDevice
        self.key = key
        self.thisDeviceMode = thisDeviceMode
        self.otherDevicesMode = otherDevicesMode
        self.ownerEvents = ownerEvents
        self.classes = classes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(5 + classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(grabWindow)
        w.writeUInt16(UInt16(classes.count))
        w.writeUInt16(modifiers)
        w.writeUInt8(modifierDevice); w.writeUInt8(grabbedDevice)
        w.writeUInt8(key)
        w.writeUInt8(thisDeviceMode); w.writeUInt8(otherDevicesMode)
        w.writeUInt8(ownerEvents ? 1 : 0); w.writePadding(2)
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGrabDeviceKey {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let grabWindow = try r.readUInt32()
        let count = Int(try r.readUInt16())
        let modifiers = try r.readUInt16()
        let modDev = try r.readUInt8()
        let grabbedDev = try r.readUInt8()
        let key = try r.readUInt8()
        let thisMode = try r.readUInt8()
        let otherMode = try r.readUInt8()
        let owner = try r.readUInt8() != 0
        try r.skip(2)
        var classes: [UInt32] = []
        classes.reserveCapacity(count)
        for _ in 0..<count { classes.append(try r.readUInt32()) }
        return XInputGrabDeviceKey(
            grabWindow: grabWindow, modifiers: modifiers,
            modifierDevice: modDev, grabbedDevice: grabbedDev,
            key: key,
            thisDeviceMode: thisMode, otherDevicesMode: otherMode,
            ownerEvents: owner, classes: classes
        )
    }
}

// MARK: - XInputUngrabDeviceKey (minor 16)

public struct XInputUngrabDeviceKey: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.ungrabDeviceKey
    public var grabWindow: UInt32
    public var modifiers: UInt16
    public var modifierDevice: UInt8
    public var key: UInt8
    public var grabbedDevice: UInt8

    public init(grabWindow: UInt32, modifiers: UInt16,
                modifierDevice: UInt8, key: UInt8, grabbedDevice: UInt8) {
        self.grabWindow = grabWindow; self.modifiers = modifiers
        self.modifierDevice = modifierDevice; self.key = key
        self.grabbedDevice = grabbedDevice
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(grabWindow)
        w.writeUInt16(modifiers)
        w.writeUInt8(modifierDevice); w.writeUInt8(key)
        w.writeUInt8(grabbedDevice); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputUngrabDeviceKey {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let grabWindow = try r.readUInt32()
        let modifiers = try r.readUInt16()
        let modDev = try r.readUInt8()
        let key = try r.readUInt8()
        let grabbedDev = try r.readUInt8()
        try r.skip(3)
        return XInputUngrabDeviceKey(
            grabWindow: grabWindow, modifiers: modifiers,
            modifierDevice: modDev, key: key, grabbedDevice: grabbedDev
        )
    }
}

// MARK: - XInputGrabDeviceButton (minor 17)

public struct XInputGrabDeviceButton: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.grabDeviceButton
    public var grabWindow: UInt32
    public var grabbedDevice: UInt8
    public var modifierDevice: UInt8
    public var modifiers: UInt16
    public var thisDeviceMode: UInt8
    public var otherDevicesMode: UInt8
    public var button: UInt8
    public var ownerEvents: Bool
    public var classes: [UInt32]

    public init(grabWindow: UInt32, grabbedDevice: UInt8,
                modifierDevice: UInt8, modifiers: UInt16,
                thisDeviceMode: UInt8, otherDevicesMode: UInt8,
                button: UInt8, ownerEvents: Bool,
                classes: [UInt32]) {
        self.grabWindow = grabWindow
        self.grabbedDevice = grabbedDevice
        self.modifierDevice = modifierDevice
        self.modifiers = modifiers
        self.thisDeviceMode = thisDeviceMode
        self.otherDevicesMode = otherDevicesMode
        self.button = button
        self.ownerEvents = ownerEvents
        self.classes = classes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(5 + classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(grabWindow)
        w.writeUInt8(grabbedDevice); w.writeUInt8(modifierDevice)
        w.writeUInt16(UInt16(classes.count))
        w.writeUInt16(modifiers)
        w.writeUInt8(thisDeviceMode); w.writeUInt8(otherDevicesMode)
        w.writeUInt8(button); w.writeUInt8(ownerEvents ? 1 : 0)
        w.writePadding(2)
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGrabDeviceButton {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let grabWindow = try r.readUInt32()
        let grabbedDev = try r.readUInt8()
        let modDev = try r.readUInt8()
        let count = Int(try r.readUInt16())
        let modifiers = try r.readUInt16()
        let thisMode = try r.readUInt8()
        let otherMode = try r.readUInt8()
        let button = try r.readUInt8()
        let owner = try r.readUInt8() != 0
        try r.skip(2)
        var classes: [UInt32] = []
        classes.reserveCapacity(count)
        for _ in 0..<count { classes.append(try r.readUInt32()) }
        return XInputGrabDeviceButton(
            grabWindow: grabWindow, grabbedDevice: grabbedDev,
            modifierDevice: modDev, modifiers: modifiers,
            thisDeviceMode: thisMode, otherDevicesMode: otherMode,
            button: button, ownerEvents: owner, classes: classes
        )
    }
}

// MARK: - XInputUngrabDeviceButton (minor 18)

public struct XInputUngrabDeviceButton: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.ungrabDeviceButton
    public var grabWindow: UInt32
    public var modifiers: UInt16
    public var modifierDevice: UInt8
    public var button: UInt8
    public var grabbedDevice: UInt8

    public init(grabWindow: UInt32, modifiers: UInt16,
                modifierDevice: UInt8, button: UInt8, grabbedDevice: UInt8) {
        self.grabWindow = grabWindow; self.modifiers = modifiers
        self.modifierDevice = modifierDevice; self.button = button
        self.grabbedDevice = grabbedDevice
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(grabWindow)
        w.writeUInt16(modifiers)
        w.writeUInt8(modifierDevice); w.writeUInt8(button)
        w.writeUInt8(grabbedDevice); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputUngrabDeviceButton {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let grabWindow = try r.readUInt32()
        let modifiers = try r.readUInt16()
        let modDev = try r.readUInt8()
        let button = try r.readUInt8()
        let grabbedDev = try r.readUInt8()
        try r.skip(3)
        return XInputUngrabDeviceButton(
            grabWindow: grabWindow, modifiers: modifiers,
            modifierDevice: modDev, button: button, grabbedDevice: grabbedDev
        )
    }
}

// MARK: - XInputAllowDeviceEvents (minor 19)

public struct XInputAllowDeviceEvents: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.allowDeviceEvents
    public var time: UInt32
    public var mode: UInt8
    public var deviceID: UInt8

    public init(time: UInt32, mode: UInt8, deviceID: UInt8) {
        self.time = time; self.mode = mode; self.deviceID = deviceID
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(time)
        w.writeUInt8(mode); w.writeUInt8(deviceID); w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputAllowDeviceEvents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let time = try r.readUInt32()
        let mode = try r.readUInt8(); let deviceID = try r.readUInt8(); try r.skip(2)
        return XInputAllowDeviceEvents(time: time, mode: mode, deviceID: deviceID)
    }
}

// MARK: - XInputGetDeviceFocus (minor 20)

public struct XInputGetDeviceFocus: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceFocus
    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceFocus {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8(); try r.skip(3)
        return XInputGetDeviceFocus(deviceID: deviceID)
    }
}

// MARK: - XInputSetDeviceFocus (minor 21)

public struct XInputSetDeviceFocus: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.setDeviceFocus
    public var focus: UInt32     // Window
    public var time: UInt32
    public var revertTo: UInt8
    public var deviceID: UInt8

    public init(focus: UInt32, time: UInt32, revertTo: UInt8, deviceID: UInt8) {
        self.focus = focus; self.time = time
        self.revertTo = revertTo; self.deviceID = deviceID
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(focus); w.writeUInt32(time)
        w.writeUInt8(revertTo); w.writeUInt8(deviceID); w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceFocus {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let focus = try r.readUInt32()
        let time = try r.readUInt32()
        let revertTo = try r.readUInt8(); let deviceID = try r.readUInt8()
        try r.skip(2)
        return XInputSetDeviceFocus(focus: focus, time: time,
                                    revertTo: revertTo, deviceID: deviceID)
    }
}

// MARK: - XInputGetFeedbackControl (minor 22)

public struct XInputGetFeedbackControl: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getFeedbackControl
    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetFeedbackControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8(); try r.skip(3)
        return XInputGetFeedbackControl(deviceID: deviceID)
    }
}

// MARK: - XInputChangeFeedbackControl (minor 23)

public struct XInputChangeFeedbackControl: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.changeFeedbackControl
    public var mask: UInt32
    public var deviceID: UInt8
    public var feedbackID: UInt8
    public var control: XInputFeedbackCtl

    public init(mask: UInt32, deviceID: UInt8, feedbackID: UInt8,
                control: XInputFeedbackCtl) {
        self.mask = mask; self.deviceID = deviceID
        self.feedbackID = feedbackID; self.control = control
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let ctlBytes = control.encode(byteOrder: byteOrder)
        let lenIn4 = UInt16(3 + ctlBytes.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(mask)
        w.writeUInt8(deviceID); w.writeUInt8(feedbackID); w.writePadding(2)
        w.writeBytes(ctlBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeFeedbackControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let mask = try r.readUInt32()
        let deviceID = try r.readUInt8()
        let feedbackID = try r.readUInt8()
        try r.skip(2)
        let ctlBytes = try r.readBytes((lenIn4 - 3) * 4)
        let control = try XInputFeedbackCtl.decode(from: ctlBytes, byteOrder: byteOrder)
        return XInputChangeFeedbackControl(
            mask: mask, deviceID: deviceID, feedbackID: feedbackID, control: control
        )
    }
}

// MARK: - XInputGetDeviceKeyMapping (minor 24)

public struct XInputGetDeviceKeyMapping: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceKeyMapping
    public var deviceID: UInt8
    public var firstKeyCode: UInt8
    public var count: UInt8

    public init(deviceID: UInt8, firstKeyCode: UInt8, count: UInt8) {
        self.deviceID = deviceID
        self.firstKeyCode = firstKeyCode
        self.count = count
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writeUInt8(firstKeyCode); w.writeUInt8(count); w.writePadding(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceKeyMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        let firstKeyCode = try r.readUInt8()
        let count = try r.readUInt8()
        try r.skip(1)
        return XInputGetDeviceKeyMapping(
            deviceID: deviceID, firstKeyCode: firstKeyCode, count: count
        )
    }
}

// MARK: - XInputChangeDeviceKeyMapping (minor 25)

public struct XInputChangeDeviceKeyMapping: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.changeDeviceKeyMapping
    public var deviceID: UInt8
    public var firstKeyCode: UInt8
    public var keySymsPerKeyCode: UInt8
    public var keyCodes: UInt8
    public var keysyms: [UInt32]

    public init(deviceID: UInt8, firstKeyCode: UInt8,
                keySymsPerKeyCode: UInt8, keyCodes: UInt8,
                keysyms: [UInt32]) {
        self.deviceID = deviceID
        self.firstKeyCode = firstKeyCode
        self.keySymsPerKeyCode = keySymsPerKeyCode
        self.keyCodes = keyCodes
        self.keysyms = keysyms
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + keysyms.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt8(deviceID); w.writeUInt8(firstKeyCode)
        w.writeUInt8(keySymsPerKeyCode); w.writeUInt8(keyCodes)
        for s in keysyms { w.writeUInt32(s) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeDeviceKeyMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceID = try r.readUInt8()
        let firstKeyCode = try r.readUInt8()
        let keySymsPerKeyCode = try r.readUInt8()
        let keyCodes = try r.readUInt8()
        var keysyms: [UInt32] = []
        let n = lenIn4 - 2
        keysyms.reserveCapacity(n)
        for _ in 0..<n { keysyms.append(try r.readUInt32()) }
        return XInputChangeDeviceKeyMapping(
            deviceID: deviceID, firstKeyCode: firstKeyCode,
            keySymsPerKeyCode: keySymsPerKeyCode, keyCodes: keyCodes,
            keysyms: keysyms
        )
    }
}

// MARK: - XInputGetDeviceModifierMapping (minor 26)

public struct XInputGetDeviceModifierMapping: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceModifierMapping
    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceModifierMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8(); try r.skip(3)
        return XInputGetDeviceModifierMapping(deviceID: deviceID)
    }
}

// MARK: - XInputSetDeviceModifierMapping (minor 27)

public struct XInputSetDeviceModifierMapping: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.setDeviceModifierMapping
    public var deviceID: UInt8
    public var numKeyPerModifier: UInt8
    public var keycodes: [UInt8]   // 8 * numKeyPerModifier

    public init(deviceID: UInt8, numKeyPerModifier: UInt8, keycodes: [UInt8]) {
        precondition(keycodes.count == 8 * Int(numKeyPerModifier),
                     "keycodes must be 8 × numKeyPerModifier")
        self.deviceID = deviceID
        self.numKeyPerModifier = numKeyPerModifier
        self.keycodes = keycodes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let n = keycodes.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt8(deviceID); w.writeUInt8(numKeyPerModifier); w.writePadding(2)
        w.writeBytes(keycodes)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceModifierMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        let per = try r.readUInt8()
        try r.skip(2)
        let keycodes = try r.readBytes(8 * Int(per))
        return XInputSetDeviceModifierMapping(
            deviceID: deviceID, numKeyPerModifier: per, keycodes: keycodes
        )
    }
}

// MARK: - XInputGetDeviceButtonMapping (minor 28)

public struct XInputGetDeviceButtonMapping: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceButtonMapping
    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceButtonMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8(); try r.skip(3)
        return XInputGetDeviceButtonMapping(deviceID: deviceID)
    }
}

// MARK: - XInputSetDeviceButtonMapping (minor 29)

public struct XInputSetDeviceButtonMapping: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.setDeviceButtonMapping
    public var deviceID: UInt8
    public var map: [UInt8]

    public init(deviceID: UInt8, map: [UInt8]) {
        self.deviceID = deviceID; self.map = map
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let n = map.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt8(deviceID); w.writeUInt8(UInt8(n)); w.writePadding(2)
        w.writeBytes(map)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceButtonMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        let mapLength = Int(try r.readUInt8())
        try r.skip(2)
        let map = try r.readBytes(mapLength)
        return XInputSetDeviceButtonMapping(deviceID: deviceID, map: map)
    }
}

// MARK: - XInputQueryDeviceState (minor 30)

public struct XInputQueryDeviceState: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.queryDeviceState
    public var deviceID: UInt8

    public init(deviceID: UInt8) { self.deviceID = deviceID }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputQueryDeviceState {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8(); try r.skip(3)
        return XInputQueryDeviceState(deviceID: deviceID)
    }
}

// MARK: - XInputSendExtensionEvent (minor 31)

public struct XInputSendExtensionEvent: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.sendExtensionEvent
    public var destination: UInt32
    public var deviceID: UInt8
    public var propagate: Bool
    /// Each event is exactly 32 bytes on the wire.
    public var events: [[UInt8]]
    public var classes: [UInt32]

    public init(destination: UInt32, deviceID: UInt8, propagate: Bool,
                events: [[UInt8]], classes: [UInt32]) {
        for e in events {
            precondition(e.count == 32, "each event must be 32 bytes")
        }
        self.destination = destination
        self.deviceID = deviceID
        self.propagate = propagate
        self.events = events
        self.classes = classes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        // length in 4-byte units = 3 (header) + events*8 + classes
        let lenIn4 = UInt16(3 + events.count * 8 + classes.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(destination)
        w.writeUInt8(deviceID); w.writeUInt8(propagate ? 1 : 0)
        w.writeUInt16(UInt16(classes.count))
        w.writeUInt8(UInt8(events.count)); w.writePadding(3)
        for e in events { w.writeBytes(e) }
        for c in classes { w.writeUInt32(c) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSendExtensionEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let destination = try r.readUInt32()
        let deviceID = try r.readUInt8()
        let propagate = try r.readUInt8() != 0
        let classCount = Int(try r.readUInt16())
        let numEvents = Int(try r.readUInt8())
        try r.skip(3)
        var events: [[UInt8]] = []
        events.reserveCapacity(numEvents)
        for _ in 0..<numEvents { events.append(try r.readBytes(32)) }
        var classes: [UInt32] = []
        classes.reserveCapacity(classCount)
        for _ in 0..<classCount { classes.append(try r.readUInt32()) }
        return XInputSendExtensionEvent(
            destination: destination, deviceID: deviceID, propagate: propagate,
            events: events, classes: classes
        )
    }
}

// MARK: - XInputDeviceBell (minor 32)

public struct XInputDeviceBell: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.deviceBell
    public var deviceID: UInt8
    public var feedbackID: UInt8
    public var feedbackClass: UInt8
    public var percent: Int8

    public init(deviceID: UInt8, feedbackID: UInt8, feedbackClass: UInt8, percent: Int8) {
        self.deviceID = deviceID; self.feedbackID = feedbackID
        self.feedbackClass = feedbackClass; self.percent = percent
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt8(deviceID); w.writeUInt8(feedbackID)
        w.writeUInt8(feedbackClass)
        w.writeUInt8(UInt8(bitPattern: percent))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputDeviceBell {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        let feedbackID = try r.readUInt8()
        let feedbackClass = try r.readUInt8()
        let percent = Int8(bitPattern: try r.readUInt8())
        return XInputDeviceBell(
            deviceID: deviceID, feedbackID: feedbackID,
            feedbackClass: feedbackClass, percent: percent
        )
    }
}

// MARK: - XInputSetDeviceValuators (minor 33)

public struct XInputSetDeviceValuators: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.setDeviceValuators
    public var deviceID: UInt8
    public var firstValuator: UInt8
    public var valuators: [Int32]    // numValuators = valuators.count

    public init(deviceID: UInt8, firstValuator: UInt8, valuators: [Int32]) {
        self.deviceID = deviceID
        self.firstValuator = firstValuator
        self.valuators = valuators
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + valuators.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt8(deviceID); w.writeUInt8(firstValuator)
        w.writeUInt8(UInt8(valuators.count)); w.writePadding(1)
        for v in valuators { w.writeUInt32(UInt32(bitPattern: v)) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputSetDeviceValuators {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceID = try r.readUInt8()
        let firstValuator = try r.readUInt8()
        let numValuators = Int(try r.readUInt8())
        try r.skip(1)
        var valuators: [Int32] = []
        valuators.reserveCapacity(numValuators)
        for _ in 0..<numValuators {
            valuators.append(Int32(bitPattern: try r.readUInt32()))
        }
        return XInputSetDeviceValuators(
            deviceID: deviceID, firstValuator: firstValuator, valuators: valuators
        )
    }
}

// MARK: - XInputGetDeviceControl (minor 34)

public struct XInputGetDeviceControl: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.getDeviceControl
    public var control: UInt16
    public var deviceID: UInt8

    public init(control: UInt16, deviceID: UInt8) {
        self.control = control; self.deviceID = deviceID
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt16(control)
        w.writeUInt8(deviceID); w.writePadding(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputGetDeviceControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let control = try r.readUInt16()
        let deviceID = try r.readUInt8()
        try r.skip(1)
        return XInputGetDeviceControl(control: control, deviceID: deviceID)
    }
}

// MARK: - XInputChangeDeviceControl (minor 35)

public struct XInputChangeDeviceControl: Equatable, Sendable {
    public static let minor: UInt8 = XInputMinor.changeDeviceControl
    public var control: UInt16
    public var deviceID: UInt8
    public var ctl: XInputDeviceCtl

    public init(control: UInt16, deviceID: UInt8, ctl: XInputDeviceCtl) {
        self.control = control; self.deviceID = deviceID; self.ctl = ctl
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let ctlBytes = ctl.encode(byteOrder: byteOrder)
        let lenIn4 = UInt16(2 + ctlBytes.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(control)
        w.writeUInt8(deviceID); w.writePadding(1)
        w.writeBytes(ctlBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XInputChangeDeviceControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let control = try r.readUInt16()
        let deviceID = try r.readUInt8()
        try r.skip(1)
        let ctlBytes = try r.readBytes((lenIn4 - 2) * 4)
        let ctl = try XInputDeviceCtl.decode(from: ctlBytes, byteOrder: byteOrder)
        return XInputChangeDeviceControl(control: control, deviceID: deviceID, ctl: ctl)
    }
}
