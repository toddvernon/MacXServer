public struct PixmapFormat: Equatable, Sendable {
    public var depth: UInt8
    public var bitsPerPixel: UInt8
    public var scanlinePad: UInt8

    public init(depth: UInt8, bitsPerPixel: UInt8, scanlinePad: UInt8) {
        self.depth = depth
        self.bitsPerPixel = bitsPerPixel
        self.scanlinePad = scanlinePad
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt8(depth)
        writer.writeUInt8(bitsPerPixel)
        writer.writeUInt8(scanlinePad)
        writer.writePadding(5)
    }

    static func decode(from reader: inout ByteReader) throws -> PixmapFormat {
        let depth = try reader.readUInt8()
        let bpp = try reader.readUInt8()
        let pad = try reader.readUInt8()
        try reader.skip(5)
        return PixmapFormat(depth: depth, bitsPerPixel: bpp, scanlinePad: pad)
    }
}
