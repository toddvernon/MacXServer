// CompatMap trailer payload — symbol-interpretation entries plus an
// optional group-compatibility array. Used by:
//   - XkbGetCompatMapReply: trailer is nSI × SymInterp records followed
//     by (if `XkbGroupCompatMask` bit in `groups`-style mask) a 4-entry
//     group-compat array (8 bytes total — 4 records × 2 bytes).
//   - XkbSetCompatMapReq:   same shape.
//
// Wire layouts from
// reference/X11R6/xc/include/extensions/XKBproto.h
// (xkbSymInterpretWireDesc + xkbModCompatWireDesc).

public struct XkbSymInterpret: Equatable, Sendable {
    public var sym: UInt32
    public var mods: UInt8
    public var match: UInt8
    public var virtualMod: UInt8
    public var flags: UInt8
    public var actionType: UInt8
    public var actionData: [UInt8]   // 7 bytes — embedded xkbActionWireDesc

    public init(sym: UInt32, mods: UInt8, match: UInt8,
                virtualMod: UInt8, flags: UInt8,
                actionType: UInt8, actionData: [UInt8]) {
        precondition(actionData.count == 7, "actionData must be 7 bytes")
        self.sym = sym; self.mods = mods; self.match = match
        self.virtualMod = virtualMod; self.flags = flags
        self.actionType = actionType; self.actionData = actionData
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt32(sym)
        w.writeUInt8(mods); w.writeUInt8(match)
        w.writeUInt8(virtualMod); w.writeUInt8(flags)
        w.writeUInt8(actionType); w.writeBytes(actionData)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSymInterpret {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let sym = try r.readUInt32()
        let mods = try r.readUInt8()
        let match = try r.readUInt8()
        let virtualMod = try r.readUInt8()
        let flags = try r.readUInt8()
        let actionType = try r.readUInt8()
        let actionData = try r.readBytes(7)
        return XkbSymInterpret(
            sym: sym, mods: mods, match: match,
            virtualMod: virtualMod, flags: flags,
            actionType: actionType, actionData: actionData
        )
    }
}

public struct XkbModCompat: Equatable, Sendable {
    public var mods: UInt8
    public var groups: UInt8

    public init(mods: UInt8, groups: UInt8) {
        self.mods = mods; self.groups = groups
    }
}

public struct XkbCompatPayload: Equatable, Sendable {
    public var symInterprets: [XkbSymInterpret]
    /// When non-empty, exactly 4 entries (one per group). Present iff
    /// the surrounding request/reply asked for group compat.
    public var groupCompat: [XkbModCompat]

    public init(symInterprets: [XkbSymInterpret] = [],
                groupCompat: [XkbModCompat] = []) {
        precondition(groupCompat.isEmpty || groupCompat.count == 4,
                     "groupCompat must be either empty or exactly 4 entries")
        self.symInterprets = symInterprets
        self.groupCompat = groupCompat
    }

    public static let empty = XkbCompatPayload()

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        for si in symInterprets {
            w.writeBytes(si.encode(byteOrder: byteOrder))
        }
        for gc in groupCompat {
            w.writeUInt8(gc.mods); w.writeUInt8(gc.groups)
        }
        // Group-compat is 4 records × 2 bytes = 8 bytes, already aligned.
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], nSymInterprets: Int,
                              includeGroupCompat: Bool,
                              byteOrder: ByteOrder) throws -> XkbCompatPayload {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        var symInterprets: [XkbSymInterpret] = []
        symInterprets.reserveCapacity(nSymInterprets)
        for _ in 0..<nSymInterprets {
            let sym = try r.readUInt32()
            let mods = try r.readUInt8()
            let match = try r.readUInt8()
            let virtualMod = try r.readUInt8()
            let flags = try r.readUInt8()
            let actionType = try r.readUInt8()
            let actionData = try r.readBytes(7)
            symInterprets.append(XkbSymInterpret(
                sym: sym, mods: mods, match: match,
                virtualMod: virtualMod, flags: flags,
                actionType: actionType, actionData: actionData
            ))
        }
        var groupCompat: [XkbModCompat] = []
        if includeGroupCompat {
            groupCompat.reserveCapacity(4)
            for _ in 0..<4 {
                let mods = try r.readUInt8()
                let groups = try r.readUInt8()
                groupCompat.append(XkbModCompat(mods: mods, groups: groups))
            }
        }
        return XkbCompatPayload(symInterprets: symInterprets, groupCompat: groupCompat)
    }
}
