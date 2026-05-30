// XKEYBOARD (XKB) extension Tier-A reply wire types.
//
// Phase 3 Session 1 (2026-05-30) — 7 replies. Three of them
// (UseExtension, GetState, GetControls) are fully fixed-size. The
// other four (GetMap, GetNames, GetIndicatorMap) carry a variable-
// length payload after the 32-byte header that we capture as raw
// bytes for now; Session 2 will decode the nested-list trailer of
// GetMap and SetMap (the gnarly piece XKB is famous for).
//
// Wire layouts from reference/X11R6/xc/include/extensions/XKBproto.h.

// MARK: - XkbUseExtension reply

public struct XkbUseExtensionReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var supported: Bool
    public var serverMajor: UInt16
    public var serverMinor: UInt16

    public init(sequenceNumber: UInt16, supported: Bool,
                serverMajor: UInt16, serverMinor: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.supported = supported
        self.serverMajor = serverMajor
        self.serverMinor = serverMinor
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(supported ? 1 : 0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(serverMajor); w.writeUInt16(serverMinor)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbUseExtensionReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let supported = try r.readUInt8() != 0
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        return XkbUseExtensionReply(
            sequenceNumber: seq, supported: supported,
            serverMajor: major, serverMinor: minor
        )
    }
}

// MARK: - XkbGetState reply

public struct XkbGetStateReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var mods: UInt8
    public var baseMods: UInt8
    public var latchedMods: UInt8
    public var lockedMods: UInt8
    public var group: UInt8
    public var baseGroup: UInt8
    public var latchedGroup: UInt8
    public var lockedGroup: UInt8
    public var compatState: UInt8

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                mods: UInt8, baseMods: UInt8, latchedMods: UInt8, lockedMods: UInt8,
                group: UInt8, baseGroup: UInt8, latchedGroup: UInt8, lockedGroup: UInt8,
                compatState: UInt8) {
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.mods = mods; self.baseMods = baseMods
        self.latchedMods = latchedMods; self.lockedMods = lockedMods
        self.group = group; self.baseGroup = baseGroup
        self.latchedGroup = latchedGroup; self.lockedGroup = lockedGroup
        self.compatState = compatState
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(0)   // pad1
        w.writeUInt8(mods); w.writeUInt8(baseMods)
        w.writeUInt8(latchedMods); w.writeUInt8(lockedMods)
        w.writeUInt8(group); w.writeUInt8(baseGroup)
        w.writeUInt8(latchedGroup); w.writeUInt8(lockedGroup)
        w.writeUInt8(compatState); w.writePadding(11)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetStateReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32(); _ = try r.readUInt32()
        let mods = try r.readUInt8(); let baseMods = try r.readUInt8()
        let latchedMods = try r.readUInt8(); let lockedMods = try r.readUInt8()
        let group = try r.readUInt8(); let baseGroup = try r.readUInt8()
        let latchedGroup = try r.readUInt8(); let lockedGroup = try r.readUInt8()
        let compatState = try r.readUInt8()
        return XkbGetStateReply(
            sequenceNumber: seq, deviceID: deviceID,
            mods: mods, baseMods: baseMods,
            latchedMods: latchedMods, lockedMods: lockedMods,
            group: group, baseGroup: baseGroup,
            latchedGroup: latchedGroup, lockedGroup: lockedGroup,
            compatState: compatState
        )
    }
}

// MARK: - XkbGetControls reply
//
// NOTE: The R6 header (XKBproto.h) annotates `internalMods` /
// `ignoreLockMods` with `B16` even though they're declared CARD8 —
// those are typos in the header. Treat them as CARD8 (the declared
// type wins) — verified by the surrounding field types and the
// reply's documented total size of 48 bytes (32 base + length=4×4 = 16
// trailing).
public struct XkbGetControlsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var mouseKeysDfltBtn: UInt8
    public var numGroups: UInt8
    public var internalMods: UInt8
    public var ignoreLockMods: UInt8
    public var internalRealMods: UInt8
    public var ignoreLockRealMods: UInt8
    public var internalVirtualMods: UInt16
    public var ignoreLockVirtualMods: UInt16
    public var enabledControls: UInt32
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

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                mouseKeysDfltBtn: UInt8, numGroups: UInt8,
                internalMods: UInt8, ignoreLockMods: UInt8,
                internalRealMods: UInt8, ignoreLockRealMods: UInt8,
                internalVirtualMods: UInt16, ignoreLockVirtualMods: UInt16,
                enabledControls: UInt32,
                repeatDelay: UInt16, repeatInterval: UInt16,
                slowKeysDelay: UInt16, debounceDelay: UInt16,
                mouseKeysDelay: UInt16, mouseKeysInterval: UInt16,
                mouseKeysTimeToMax: UInt16, mouseKeysMaxSpeed: UInt16,
                mouseKeysCurve: UInt16,
                accessXTimeout: UInt16, accessXTimeoutMask: UInt32) {
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.mouseKeysDfltBtn = mouseKeysDfltBtn; self.numGroups = numGroups
        self.internalMods = internalMods; self.ignoreLockMods = ignoreLockMods
        self.internalRealMods = internalRealMods; self.ignoreLockRealMods = ignoreLockRealMods
        self.internalVirtualMods = internalVirtualMods
        self.ignoreLockVirtualMods = ignoreLockVirtualMods
        self.enabledControls = enabledControls
        self.repeatDelay = repeatDelay; self.repeatInterval = repeatInterval
        self.slowKeysDelay = slowKeysDelay; self.debounceDelay = debounceDelay
        self.mouseKeysDelay = mouseKeysDelay; self.mouseKeysInterval = mouseKeysInterval
        self.mouseKeysTimeToMax = mouseKeysTimeToMax
        self.mouseKeysMaxSpeed = mouseKeysMaxSpeed
        self.mouseKeysCurve = mouseKeysCurve
        self.accessXTimeout = accessXTimeout
        self.accessXTimeoutMask = accessXTimeoutMask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(4)
        w.writeUInt8(mouseKeysDfltBtn); w.writeUInt8(numGroups)
        w.writeUInt8(internalMods); w.writeUInt8(ignoreLockMods)
        w.writeUInt8(internalRealMods); w.writeUInt8(ignoreLockRealMods)
        w.writeUInt16(internalVirtualMods); w.writeUInt16(ignoreLockVirtualMods)
        w.writePadding(2)
        w.writeUInt32(enabledControls)
        w.writeUInt16(repeatDelay); w.writeUInt16(repeatInterval)
        w.writeUInt16(slowKeysDelay); w.writeUInt16(debounceDelay)
        w.writeUInt16(mouseKeysDelay); w.writeUInt16(mouseKeysInterval)
        w.writeUInt16(mouseKeysTimeToMax); w.writeUInt16(mouseKeysMaxSpeed)
        w.writeUInt16(mouseKeysCurve); w.writeUInt16(accessXTimeout)
        w.writeUInt32(accessXTimeoutMask)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetControlsReply {
        guard bytes.count >= 48 else {
            throw FramerError.truncated(needed: 48, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let mouseKeysDfltBtn = try r.readUInt8()
        let numGroups = try r.readUInt8()
        let internalMods = try r.readUInt8()
        let ignoreLockMods = try r.readUInt8()
        let internalRealMods = try r.readUInt8()
        let ignoreLockRealMods = try r.readUInt8()
        let internalVirtualMods = try r.readUInt16()
        let ignoreLockVirtualMods = try r.readUInt16()
        try r.skip(2)
        let enabledControls = try r.readUInt32()
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
        return XkbGetControlsReply(
            sequenceNumber: seq, deviceID: deviceID,
            mouseKeysDfltBtn: mouseKeysDfltBtn, numGroups: numGroups,
            internalMods: internalMods, ignoreLockMods: ignoreLockMods,
            internalRealMods: internalRealMods, ignoreLockRealMods: ignoreLockRealMods,
            internalVirtualMods: internalVirtualMods,
            ignoreLockVirtualMods: ignoreLockVirtualMods,
            enabledControls: enabledControls,
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

// MARK: - XkbGetMap reply (32-byte header + typed trailer payload)

/// 32-byte fixed header followed by the typed map payload (KeyTypes →
/// SymMaps → KeyActions → Behaviors → VirtualMods → Explicits). The
/// payload codec lives in `XkbMapPayload.swift` and is shared with
/// `XkbSetMap`. Phase 3 Session 1 captured the trailer as raw bytes;
/// Session 2 (2026-05-30) replaced it with the typed `payload` field.
public struct XkbGetMapReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var minKeyCode: UInt8
    public var maxKeyCode: UInt8
    public var present: UInt16
    public var firstType: UInt8
    public var nTypes: UInt8
    public var totalTypes: UInt8
    public var firstKeySym: UInt8
    public var nKeySyms: UInt8
    public var firstKeyAction: UInt8
    public var nKeyActions: UInt8
    public var totalKeyBehaviors: UInt8
    public var virtualMods: UInt16
    public var totalSyms: UInt16
    public var totalActions: UInt16
    public var totalKeyExplicit: UInt8
    public var payload: XkbMapPayload

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                minKeyCode: UInt8, maxKeyCode: UInt8, present: UInt16,
                firstType: UInt8, nTypes: UInt8, totalTypes: UInt8,
                firstKeySym: UInt8, nKeySyms: UInt8,
                firstKeyAction: UInt8, nKeyActions: UInt8,
                totalKeyBehaviors: UInt8, virtualMods: UInt16,
                totalSyms: UInt16, totalActions: UInt16,
                totalKeyExplicit: UInt8,
                payload: XkbMapPayload = .empty) {
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.minKeyCode = minKeyCode; self.maxKeyCode = maxKeyCode
        self.present = present
        self.firstType = firstType; self.nTypes = nTypes; self.totalTypes = totalTypes
        self.firstKeySym = firstKeySym; self.nKeySyms = nKeySyms
        self.firstKeyAction = firstKeyAction; self.nKeyActions = nKeyActions
        self.totalKeyBehaviors = totalKeyBehaviors
        self.virtualMods = virtualMods
        self.totalSyms = totalSyms; self.totalActions = totalActions
        self.totalKeyExplicit = totalKeyExplicit
        self.payload = payload
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let trailerBytes = payload.encode(byteOrder: byteOrder)
        let lenIn4 = UInt32(trailerBytes.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(minKeyCode); w.writeUInt8(maxKeyCode)
        w.writeUInt16(present)
        w.writeUInt8(firstType); w.writeUInt8(nTypes); w.writeUInt8(totalTypes)
        w.writeUInt8(firstKeySym); w.writeUInt8(nKeySyms)
        w.writeUInt8(firstKeyAction); w.writeUInt8(nKeyActions)
        w.writeUInt8(totalKeyBehaviors)
        w.writeUInt16(virtualMods)
        w.writeUInt16(totalSyms); w.writeUInt16(totalActions)
        w.writeUInt8(totalKeyExplicit); w.writeUInt8(0)
        w.writeUInt32(0)
        w.writeBytes(trailerBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetMapReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let minKeyCode = try r.readUInt8()
        let maxKeyCode = try r.readUInt8()
        let present = try r.readUInt16()
        let firstType = try r.readUInt8()
        let nTypes = try r.readUInt8()
        let totalTypes = try r.readUInt8()
        let firstKeySym = try r.readUInt8()
        let nKeySyms = try r.readUInt8()
        let firstKeyAction = try r.readUInt8()
        let nKeyActions = try r.readUInt8()
        let totalKeyBehaviors = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let totalSyms = try r.readUInt16()
        let totalActions = try r.readUInt16()
        let totalKeyExplicit = try r.readUInt8()
        try r.skip(1)
        try r.skip(4)
        let trailerBytes = lenIn4 > 0 ? try r.readBytes(lenIn4 * 4) : []
        let payload = try XkbMapPayload.decode(
            from: trailerBytes,
            nTypes: nTypes, nKeySyms: nKeySyms,
            nKeyActions: nKeyActions,
            totalKeyBehaviors: totalKeyBehaviors,
            virtualModsBitmap: virtualMods,
            totalKeyExplicit: totalKeyExplicit,
            byteOrder: byteOrder
        )
        return XkbGetMapReply(
            sequenceNumber: seq, deviceID: deviceID,
            minKeyCode: minKeyCode, maxKeyCode: maxKeyCode,
            present: present,
            firstType: firstType, nTypes: nTypes, totalTypes: totalTypes,
            firstKeySym: firstKeySym, nKeySyms: nKeySyms,
            firstKeyAction: firstKeyAction, nKeyActions: nKeyActions,
            totalKeyBehaviors: totalKeyBehaviors,
            virtualMods: virtualMods,
            totalSyms: totalSyms, totalActions: totalActions,
            totalKeyExplicit: totalKeyExplicit,
            payload: payload
        )
    }
}

// MARK: - XkbGetNames reply (header + raw trailer)

public struct XkbGetNamesReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var which: UInt32
    public var nTypes: UInt8
    public var modifiers: UInt8
    public var virtualMods: UInt16
    public var firstKey: UInt8
    public var nKeys: UInt8
    public var nRadioGroups: UInt8
    public var nCharSets: UInt8
    public var indicators: UInt32
    /// Atom-list trailer; Session 3 will decode per the `which`-mask order.
    public var trailer: [UInt8]

    public init(sequenceNumber: UInt16, deviceID: UInt8, which: UInt32,
                nTypes: UInt8, modifiers: UInt8, virtualMods: UInt16,
                firstKey: UInt8, nKeys: UInt8,
                nRadioGroups: UInt8, nCharSets: UInt8,
                indicators: UInt32, trailer: [UInt8] = []) {
        precondition(trailer.count % 4 == 0, "trailer must be 4-byte aligned")
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.which = which
        self.nTypes = nTypes; self.modifiers = modifiers
        self.virtualMods = virtualMods
        self.firstKey = firstKey; self.nKeys = nKeys
        self.nRadioGroups = nRadioGroups; self.nCharSets = nCharSets
        self.indicators = indicators
        self.trailer = trailer
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(which)
        w.writeUInt8(nTypes); w.writeUInt8(modifiers)
        w.writeUInt16(virtualMods)
        w.writeUInt8(firstKey); w.writeUInt8(nKeys)
        w.writeUInt8(nRadioGroups); w.writeUInt8(nCharSets)
        w.writeUInt32(indicators)
        w.writePadding(8)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetNamesReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let which = try r.readUInt32()
        let nTypes = try r.readUInt8()
        let modifiers = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let firstKey = try r.readUInt8()
        let nKeys = try r.readUInt8()
        let nRadioGroups = try r.readUInt8()
        let nCharSets = try r.readUInt8()
        let indicators = try r.readUInt32()
        try r.skip(8)
        let trailer = lenIn4 > 0 ? try r.readBytes(lenIn4 * 4) : []
        return XkbGetNamesReply(
            sequenceNumber: seq, deviceID: deviceID, which: which,
            nTypes: nTypes, modifiers: modifiers, virtualMods: virtualMods,
            firstKey: firstKey, nKeys: nKeys,
            nRadioGroups: nRadioGroups, nCharSets: nCharSets,
            indicators: indicators, trailer: trailer
        )
    }
}

// MARK: - XkbGetIndicatorMap reply (typed trailer — Session 3)

/// 32-byte header + nIndicators × 12-byte IndicatorMapWireDesc trailer.
public struct XkbGetIndicatorMapReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var which: UInt32
    public var nRealIndicators: UInt8
    public var nIndicators: UInt8
    public var maps: [XkbIndicatorMapEntry]

    public init(sequenceNumber: UInt16, deviceID: UInt8, which: UInt32,
                nRealIndicators: UInt8, nIndicators: UInt8,
                maps: [XkbIndicatorMapEntry] = []) {
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.which = which
        self.nRealIndicators = nRealIndicators
        self.nIndicators = nIndicators
        self.maps = maps
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let trailer = XkbIndicatorMapList.encode(maps, byteOrder: byteOrder)
        let lenIn4 = UInt32(trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(which)
        w.writeUInt8(nRealIndicators); w.writeUInt8(nIndicators)
        w.writePadding(2)
        w.writePadding(16)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetIndicatorMapReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let which = try r.readUInt32()
        let nReal = try r.readUInt8()
        let n = try r.readUInt8()
        try r.skip(2)
        try r.skip(16)
        let trailerBytes = lenIn4 * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        // Trailer is exactly trailerBytes / 12 records.
        let mapCount = trailerBytes / 12
        let maps = try XkbIndicatorMapList.decode(from: trailer, count: mapCount, byteOrder: byteOrder)
        return XkbGetIndicatorMapReply(
            sequenceNumber: seq, deviceID: deviceID, which: which,
            nRealIndicators: nReal, nIndicators: n,
            maps: maps
        )
    }
}

// MARK: - Session 3 new replies

/// XkbGetIndicatorState reply — 32 bytes, flat. `state` is a 32-bit
/// bitmask of on/off per indicator.
public struct XkbGetIndicatorStateReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var state: UInt32

    public init(sequenceNumber: UInt16, deviceID: UInt8, state: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.deviceID = deviceID
        self.state = state
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(state)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetIndicatorStateReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let state = try r.readUInt32()
        return XkbGetIndicatorStateReply(sequenceNumber: seq, deviceID: deviceID, state: state)
    }
}

/// XkbGetCompatMap reply — 32-byte header + SymInterpret trailer
/// (each 16B) followed by optional 4×2B GroupCompat array.
public struct XkbGetCompatMapReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var mods: UInt8
    public var virtualMods: UInt16
    public var firstSI: UInt16
    public var nSI: UInt16
    public var nTotalSI: UInt16
    public var payload: XkbCompatPayload

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                mods: UInt8, virtualMods: UInt16,
                firstSI: UInt16, nSI: UInt16, nTotalSI: UInt16,
                payload: XkbCompatPayload = .empty) {
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.mods = mods; self.virtualMods = virtualMods
        self.firstSI = firstSI; self.nSI = nSI; self.nTotalSI = nTotalSI
        self.payload = payload
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let trailer = payload.encode(byteOrder: byteOrder)
        let lenIn4 = UInt32(trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt8(0); w.writeUInt8(mods)
        w.writeUInt16(virtualMods)
        w.writeUInt16(firstSI); w.writeUInt16(nSI); w.writeUInt16(nTotalSI)
        w.writePadding(2)
        w.writePadding(12)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetCompatMapReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        _ = try r.readUInt8()
        let mods = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let firstSI = try r.readUInt16()
        let nSI = try r.readUInt16()
        let nTotalSI = try r.readUInt16()
        try r.skip(2)
        try r.skip(12)
        let trailerBytes = lenIn4 * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        let siBytes = Int(nSI) * 16
        let includeGroupCompat = trailerBytes > siBytes
        let payload = try XkbCompatPayload.decode(
            from: trailer, nSymInterprets: Int(nSI),
            includeGroupCompat: includeGroupCompat,
            byteOrder: byteOrder
        )
        return XkbGetCompatMapReply(
            sequenceNumber: seq, deviceID: deviceID,
            mods: mods, virtualMods: virtualMods,
            firstSI: firstSI, nSI: nSI, nTotalSI: nTotalSI,
            payload: payload
        )
    }
}

/// XkbListAlternateSyms reply — 32 bytes flat with 20-byte inline indices.
public struct XkbListAlternateSymsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var nAlternateSyms: UInt8
    public var indices: [UInt8]   // exactly 20 bytes

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                nAlternateSyms: UInt8, indices: [UInt8]) {
        precondition(indices.count == 20, "indices must be 20 bytes")
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.nAlternateSyms = nAlternateSyms; self.indices = indices
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt8(nAlternateSyms); w.writePadding(3)
        w.writeBytes(indices)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbListAlternateSymsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let n = try r.readUInt8()
        try r.skip(3)
        let indices = try r.readBytes(20)
        return XkbListAlternateSymsReply(
            sequenceNumber: seq, deviceID: deviceID,
            nAlternateSyms: n, indices: indices
        )
    }
}

/// XkbGetAlternateSyms reply — 32-byte header + trailing CARD32 syms.
public struct XkbGetAlternateSymsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var name: UInt32
    public var index: UInt8
    public var nCharSets: UInt8
    public var firstKey: UInt8
    public var nKeys: UInt8
    public var totalSyms: UInt16
    public var syms: [UInt32]

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                name: UInt32, index: UInt8, nCharSets: UInt8,
                firstKey: UInt8, nKeys: UInt8,
                totalSyms: UInt16, syms: [UInt32] = []) {
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.name = name
        self.index = index; self.nCharSets = nCharSets
        self.firstKey = firstKey; self.nKeys = nKeys
        self.totalSyms = totalSyms; self.syms = syms
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(syms.count)   // each sym is 4 bytes
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(name)
        w.writeUInt8(index); w.writeUInt8(nCharSets)
        w.writeUInt8(firstKey); w.writeUInt8(nKeys)
        w.writeUInt16(totalSyms)
        w.writePadding(2)
        w.writePadding(12)
        for s in syms { w.writeUInt32(s) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetAlternateSymsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let name = try r.readUInt32()
        let index = try r.readUInt8()
        let nCharSets = try r.readUInt8()
        let firstKey = try r.readUInt8()
        let nKeys = try r.readUInt8()
        let totalSyms = try r.readUInt16()
        try r.skip(2)
        try r.skip(12)
        var syms: [UInt32] = []
        syms.reserveCapacity(lenIn4)
        for _ in 0..<lenIn4 { syms.append(try r.readUInt32()) }
        return XkbGetAlternateSymsReply(
            sequenceNumber: seq, deviceID: deviceID,
            name: name, index: index, nCharSets: nCharSets,
            firstKey: firstKey, nKeys: nKeys,
            totalSyms: totalSyms, syms: syms
        )
    }
}

/// XkbGetGeometry reply — 32-byte header + variable tree trailer.
/// Trailer kept raw for now (the Shape/Section/Doodad tree walker is
/// a deferred follow-up; real clients rarely emit this request).
public struct XkbGetGeometryReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var deviceID: UInt8
    public var name: UInt32
    public var width: UInt16
    public var height: UInt16
    public var shape: UInt8
    public var color: UInt8
    public var nShapes: UInt8
    public var nSections: UInt8
    public var nPoints: UInt16
    public var nOutlines: UInt16
    public var nColors: UInt8
    public var nDoodads: UInt8
    public var nLabels: UInt8
    public var nFonts: UInt8
    public var trailer: [UInt8]

    public init(sequenceNumber: UInt16, deviceID: UInt8,
                name: UInt32, width: UInt16, height: UInt16,
                shape: UInt8, color: UInt8,
                nShapes: UInt8, nSections: UInt8,
                nPoints: UInt16, nOutlines: UInt16,
                nColors: UInt8, nDoodads: UInt8,
                nLabels: UInt8, nFonts: UInt8,
                trailer: [UInt8] = []) {
        precondition(trailer.count % 4 == 0, "trailer must be 4-byte aligned")
        self.sequenceNumber = sequenceNumber; self.deviceID = deviceID
        self.name = name; self.width = width; self.height = height
        self.shape = shape; self.color = color
        self.nShapes = nShapes; self.nSections = nSections
        self.nPoints = nPoints; self.nOutlines = nOutlines
        self.nColors = nColors; self.nDoodads = nDoodads
        self.nLabels = nLabels; self.nFonts = nFonts
        self.trailer = trailer
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(deviceID); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(name)
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt8(shape); w.writeUInt8(color)
        w.writeUInt8(nShapes); w.writeUInt8(nSections)
        w.writeUInt16(nPoints); w.writeUInt16(nOutlines)
        w.writeUInt8(nColors); w.writeUInt8(nDoodads)
        w.writeUInt8(nLabels); w.writeUInt8(nFonts)
        w.writeUInt32(0)
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbGetGeometryReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let deviceID = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let name = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let shape = try r.readUInt8()
        let color = try r.readUInt8()
        let nShapes = try r.readUInt8()
        let nSections = try r.readUInt8()
        let nPoints = try r.readUInt16()
        let nOutlines = try r.readUInt16()
        let nColors = try r.readUInt8()
        let nDoodads = try r.readUInt8()
        let nLabels = try r.readUInt8()
        let nFonts = try r.readUInt8()
        try r.skip(4)
        let trailerBytes = lenIn4 * 4
        let trailer = trailerBytes > 0 ? try r.readBytes(trailerBytes) : []
        return XkbGetGeometryReply(
            sequenceNumber: seq, deviceID: deviceID,
            name: name, width: width, height: height,
            shape: shape, color: color,
            nShapes: nShapes, nSections: nSections,
            nPoints: nPoints, nOutlines: nOutlines,
            nColors: nColors, nDoodads: nDoodads,
            nLabels: nLabels, nFonts: nFonts,
            trailer: trailer
        )
    }
}

/// XkbSetDebuggingFlags reply — 32 bytes flat.
public struct XkbSetDebuggingFlagsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var disableLocks: UInt8
    public var currentFlags: UInt16

    public init(sequenceNumber: UInt16, disableLocks: UInt8, currentFlags: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.disableLocks = disableLocks
        self.currentFlags = currentFlags
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(disableLocks); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(currentFlags); w.writePadding(2)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSetDebuggingFlagsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let disableLocks = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let currentFlags = try r.readUInt16()
        return XkbSetDebuggingFlagsReply(
            sequenceNumber: seq, disableLocks: disableLocks,
            currentFlags: currentFlags
        )
    }
}
