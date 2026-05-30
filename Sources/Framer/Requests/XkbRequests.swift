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

// MARK: - XkbSetMap (minor 9)

/// xkbSetMapReq: 28-byte header + the map payload trailer shared with
/// XkbGetMapReply. `present` is the bitmask gating which sections
/// appear in the trailer (sister of GetMap's `partial`/`full`). The
/// counts in the header tell how to walk each present section, just
/// like the reply does.
public struct XkbSetMap: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setMap

    public var deviceSpec: UInt16
    public var present: UInt16
    public var resize: UInt16
    public var firstType: UInt8
    public var nTypes: UInt8
    public var firstKeySym: UInt8
    public var nKeySyms: UInt8
    public var firstKeyAction: UInt8
    public var nKeyActions: UInt8
    public var totalKeyBehaviors: UInt8
    public var virtualMods: UInt16
    public var totalKeyExplicit: UInt8
    public var totalSyms: UInt16
    public var totalActions: UInt16
    public var payload: XkbMapPayload

    public init(deviceSpec: UInt16, present: UInt16, resize: UInt16,
                firstType: UInt8, nTypes: UInt8,
                firstKeySym: UInt8, nKeySyms: UInt8,
                firstKeyAction: UInt8, nKeyActions: UInt8,
                totalKeyBehaviors: UInt8, virtualMods: UInt16,
                totalKeyExplicit: UInt8,
                totalSyms: UInt16, totalActions: UInt16,
                payload: XkbMapPayload = .empty) {
        self.deviceSpec = deviceSpec
        self.present = present
        self.resize = resize
        self.firstType = firstType; self.nTypes = nTypes
        self.firstKeySym = firstKeySym; self.nKeySyms = nKeySyms
        self.firstKeyAction = firstKeyAction; self.nKeyActions = nKeyActions
        self.totalKeyBehaviors = totalKeyBehaviors
        self.virtualMods = virtualMods
        self.totalKeyExplicit = totalKeyExplicit
        self.totalSyms = totalSyms
        self.totalActions = totalActions
        self.payload = payload
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let trailer = payload.encode(byteOrder: byteOrder)
        // 28-byte header = 7 4-byte words; trailer is already padded.
        let lenIn4 = UInt16(7 + trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec)
        w.writeUInt16(present)
        w.writeUInt16(resize)
        w.writeUInt8(firstType); w.writeUInt8(nTypes)
        w.writeUInt8(firstKeySym); w.writeUInt8(nKeySyms)
        w.writeUInt8(firstKeyAction); w.writeUInt8(nKeyActions)
        w.writeUInt8(totalKeyBehaviors)
        // The C struct has totalKeyBehaviors at offset 16 followed by
        // CARD16 virtualMods, so the compiler inserts a 1-byte natural
        // alignment pad here. X11 wire follows C struct layout exactly.
        w.writePadding(1)
        w.writeUInt16(virtualMods)
        w.writeUInt8(totalKeyExplicit); w.writeUInt8(0)
        w.writeUInt16(totalSyms); w.writeUInt16(totalActions)
        w.writeUInt16(0)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetMap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceSpec = try r.readUInt16()
        let present = try r.readUInt16()
        let resize = try r.readUInt16()
        let firstType = try r.readUInt8()
        let nTypes = try r.readUInt8()
        let firstKeySym = try r.readUInt8()
        let nKeySyms = try r.readUInt8()
        let firstKeyAction = try r.readUInt8()
        let nKeyActions = try r.readUInt8()
        let totalKeyBehaviors = try r.readUInt8()
        try r.skip(1)   // natural alignment pad before virtualMods
        let virtualMods = try r.readUInt16()
        let totalKeyExplicit = try r.readUInt8()
        try r.skip(1)
        let totalSyms = try r.readUInt16()
        let totalActions = try r.readUInt16()
        try r.skip(2)
        let trailerBytes = (lenIn4 - 7) * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        let payload = try XkbMapPayload.decode(
            from: trailer,
            nTypes: nTypes, nKeySyms: nKeySyms,
            nKeyActions: nKeyActions,
            totalKeyBehaviors: totalKeyBehaviors,
            virtualModsBitmap: virtualMods,
            totalKeyExplicit: totalKeyExplicit,
            byteOrder: byteOrder
        )
        return XkbSetMap(
            deviceSpec: deviceSpec, present: present, resize: resize,
            firstType: firstType, nTypes: nTypes,
            firstKeySym: firstKeySym, nKeySyms: nKeySyms,
            firstKeyAction: firstKeyAction, nKeyActions: nKeyActions,
            totalKeyBehaviors: totalKeyBehaviors,
            virtualMods: virtualMods,
            totalKeyExplicit: totalKeyExplicit,
            totalSyms: totalSyms, totalActions: totalActions,
            payload: payload
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

// =============================================================================
// Session 3 (2026-05-30): Tier B + Tier C requests.
// =============================================================================

// MARK: - XkbLatchLockState (minor 5)

public struct XkbLatchLockState: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.latchLockState

    public var deviceSpec: UInt16
    public var affectModLocks: UInt8
    public var modLocks: UInt8
    public var lockGroup: Bool
    public var groupLock: UInt8
    public var affectModLatches: UInt8
    public var modLatches: UInt8
    public var latchGroup: Bool
    public var groupLatch: UInt8

    public init(deviceSpec: UInt16,
                affectModLocks: UInt8, modLocks: UInt8,
                lockGroup: Bool, groupLock: UInt8,
                affectModLatches: UInt8, modLatches: UInt8,
                latchGroup: Bool, groupLatch: UInt8) {
        self.deviceSpec = deviceSpec
        self.affectModLocks = affectModLocks; self.modLocks = modLocks
        self.lockGroup = lockGroup; self.groupLock = groupLock
        self.affectModLatches = affectModLatches; self.modLatches = modLatches
        self.latchGroup = latchGroup; self.groupLatch = groupLatch
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(affectModLocks); w.writeUInt8(modLocks)
        w.writeUInt8(lockGroup ? 1 : 0); w.writeUInt8(groupLock)
        w.writeUInt8(affectModLatches); w.writeUInt8(modLatches)
        w.writeUInt8(latchGroup ? 1 : 0); w.writeUInt8(groupLatch)
        w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbLatchLockState {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        let affectModLocks = try r.readUInt8()
        let modLocks = try r.readUInt8()
        let lockGroup = try r.readUInt8() != 0
        let groupLock = try r.readUInt8()
        let affectModLatches = try r.readUInt8()
        let modLatches = try r.readUInt8()
        let latchGroup = try r.readUInt8() != 0
        let groupLatch = try r.readUInt8()
        try r.skip(2)
        return XkbLatchLockState(
            deviceSpec: deviceSpec,
            affectModLocks: affectModLocks, modLocks: modLocks,
            lockGroup: lockGroup, groupLock: groupLock,
            affectModLatches: affectModLatches, modLatches: modLatches,
            latchGroup: latchGroup, groupLatch: groupLatch
        )
    }
}

// MARK: - XkbSetControls (minor 7)

/// xkbSetControlsReq: 56 bytes total. The R6 header annotates the first
/// four CARD8 mod fields with `B16` typos (same issue we documented on
/// XkbGetControlsReply); treat them as CARD8 per their declared type.
/// No hidden alignment padding — affectEnabledControls naturally lands
/// at offset 20 which is already 4-byte aligned.
public struct XkbSetControls: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setControls

    public var deviceSpec: UInt16
    public var affectInternalRealMods: UInt8
    public var internalRealMods: UInt8
    public var affectIgnoreLockRealMods: UInt8
    public var ignoreLockRealMods: UInt8
    public var affectInternalVirtualMods: UInt16
    public var internalVirtualMods: UInt16
    public var affectIgnoreLockVirtualMods: UInt16
    public var ignoreLockVirtualMods: UInt16
    public var mouseKeysDfltBtn: UInt8
    public var affectEnabledControls: UInt32
    public var enabledControls: UInt32
    public var changeControls: UInt32
    public var repeatDelay: UInt16
    public var repeatInterval: UInt16
    public var slowKeysDelay: UInt16
    public var debounceDelay: UInt16
    public var mouseKeysDelay: UInt16
    public var mouseKeysInterval: UInt16
    public var mouseKeysTimeToMax: UInt16
    public var mouseKeysMaxSpeed: UInt16
    public var mouseKeysCurve: UInt16
    public var accessXTimeout: UInt16
    public var accessXTimeoutMask: UInt32

    public init(deviceSpec: UInt16,
                affectInternalRealMods: UInt8, internalRealMods: UInt8,
                affectIgnoreLockRealMods: UInt8, ignoreLockRealMods: UInt8,
                affectInternalVirtualMods: UInt16, internalVirtualMods: UInt16,
                affectIgnoreLockVirtualMods: UInt16, ignoreLockVirtualMods: UInt16,
                mouseKeysDfltBtn: UInt8,
                affectEnabledControls: UInt32, enabledControls: UInt32, changeControls: UInt32,
                repeatDelay: UInt16, repeatInterval: UInt16,
                slowKeysDelay: UInt16, debounceDelay: UInt16,
                mouseKeysDelay: UInt16, mouseKeysInterval: UInt16,
                mouseKeysTimeToMax: UInt16, mouseKeysMaxSpeed: UInt16,
                mouseKeysCurve: UInt16,
                accessXTimeout: UInt16, accessXTimeoutMask: UInt32) {
        self.deviceSpec = deviceSpec
        self.affectInternalRealMods = affectInternalRealMods
        self.internalRealMods = internalRealMods
        self.affectIgnoreLockRealMods = affectIgnoreLockRealMods
        self.ignoreLockRealMods = ignoreLockRealMods
        self.affectInternalVirtualMods = affectInternalVirtualMods
        self.internalVirtualMods = internalVirtualMods
        self.affectIgnoreLockVirtualMods = affectIgnoreLockVirtualMods
        self.ignoreLockVirtualMods = ignoreLockVirtualMods
        self.mouseKeysDfltBtn = mouseKeysDfltBtn
        self.affectEnabledControls = affectEnabledControls
        self.enabledControls = enabledControls
        self.changeControls = changeControls
        self.repeatDelay = repeatDelay; self.repeatInterval = repeatInterval
        self.slowKeysDelay = slowKeysDelay; self.debounceDelay = debounceDelay
        self.mouseKeysDelay = mouseKeysDelay; self.mouseKeysInterval = mouseKeysInterval
        self.mouseKeysTimeToMax = mouseKeysTimeToMax
        self.mouseKeysMaxSpeed = mouseKeysMaxSpeed
        self.mouseKeysCurve = mouseKeysCurve
        self.accessXTimeout = accessXTimeout
        self.accessXTimeoutMask = accessXTimeoutMask
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(14)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(affectInternalRealMods); w.writeUInt8(internalRealMods)
        w.writeUInt8(affectIgnoreLockRealMods); w.writeUInt8(ignoreLockRealMods)
        w.writeUInt16(affectInternalVirtualMods); w.writeUInt16(internalVirtualMods)
        w.writeUInt16(affectIgnoreLockVirtualMods); w.writeUInt16(ignoreLockVirtualMods)
        w.writeUInt8(mouseKeysDfltBtn); w.writePadding(1)
        w.writeUInt32(affectEnabledControls); w.writeUInt32(enabledControls); w.writeUInt32(changeControls)
        w.writeUInt16(repeatDelay); w.writeUInt16(repeatInterval)
        w.writeUInt16(slowKeysDelay); w.writeUInt16(debounceDelay)
        w.writeUInt16(mouseKeysDelay); w.writeUInt16(mouseKeysInterval)
        w.writeUInt16(mouseKeysTimeToMax); w.writeUInt16(mouseKeysMaxSpeed)
        w.writeUInt16(mouseKeysCurve); w.writeUInt16(accessXTimeout)
        w.writeUInt32(accessXTimeoutMask)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetControls {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        let airm = try r.readUInt8(); let irm = try r.readUInt8()
        let aigm = try r.readUInt8(); let igm = try r.readUInt8()
        let aivm = try r.readUInt16(); let ivm = try r.readUInt16()
        let aigvm = try r.readUInt16(); let igvm = try r.readUInt16()
        let mouseKeysDfltBtn = try r.readUInt8()
        try r.skip(1)
        let affectEnabledControls = try r.readUInt32()
        let enabledControls = try r.readUInt32()
        let changeControls = try r.readUInt32()
        let repeatDelay = try r.readUInt16()
        let repeatInterval = try r.readUInt16()
        let slowKeysDelay = try r.readUInt16()
        let debounceDelay = try r.readUInt16()
        let mouseKeysDelay = try r.readUInt16()
        let mouseKeysInterval = try r.readUInt16()
        let mouseKeysTimeToMax = try r.readUInt16()
        let mouseKeysMaxSpeed = try r.readUInt16()
        let mouseKeysCurve = try r.readUInt16()
        let accessXTimeout = try r.readUInt16()
        let accessXTimeoutMask = try r.readUInt32()
        return XkbSetControls(
            deviceSpec: deviceSpec,
            affectInternalRealMods: airm, internalRealMods: irm,
            affectIgnoreLockRealMods: aigm, ignoreLockRealMods: igm,
            affectInternalVirtualMods: aivm, internalVirtualMods: ivm,
            affectIgnoreLockVirtualMods: aigvm, ignoreLockVirtualMods: igvm,
            mouseKeysDfltBtn: mouseKeysDfltBtn,
            affectEnabledControls: affectEnabledControls,
            enabledControls: enabledControls, changeControls: changeControls,
            repeatDelay: repeatDelay, repeatInterval: repeatInterval,
            slowKeysDelay: slowKeysDelay, debounceDelay: debounceDelay,
            mouseKeysDelay: mouseKeysDelay, mouseKeysInterval: mouseKeysInterval,
            mouseKeysTimeToMax: mouseKeysTimeToMax,
            mouseKeysMaxSpeed: mouseKeysMaxSpeed,
            mouseKeysCurve: mouseKeysCurve,
            accessXTimeout: accessXTimeout,
            accessXTimeoutMask: accessXTimeoutMask
        )
    }
}

// MARK: - XkbBell (minor 3)

public struct XkbBell: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.bell

    public var deviceSpec: UInt16
    public var bellClass: UInt8
    public var bellID: UInt8
    public var percent: Int8
    public var doOverride: Bool
    public var name: UInt32
    public var window: UInt32

    public init(deviceSpec: UInt16, bellClass: UInt8, bellID: UInt8,
                percent: Int8, doOverride: Bool,
                name: UInt32, window: UInt32) {
        self.deviceSpec = deviceSpec; self.bellClass = bellClass; self.bellID = bellID
        self.percent = percent; self.doOverride = doOverride
        self.name = name; self.window = window
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(5)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(bellClass); w.writeUInt8(bellID)
        w.writeUInt8(UInt8(bitPattern: percent)); w.writeUInt8(doOverride ? 1 : 0)
        w.writePadding(2)
        w.writeUInt32(name); w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbBell {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        let bellClass = try r.readUInt8()
        let bellID = try r.readUInt8()
        let percent = Int8(bitPattern: try r.readUInt8())
        let doOverride = try r.readUInt8() != 0
        try r.skip(2)
        let name = try r.readUInt32()
        let window = try r.readUInt32()
        return XkbBell(deviceSpec: deviceSpec, bellClass: bellClass, bellID: bellID,
                       percent: percent, doOverride: doOverride,
                       name: name, window: window)
    }
}

// MARK: - XkbSendEvent (minor 2)

/// xkbSendEventReq: 48 bytes. The last 32 bytes are a wrapped core
/// xEvent. We capture that as a raw [UInt8] (length 32) since the
/// embedded event could be any of the 33+ flavors; the dumper just
/// reports "event=..." without re-walking it.
public struct XkbSendEvent: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.sendEvent

    public var propagate: Bool
    public var synthesizeClick: Bool
    public var destination: UInt32
    public var eventMask: UInt32
    public var eventBytes: [UInt8]   // exactly 32 bytes

    public init(propagate: Bool, synthesizeClick: Bool,
                destination: UInt32, eventMask: UInt32,
                eventBytes: [UInt8]) {
        precondition(eventBytes.count == 32, "eventBytes must be 32 bytes")
        self.propagate = propagate; self.synthesizeClick = synthesizeClick
        self.destination = destination; self.eventMask = eventMask
        self.eventBytes = eventBytes
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(12)
        w.writeUInt8(propagate ? 1 : 0); w.writeUInt8(synthesizeClick ? 1 : 0)
        w.writePadding(2)
        w.writeUInt32(destination)
        w.writeUInt32(eventMask)
        w.writeBytes(eventBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSendEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let propagate = try r.readUInt8() != 0
        let synthesizeClick = try r.readUInt8() != 0
        try r.skip(2)
        let destination = try r.readUInt32()
        let eventMask = try r.readUInt32()
        let eventBytes = try r.readBytes(32)
        return XkbSendEvent(
            propagate: propagate, synthesizeClick: synthesizeClick,
            destination: destination, eventMask: eventMask,
            eventBytes: eventBytes
        )
    }
}

// MARK: - XkbGetIndicatorState (minor 12)

public struct XkbGetIndicatorState: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getIndicatorState

    public var deviceSpec: UInt16
    public init(deviceSpec: UInt16) { self.deviceSpec = deviceSpec }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetIndicatorState {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        try r.skip(2)
        return XkbGetIndicatorState(deviceSpec: deviceSpec)
    }
}

// MARK: - XkbSetIndicatorMap (minor 14)

/// xkbSetIndicatorMapReq: 12-byte header + N × 12-byte IndicatorMap
/// records, where N = popcount(`which`). Trailing payload uses the
/// shared `XkbIndicatorMapList` codec.
public struct XkbSetIndicatorMap: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setIndicatorMap

    public var deviceSpec: UInt16
    public var which: UInt32
    public var maps: [XkbIndicatorMapEntry]   // count must equal popcount(which)

    public init(deviceSpec: UInt16, which: UInt32, maps: [XkbIndicatorMapEntry]) {
        precondition(maps.count == which.nonzeroBitCount,
                     "maps.count must equal popcount(which)")
        self.deviceSpec = deviceSpec; self.which = which; self.maps = maps
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + maps.count * 3)   // 12 bytes per record = 3 words
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        w.writeUInt32(which)
        for m in maps { w.writeBytes(m.encode(byteOrder: byteOrder)) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetIndicatorMap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        try r.skip(2)
        let which = try r.readUInt32()
        let n = which.nonzeroBitCount
        let trailer = try r.readBytes(n * 12)
        let maps = try XkbIndicatorMapList.decode(from: trailer, count: n, byteOrder: byteOrder)
        return XkbSetIndicatorMap(deviceSpec: deviceSpec, which: which, maps: maps)
    }
}

// MARK: - XkbGetCompatMap (minor 10)

public struct XkbGetCompatMap: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getCompatMap

    public var deviceSpec: UInt16
    public var virtualMods: UInt16
    public var mods: UInt8
    public var getAllSI: Bool
    public var firstSI: UInt16
    public var nSI: UInt16

    public init(deviceSpec: UInt16, virtualMods: UInt16, mods: UInt8,
                getAllSI: Bool, firstSI: UInt16, nSI: UInt16) {
        self.deviceSpec = deviceSpec; self.virtualMods = virtualMods
        self.mods = mods; self.getAllSI = getAllSI
        self.firstSI = firstSI; self.nSI = nSI
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt16(deviceSpec)
        w.writeUInt16(virtualMods)
        w.writeUInt8(mods); w.writeUInt8(getAllSI ? 1 : 0)
        w.writeUInt16(firstSI); w.writeUInt16(nSI)
        w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetCompatMap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        let virtualMods = try r.readUInt16()
        let mods = try r.readUInt8()
        let getAllSI = try r.readUInt8() != 0
        let firstSI = try r.readUInt16()
        let nSI = try r.readUInt16()
        try r.skip(2)
        return XkbGetCompatMap(
            deviceSpec: deviceSpec, virtualMods: virtualMods,
            mods: mods, getAllSI: getAllSI,
            firstSI: firstSI, nSI: nSI
        )
    }
}

// MARK: - XkbSetCompatMap (minor 11)

/// 16-byte header + trailer of N × 16-byte SymInterpret records,
/// optionally followed by 4 × 2-byte GroupCompat records when the
/// `groups`-style bits in the request indicate.
/// We don't have separate "include groupCompat" bit in this struct;
/// for v0.30 the convention is "always include groupCompat when
/// recomputeActions is true." Real clients vary — we capture by
/// reading the trailer's actual length and inferring presence.
public struct XkbSetCompatMap: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setCompatMap

    public var deviceSpec: UInt16
    public var recomputeActions: Bool
    public var truncateSI: Bool
    public var mods: UInt8
    public var virtualMods: UInt16
    public var firstSI: UInt16
    public var nSI: UInt16
    public var payload: XkbCompatPayload

    public init(deviceSpec: UInt16, recomputeActions: Bool, truncateSI: Bool,
                mods: UInt8, virtualMods: UInt16,
                firstSI: UInt16, nSI: UInt16,
                payload: XkbCompatPayload = .empty) {
        self.deviceSpec = deviceSpec
        self.recomputeActions = recomputeActions
        self.truncateSI = truncateSI
        self.mods = mods
        self.virtualMods = virtualMods
        self.firstSI = firstSI; self.nSI = nSI
        self.payload = payload
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let trailer = payload.encode(byteOrder: byteOrder)
        let lenIn4 = UInt16(4 + trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(recomputeActions ? 1 : 0); w.writeUInt8(truncateSI ? 1 : 0)
        w.writeUInt8(0); w.writeUInt8(mods)
        w.writeUInt16(virtualMods)
        w.writeUInt16(firstSI); w.writeUInt16(nSI)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetCompatMap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceSpec = try r.readUInt16()
        let recompute = try r.readUInt8() != 0
        let truncate = try r.readUInt8() != 0
        try r.skip(1)
        let mods = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let firstSI = try r.readUInt16()
        let nSI = try r.readUInt16()
        let trailerBytes = (lenIn4 - 4) * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        // Infer groupCompat presence: each SymInterpret is 16 bytes,
        // each GroupCompat is 2 bytes (4 entries = 8 bytes). If trailer
        // size > nSI*16, assume groupCompat is present.
        let siBytes = Int(nSI) * 16
        let includeGroupCompat = trailer.count > siBytes
        let payload = try XkbCompatPayload.decode(
            from: trailer, nSymInterprets: Int(nSI),
            includeGroupCompat: includeGroupCompat,
            byteOrder: byteOrder
        )
        return XkbSetCompatMap(
            deviceSpec: deviceSpec,
            recomputeActions: recompute, truncateSI: truncate,
            mods: mods, virtualMods: virtualMods,
            firstSI: firstSI, nSI: nSI,
            payload: payload
        )
    }
}

// MARK: - XkbSetNames (minor 16)

/// xkbSetNamesReq: 32-byte header + Atom-list trailer (gated by the
/// `which` mask in a fixed order). Trailer kept raw here; a typed
/// walker can decode the which-mask-driven Atom sequence in a later
/// pass — same approach as we used for Session 1's GetNames reply.
public struct XkbSetNames: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setNames

    public var deviceSpec: UInt16
    public var which: UInt32
    public var firstType: UInt8
    public var nTypes: UInt8
    public var firstKTLevel: UInt8
    public var nKTLevels: UInt8
    public var indicators: UInt32
    public var modifiers: UInt8
    public var virtualMods: UInt16
    public var nRadioGroups: UInt8
    public var nCharSets: UInt8
    public var firstKey: UInt8
    public var nKeys: UInt8
    public var resize: UInt32
    /// Atom list, encoded per the `which` mask's bit order. Kept raw.
    public var trailer: [UInt8]

    public init(deviceSpec: UInt16, which: UInt32,
                firstType: UInt8, nTypes: UInt8,
                firstKTLevel: UInt8, nKTLevels: UInt8,
                indicators: UInt32, modifiers: UInt8,
                virtualMods: UInt16,
                nRadioGroups: UInt8, nCharSets: UInt8,
                firstKey: UInt8, nKeys: UInt8,
                resize: UInt32, trailer: [UInt8] = []) {
        precondition(trailer.count % 4 == 0, "trailer must be 4-byte aligned")
        self.deviceSpec = deviceSpec; self.which = which
        self.firstType = firstType; self.nTypes = nTypes
        self.firstKTLevel = firstKTLevel; self.nKTLevels = nKTLevels
        self.indicators = indicators; self.modifiers = modifiers
        self.virtualMods = virtualMods
        self.nRadioGroups = nRadioGroups; self.nCharSets = nCharSets
        self.firstKey = firstKey; self.nKeys = nKeys
        self.resize = resize; self.trailer = trailer
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(8 + trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        w.writeUInt32(which)
        w.writeUInt8(firstType); w.writeUInt8(nTypes)
        w.writeUInt8(firstKTLevel); w.writeUInt8(nKTLevels)
        w.writeUInt32(indicators)
        w.writeUInt8(modifiers); w.writePadding(1)
        w.writeUInt16(virtualMods)
        w.writeUInt8(nRadioGroups); w.writeUInt8(nCharSets)
        w.writeUInt8(firstKey); w.writeUInt8(nKeys)
        w.writeUInt32(resize)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetNames {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceSpec = try r.readUInt16(); try r.skip(2)
        let which = try r.readUInt32()
        let firstType = try r.readUInt8(); let nTypes = try r.readUInt8()
        let firstKTLevel = try r.readUInt8(); let nKTLevels = try r.readUInt8()
        let indicators = try r.readUInt32()
        let modifiers = try r.readUInt8(); try r.skip(1)
        let virtualMods = try r.readUInt16()
        let nRadioGroups = try r.readUInt8(); let nCharSets = try r.readUInt8()
        let firstKey = try r.readUInt8(); let nKeys = try r.readUInt8()
        let resize = try r.readUInt32()
        let trailerBytes = (lenIn4 - 8) * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        return XkbSetNames(
            deviceSpec: deviceSpec, which: which,
            firstType: firstType, nTypes: nTypes,
            firstKTLevel: firstKTLevel, nKTLevels: nKTLevels,
            indicators: indicators, modifiers: modifiers,
            virtualMods: virtualMods,
            nRadioGroups: nRadioGroups, nCharSets: nCharSets,
            firstKey: firstKey, nKeys: nKeys,
            resize: resize, trailer: trailer
        )
    }
}

// MARK: - Tier C: XkbListAlternateSyms (minor 17)

public struct XkbListAlternateSyms: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.listAlternateSyms

    public var deviceSpec: UInt16
    public var name: UInt32       // Atom
    public var charset: UInt32    // Atom

    public init(deviceSpec: UInt16, name: UInt32, charset: UInt32) {
        self.deviceSpec = deviceSpec; self.name = name; self.charset = charset
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        w.writeUInt32(name); w.writeUInt32(charset)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbListAlternateSyms {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16(); try r.skip(2)
        let name = try r.readUInt32()
        let charset = try r.readUInt32()
        return XkbListAlternateSyms(deviceSpec: deviceSpec, name: name, charset: charset)
    }
}

// MARK: - XkbGetAlternateSyms (minor 18)

public struct XkbGetAlternateSyms: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getAlternateSyms

    public var deviceSpec: UInt16
    public var index: UInt8
    public var firstKey: UInt8
    public var nKeys: UInt8

    public init(deviceSpec: UInt16, index: UInt8, firstKey: UInt8, nKeys: UInt8) {
        self.deviceSpec = deviceSpec
        self.index = index; self.firstKey = firstKey; self.nKeys = nKeys
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(index); w.writeUInt8(firstKey); w.writeUInt8(nKeys); w.writePadding(1)
        w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetAlternateSyms {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16()
        let index = try r.readUInt8()
        let firstKey = try r.readUInt8()
        let nKeys = try r.readUInt8()
        try r.skip(1)
        try r.skip(2)
        return XkbGetAlternateSyms(deviceSpec: deviceSpec, index: index,
                                   firstKey: firstKey, nKeys: nKeys)
    }
}

// MARK: - XkbSetAlternateSyms (minor 19)

public struct XkbSetAlternateSyms: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setAlternateSyms

    public var deviceSpec: UInt16
    public var create: Bool
    public var replace: UInt8
    public var present: UInt16
    public var name: UInt32   // Atom
    public var nCharSets: UInt8
    public var firstKey: UInt8
    public var nKeys: UInt8
    /// CARD32 syms trailing payload. Count is (lenIn4 - 5) words / 1 per sym.
    public var syms: [UInt32]

    public init(deviceSpec: UInt16, create: Bool, replace: UInt8,
                present: UInt16, name: UInt32,
                nCharSets: UInt8, firstKey: UInt8, nKeys: UInt8,
                syms: [UInt32] = []) {
        self.deviceSpec = deviceSpec; self.create = create; self.replace = replace
        self.present = present; self.name = name
        self.nCharSets = nCharSets; self.firstKey = firstKey; self.nKeys = nKeys
        self.syms = syms
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(5 + syms.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(create ? 1 : 0); w.writeUInt8(replace)
        w.writeUInt16(present); w.writePadding(2)
        w.writeUInt32(name)
        w.writeUInt8(nCharSets); w.writeUInt8(firstKey); w.writeUInt8(nKeys); w.writePadding(1)
        for s in syms { w.writeUInt32(s) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetAlternateSyms {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceSpec = try r.readUInt16()
        let create = try r.readUInt8() != 0
        let replace = try r.readUInt8()
        let present = try r.readUInt16()
        try r.skip(2)
        let name = try r.readUInt32()
        let nCharSets = try r.readUInt8()
        let firstKey = try r.readUInt8()
        let nKeys = try r.readUInt8()
        try r.skip(1)
        let nSyms = lenIn4 - 5
        var syms: [UInt32] = []
        syms.reserveCapacity(nSyms)
        for _ in 0..<nSyms { syms.append(try r.readUInt32()) }
        return XkbSetAlternateSyms(
            deviceSpec: deviceSpec, create: create, replace: replace,
            present: present, name: name,
            nCharSets: nCharSets, firstKey: firstKey, nKeys: nKeys,
            syms: syms
        )
    }
}

// MARK: - XkbGetGeometry (minor 20)

public struct XkbGetGeometry: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.getGeometry

    public var deviceSpec: UInt16
    public var name: UInt32   // Atom; 0 = default

    public init(deviceSpec: UInt16, name: UInt32) {
        self.deviceSpec = deviceSpec; self.name = name
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt16(deviceSpec); w.writePadding(2)
        w.writeUInt32(name)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetGeometry {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let deviceSpec = try r.readUInt16(); try r.skip(2)
        let name = try r.readUInt32()
        return XkbGetGeometry(deviceSpec: deviceSpec, name: name)
    }
}

// MARK: - XkbSetGeometry (minor 21)

/// 16-byte header + the geometry tree trailer (Shape → Outline → Point;
/// Section → Row → Key; Doodad; Label; Font lists). The tree is kept
/// raw for now; the typed walker is a deferred follow-up since this
/// request is rarely emitted by real clients.
public struct XkbSetGeometry: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setGeometry

    public var deviceSpec: UInt16
    public var nShapes: UInt8
    public var nSections: UInt8
    public var name: UInt32
    public var widthMM: UInt16
    public var heightMM: UInt16
    public var trailer: [UInt8]

    public init(deviceSpec: UInt16, nShapes: UInt8, nSections: UInt8,
                name: UInt32, widthMM: UInt16, heightMM: UInt16,
                trailer: [UInt8] = []) {
        precondition(trailer.count % 4 == 0, "trailer must be 4-byte aligned")
        self.deviceSpec = deviceSpec
        self.nShapes = nShapes; self.nSections = nSections
        self.name = name
        self.widthMM = widthMM; self.heightMM = heightMM
        self.trailer = trailer
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(4 + trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(deviceSpec)
        w.writeUInt8(nShapes); w.writeUInt8(nSections)
        w.writeUInt32(name)
        w.writeUInt16(widthMM); w.writeUInt16(heightMM)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetGeometry {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let deviceSpec = try r.readUInt16()
        let nShapes = try r.readUInt8()
        let nSections = try r.readUInt8()
        let name = try r.readUInt32()
        let widthMM = try r.readUInt16()
        let heightMM = try r.readUInt16()
        let trailerBytes = (lenIn4 - 4) * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        return XkbSetGeometry(
            deviceSpec: deviceSpec, nShapes: nShapes, nSections: nSections,
            name: name, widthMM: widthMM, heightMM: heightMM,
            trailer: trailer
        )
    }
}

// MARK: - XkbSetDebuggingFlags (minor 101)

/// xkbSetDebuggingFlagsReq: 12-byte header + a CARD8 message blob of
/// length `msgLength`, padded to 4. Rarely emitted by real clients.
public struct XkbSetDebuggingFlags: Equatable, Sendable {
    public static let minor: UInt8 = XkbMinor.setDebuggingFlags

    public var mask: UInt16
    public var flags: UInt16
    public var disableLocks: UInt8
    public var message: [UInt8]   // length = msgLength

    public init(mask: UInt16, flags: UInt16, disableLocks: UInt8,
                message: [UInt8] = []) {
        self.mask = mask; self.flags = flags
        self.disableLocks = disableLocks
        self.message = message
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let n = message.count
        let p = xPad(n)
        let lenIn4 = UInt16(3 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt16(mask); w.writeUInt16(flags)
        w.writeUInt16(UInt16(n))
        w.writeUInt8(disableLocks); w.writePadding(1)
        w.writeBytes(message)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetDebuggingFlags {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let mask = try r.readUInt16()
        let flags = try r.readUInt16()
        let msgLength = Int(try r.readUInt16())
        let disableLocks = try r.readUInt8()
        try r.skip(1)
        let message = try r.readBytes(msgLength)
        return XkbSetDebuggingFlags(
            mask: mask, flags: flags,
            disableLocks: disableLocks, message: message
        )
    }
}
