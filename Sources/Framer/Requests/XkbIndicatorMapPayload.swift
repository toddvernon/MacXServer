// XkbIndicatorMapWireDesc — the per-indicator 12-byte record that
// appears as a flat array trailer in:
//   - XkbGetIndicatorMapReply (count = nIndicators)
//   - XkbSetIndicatorMapReq    (count = popcount of `which` mask)
//
// Wire layout from
// reference/X11R6/xc/include/extensions/XKBproto.h:
//   CARD8  flags
//   CARD8  whichGroups
//   CARD8  groups
//   CARD8  whichMods
//   CARD8  mods
//   CARD8  realMods
//   CARD16 virtualMods
//   CARD32 ctrls

public struct XkbIndicatorMapEntry: Equatable, Sendable {
    public var flags: UInt8
    public var whichGroups: UInt8
    public var groups: UInt8
    public var whichMods: UInt8
    public var mods: UInt8
    public var realMods: UInt8
    public var virtualMods: UInt16
    public var ctrls: UInt32

    public init(flags: UInt8, whichGroups: UInt8, groups: UInt8,
                whichMods: UInt8, mods: UInt8, realMods: UInt8,
                virtualMods: UInt16, ctrls: UInt32) {
        self.flags = flags
        self.whichGroups = whichGroups
        self.groups = groups
        self.whichMods = whichMods
        self.mods = mods
        self.realMods = realMods
        self.virtualMods = virtualMods
        self.ctrls = ctrls
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(flags); w.writeUInt8(whichGroups); w.writeUInt8(groups)
        w.writeUInt8(whichMods); w.writeUInt8(mods); w.writeUInt8(realMods)
        w.writeUInt16(virtualMods)
        w.writeUInt32(ctrls)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbIndicatorMapEntry {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let flags = try r.readUInt8()
        let whichGroups = try r.readUInt8()
        let groups = try r.readUInt8()
        let whichMods = try r.readUInt8()
        let mods = try r.readUInt8()
        let realMods = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let ctrls = try r.readUInt32()
        return XkbIndicatorMapEntry(
            flags: flags, whichGroups: whichGroups, groups: groups,
            whichMods: whichMods, mods: mods, realMods: realMods,
            virtualMods: virtualMods, ctrls: ctrls
        )
    }
}

/// Helper: pack/unpack a list of XkbIndicatorMapEntry as a 12n-byte
/// trailer. Both GetIndicatorMap and SetIndicatorMap use this shape.
public enum XkbIndicatorMapList {
    public static func encode(_ entries: [XkbIndicatorMapEntry], byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        for e in entries {
            w.writeBytes(e.encode(byteOrder: byteOrder))
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], count: Int, byteOrder: ByteOrder) throws -> [XkbIndicatorMapEntry] {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        var entries: [XkbIndicatorMapEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let flags = try r.readUInt8()
            let whichGroups = try r.readUInt8()
            let groups = try r.readUInt8()
            let whichMods = try r.readUInt8()
            let mods = try r.readUInt8()
            let realMods = try r.readUInt8()
            let virtualMods = try r.readUInt16()
            let ctrls = try r.readUInt32()
            entries.append(XkbIndicatorMapEntry(
                flags: flags, whichGroups: whichGroups, groups: groups,
                whichMods: whichMods, mods: mods, realMods: realMods,
                virtualMods: virtualMods, ctrls: ctrls
            ))
        }
        return entries
    }
}
