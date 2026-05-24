// ListFontsWithInfo reply layout (X11 spec section 9, "List Fonts with Info"):
//
// The server sends ONE reply per matching font name, followed by a final
// reply with name-length = 0 to mark the end of the batch. Each reply
// looks like:
//
//   1 byte:    marker (1)
//   1 byte:    name length n (0 means "this is the terminator")
//   2 bytes:   sequence number
//   4 bytes:   additional length in 4-byte units = 7 + 2m + (n+p)/4
//  12 bytes:   minBounds CHARINFO
//   4 bytes:   unused
//  12 bytes:   maxBounds CHARINFO
//   4 bytes:   unused
//   2 bytes:   minCharOrByte2
//   2 bytes:   maxCharOrByte2
//   2 bytes:   defaultChar
//   2 bytes:   number of FONTPROPs (m)
//   1 byte:    drawDirection
//   1 byte:    minByte1
//   1 byte:    maxByte1
//   1 byte:    allCharsExist
//   2 bytes:   fontAscent
//   2 bytes:   fontDescent
//   4 bytes:   replies-hint (the count of replies still to come; may be 0)
//  8m bytes:   FONTPROP entries
//   n bytes:   font name
//   p bytes:   pad to 4-byte boundary
//
// Differences from QueryFontReply: byte 1 carries `n` (not unused), the
// 4-byte slot before the FONTPROP array carries `replies-hint` (not the
// CharInfo count), there's no per-glyph CharInfo array, and the trailing
// data is the font name + padding.
//
// The terminator reply (sent after the last match) has n=0 and zero
// bounds/properties. lenIn4 = 7 (total reply size 60 bytes, all zeros
// after the header).

public struct ListFontsWithInfoReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var name: [UInt8]              // empty = terminator
    public var minBounds: CharInfo
    public var maxBounds: CharInfo
    public var minCharOrByte2: UInt16
    public var maxCharOrByte2: UInt16
    public var defaultChar: UInt16
    public var drawDirection: DrawDirection
    public var minByte1: UInt8
    public var maxByte1: UInt8
    public var allCharsExist: Bool
    public var fontAscent: Int16
    public var fontDescent: Int16
    public var repliesHint: UInt32
    public var properties: [FontProp]

    public init(
        sequenceNumber: UInt16,
        name: [UInt8],
        minBounds: CharInfo, maxBounds: CharInfo,
        minCharOrByte2: UInt16, maxCharOrByte2: UInt16, defaultChar: UInt16,
        drawDirection: DrawDirection,
        minByte1: UInt8, maxByte1: UInt8, allCharsExist: Bool,
        fontAscent: Int16, fontDescent: Int16,
        repliesHint: UInt32,
        properties: [FontProp]
    ) {
        precondition(name.count <= 255, "name must fit in CARD8 length")
        self.sequenceNumber = sequenceNumber
        self.name = name
        self.minBounds = minBounds
        self.maxBounds = maxBounds
        self.minCharOrByte2 = minCharOrByte2
        self.maxCharOrByte2 = maxCharOrByte2
        self.defaultChar = defaultChar
        self.drawDirection = drawDirection
        self.minByte1 = minByte1
        self.maxByte1 = maxByte1
        self.allCharsExist = allCharsExist
        self.fontAscent = fontAscent
        self.fontDescent = fontDescent
        self.repliesHint = repliesHint
        self.properties = properties
    }

    /// Build a zero-filled terminator (name-length = 0) signalling
    /// "no more replies in this batch."
    public static func terminator(sequenceNumber: UInt16) -> ListFontsWithInfoReply {
        let zero = CharInfo(leftSideBearing: 0, rightSideBearing: 0,
                            characterWidth: 0, ascent: 0, descent: 0,
                            attributes: 0)
        return ListFontsWithInfoReply(
            sequenceNumber: sequenceNumber,
            name: [],
            minBounds: zero, maxBounds: zero,
            minCharOrByte2: 0, maxCharOrByte2: 0, defaultChar: 0,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0, allCharsExist: false,
            fontAscent: 0, fontDescent: 0,
            repliesHint: 0,
            properties: []
        )
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let m = properties.count
        let lenIn4 = UInt32(7 + 2 * m + (n + p) / 4)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)                              // reply marker
        w.writeUInt8(UInt8(n))                       // name length (0 = terminator)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        minBounds.encode(into: &w)
        w.writePadding(4)
        maxBounds.encode(into: &w)
        w.writePadding(4)
        w.writeUInt16(minCharOrByte2)
        w.writeUInt16(maxCharOrByte2)
        w.writeUInt16(defaultChar)
        w.writeUInt16(UInt16(m))
        w.writeUInt8(drawDirection.rawValue)
        w.writeUInt8(minByte1)
        w.writeUInt8(maxByte1)
        w.writeUInt8(allCharsExist ? 1 : 0)
        w.writeUInt16(UInt16(bitPattern: fontAscent))
        w.writeUInt16(UInt16(bitPattern: fontDescent))
        w.writeUInt32(repliesHint)
        for prop in properties { prop.encode(into: &w) }
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListFontsWithInfoReply {
        guard bytes.count >= 60 else {
            throw FramerError.truncated(needed: 60, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()                         // marker
        let n = Int(try r.readUInt8())                // name length
        let seq = try r.readUInt16()
        _ = try r.readUInt32()                        // lenIn4, derivable
        let minBounds = try CharInfo.decode(from: &r)
        try r.skip(4)
        let maxBounds = try CharInfo.decode(from: &r)
        try r.skip(4)
        let minCh = try r.readUInt16()
        let maxCh = try r.readUInt16()
        let defaultChar = try r.readUInt16()
        let m = Int(try r.readUInt16())
        let drawDirRaw = try r.readUInt8()
        guard let drawDir = DrawDirection(rawValue: drawDirRaw) else {
            throw FramerError.invalidEnum(name: "DrawDirection", value: UInt32(drawDirRaw))
        }
        let minByte1 = try r.readUInt8()
        let maxByte1 = try r.readUInt8()
        let allCharsExist = (try r.readUInt8()) != 0
        let fontAscent = Int16(bitPattern: try r.readUInt16())
        let fontDescent = Int16(bitPattern: try r.readUInt16())
        let repliesHint = try r.readUInt32()

        var properties: [FontProp] = []
        properties.reserveCapacity(m)
        for _ in 0..<m {
            properties.append(try FontProp.decode(from: &r))
        }
        let name = try r.readBytes(n)
        try r.skip(xPad(n))

        return ListFontsWithInfoReply(
            sequenceNumber: seq,
            name: name,
            minBounds: minBounds, maxBounds: maxBounds,
            minCharOrByte2: minCh, maxCharOrByte2: maxCh, defaultChar: defaultChar,
            drawDirection: drawDir,
            minByte1: minByte1, maxByte1: maxByte1, allCharsExist: allCharsExist,
            fontAscent: fontAscent, fontDescent: fontDescent,
            repliesHint: repliesHint,
            properties: properties
        )
    }
}
