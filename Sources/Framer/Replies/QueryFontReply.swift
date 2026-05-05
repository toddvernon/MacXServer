// QueryFont reply layout (X11 spec section 7.5):
//
//   8 bytes:   standard reply header (marker=1, draw-direction byte, sequence,
//              additional-length-in-4-byte-units)
//  12 bytes:   minBounds CHARINFO
//   4 bytes:   unused
//  12 bytes:   maxBounds CHARINFO
//   4 bytes:   unused
//   2 bytes:   minCharOrByte2
//   2 bytes:   maxCharOrByte2
//   2 bytes:   defaultChar
//   2 bytes:   number of FONTPROPs (n)
//   1 byte:    drawDirection
//   1 byte:    minByte1
//   1 byte:    maxByte1
//   1 byte:    allCharsExist
//   2 bytes:   fontAscent
//   2 bytes:   fontDescent
//   4 bytes:   number of CHARINFOs (m)
//  8n bytes:   FONTPROP entries (atom + value)
// 12m bytes:   CHARINFO entries (per-glyph metrics)
//
// Total fixed = 60 bytes; reply-length-in-4-byte-units = 7 + 2n + 3m.

public struct CharInfo: Equatable, Sendable {
    public var leftSideBearing: Int16
    public var rightSideBearing: Int16
    public var characterWidth: Int16
    public var ascent: Int16
    public var descent: Int16
    public var attributes: UInt16

    public init(
        leftSideBearing: Int16, rightSideBearing: Int16,
        characterWidth: Int16, ascent: Int16, descent: Int16, attributes: UInt16
    ) {
        self.leftSideBearing = leftSideBearing
        self.rightSideBearing = rightSideBearing
        self.characterWidth = characterWidth
        self.ascent = ascent
        self.descent = descent
        self.attributes = attributes
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt16(UInt16(bitPattern: leftSideBearing))
        writer.writeUInt16(UInt16(bitPattern: rightSideBearing))
        writer.writeUInt16(UInt16(bitPattern: characterWidth))
        writer.writeUInt16(UInt16(bitPattern: ascent))
        writer.writeUInt16(UInt16(bitPattern: descent))
        writer.writeUInt16(attributes)
    }

    static func decode(from reader: inout ByteReader) throws -> CharInfo {
        let lsb = Int16(bitPattern: try reader.readUInt16())
        let rsb = Int16(bitPattern: try reader.readUInt16())
        let cw = Int16(bitPattern: try reader.readUInt16())
        let asc = Int16(bitPattern: try reader.readUInt16())
        let desc = Int16(bitPattern: try reader.readUInt16())
        let attrs = try reader.readUInt16()
        return CharInfo(
            leftSideBearing: lsb, rightSideBearing: rsb,
            characterWidth: cw, ascent: asc, descent: desc, attributes: attrs
        )
    }
}

public struct FontProp: Equatable, Sendable {
    public var name: UInt32           // ATOM
    public var value: UInt32          // interpretation depends on the property; sometimes ATOM, sometimes CARD32

    public init(name: UInt32, value: UInt32) {
        self.name = name
        self.value = value
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt32(name)
        writer.writeUInt32(value)
    }

    static func decode(from reader: inout ByteReader) throws -> FontProp {
        let name = try reader.readUInt32()
        let value = try reader.readUInt32()
        return FontProp(name: name, value: value)
    }
}

public enum DrawDirection: UInt8, Sendable {
    case leftToRight = 0
    case rightToLeft = 1
}

public struct QueryFontReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
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
    public var properties: [FontProp]
    public var charInfos: [CharInfo]

    public init(
        sequenceNumber: UInt16,
        minBounds: CharInfo, maxBounds: CharInfo,
        minCharOrByte2: UInt16, maxCharOrByte2: UInt16, defaultChar: UInt16,
        drawDirection: DrawDirection,
        minByte1: UInt8, maxByte1: UInt8, allCharsExist: Bool,
        fontAscent: Int16, fontDescent: Int16,
        properties: [FontProp], charInfos: [CharInfo]
    ) {
        self.sequenceNumber = sequenceNumber
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
        self.properties = properties
        self.charInfos = charInfos
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = properties.count
        let m = charInfos.count
        let lenIn4 = UInt32(7 + 2 * n + 3 * m)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)                       // unused (the dataByte slot; QueryFont doesn't use it)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        minBounds.encode(into: &w)
        w.writePadding(4)
        maxBounds.encode(into: &w)
        w.writePadding(4)
        w.writeUInt16(minCharOrByte2)
        w.writeUInt16(maxCharOrByte2)
        w.writeUInt16(defaultChar)
        w.writeUInt16(UInt16(n))
        w.writeUInt8(drawDirection.rawValue)
        w.writeUInt8(minByte1)
        w.writeUInt8(maxByte1)
        w.writeUInt8(allCharsExist ? 1 : 0)
        w.writeUInt16(UInt16(bitPattern: fontAscent))
        w.writeUInt16(UInt16(bitPattern: fontDescent))
        w.writeUInt32(UInt32(m))
        for p in properties { p.encode(into: &w) }
        for c in charInfos { c.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryFontReply {
        guard bytes.count >= 60 else {
            throw FramerError.truncated(needed: 60, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()                // length, derivable
        let minBounds = try CharInfo.decode(from: &r)
        try r.skip(4)
        let maxBounds = try CharInfo.decode(from: &r)
        try r.skip(4)
        let minCh = try r.readUInt16()
        let maxCh = try r.readUInt16()
        let defaultChar = try r.readUInt16()
        let n = Int(try r.readUInt16())
        let drawDirRaw = try r.readUInt8()
        guard let drawDir = DrawDirection(rawValue: drawDirRaw) else {
            throw FramerError.invalidEnum(name: "DrawDirection", value: UInt32(drawDirRaw))
        }
        let minByte1 = try r.readUInt8()
        let maxByte1 = try r.readUInt8()
        let allCharsExist = (try r.readUInt8()) != 0
        let fontAscent = Int16(bitPattern: try r.readUInt16())
        let fontDescent = Int16(bitPattern: try r.readUInt16())
        let m = Int(try r.readUInt32())

        var properties: [FontProp] = []
        properties.reserveCapacity(n)
        for _ in 0..<n {
            properties.append(try FontProp.decode(from: &r))
        }
        var charInfos: [CharInfo] = []
        charInfos.reserveCapacity(m)
        for _ in 0..<m {
            charInfos.append(try CharInfo.decode(from: &r))
        }

        return QueryFontReply(
            sequenceNumber: seq,
            minBounds: minBounds, maxBounds: maxBounds,
            minCharOrByte2: minCh, maxCharOrByte2: maxCh, defaultChar: defaultChar,
            drawDirection: drawDir,
            minByte1: minByte1, maxByte1: maxByte1, allCharsExist: allCharsExist,
            fontAscent: fontAscent, fontDescent: fontDescent,
            properties: properties, charInfos: charInfos
        )
    }
}
