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
