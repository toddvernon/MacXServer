// SelectionClear, SelectionRequest, SelectionNotify.

public struct SelectionClearEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var owner: UInt32
    public var selection: UInt32

    public init(sequenceNumber: UInt16, time: UInt32, owner: UInt32, selection: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.time = time
        self.owner = owner
        self.selection = selection
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(29); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(time); w.writeUInt32(owner); w.writeUInt32(selection)
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SelectionClearEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32(); let owner = try r.readUInt32(); let sel = try r.readUInt32()
        return SelectionClearEvent(sequenceNumber: seq, time: time, owner: owner, selection: sel)
    }
}

public struct SelectionRequestEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var owner: UInt32
    public var requestor: UInt32
    public var selection: UInt32
    public var target: UInt32
    public var property: UInt32

    public init(
        sequenceNumber: UInt16, time: UInt32,
        owner: UInt32, requestor: UInt32, selection: UInt32, target: UInt32, property: UInt32
    ) {
        self.sequenceNumber = sequenceNumber
        self.time = time
        self.owner = owner
        self.requestor = requestor
        self.selection = selection
        self.target = target
        self.property = property
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(30); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(time); w.writeUInt32(owner); w.writeUInt32(requestor)
        w.writeUInt32(selection); w.writeUInt32(target); w.writeUInt32(property)
        w.writePadding(4)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SelectionRequestEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32(); let owner = try r.readUInt32(); let requestor = try r.readUInt32()
        let sel = try r.readUInt32(); let target = try r.readUInt32(); let property = try r.readUInt32()
        return SelectionRequestEvent(
            sequenceNumber: seq, time: time,
            owner: owner, requestor: requestor, selection: sel, target: target, property: property
        )
    }
}

public struct SelectionNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var requestor: UInt32
    public var selection: UInt32
    public var target: UInt32
    public var property: UInt32             // 0 = None (rejected)

    public init(
        sequenceNumber: UInt16, time: UInt32,
        requestor: UInt32, selection: UInt32, target: UInt32, property: UInt32
    ) {
        self.sequenceNumber = sequenceNumber
        self.time = time
        self.requestor = requestor
        self.selection = selection
        self.target = target
        self.property = property
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(31); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(time); w.writeUInt32(requestor)
        w.writeUInt32(selection); w.writeUInt32(target); w.writeUInt32(property)
        w.writePadding(8)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SelectionNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32(); let requestor = try r.readUInt32()
        let sel = try r.readUInt32(); let target = try r.readUInt32(); let property = try r.readUInt32()
        return SelectionNotifyEvent(
            sequenceNumber: seq, time: time,
            requestor: requestor, selection: sel, target: target, property: property
        )
    }
}

// ClientMessage. The 20 trailing bytes' interpretation depends on `format`
// (8 = 20 bytes, 16 = 10 16-bit values, 32 = 5 32-bit values), so we keep them
// as raw bytes and let callers interpret.
public struct ClientMessageEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var format: PropertyFormat        // 8, 16, or 32
    public var window: UInt32
    public var type: UInt32
    public var data: [UInt8]                 // exactly 20 bytes

    public init(sequenceNumber: UInt16, format: PropertyFormat, window: UInt32, type: UInt32, data: [UInt8]) {
        precondition(data.count == 20, "ClientMessage data must be 20 bytes")
        self.sequenceNumber = sequenceNumber
        self.format = format
        self.window = window
        self.type = type
        self.data = data
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(33)
        w.writeUInt8(format.rawValue)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(window)
        w.writeUInt32(type)
        w.writeBytes(data)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ClientMessageEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let formatRaw = try r.readUInt8()
        guard let format = PropertyFormat(rawValue: formatRaw) else {
            throw FramerError.invalidEnum(name: "PropertyFormat", value: UInt32(formatRaw))
        }
        let seq = try r.readUInt16()
        let window = try r.readUInt32()
        let type = try r.readUInt32()
        let data = try r.readBytes(20)
        return ClientMessageEvent(sequenceNumber: seq, format: format, window: window, type: type, data: data)
    }
}
