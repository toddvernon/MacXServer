// Pointer + modifier mapping/control requests. Four opcodes covering
// pointer acceleration, button mapping, and modifier-key assignment.
//
// Wire formats per X11R6 Xproto.h.

// MARK: - ChangePointerControl (opcode 105)

/// xChangePointerControlReq: opcode(1) + pad(1) + length(2=3) +
/// accelNum(2) + accelDen(2) + threshold(2) + doAccel(1) + doThresh(1).
/// The accel/threshold fields are signed (INT16); a value of -1 with
/// the corresponding do-bit set means "default".
public struct ChangePointerControl: Equatable, Sendable {
    public static let opcode: UInt8 = 105

    public var accelerationNumerator: Int16
    public var accelerationDenominator: Int16
    public var threshold: Int16
    public var doAcceleration: Bool
    public var doThreshold: Bool

    public init(accelerationNumerator: Int16, accelerationDenominator: Int16,
                threshold: Int16, doAcceleration: Bool, doThreshold: Bool) {
        self.accelerationNumerator = accelerationNumerator
        self.accelerationDenominator = accelerationDenominator
        self.threshold = threshold
        self.doAcceleration = doAcceleration
        self.doThreshold = doThreshold
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(3)
        w.writeUInt16(UInt16(bitPattern: accelerationNumerator))
        w.writeUInt16(UInt16(bitPattern: accelerationDenominator))
        w.writeUInt16(UInt16(bitPattern: threshold))
        w.writeUInt8(doAcceleration ? 1 : 0)
        w.writeUInt8(doThreshold ? 1 : 0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangePointerControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let accelNum = Int16(bitPattern: try r.readUInt16())
        let accelDen = Int16(bitPattern: try r.readUInt16())
        let threshold = Int16(bitPattern: try r.readUInt16())
        let doAccel = try r.readUInt8() != 0
        let doThresh = try r.readUInt8() != 0
        return ChangePointerControl(accelerationNumerator: accelNum,
                                    accelerationDenominator: accelDen,
                                    threshold: threshold,
                                    doAcceleration: doAccel,
                                    doThreshold: doThresh)
    }
}

// MARK: - GetPointerControl (opcode 106)

public struct GetPointerControl: Equatable, Sendable {
    public static let opcode: UInt8 = 106
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetPointerControl {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GetPointerControl()
    }
}

// MARK: - SetPointerMapping (opcode 116)

/// xSetPointerMappingReq: opcode(1) + nElts(1) + length(2) + n CARD8s + pad.
/// `map` is a LISTofCARD8 — physical-button-N → logical-button mapping.
public struct SetPointerMapping: Equatable, Sendable {
    public static let opcode: UInt8 = 116

    public var map: [UInt8]

    public init(map: [UInt8]) { self.map = map }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = map.count
        let p = xPad(n)
        let lenIn4 = UInt16(1 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(UInt8(n)); w.writeUInt16(lenIn4)
        w.writeBytes(map)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetPointerMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let n = Int(try r.readUInt8())
        _ = try r.readUInt16()
        let map = try r.readBytes(n)
        return SetPointerMapping(map: map)
    }
}

// MARK: - SetModifierMapping (opcode 118)

/// xSetModifierMappingReq: opcode(1) + numKeyPerModifier(1) + length(2).
/// Then 8 × numKeyPerModifier KEYCODEs (1 byte each) + pad to 4. There are
/// always exactly 8 modifier slots in X11 (Shift, Lock, Control, Mod1-Mod5).
public struct SetModifierMapping: Equatable, Sendable {
    public static let opcode: UInt8 = 118

    public var keycodesPerModifier: UInt8
    public var keycodes: [UInt8]   // length = 8 * keycodesPerModifier

    public init(keycodesPerModifier: UInt8, keycodes: [UInt8]) {
        precondition(keycodes.count == 8 * Int(keycodesPerModifier),
                     "keycodes must hold 8 * keycodesPerModifier entries")
        self.keycodesPerModifier = keycodesPerModifier
        self.keycodes = keycodes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = keycodes.count
        let p = xPad(n)
        let lenIn4 = UInt16(1 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(keycodesPerModifier); w.writeUInt16(lenIn4)
        w.writeBytes(keycodes)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetModifierMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let perMod = try r.readUInt8()
        _ = try r.readUInt16()
        let keycodes = try r.readBytes(8 * Int(perMod))
        return SetModifierMapping(keycodesPerModifier: perMod, keycodes: keycodes)
    }
}
