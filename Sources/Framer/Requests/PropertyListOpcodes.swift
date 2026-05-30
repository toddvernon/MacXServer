// Three small requests that operate over property lists or save-set state.
// Grouped because each is a few lines and they don't fit any other theme.

// MARK: - ChangeSaveSet (opcode 6)

/// xChangeSaveSetReq: opcode(1) + mode(1) + length(2=2) + window(4).
/// Mode is Insert(0) / Delete(1) per the X11 spec.
public struct ChangeSaveSet: Equatable, Sendable {
    public static let opcode: UInt8 = 6

    public enum Mode: UInt8, Sendable {
        case insert = 0
        case delete = 1
    }

    public var mode: Mode
    public var window: UInt32

    public init(mode: Mode, window: UInt32) {
        self.mode = mode
        self.window = window
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(mode.rawValue); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeSaveSet {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let modeRaw = try r.readUInt8()
        guard let mode = Mode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "ChangeSaveSet.Mode", value: UInt32(modeRaw))
        }
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        return ChangeSaveSet(mode: mode, window: window)
    }
}

// MARK: - ListProperties (opcode 21)

/// xResourceReq (window): opcode(1) + pad(1) + length(2=2) + window(4).
public struct ListProperties: Equatable, Sendable {
    public static let opcode: UInt8 = 21

    public var window: UInt32

    public init(window: UInt32) { self.window = window }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListProperties {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        return ListProperties(window: window)
    }
}

// MARK: - RotateProperties (opcode 114)

/// xRotatePropertiesReq: opcode(1) + pad(1) + length(2) + window(4) +
/// nAtoms(2) + delta(2, INT16). Then nAtoms ATOMs (4 bytes each).
public struct RotateProperties: Equatable, Sendable {
    public static let opcode: UInt8 = 114

    public var window: UInt32
    public var delta: Int16
    public var properties: [UInt32]

    public init(window: UInt32, delta: Int16, properties: [UInt32]) {
        self.window = window
        self.delta = delta
        self.properties = properties
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + properties.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(window)
        w.writeUInt16(UInt16(properties.count))
        w.writeUInt16(UInt16(bitPattern: delta))
        for a in properties { w.writeUInt32(a) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RotateProperties {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        let nAtoms = Int(try r.readUInt16())
        let delta = Int16(bitPattern: try r.readUInt16())
        var atoms: [UInt32] = []
        atoms.reserveCapacity(nAtoms)
        for _ in 0..<nAtoms { atoms.append(try r.readUInt32()) }
        return RotateProperties(window: window, delta: delta, properties: atoms)
    }
}
