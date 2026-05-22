// GetImage reply layout (X11 spec section 9, X_GetImage):
//
//   1 byte:   marker (1)
//   1 byte:   depth (drawable depth as the server advertises it)
//   2 bytes:  sequence number
//   4 bytes:  reply length = (imageData.count + 3) / 4
//   4 bytes:  visual ID (None=0 for pixmap source)
//  20 bytes:  pad
//   N bytes:  imageData (must be padded to a 4-byte boundary)
//
// imageData layout depends on the request format:
//
// ZPixmap: pixels in image-byte-order, bits-per-pixel-for-depth packed per
// pixel, each scanline padded out to the advertised scanline-pad. For our
// PseudoColor 8-bit visual that's 1 byte per pixel, scanlines padded to a
// 4-byte boundary.
//
// XYPixmap: one bitmap plane per set bit in planeMask, MSB plane first.
// Each plane is `depth` bits per pixel stored as separate bitmap planes —
// 1 bit per pixel, packed MSB-first within bytes, scanlines padded to
// bitmap-scanline-pad (32 bits in our setup).

public struct GetImageReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var depth: UInt8
    public var visual: UInt32
    public var imageData: [UInt8]

    public init(sequenceNumber: UInt16, depth: UInt8, visual: UInt32, imageData: [UInt8]) {
        self.sequenceNumber = sequenceNumber
        self.depth = depth
        self.visual = visual
        self.imageData = imageData
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let padCount = (4 - imageData.count % 4) % 4
        let paddedLen = imageData.count + padCount
        let lenIn4 = UInt32(paddedLen / 4)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(depth)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(visual)
        w.writePadding(20)
        w.writeBytes(imageData)
        w.writePadding(padCount)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetImageReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let depth = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = try r.readUInt32()
        let visual = try r.readUInt32()
        try r.skip(20)
        let bodyLen = Int(lenIn4) * 4
        guard bytes.count >= 32 + bodyLen else {
            throw FramerError.truncated(needed: 32 + bodyLen, available: bytes.count)
        }
        let data = try r.readBytes(bodyLen)
        return GetImageReply(sequenceNumber: seq, depth: depth, visual: visual, imageData: data)
    }
}
