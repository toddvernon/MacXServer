public struct Segment: Equatable, Sendable {
    public var x1: Int16
    public var y1: Int16
    public var x2: Int16
    public var y2: Int16

    public init(x1: Int16, y1: Int16, x2: Int16, y2: Int16) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt16(UInt16(bitPattern: x1))
        writer.writeUInt16(UInt16(bitPattern: y1))
        writer.writeUInt16(UInt16(bitPattern: x2))
        writer.writeUInt16(UInt16(bitPattern: y2))
    }

    static func decode(from reader: inout ByteReader) throws -> Segment {
        let x1 = Int16(bitPattern: try reader.readUInt16())
        let y1 = Int16(bitPattern: try reader.readUInt16())
        let x2 = Int16(bitPattern: try reader.readUInt16())
        let y2 = Int16(bitPattern: try reader.readUInt16())
        return Segment(x1: x1, y1: y1, x2: x2, y2: y2)
    }
}

public struct Arc: Equatable, Sendable {
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var angle1: Int16          // angles are in 64ths of a degree
    public var angle2: Int16

    public init(x: Int16, y: Int16, width: UInt16, height: UInt16, angle1: Int16, angle2: Int16) {
        self.x = x; self.y = y
        self.width = width; self.height = height
        self.angle1 = angle1; self.angle2 = angle2
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt16(UInt16(bitPattern: x))
        writer.writeUInt16(UInt16(bitPattern: y))
        writer.writeUInt16(width)
        writer.writeUInt16(height)
        writer.writeUInt16(UInt16(bitPattern: angle1))
        writer.writeUInt16(UInt16(bitPattern: angle2))
    }

    static func decode(from reader: inout ByteReader) throws -> Arc {
        let x = Int16(bitPattern: try reader.readUInt16())
        let y = Int16(bitPattern: try reader.readUInt16())
        let w = try reader.readUInt16()
        let h = try reader.readUInt16()
        let a1 = Int16(bitPattern: try reader.readUInt16())
        let a2 = Int16(bitPattern: try reader.readUInt16())
        return Arc(x: x, y: y, width: w, height: h, angle1: a1, angle2: a2)
    }
}

public struct Point: Equatable, Sendable {
    public var x: Int16
    public var y: Int16

    public init(x: Int16, y: Int16) {
        self.x = x
        self.y = y
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt16(UInt16(bitPattern: x))
        writer.writeUInt16(UInt16(bitPattern: y))
    }

    static func decode(from reader: inout ByteReader) throws -> Point {
        let x = Int16(bitPattern: try reader.readUInt16())
        let y = Int16(bitPattern: try reader.readUInt16())
        return Point(x: x, y: y)
    }
}

public struct Rectangle: Equatable, Sendable {
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16

    public init(x: Int16, y: Int16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt16(UInt16(bitPattern: x))
        writer.writeUInt16(UInt16(bitPattern: y))
        writer.writeUInt16(width)
        writer.writeUInt16(height)
    }

    static func decode(from reader: inout ByteReader) throws -> Rectangle {
        let x = Int16(bitPattern: try reader.readUInt16())
        let y = Int16(bitPattern: try reader.readUInt16())
        let w = try reader.readUInt16()
        let h = try reader.readUInt16()
        return Rectangle(x: x, y: y, width: w, height: h)
    }
}
