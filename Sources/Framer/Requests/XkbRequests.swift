// XKEYBOARD (XKB) extension Tier-A request wire types.
//
// Phase 3 Session 1 (2026-05-30) lands the 7 requests every modern
// Xlib client emits during keyboard initialization, plus the events
// they subscribe to. Tier B (SetMap, Set* mirrors, GetCompatMap,
// LatchLockState, Bell, SendEvent, GetIndicatorState) and Tier C
// (Geometry, AlternateSyms, SetDebuggingFlags) come in later sessions.
//
// Wire layouts verified against
// reference/X11R6/xc/include/extensions/XKBproto.h and XKB.h.

public enum XkbMinor {
    public static let useExtension: UInt8 = 0
    public static let selectEvents: UInt8 = 1
    public static let sendEvent: UInt8 = 2
    public static let bell: UInt8 = 3
    public static let getState: UInt8 = 4
    public static let latchLockState: UInt8 = 5
    public static let getControls: UInt8 = 6
    public static let setControls: UInt8 = 7
    public static let getMap: UInt8 = 8
    public static let setMap: UInt8 = 9
    public static let getCompatMap: UInt8 = 10
    public static let setCompatMap: UInt8 = 11
    public static let getIndicatorState: UInt8 = 12
    public static let getIndicatorMap: UInt8 = 13
    public static let setIndicatorMap: UInt8 = 14
    public static let getNames: UInt8 = 15
    public static let setNames: UInt8 = 16
    public static let listAlternateSyms: UInt8 = 17
    public static let getAlternateSyms: UInt8 = 18
    public static let setAlternateSyms: UInt8 = 19
    public static let getGeometry: UInt8 = 20
    public static let setGeometry: UInt8 = 21
    public static let setDebuggingFlags: UInt8 = 101
}

// MARK: - XkbUseExtension (minor 0)

public struct XkbUseExtension: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.useExtension

    public var wantedMajor: UInt16
    public var wantedMinor: UInt16

    public init(wantedMajor: UInt16, wantedMinor: UInt16) {
        self.wantedMajor = wantedMajor
        self.wantedMinor = wantedMinor
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt16(wantedMajor); w.writeUInt16(wantedMinor)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbUseExtension {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        return XkbUseExtension(wantedMajor: major, wantedMinor: minor)
    }
}

// MARK: - XkbSelectEvents (minor 1)

/// xkbSelectEventsReq: opcode(1) + minor(1) + length(2) + deviceSpec(2)
/// + affectWhich(2) + clear(2) + selectAll(2) + affectMap(2) + map(2).
/// Per-event detail masks (the "trailing variable" the agent flagged)
/// only appear when `affectWhich` has bits set that aren't covered by
/// the shorthand `clear`/`selectAll`/`affectMap`/`map` fields. For the
/// common XkbAllEventsMask startup case the trailing data is empty
/// and the request is exactly 16 bytes. We capture the optional
/// trailing detail-pair list as raw bytes for fidelity.
public struct XkbSelectEvents: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.selectEvents

    public var deviceSpec: UInt16
    public var affectWhich: UInt16
    public var clear: UInt16
    public var selectAll: UInt16
    public var affectMap: UInt16
    public var map: UInt16
    /// Optional per-event-detail trailing data; empty for the common
    /// "select all" startup case (length=4 in 4-byte units).
    public var detailTrailer: [UInt8]

    public init(deviceSpec: UInt16, affectWhich: UInt16, clear: UInt16,
                selectAll: UInt16, affectMap: UInt16, map: UInt16,
                detailTrailer: [UInt8] = []) {
        precondition(detailTrailer.count % 4 == 0, "trailer must be 4-byte aligned")
        self.deviceSpec = deviceSpec
        self.affectWhich = affectWhich
        self.clear = clear
        self.selectAll = selectAll
        self.affectMap = affectMap
        self.map = map
        self.detailTrailer = detailTrailer
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(4 + detailTrailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec); w.writeUInt16(affectWhich)
        w.writeUInt16(clear); w.writeUInt16(selectAll)
        w.writeUInt16(affectMap); w.writeUInt16(map)
        w.writeBytes(detailTrailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSelectEvents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceSpec = try r.readUInt16()
        let affectWhich = try r.readUInt16()
        let clear = try r.readUInt16()
        let selectAll = try r.readUInt16()
        let affectMap = try r.readUInt16()
        let map = try r.readUInt16()
        let trailerBytes = (lenIn4 - 4) * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        return XkbSelectEvents(
            deviceSpec: deviceSpec, affectWhich: affectWhich,
            clear: clear, selectAll: selectAll,
            affectMap: affectMap, map: map,
            detailTrailer: trailer
        )
    }
}

// MARK: - XkbGetState (minor 4)

public struct XkbGetState: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getState

    public var deviceSpec: UInt16

    public init(deviceSpec: UInt16) { self.deviceSpec = deviceSpec }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetState {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        try r.skip(2)
        return XkbGetState(deviceSpec: deviceSpec)
    }
}

// MARK: - XkbGetControls (minor 6)

public struct XkbGetControls: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getControls

    public var deviceSpec: UInt16

    public init(deviceSpec: UInt16) { self.deviceSpec = deviceSpec }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetControls {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        try r.skip(2)
        return XkbGetControls(deviceSpec: deviceSpec)
    }
}

// MARK: - XkbGetMap (minor 8)

/// xkbGetMapReq: opcode(1) + minor(1) + length(2=7) + deviceSpec(2) +
/// full(2) + partial(2) + firstType(1) + nTypes(1) + firstKeySym(1) +
/// nKeySyms(1) + firstKeyAction(1) + nKeyActions(1) +
/// firstKeyBehavior(1) + nKeyBehaviors(1) + virtualMods(2) +
/// firstKeyExplicit(1) + nKeyExplicit(1) + 2 bytes pad. 28 bytes total.
public struct XkbGetMap: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getMap

    public var deviceSpec: UInt16
    public var full: UInt16
    public var partial: UInt16
    public var firstType: UInt8
    public var nTypes: UInt8
    public var firstKeySym: UInt8
    public var nKeySyms: UInt8
    public var firstKeyAction: UInt8
    public var nKeyActions: UInt8
    public var firstKeyBehavior: UInt8
    public var nKeyBehaviors: UInt8
    public var virtualMods: UInt16
    public var firstKeyExplicit: UInt8
    public var nKeyExplicit: UInt8

    public init(deviceSpec: UInt16, full: UInt16, partial: UInt16,
                firstType: UInt8, nTypes: UInt8,
                firstKeySym: UInt8, nKeySyms: UInt8,
                firstKeyAction: UInt8, nKeyActions: UInt8,
                firstKeyBehavior: UInt8, nKeyBehaviors: UInt8,
                virtualMods: UInt16,
                firstKeyExplicit: UInt8, nKeyExplicit: UInt8) {
        self.deviceSpec = deviceSpec; self.full = full; self.partial = partial
        self.firstType = firstType; self.nTypes = nTypes
        self.firstKeySym = firstKeySym; self.nKeySyms = nKeySyms
        self.firstKeyAction = firstKeyAction; self.nKeyActions = nKeyActions
        self.firstKeyBehavior = firstKeyBehavior; self.nKeyBehaviors = nKeyBehaviors
        self.virtualMods = virtualMods
        self.firstKeyExplicit = firstKeyExplicit; self.nKeyExplicit = nKeyExplicit
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(7)
        w.writeUInt16(deviceSpec); w.writeUInt16(full); w.writeUInt16(partial)
        w.writeUInt8(firstType); w.writeUInt8(nTypes)
        w.writeUInt8(firstKeySym); w.writeUInt8(nKeySyms)
        w.writeUInt8(firstKeyAction); w.writeUInt8(nKeyActions)
        w.writeUInt8(firstKeyBehavior); w.writeUInt8(nKeyBehaviors)
        w.writeUInt16(virtualMods)
        w.writeUInt8(firstKeyExplicit); w.writeUInt8(nKeyExplicit)
        w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetMap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        let full = try r.readUInt16()
        let partial = try r.readUInt16()
        let firstType = try r.readUInt8(); let nTypes = try r.readUInt8()
        let firstKeySym = try r.readUInt8(); let nKeySyms = try r.readUInt8()
        let firstKeyAction = try r.readUInt8(); let nKeyActions = try r.readUInt8()
        let firstKeyBehavior = try r.readUInt8(); let nKeyBehaviors = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let firstKeyExplicit = try r.readUInt8(); let nKeyExplicit = try r.readUInt8()
        try r.skip(2)
        return XkbGetMap(
            deviceSpec: deviceSpec, full: full, partial: partial,
            firstType: firstType, nTypes: nTypes,
            firstKeySym: firstKeySym, nKeySyms: nKeySyms,
            firstKeyAction: firstKeyAction, nKeyActions: nKeyActions,
            firstKeyBehavior: firstKeyBehavior, nKeyBehaviors: nKeyBehaviors,
            virtualMods: virtualMods,
            firstKeyExplicit: firstKeyExplicit, nKeyExplicit: nKeyExplicit
        )
    }
}

// MARK: - XkbGetNames (minor 15)

public struct XkbGetNames: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getNames

    public var deviceSpec: UInt16
    public var which: UInt32

    public init(deviceSpec: UInt16, which: UInt32) {
        self.deviceSpec = deviceSpec; self.which = which
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        w.writeUInt32(which)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetNames {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        try r.skip(2)
        let which = try r.readUInt32()
        return XkbGetNames(deviceSpec: deviceSpec, which: which)
    }
}

// MARK: - XkbGetIndicatorMap (minor 13)

public struct XkbGetIndicatorMap: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getIndicatorMap

    public var deviceSpec: UInt16
    public var which: UInt32

    public init(deviceSpec: UInt16, which: UInt32) {
        self.deviceSpec = deviceSpec; self.which = which
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        w.writeUInt32(which)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetIndicatorMap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        try r.skip(2)
        let which = try r.readUInt32()
        return XkbGetIndicatorMap(deviceSpec: deviceSpec, which: which)
    }
}
