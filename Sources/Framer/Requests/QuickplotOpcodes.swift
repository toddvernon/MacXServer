// Opcodes surfaced by the quickplot Motif capture: lots of clip-rectangle
// fiddling for rubberband drawing, dashed lines, sent events, key grabs, etc.

public enum ClipOrdering: UInt8, Sendable {
    case unsorted = 0
    case ySorted = 1
    case yxSorted = 2
    case yxBanded = 3
}

public struct SetClipRectangles: Equatable, Sendable {
    public static let opcode: UInt8 = 59
    public var ordering: ClipOrdering
    public var gc: UInt32
    public var clipXOrigin: Int16
    public var clipYOrigin: Int16
    public var rectangles: [Rectangle]

    public init(ordering: ClipOrdering, gc: UInt32, clipXOrigin: Int16, clipYOrigin: Int16, rectangles: [Rectangle]) {
        self.ordering = ordering
        self.gc = gc
        self.clipXOrigin = clipXOrigin
        self.clipYOrigin = clipYOrigin
        self.rectangles = rectangles
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + 2 * rectangles.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(ordering.rawValue)
        w.writeUInt16(lenIn4)
        w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: clipXOrigin))
        w.writeUInt16(UInt16(bitPattern: clipYOrigin))
        for r in rectangles { r.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetClipRectangles {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let ordRaw = try r.readUInt8()
        guard let ordering = ClipOrdering(rawValue: ordRaw) else {
            throw FramerError.invalidEnum(name: "ClipOrdering", value: UInt32(ordRaw))
        }
        let lenIn4 = Int(try r.readUInt16())
        let gc = try r.readUInt32()
        let cx = Int16(bitPattern: try r.readUInt16())
        let cy = Int16(bitPattern: try r.readUInt16())
        let n = (lenIn4 - 3) / 2
        var rects: [Rectangle] = []
        rects.reserveCapacity(n)
        for _ in 0..<n {
            rects.append(try Rectangle.decode(from: &r))
        }
        return SetClipRectangles(ordering: ordering, gc: gc, clipXOrigin: cx, clipYOrigin: cy, rectangles: rects)
    }
}

public struct SetDashes: Equatable, Sendable {
    public static let opcode: UInt8 = 58
    public var gc: UInt32
    public var dashOffset: Int16
    public var dashes: [UInt8]

    public init(gc: UInt32, dashOffset: Int16, dashes: [UInt8]) {
        self.gc = gc
        self.dashOffset = dashOffset
        self.dashes = dashes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = dashes.count
        let p = xPad(n)
        let lenIn4 = UInt16(3 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: dashOffset))
        w.writeUInt16(UInt16(n))
        w.writeBytes(dashes)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetDashes {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let gc = try r.readUInt32()
        let off = Int16(bitPattern: try r.readUInt16())
        let n = Int(try r.readUInt16())
        let dashes = try r.readBytes(n)
        try r.skip(xPad(n))
        return SetDashes(gc: gc, dashOffset: off, dashes: dashes)
    }
}

public struct PolyRectangle: Equatable, Sendable {
    public static let opcode: UInt8 = 67
    public var drawable: UInt32
    public var gc: UInt32
    public var rectangles: [Rectangle]

    public init(drawable: UInt32, gc: UInt32, rectangles: [Rectangle]) {
        self.drawable = drawable
        self.gc = gc
        self.rectangles = rectangles
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + 2 * rectangles.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        for r in rectangles { r.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyRectangle {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let n = (lenIn4 - 3) / 2
        var rects: [Rectangle] = []
        rects.reserveCapacity(n)
        for _ in 0..<n {
            rects.append(try Rectangle.decode(from: &r))
        }
        return PolyRectangle(drawable: drawable, gc: gc, rectangles: rects)
    }
}

public struct LookupColor: Equatable, Sendable {
    public static let opcode: UInt8 = 92
    public var cmap: UInt32
    public var name: [UInt8]

    public init(cmap: UInt32, name: [UInt8]) {
        self.cmap = cmap
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let lenIn4 = UInt16(3 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(cmap)
        w.writeUInt16(UInt16(n)); w.writeUInt16(0)
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> LookupColor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return LookupColor(cmap: cmap, name: name)
    }
}

public struct SendEvent: Equatable, Sendable {
    public static let opcode: UInt8 = 25
    public var propagate: Bool
    public var destination: UInt32        // window, or 0=PointerWindow, 1=InputFocus
    public var eventMask: UInt32
    public var event: [UInt8]             // exactly 32 bytes — the synthetic event being sent

    public init(propagate: Bool, destination: UInt32, eventMask: UInt32, event: [UInt8]) {
        precondition(event.count == 32, "SendEvent payload must be 32 bytes")
        self.propagate = propagate
        self.destination = destination
        self.eventMask = eventMask
        self.event = event
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(propagate ? 1 : 0)
        w.writeUInt16(11)
        w.writeUInt32(destination)
        w.writeUInt32(eventMask)
        w.writeBytes(event)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SendEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let prop = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let dest = try r.readUInt32()
        let mask = try r.readUInt32()
        let event = try r.readBytes(32)
        return SendEvent(propagate: prop, destination: dest, eventMask: mask, event: event)
    }
}

public struct GrabKey: Equatable, Sendable {
    public static let opcode: UInt8 = 33
    public var ownerEvents: Bool
    public var grabWindow: UInt32
    public var modifiers: UInt16
    public var key: UInt8                 // 0 = AnyKey
    public var pointerMode: GrabMode
    public var keyboardMode: GrabMode

    public init(
        ownerEvents: Bool, grabWindow: UInt32, modifiers: UInt16, key: UInt8,
        pointerMode: GrabMode, keyboardMode: GrabMode
    ) {
        self.ownerEvents = ownerEvents
        self.grabWindow = grabWindow
        self.modifiers = modifiers
        self.key = key
        self.pointerMode = pointerMode
        self.keyboardMode = keyboardMode
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(ownerEvents ? 1 : 0)
        w.writeUInt16(4)
        w.writeUInt32(grabWindow)
        w.writeUInt16(modifiers)
        w.writeUInt8(key)
        w.writeUInt8(pointerMode.rawValue)
        w.writeUInt8(keyboardMode.rawValue)
        w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GrabKey {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let oe = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let mod = try r.readUInt16()
        let key = try r.readUInt8()
        let pmRaw = try r.readUInt8()
        let kmRaw = try r.readUInt8()
        try r.skip(3)
        guard let pm = GrabMode(rawValue: pmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(pmRaw))
        }
        guard let km = GrabMode(rawValue: kmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(kmRaw))
        }
        return GrabKey(
            ownerEvents: oe, grabWindow: win, modifiers: mod, key: key,
            pointerMode: pm, keyboardMode: km
        )
    }
}

public struct ListFonts: Equatable, Sendable {
    public static let opcode: UInt8 = 49
    public var maxNames: UInt16
    public var pattern: [UInt8]

    public init(maxNames: UInt16, pattern: [UInt8]) {
        self.maxNames = maxNames
        self.pattern = pattern
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = pattern.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt16(maxNames)
        w.writeUInt16(UInt16(n))
        w.writeBytes(pattern)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListFonts {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let max = try r.readUInt16()
        let n = Int(try r.readUInt16())
        let pat = try r.readBytes(n)
        try r.skip(xPad(n))
        return ListFonts(maxNames: max, pattern: pat)
    }
}

public struct ListFontsWithInfo: Equatable, Sendable {
    public static let opcode: UInt8 = 50
    public var maxNames: UInt16
    public var pattern: [UInt8]

    public init(maxNames: UInt16, pattern: [UInt8]) {
        self.maxNames = maxNames
        self.pattern = pattern
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = pattern.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt16(maxNames)
        w.writeUInt16(UInt16(n))
        w.writeBytes(pattern)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListFontsWithInfo {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let max = try r.readUInt16()
        let n = Int(try r.readUInt16())
        let pat = try r.readBytes(n)
        try r.skip(xPad(n))
        return ListFontsWithInfo(maxNames: max, pattern: pat)
    }
}

public enum BestSizeClass: UInt8, Sendable {
    case cursor = 0
    case tile = 1
    case stipple = 2
}

public struct QueryBestSize: Equatable, Sendable {
    public static let opcode: UInt8 = 97
    public var sizeClass: BestSizeClass
    public var drawable: UInt32
    public var width: UInt16
    public var height: UInt16

    public init(sizeClass: BestSizeClass, drawable: UInt32, width: UInt16, height: UInt16) {
        self.sizeClass = sizeClass
        self.drawable = drawable
        self.width = width
        self.height = height
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(sizeClass.rawValue)
        w.writeUInt16(3)
        w.writeUInt32(drawable)
        w.writeUInt16(width)
        w.writeUInt16(height)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryBestSize {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let scRaw = try r.readUInt8()
        guard let sc = BestSizeClass(rawValue: scRaw) else {
            throw FramerError.invalidEnum(name: "BestSizeClass", value: UInt32(scRaw))
        }
        _ = try r.readUInt16()
        let drawable = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return QueryBestSize(sizeClass: sc, drawable: drawable, width: width, height: height)
    }
}
