// Colormap-related opcodes 78-90 (minus AllocColor=84 / AllocNamedColor=85
// / AllocColorCells=86 which are elsewhere). Wire layouts from
// `reference/X11R6/xc/include/Xproto.h`. Added 2026-05-15 to close the
// "falls through to BadRequest" gap surfaced by the comparison study:
// Xt's color-allocation paths catch BadAlloc / BadAccess / BadColor and
// degrade gracefully; the prior BadRequest just got logged as "server is
// broken." Per-handler semantics live in ServerSession; here we just do
// the wire encode/decode.

public struct CreateColormap: Equatable, Sendable {
    public static let opcode: UInt8 = 78
    public var alloc: UInt8                // 0 None, 1 All
    public var mid: UInt32
    public var window: UInt32
    public var visual: UInt32

    public init(alloc: UInt8, mid: UInt32, window: UInt32, visual: UInt32) {
        self.alloc = alloc; self.mid = mid; self.window = window; self.visual = visual
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(alloc); w.writeUInt16(4)
        w.writeUInt32(mid); w.writeUInt32(window); w.writeUInt32(visual)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CreateColormap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let alloc = try r.readUInt8()
        _ = try r.readUInt16()
        let mid = try r.readUInt32()
        let window = try r.readUInt32()
        let visual = try r.readUInt32()
        return CreateColormap(alloc: alloc, mid: mid, window: window, visual: visual)
    }
}

public struct FreeColormap: Equatable, Sendable {
    public static let opcode: UInt8 = 79
    public var cmap: UInt32

    public init(cmap: UInt32) { self.cmap = cmap }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(2)
        w.writeUInt32(cmap)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FreeColormap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8(); _ = try r.readUInt16()
        return FreeColormap(cmap: try r.readUInt32())
    }
}

public struct CopyColormapAndFree: Equatable, Sendable {
    public static let opcode: UInt8 = 80
    public var mid: UInt32
    public var srcCmap: UInt32

    public init(mid: UInt32, srcCmap: UInt32) { self.mid = mid; self.srcCmap = srcCmap }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(3)
        w.writeUInt32(mid); w.writeUInt32(srcCmap)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CopyColormapAndFree {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8(); _ = try r.readUInt16()
        return CopyColormapAndFree(mid: try r.readUInt32(), srcCmap: try r.readUInt32())
    }
}

public struct InstallColormap: Equatable, Sendable {
    public static let opcode: UInt8 = 81
    public var cmap: UInt32

    public init(cmap: UInt32) { self.cmap = cmap }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(2)
        w.writeUInt32(cmap)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> InstallColormap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8(); _ = try r.readUInt16()
        return InstallColormap(cmap: try r.readUInt32())
    }
}

public struct UninstallColormap: Equatable, Sendable {
    public static let opcode: UInt8 = 82
    public var cmap: UInt32

    public init(cmap: UInt32) { self.cmap = cmap }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(2)
        w.writeUInt32(cmap)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UninstallColormap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8(); _ = try r.readUInt16()
        return UninstallColormap(cmap: try r.readUInt32())
    }
}

public struct ListInstalledColormaps: Equatable, Sendable {
    public static let opcode: UInt8 = 83
    public var window: UInt32

    public init(window: UInt32) { self.window = window }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListInstalledColormaps {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8(); _ = try r.readUInt16()
        return ListInstalledColormaps(window: try r.readUInt32())
    }
}

public struct AllocColorPlanes: Equatable, Sendable {
    public static let opcode: UInt8 = 87
    public var contiguous: Bool
    public var cmap: UInt32
    public var colors: UInt16
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(contiguous: Bool, cmap: UInt32, colors: UInt16, red: UInt16, green: UInt16, blue: UInt16) {
        self.contiguous = contiguous; self.cmap = cmap
        self.colors = colors; self.red = red; self.green = green; self.blue = blue
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(contiguous ? 1 : 0); w.writeUInt16(4)
        w.writeUInt32(cmap)
        w.writeUInt16(colors); w.writeUInt16(red); w.writeUInt16(green); w.writeUInt16(blue)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocColorPlanes {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let contig = try r.readUInt8() != 0
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        return AllocColorPlanes(
            contiguous: contig, cmap: cmap,
            colors: try r.readUInt16(), red: try r.readUInt16(),
            green: try r.readUInt16(), blue: try r.readUInt16()
        )
    }
}

public struct FreeColors: Equatable, Sendable {
    public static let opcode: UInt8 = 88
    public var cmap: UInt32
    public var planeMask: UInt32
    public var pixels: [UInt32]

    public init(cmap: UInt32, planeMask: UInt32, pixels: [UInt32]) {
        self.cmap = cmap; self.planeMask = planeMask; self.pixels = pixels
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + pixels.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(cmap); w.writeUInt32(planeMask)
        for p in pixels { w.writeUInt32(p) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FreeColors {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let cmap = try r.readUInt32()
        let planeMask = try r.readUInt32()
        var pixels: [UInt32] = []
        let pixelCount = max(0, lenIn4 - 3)
        pixels.reserveCapacity(pixelCount)
        for _ in 0..<pixelCount {
            pixels.append(try r.readUInt32())
        }
        return FreeColors(cmap: cmap, planeMask: planeMask, pixels: pixels)
    }
}

public struct StoreColors: Equatable, Sendable {
    public static let opcode: UInt8 = 89
    public var cmap: UInt32
    // Each item on the wire is 12 bytes: pixel(4) + r/g/b(6) + flags(1) + pad(1).
    // We keep the raw item bytes since we never honor a StoreColors request
    // (server is TrueColor-backed; the handler emits BadAccess). Preserved
    // for round-trip-decode-then-re-encode tests.
    public var rawItems: [UInt8]

    public init(cmap: UInt32, rawItems: [UInt8]) {
        self.cmap = cmap; self.rawItems = rawItems
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + rawItems.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(cmap)
        w.writeBytes(rawItems)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> StoreColors {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let cmap = try r.readUInt32()
        let itemBytes = max(0, (lenIn4 - 2) * 4)
        let raw = try r.readBytes(itemBytes)
        return StoreColors(cmap: cmap, rawItems: raw)
    }
}

public struct StoreNamedColor: Equatable, Sendable {
    public static let opcode: UInt8 = 90
    public var flags: UInt8                // DoRed | DoGreen | DoBlue
    public var cmap: UInt32
    public var pixel: UInt32
    public var name: [UInt8]

    public init(flags: UInt8, cmap: UInt32, pixel: UInt32, name: [UInt8]) {
        self.flags = flags; self.cmap = cmap; self.pixel = pixel; self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let pad = xPad(n)
        let lenIn4 = UInt16(4 + (n + pad) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(flags); w.writeUInt16(lenIn4)
        w.writeUInt32(cmap); w.writeUInt32(pixel)
        w.writeUInt16(UInt16(n)); w.writeUInt16(0)
        w.writeBytes(name); w.writePadding(pad)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> StoreNamedColor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let flags = try r.readUInt8()
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        let pixel = try r.readUInt32()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return StoreNamedColor(flags: flags, cmap: cmap, pixel: pixel, name: name)
    }
}
