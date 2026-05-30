// XKEYBOARD map-payload codec — the nested-list trailer that GetMap
// reply and SetMap request share.
//
// Phase 3 XKB Session 2 (2026-05-30). The trailer has six optional
// sections, written in fixed order:
//
//   1. KeyTypes        — array of KeyType, each with embedded MapEntry
//                         array and (optionally) Preserve array
//   2. KeySyms         — array of SymMap, each with embedded keysym list
//   3. KeyActions      — per-key action-count byte array, padded, then a
//                         flat action-record array
//   4. KeyBehaviors    — flat array of BehaviorWireDesc
//   5. VirtualMods     — one byte per set bit in `virtualMods`, padded
//   6. ExplicitComponents — array of (key, explicit-bits) pairs, padded
//
// Gating differs by direction:
//   - GetMap reply: section X is present iff its count in the reply
//     header is > 0.
//   - SetMap request: section X is present iff `present & maskX` is set,
//     where the counts in the header tell how to walk it.
//
// Either way, the count-driven walker is the same. The XkbMapPayload
// codec takes counts as parameters (the header fields). Caller decides
// which sections to include; the codec writes/reads accordingly.

// MARK: - Inner record types

public struct XkbKTMapEntry: Equatable, Sendable {
    public var active: Bool
    public var mask: UInt8
    public var level: UInt8
    public var realMods: UInt8
    public var virtualMods: UInt16

    public init(active: Bool, mask: UInt8, level: UInt8,
                realMods: UInt8, virtualMods: UInt16) {
        self.active = active; self.mask = mask; self.level = level
        self.realMods = realMods; self.virtualMods = virtualMods
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt8(active ? 1 : 0)
        w.writeUInt8(mask); w.writeUInt8(level); w.writeUInt8(realMods)
        w.writeUInt16(virtualMods); w.writePadding(2)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> XkbKTMapEntry {
        let active = try r.readUInt8() != 0
        let mask = try r.readUInt8()
        let level = try r.readUInt8()
        let realMods = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        try r.skip(2)
        return XkbKTMapEntry(active: active, mask: mask, level: level,
                             realMods: realMods, virtualMods: virtualMods)
    }
}

public struct XkbKTPreserveEntry: Equatable, Sendable {
    public var mask: UInt8
    public var realMods: UInt8
    public var virtualMods: UInt16

    public init(mask: UInt8, realMods: UInt8, virtualMods: UInt16) {
        self.mask = mask; self.realMods = realMods; self.virtualMods = virtualMods
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt8(mask); w.writeUInt8(realMods); w.writeUInt16(virtualMods)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> XkbKTPreserveEntry {
        let mask = try r.readUInt8()
        let realMods = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        return XkbKTPreserveEntry(mask: mask, realMods: realMods, virtualMods: virtualMods)
    }
}

public struct XkbKeyType: Equatable, Sendable {
    public var mask: UInt8
    public var realMods: UInt8
    public var virtualMods: UInt16
    public var groupWidth: UInt8
    public var mapEntries: [XkbKTMapEntry]
    /// If non-empty, `preserves.count == mapEntries.count`. Sent on the
    /// wire as an additional array after the map entries. The "preserve"
    /// bool in the wire header is true iff this array is non-empty.
    public var preserves: [XkbKTPreserveEntry]

    public init(mask: UInt8, realMods: UInt8, virtualMods: UInt16,
                groupWidth: UInt8,
                mapEntries: [XkbKTMapEntry],
                preserves: [XkbKTPreserveEntry] = []) {
        precondition(preserves.isEmpty || preserves.count == mapEntries.count,
                     "preserves must be either empty or match mapEntries.count")
        self.mask = mask; self.realMods = realMods; self.virtualMods = virtualMods
        self.groupWidth = groupWidth
        self.mapEntries = mapEntries
        self.preserves = preserves
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt8(mask); w.writeUInt8(realMods); w.writeUInt16(virtualMods)
        w.writeUInt8(groupWidth); w.writeUInt8(UInt8(mapEntries.count))
        w.writeUInt8(preserves.isEmpty ? 0 : 1)   // preserve flag
        w.writePadding(1)
        for e in mapEntries { e.write(into: &w) }
        for p in preserves  { p.write(into: &w) }
    }

    fileprivate static func read(from r: inout ByteReader) throws -> XkbKeyType {
        let mask = try r.readUInt8()
        let realMods = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let groupWidth = try r.readUInt8()
        let nMapEntries = Int(try r.readUInt8())
        let preserve = try r.readUInt8() != 0
        try r.skip(1)
        var entries: [XkbKTMapEntry] = []
        entries.reserveCapacity(nMapEntries)
        for _ in 0..<nMapEntries { entries.append(try XkbKTMapEntry.read(from: &r)) }
        var preserves: [XkbKTPreserveEntry] = []
        if preserve {
            preserves.reserveCapacity(nMapEntries)
            for _ in 0..<nMapEntries { preserves.append(try XkbKTPreserveEntry.read(from: &r)) }
        }
        return XkbKeyType(mask: mask, realMods: realMods, virtualMods: virtualMods,
                          groupWidth: groupWidth, mapEntries: entries,
                          preserves: preserves)
    }
}

public struct XkbSymMap: Equatable, Sendable {
    public var ktIndex: UInt8
    public var groupInfo: UInt8
    public var syms: [UInt32]   // nSyms = syms.count on the wire

    public init(ktIndex: UInt8, groupInfo: UInt8, syms: [UInt32]) {
        self.ktIndex = ktIndex; self.groupInfo = groupInfo; self.syms = syms
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt8(ktIndex); w.writeUInt8(groupInfo)
        w.writeUInt16(UInt16(syms.count))
        for s in syms { w.writeUInt32(s) }
    }

    fileprivate static func read(from r: inout ByteReader) throws -> XkbSymMap {
        let ktIndex = try r.readUInt8()
        let groupInfo = try r.readUInt8()
        let nSyms = Int(try r.readUInt16())
        var syms: [UInt32] = []
        syms.reserveCapacity(nSyms)
        for _ in 0..<nSyms { syms.append(try r.readUInt32()) }
        return XkbSymMap(ktIndex: ktIndex, groupInfo: groupInfo, syms: syms)
    }
}

public struct XkbAction: Equatable, Sendable {
    public var type: UInt8
    public var data: [UInt8]    // exactly 7 bytes

    public init(type: UInt8, data: [UInt8]) {
        precondition(data.count == 7, "XkbAction data must be 7 bytes")
        self.type = type; self.data = data
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt8(type); w.writeBytes(data)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> XkbAction {
        let type = try r.readUInt8()
        let data = try r.readBytes(7)
        return XkbAction(type: type, data: data)
    }
}

public struct XkbBehavior: Equatable, Sendable {
    public var key: UInt8
    public var type: UInt8
    public var data: UInt8

    public init(key: UInt8, type: UInt8, data: UInt8) {
        self.key = key; self.type = type; self.data = data
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt8(key); w.writeUInt8(type); w.writeUInt8(data); w.writePadding(1)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> XkbBehavior {
        let key = try r.readUInt8()
        let type = try r.readUInt8()
        let data = try r.readUInt8()
        try r.skip(1)
        return XkbBehavior(key: key, type: type, data: data)
    }
}

public struct XkbExplicit: Equatable, Sendable {
    public var key: UInt8
    public var explicit: UInt8

    public init(key: UInt8, explicit: UInt8) {
        self.key = key; self.explicit = explicit
    }
}

// MARK: - The full payload

/// All six sections of the GetMap/SetMap trailer. Each section is
/// independently present/absent; an empty array means "section absent."
/// Encoding lays them out in fixed order with the right inter-section
/// padding. Decoding walks the trailer by counts supplied by the caller
/// (which match the header fields of the surrounding request/reply).
public struct XkbMapPayload: Equatable, Sendable {
    public var keyTypes: [XkbKeyType]
    public var keySyms: [XkbSymMap]
    /// Per-key action counts (length = nKeyActions in the header). Zero
    /// means no actions for that key.
    public var actionsPerKey: [UInt8]
    /// Flat action list. `actions.count == sum(actionsPerKey)`.
    public var actions: [XkbAction]
    public var behaviors: [XkbBehavior]
    /// One byte per set bit in the surrounding `virtualMods` bitmap,
    /// in bit-order (bit 0 first).
    public var virtualMods: [UInt8]
    public var explicits: [XkbExplicit]

    public init(keyTypes: [XkbKeyType] = [],
                keySyms: [XkbSymMap] = [],
                actionsPerKey: [UInt8] = [],
                actions: [XkbAction] = [],
                behaviors: [XkbBehavior] = [],
                virtualMods: [UInt8] = [],
                explicits: [XkbExplicit] = []) {
        self.keyTypes = keyTypes
        self.keySyms = keySyms
        self.actionsPerKey = actionsPerKey
        self.actions = actions
        self.behaviors = behaviors
        self.virtualMods = virtualMods
        self.explicits = explicits
    }

    public static let empty = XkbMapPayload()

    public var isEmpty: Bool {
        keyTypes.isEmpty && keySyms.isEmpty && actionsPerKey.isEmpty
            && actions.isEmpty && behaviors.isEmpty
            && virtualMods.isEmpty && explicits.isEmpty
    }

    /// Encode the trailer payload. Section order matches the wire
    /// format used by both GetMap reply and SetMap request.
    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)

        // KeyTypes section
        for t in keyTypes { t.write(into: &w) }
        // (key types are intrinsically 4-byte aligned: 8B header + 8B
        // entries + 4B preserves all align cleanly.)

        // KeySyms section
        for s in keySyms { s.write(into: &w) }
        // (sym maps: 4B header + 4B keysyms — already aligned.)

        // KeyActions section: per-key counts (padded to 4) + flat actions
        if !actionsPerKey.isEmpty {
            w.writeBytes(actionsPerKey)
            w.writePadding(xPad(actionsPerKey.count))
            for a in actions { a.write(into: &w) }
        }

        // KeyBehaviors section
        for b in behaviors { b.write(into: &w) }

        // VirtualMods section: 1 byte per entry, padded to 4
        if !virtualMods.isEmpty {
            w.writeBytes(virtualMods)
            w.writePadding(xPad(virtualMods.count))
        }

        // ExplicitComponents section: 2 bytes per entry (key + flags),
        // padded to 4
        if !explicits.isEmpty {
            for e in explicits {
                w.writeUInt8(e.key); w.writeUInt8(e.explicit)
            }
            w.writePadding(xPad(explicits.count * 2))
        }

        return w.bytes
    }

    /// Decode a trailer payload. Counts come from the surrounding
    /// header (XkbGetMapReply or XkbSetMap). `virtualModsBitmap` is the
    /// 16-bit field; the number of bytes in the section equals its
    /// popcount.
    public static func decode(
        from bytes: [UInt8],
        nTypes: UInt8,
        nKeySyms: UInt8,
        nKeyActions: UInt8,
        totalKeyBehaviors: UInt8,
        virtualModsBitmap: UInt16,
        totalKeyExplicit: UInt8,
        byteOrder: ByteOrder
    ) throws -> XkbMapPayload {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)

        var keyTypes: [XkbKeyType] = []
        keyTypes.reserveCapacity(Int(nTypes))
        for _ in 0..<Int(nTypes) {
            keyTypes.append(try XkbKeyType.read(from: &r))
        }

        var keySyms: [XkbSymMap] = []
        keySyms.reserveCapacity(Int(nKeySyms))
        for _ in 0..<Int(nKeySyms) {
            keySyms.append(try XkbSymMap.read(from: &r))
        }

        var actionsPerKey: [UInt8] = []
        var actions: [XkbAction] = []
        if nKeyActions > 0 {
            actionsPerKey = try r.readBytes(Int(nKeyActions))
            try r.skip(xPad(Int(nKeyActions)))
            let totalActions = actionsPerKey.reduce(0) { $0 + Int($1) }
            actions.reserveCapacity(totalActions)
            for _ in 0..<totalActions {
                actions.append(try XkbAction.read(from: &r))
            }
        }

        var behaviors: [XkbBehavior] = []
        behaviors.reserveCapacity(Int(totalKeyBehaviors))
        for _ in 0..<Int(totalKeyBehaviors) {
            behaviors.append(try XkbBehavior.read(from: &r))
        }

        var virtualMods: [UInt8] = []
        let vmodsCount = virtualModsBitmap.nonzeroBitCount
        if vmodsCount > 0 {
            virtualMods = try r.readBytes(vmodsCount)
            try r.skip(xPad(vmodsCount))
        }

        var explicits: [XkbExplicit] = []
        if totalKeyExplicit > 0 {
            explicits.reserveCapacity(Int(totalKeyExplicit))
            for _ in 0..<Int(totalKeyExplicit) {
                let key = try r.readUInt8()
                let exp = try r.readUInt8()
                explicits.append(XkbExplicit(key: key, explicit: exp))
            }
            try r.skip(xPad(Int(totalKeyExplicit) * 2))
        }

        return XkbMapPayload(
            keyTypes: keyTypes, keySyms: keySyms,
            actionsPerKey: actionsPerKey, actions: actions,
            behaviors: behaviors,
            virtualMods: virtualMods,
            explicits: explicits
        )
    }
}
