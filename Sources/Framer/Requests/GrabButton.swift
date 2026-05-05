public enum GrabMode: UInt8, Sendable {
    case synchronous = 0
    case asynchronous = 1
}

public struct GrabButton: Equatable, Sendable {
    public static let opcode: UInt8 = 28

    public var ownerEvents: Bool
    public var grabWindow: UInt32
    public var eventMask: UInt16
    public var pointerMode: GrabMode
    public var keyboardMode: GrabMode
    public var confineTo: UInt32        // 0 = None
    public var cursor: UInt32           // 0 = None
    public var button: UInt8            // 0 = AnyButton
    public var modifiers: UInt16        // 0x8000 = AnyModifier

    public init(
        ownerEvents: Bool,
        grabWindow: UInt32,
        eventMask: UInt16,
        pointerMode: GrabMode,
        keyboardMode: GrabMode,
        confineTo: UInt32 = 0,
        cursor: UInt32 = 0,
        button: UInt8 = 0,
        modifiers: UInt16
    ) {
        self.ownerEvents = ownerEvents
        self.grabWindow = grabWindow
        self.eventMask = eventMask
        self.pointerMode = pointerMode
        self.keyboardMode = keyboardMode
        self.confineTo = confineTo
        self.cursor = cursor
        self.button = button
        self.modifiers = modifiers
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(ownerEvents ? 1 : 0)
        w.writeUInt16(6)
        w.writeUInt32(grabWindow)
        w.writeUInt16(eventMask)
        w.writeUInt8(pointerMode.rawValue)
        w.writeUInt8(keyboardMode.rawValue)
        w.writeUInt32(confineTo)
        w.writeUInt32(cursor)
        w.writeUInt8(button)
        w.writeUInt8(0)
        w.writeUInt16(modifiers)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GrabButton {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let ownerEvents = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let grabWindow = try r.readUInt32()
        let eventMask = try r.readUInt16()
        let pmRaw = try r.readUInt8()
        let kmRaw = try r.readUInt8()
        guard let pm = GrabMode(rawValue: pmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(pmRaw))
        }
        guard let km = GrabMode(rawValue: kmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(kmRaw))
        }
        let confineTo = try r.readUInt32()
        let cursor = try r.readUInt32()
        let button = try r.readUInt8()
        _ = try r.readUInt8()
        let modifiers = try r.readUInt16()
        return GrabButton(
            ownerEvents: ownerEvents,
            grabWindow: grabWindow,
            eventMask: eventMask,
            pointerMode: pm,
            keyboardMode: km,
            confineTo: confineTo,
            cursor: cursor,
            button: button,
            modifiers: modifiers
        )
    }
}
