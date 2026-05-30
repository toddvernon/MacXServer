// Keyboard mapping + control requests. Three opcodes that share a theme:
// they shape what keys mean and how the keyboard behaves.
//
// Wire formats per X11R6 Xproto.h.

// MARK: - ChangeKeyboardMapping (opcode 100)

/// Updates the mapping from keycodes to keysyms.
/// xChangeKeyboardMappingReq: opcode(1) + keyCodes(1) + length(2) +
/// firstKeyCode(1) + keySymsPerKeyCode(1) + pad(2). Then n*m KEYSYMs (4 bytes each).
public struct ChangeKeyboardMapping: Equatable, Sendable {
    public static let opcode: UInt8 = 100

    public var firstKeyCode: UInt8
    public var keysymsPerKeycode: UInt8
    public var keysyms: [UInt32]

    public init(firstKeyCode: UInt8, keysymsPerKeycode: UInt8, keysyms: [UInt32]) {
        precondition(keysymsPerKeycode > 0, "keysymsPerKeycode must be > 0")
        precondition(keysyms.count % Int(keysymsPerKeycode) == 0,
                     "keysyms count must be a multiple of keysymsPerKeycode")
        self.firstKeyCode = firstKeyCode
        self.keysymsPerKeycode = keysymsPerKeycode
        self.keysyms = keysyms
    }

    /// Number of keycodes this request rewrites (= keysyms.count / keysymsPerKeycode).
    public var keycodeCount: Int { keysyms.count / Int(keysymsPerKeycode) }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = UInt8(keycodeCount)
        let lenIn4 = UInt16(2 + keysyms.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(n); w.writeUInt16(lenIn4)
        w.writeUInt8(firstKeyCode); w.writeUInt8(keysymsPerKeycode); w.writePadding(2)
        for ks in keysyms { w.writeUInt32(ks) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeKeyboardMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let n = Int(try r.readUInt8())
        _ = try r.readUInt16()
        let firstKeyCode = try r.readUInt8()
        let keysymsPerKeycode = try r.readUInt8()
        try r.skip(2)
        var keysyms: [UInt32] = []
        keysyms.reserveCapacity(n * Int(keysymsPerKeycode))
        for _ in 0..<(n * Int(keysymsPerKeycode)) {
            keysyms.append(try r.readUInt32())
        }
        return ChangeKeyboardMapping(firstKeyCode: firstKeyCode,
                                     keysymsPerKeycode: keysymsPerKeycode,
                                     keysyms: keysyms)
    }
}

// MARK: - ChangeKeyboardControl (opcode 102)

/// Sets keyboard control parameters per the value-mask bits.
/// xChangeKeyboardControlReq: opcode(1) + pad(1) + length(2) + mask(4).
/// Then one CARD32-padded value per set bit (same pattern as ChangeGC).
public struct ChangeKeyboardControl: Equatable, Sendable {
    public static let opcode: UInt8 = 102

    public var valueMask: UInt32
    /// Raw value-list bytes. One 4-byte slot per set bit in valueMask, in
    /// ascending mask-bit order, low-byte/word holding the actual datum
    /// (INT8 / INT16 / CARD8 / KEYCODE / etc. per the spec).
    public var valueList: [UInt8]

    public init(valueMask: UInt32, valueList: [UInt8]) {
        precondition(valueList.count % 4 == 0, "valueList must be 4-byte aligned")
        precondition(valueList.count / 4 == valueMask.nonzeroBitCount,
                     "valueList size must match valueMask popcount")
        self.valueMask = valueMask
        self.valueList = valueList
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + valueList.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(valueMask)
        w.writeBytes(valueList)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeKeyboardControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let valueMask = try r.readUInt32()
        let valueList = try r.readBytes((lenIn4 - 2) * 4)
        return ChangeKeyboardControl(valueMask: valueMask, valueList: valueList)
    }
}

// MARK: - GetKeyboardControl (opcode 103)

/// Header-only request; the reply carries the keyboard state.
public struct GetKeyboardControl: Equatable, Sendable {
    public static let opcode: UInt8 = 103
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetKeyboardControl {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GetKeyboardControl()
    }
}
