// XKEYBOARD (XKB) extension event wire types — all 11 of them.
//
// XKB is unusual among extensions: every event shares ONE event code
// (firstEvent + XkbEventCode = firstEvent + 0), and the actual event
// type lives in the `xkbType` byte at offset 1. So a single dumper
// dispatcher routes on that byte, not on the absolute code.
//
// All 11 are exactly 32 bytes; no variable trailers. Layouts verified
// against reference/X11R6/xc/include/extensions/XKBproto.h.

/// Sub-event discriminator at byte 1. XkbDumper.formatEvent routes on
/// these. Names match `#define XkbXxxNotify` in XKB.h.
public enum XkbEventType {
    public static let mapNotify: UInt8 = 0
    public static let stateNotify: UInt8 = 1
    public static let controlsNotify: UInt8 = 2
    public static let indicatorStateNotify: UInt8 = 3
    public static let indicatorMapNotify: UInt8 = 4
    public static let namesNotify: UInt8 = 5
    public static let compatMapNotify: UInt8 = 6
    public static let alternateSymsNotify: UInt8 = 7
    public static let bellNotify: UInt8 = 8
    public static let actionMessage: UInt8 = 9
    public static let slowKeyNotify: UInt8 = 10
}

/// Generic XKB event envelope: same first 8 bytes for every XKB event,
/// then the per-flavor body. Useful when the dispatcher just wants
/// `xkbType` and `time` without fully decoding.
public struct XkbAnyEvent: Equatable, Sendable {
    public var type: UInt8         // firstEvent + 0
    public var xkbType: UInt8      // one of XkbEventType.*
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbAnyEvent {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8()
        let xkbType = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let deviceID = try r.readUInt8()
        return XkbAnyEvent(type: type, xkbType: xkbType, sequenceNumber: seq,
                           time: time, deviceID: deviceID)
    }
}

// MARK: - XkbStateNotify (xkbType=1)

public struct XkbStateNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
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
    public var keycode: UInt8
    public var eventType: UInt8
    public var requestMajor: UInt8
    public var requestMinor: UInt8
    public var changed: UInt16

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.stateNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID)
        w.writeUInt8(mods); w.writeUInt8(baseMods)
        w.writeUInt8(latchedMods); w.writeUInt8(lockedMods)
        w.writeUInt8(group); w.writeUInt8(baseGroup)
        w.writeUInt8(latchedGroup); w.writeUInt8(lockedGroup)
        w.writeUInt8(compatState)
        w.writeUInt8(keycode); w.writeUInt8(eventType)
        w.writeUInt8(requestMajor); w.writeUInt8(requestMinor)
        w.writeUInt16(changed)
        w.writePadding(8)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbStateNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8()
        let mods = try r.readUInt8(); let baseMods = try r.readUInt8()
        let latchedMods = try r.readUInt8(); let lockedMods = try r.readUInt8()
        let group = try r.readUInt8(); let baseGroup = try r.readUInt8()
        let latchedGroup = try r.readUInt8(); let lockedGroup = try r.readUInt8()
        let compatState = try r.readUInt8()
        let keycode = try r.readUInt8(); let eventType = try r.readUInt8()
        let requestMajor = try r.readUInt8(); let requestMinor = try r.readUInt8()
        let changed = try r.readUInt16()
        return XkbStateNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            mods: mods, baseMods: baseMods,
            latchedMods: latchedMods, lockedMods: lockedMods,
            group: group, baseGroup: baseGroup,
            latchedGroup: latchedGroup, lockedGroup: lockedGroup,
            compatState: compatState,
            keycode: keycode, eventType: eventType,
            requestMajor: requestMajor, requestMinor: requestMinor,
            changed: changed
        )
    }
}

// MARK: - XkbMapNotify (xkbType=0)

public struct XkbMapNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var changed: UInt16
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

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.mapNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(0)             // pad1
        w.writeUInt8(deviceID)
        w.writeUInt16(changed)
        w.writeUInt8(firstType); w.writeUInt8(nTypes)
        w.writeUInt8(firstKeySym); w.writeUInt8(nKeySyms)
        w.writeUInt8(firstKeyAction); w.writeUInt8(nKeyActions)
        w.writeUInt8(firstKeyBehavior); w.writeUInt8(nKeyBehaviors)
        w.writeUInt16(virtualMods)
        w.writeUInt8(firstKeyExplicit); w.writeUInt8(nKeyExplicit)
        w.writePadding(8)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbMapNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        try r.skip(1)
        let deviceID = try r.readUInt8()
        let changed = try r.readUInt16()
        let firstType = try r.readUInt8(); let nTypes = try r.readUInt8()
        let firstKeySym = try r.readUInt8(); let nKeySyms = try r.readUInt8()
        let firstKeyAction = try r.readUInt8(); let nKeyActions = try r.readUInt8()
        let firstKeyBehavior = try r.readUInt8(); let nKeyBehaviors = try r.readUInt8()
        let virtualMods = try r.readUInt16()
        let firstKeyExplicit = try r.readUInt8(); let nKeyExplicit = try r.readUInt8()
        return XkbMapNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            changed: changed,
            firstType: firstType, nTypes: nTypes,
            firstKeySym: firstKeySym, nKeySyms: nKeySyms,
            firstKeyAction: firstKeyAction, nKeyActions: nKeyActions,
            firstKeyBehavior: firstKeyBehavior, nKeyBehaviors: nKeyBehaviors,
            virtualMods: virtualMods,
            firstKeyExplicit: firstKeyExplicit, nKeyExplicit: nKeyExplicit
        )
    }
}

// MARK: - XkbControlsNotify (xkbType=2)

public struct XkbControlsNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var changedControls: UInt32
    public var enabledControls: UInt32
    public var enabledControlChanges: UInt32
    public var keycode: UInt8
    public var eventType: UInt8
    public var requestMajor: UInt8
    public var requestMinor: UInt8

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.controlsNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writePadding(3)
        w.writeUInt32(changedControls)
        w.writeUInt32(enabledControls)
        w.writeUInt32(enabledControlChanges)
        w.writeUInt8(keycode); w.writeUInt8(eventType)
        w.writeUInt8(requestMajor); w.writeUInt8(requestMinor)
        w.writePadding(4)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbControlsNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); try r.skip(3)
        let changed = try r.readUInt32()
        let enabled = try r.readUInt32()
        let enabledChanges = try r.readUInt32()
        let keycode = try r.readUInt8(); let eventType = try r.readUInt8()
        let reqMajor = try r.readUInt8(); let reqMinor = try r.readUInt8()
        return XkbControlsNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            changedControls: changed, enabledControls: enabled,
            enabledControlChanges: enabledChanges,
            keycode: keycode, eventType: eventType,
            requestMajor: reqMajor, requestMinor: reqMinor
        )
    }
}

// MARK: - XkbIndicatorNotify (xkbType=3 IndicatorState, xkbType=4 IndicatorMap; same struct)

public struct XkbIndicatorNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var xkbType: UInt8       // 3 or 4
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var stateChanged: UInt32
    public var state: UInt32
    public var mapChanged: UInt32

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(xkbType)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writePadding(3)
        w.writeUInt32(stateChanged); w.writeUInt32(state); w.writeUInt32(mapChanged)
        w.writePadding(8)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbIndicatorNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); let xkbType = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); try r.skip(3)
        let stateChanged = try r.readUInt32()
        let state = try r.readUInt32()
        let mapChanged = try r.readUInt32()
        return XkbIndicatorNotifyEvent(
            type: type, xkbType: xkbType,
            sequenceNumber: seq, time: time, deviceID: deviceID,
            stateChanged: stateChanged, state: state, mapChanged: mapChanged
        )
    }
}

// MARK: - XkbNamesNotify (xkbType=5)

public struct XkbNamesNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var changed: UInt16
    public var firstType: UInt8
    public var nTypes: UInt8
    public var firstLevelName: UInt8
    public var nLevelNames: UInt8
    public var firstRadioGroup: UInt8
    public var nRadioGroups: UInt8
    public var nCharSets: UInt8
    public var changedMods: UInt8
    public var changedVirtualMods: UInt16
    public var changedIndicators: UInt32

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.namesNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writePadding(1)
        w.writeUInt16(changed)
        w.writeUInt8(firstType); w.writeUInt8(nTypes)
        w.writeUInt8(firstLevelName); w.writeUInt8(nLevelNames)
        w.writeUInt8(firstRadioGroup); w.writeUInt8(nRadioGroups)
        w.writeUInt8(nCharSets); w.writeUInt8(changedMods)
        w.writeUInt16(changedVirtualMods)
        w.writePadding(2)
        w.writeUInt32(changedIndicators)
        w.writePadding(4)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbNamesNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); try r.skip(1)
        let changed = try r.readUInt16()
        let firstType = try r.readUInt8(); let nTypes = try r.readUInt8()
        let firstLevelName = try r.readUInt8(); let nLevelNames = try r.readUInt8()
        let firstRadioGroup = try r.readUInt8(); let nRadioGroups = try r.readUInt8()
        let nCharSets = try r.readUInt8(); let changedMods = try r.readUInt8()
        let changedVirtualMods = try r.readUInt16()
        try r.skip(2)
        let changedIndicators = try r.readUInt32()
        return XkbNamesNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            changed: changed,
            firstType: firstType, nTypes: nTypes,
            firstLevelName: firstLevelName, nLevelNames: nLevelNames,
            firstRadioGroup: firstRadioGroup, nRadioGroups: nRadioGroups,
            nCharSets: nCharSets, changedMods: changedMods,
            changedVirtualMods: changedVirtualMods,
            changedIndicators: changedIndicators
        )
    }
}

// MARK: - XkbCompatMapNotify (xkbType=6)

public struct XkbCompatMapNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var changedMods: UInt8
    public var changedVirtualMods: UInt16
    public var firstSI: UInt16
    public var nSI: UInt16
    public var nTotalSI: UInt16

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.compatMapNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writeUInt8(changedMods)
        w.writeUInt16(changedVirtualMods)
        w.writeUInt16(firstSI); w.writeUInt16(nSI); w.writeUInt16(nTotalSI)
        w.writePadding(14)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbCompatMapNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8()
        let changedMods = try r.readUInt8()
        let changedVirtualMods = try r.readUInt16()
        let firstSI = try r.readUInt16(); let nSI = try r.readUInt16()
        let nTotalSI = try r.readUInt16()
        return XkbCompatMapNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            changedMods: changedMods, changedVirtualMods: changedVirtualMods,
            firstSI: firstSI, nSI: nSI, nTotalSI: nTotalSI
        )
    }
}

// MARK: - XkbBellNotify (xkbType=8)

public struct XkbBellNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var bellClass: UInt8
    public var bellID: UInt8
    public var percent: UInt8
    public var pitch: UInt16
    public var duration: UInt16
    public var name: UInt32
    public var window: UInt32

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.bellNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writeUInt8(bellClass)
        w.writeUInt8(bellID); w.writeUInt8(percent)
        w.writeUInt16(pitch); w.writeUInt16(duration)
        w.writeUInt32(name); w.writeUInt32(window)
        w.writePadding(8)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbBellNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8()
        let bellClass = try r.readUInt8(); let bellID = try r.readUInt8()
        let percent = try r.readUInt8()
        let pitch = try r.readUInt16(); let duration = try r.readUInt16()
        let name = try r.readUInt32(); let window = try r.readUInt32()
        return XkbBellNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            bellClass: bellClass, bellID: bellID, percent: percent,
            pitch: pitch, duration: duration, name: name, window: window
        )
    }
}

// MARK: - XkbAlternateSymsNotify (xkbType=7)

public struct XkbAlternateSymsNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var altSymsID: UInt8
    public var firstKey: UInt8
    public var nKeys: UInt8

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.alternateSymsNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writeUInt8(altSymsID)
        w.writeUInt8(firstKey); w.writeUInt8(nKeys)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbAlternateSymsNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); let altSymsID = try r.readUInt8()
        let firstKey = try r.readUInt8(); let nKeys = try r.readUInt8()
        return XkbAlternateSymsNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            altSymsID: altSymsID, firstKey: firstKey, nKeys: nKeys
        )
    }
}

// MARK: - XkbActionMessage (xkbType=9)

public struct XkbActionMessageEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var keycode: UInt8
    public var press: Bool
    public var keyEventFollows: Bool
    public var message: [UInt8]   // 8 bytes

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        precondition(message.count == 8, "ActionMessage message must be 8 bytes")
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.actionMessage)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writeUInt8(keycode)
        w.writeUInt8(press ? 1 : 0); w.writeUInt8(keyEventFollows ? 1 : 0)
        w.writeBytes(message)
        w.writePadding(12)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbActionMessageEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); let keycode = try r.readUInt8()
        let press = try r.readUInt8() != 0
        let kef = try r.readUInt8() != 0
        let msg = try r.readBytes(8)
        return XkbActionMessageEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            keycode: keycode, press: press, keyEventFollows: kef,
            message: msg
        )
    }
}

// MARK: - XkbSlowKeyNotify (xkbType=10)

public struct XkbSlowKeyNotifyEvent: Equatable, Sendable {
    public var type: UInt8
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var deviceID: UInt8
    public var slowKeyState: UInt8
    public var keycode: UInt8
    public var delay: UInt16

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(XkbEventType.slowKeyNotify)
        w.writeUInt16(sequenceNumber); w.writeUInt32(time)
        w.writeUInt8(deviceID); w.writeUInt8(slowKeyState)
        w.writeUInt8(keycode); w.writePadding(1)
        w.writeUInt16(delay)
        w.writePadding(18)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> XkbSlowKeyNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16(); let time = try r.readUInt32()
        let deviceID = try r.readUInt8(); let slowKeyState = try r.readUInt8()
        let keycode = try r.readUInt8(); try r.skip(1)
        let delay = try r.readUInt16()
        return XkbSlowKeyNotifyEvent(
            type: type, sequenceNumber: seq, time: time, deviceID: deviceID,
            slowKeyState: slowKeyState, keycode: keycode, delay: delay
        )
    }
}
