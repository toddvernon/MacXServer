import Framer

// XKEYBOARD (XKB) extension dumper.
//
// Phase 3 Session 1 (2026-05-30) covers Tier A — the requests every
// Xlib client emits at startup, plus all 11 event flavors. Tier B
// (SetMap, SetNames, GetCompatMap, LatchLockState, Bell, etc.) and
// Tier C (Geometry, AlternateSyms) come in later sessions. The GetMap
// reply's nested-list trailer is captured raw and decoded in Session 2.
//
// XKB is unusual: every event shares ONE absolute event code
// (firstEvent + 0), with the actual event type living in byte 1
// (`xkbType`). So formatEvent sub-routes on byte 1 — not on the
// absolute code.

public enum XkbDumper: ExtensionDumper {
    public static let extensionName = "XKEYBOARD"
    public static let eventCount = 1   // all 11 sub-types share one absolute code

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {

        case XkbMinor.useExtension:
            if let r = try? XkbUseExtension.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbUseExtension          wanted=\(r.wantedMajor).\(r.wantedMinor)"
            }

        case XkbMinor.selectEvents:
            if let r = try? XkbSelectEvents.decode(from: bytes, byteOrder: byteOrder) {
                let trailer = r.detailTrailer.isEmpty ? "" : " trailer=\(r.detailTrailer.count)b"
                return "XkbSelectEvents          dev=\(r.deviceSpec) affect=\(hx(r.affectWhich)) clear=\(hx(r.clear)) selAll=\(hx(r.selectAll)) affMap=\(hx(r.affectMap)) map=\(hx(r.map))\(trailer)"
            }

        case XkbMinor.getState:
            if let r = try? XkbGetState.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetState              dev=\(r.deviceSpec)"
            }

        case XkbMinor.getControls:
            if let r = try? XkbGetControls.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetControls           dev=\(r.deviceSpec)"
            }

        case XkbMinor.getMap:
            if let r = try? XkbGetMap.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetMap                dev=\(r.deviceSpec) full=\(hx(r.full)) partial=\(hx(r.partial)) types=\(r.firstType)+\(r.nTypes) syms=\(r.firstKeySym)+\(r.nKeySyms) actions=\(r.firstKeyAction)+\(r.nKeyActions)"
            }

        case XkbMinor.setMap:
            if let r = try? XkbSetMap.decode(from: bytes, byteOrder: byteOrder) {
                let p = r.payload
                let summary = "types=\(p.keyTypes.count) syms=\(p.keySyms.count) actions=\(p.actions.count)/\(p.actionsPerKey.count)k behaviors=\(p.behaviors.count) vmods=\(p.virtualMods.count) explicits=\(p.explicits.count)"
                return "XkbSetMap                dev=\(r.deviceSpec) present=\(hx(r.present)) resize=\(hx(r.resize)) [\(summary)]"
            }

        case XkbMinor.getNames:
            if let r = try? XkbGetNames.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetNames              dev=\(r.deviceSpec) which=\(hx(r.which))"
            }

        case XkbMinor.getIndicatorMap:
            if let r = try? XkbGetIndicatorMap.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetIndicatorMap       dev=\(r.deviceSpec) which=\(hx(r.which))"
            }

        // Session 3 (Tier B)
        case XkbMinor.latchLockState:
            if let r = try? XkbLatchLockState.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbLatchLockState        dev=\(r.deviceSpec) modLocks=\(hx(r.modLocks))/aff=\(hx(r.affectModLocks)) modLatches=\(hx(r.modLatches))/aff=\(hx(r.affectModLatches)) group=lock=\(r.lockGroup):\(r.groupLock) latch=\(r.latchGroup):\(r.groupLatch)"
            }
        case XkbMinor.setControls:
            if let r = try? XkbSetControls.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSetControls           dev=\(r.deviceSpec) enabledControls=\(hx(r.enabledControls)) affect=\(hx(r.affectEnabledControls)) change=\(hx(r.changeControls)) repeat=\(r.repeatDelay)/\(r.repeatInterval)"
            }
        case XkbMinor.bell:
            if let r = try? XkbBell.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbBell                  dev=\(r.deviceSpec) class=\(r.bellClass) id=\(r.bellID) pct=\(r.percent) override=\(r.doOverride) name=\(hx(r.name)) window=\(hx(r.window))"
            }
        case XkbMinor.sendEvent:
            if let r = try? XkbSendEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSendEvent             dst=\(hx(r.destination)) mask=\(hx(r.eventMask)) propagate=\(r.propagate) synthClick=\(r.synthesizeClick) eventBytes=\(r.eventBytes.count)b"
            }
        case XkbMinor.getIndicatorState:
            if let r = try? XkbGetIndicatorState.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetIndicatorState     dev=\(r.deviceSpec)"
            }
        case XkbMinor.setIndicatorMap:
            if let r = try? XkbSetIndicatorMap.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSetIndicatorMap       dev=\(r.deviceSpec) which=\(hx(r.which)) maps=\(r.maps.count)"
            }
        case XkbMinor.getCompatMap:
            if let r = try? XkbGetCompatMap.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetCompatMap          dev=\(r.deviceSpec) vmods=\(hx(r.virtualMods)) mods=\(hx(r.mods)) getAllSI=\(r.getAllSI) firstSI=\(r.firstSI) nSI=\(r.nSI)"
            }
        case XkbMinor.setCompatMap:
            if let r = try? XkbSetCompatMap.decode(from: bytes, byteOrder: byteOrder) {
                let gc = r.payload.groupCompat.isEmpty ? "" : " +groupCompat"
                return "XkbSetCompatMap          dev=\(r.deviceSpec) recompute=\(r.recomputeActions) truncate=\(r.truncateSI) mods=\(hx(r.mods)) firstSI=\(r.firstSI) nSI=\(r.nSI) symInterprets=\(r.payload.symInterprets.count)\(gc)"
            }
        case XkbMinor.setNames:
            if let r = try? XkbSetNames.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSetNames              dev=\(r.deviceSpec) which=\(hx(r.which)) types=\(r.firstType)+\(r.nTypes) keys=\(r.firstKey)+\(r.nKeys) trailer=\(r.trailer.count)b"
            }

        // Session 3 (Tier C)
        case XkbMinor.listAlternateSyms:
            if let r = try? XkbListAlternateSyms.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbListAlternateSyms     dev=\(r.deviceSpec) name=\(hx(r.name)) charset=\(hx(r.charset))"
            }
        case XkbMinor.getAlternateSyms:
            if let r = try? XkbGetAlternateSyms.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetAlternateSyms      dev=\(r.deviceSpec) index=\(r.index) keys=\(r.firstKey)+\(r.nKeys)"
            }
        case XkbMinor.setAlternateSyms:
            if let r = try? XkbSetAlternateSyms.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSetAlternateSyms      dev=\(r.deviceSpec) create=\(r.create) replace=\(r.replace) present=\(hx(r.present)) name=\(hx(r.name)) syms=\(r.syms.count)"
            }
        case XkbMinor.getGeometry:
            if let r = try? XkbGetGeometry.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbGetGeometry           dev=\(r.deviceSpec) name=\(hx(r.name))"
            }
        case XkbMinor.setGeometry:
            if let r = try? XkbSetGeometry.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSetGeometry           dev=\(r.deviceSpec) name=\(hx(r.name)) \(r.widthMM)x\(r.heightMM)mm shapes=\(r.nShapes) sections=\(r.nSections) trailer=\(r.trailer.count)b"
            }
        case XkbMinor.setDebuggingFlags:
            if let r = try? XkbSetDebuggingFlags.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSetDebuggingFlags     mask=\(hx(r.mask)) flags=\(hx(r.flags)) disableLocks=\(r.disableLocks) msg=\(r.message.count)b"
            }

        default:
            break
        }
        return nil
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        // All 11 XKB events share one absolute event code; the
        // discriminator is byte 1 (xkbType).
        guard bytes.count >= 2 else { return nil }
        let code = bytes[0] & 0x7F
        guard code == firstEvent else { return nil }

        switch bytes[1] {

        case XkbEventType.mapNotify:
            if let e = try? XkbMapNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbMapNotify             dev=\(e.deviceID) changed=\(hx(e.changed)) types=\(e.firstType)+\(e.nTypes)"
            }

        case XkbEventType.stateNotify:
            if let e = try? XkbStateNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbStateNotify           dev=\(e.deviceID) mods=\(hx(e.mods)) group=\(e.group) changed=\(hx(e.changed)) keycode=\(e.keycode)"
            }

        case XkbEventType.controlsNotify:
            if let e = try? XkbControlsNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbControlsNotify        dev=\(e.deviceID) changed=\(hx(e.changedControls)) enabled=\(hx(e.enabledControls))"
            }

        case XkbEventType.indicatorStateNotify, XkbEventType.indicatorMapNotify:
            if let e = try? XkbIndicatorNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                let flavor = e.xkbType == XkbEventType.indicatorStateNotify ? "State" : "Map"
                return "XkbIndicator\(flavor)Notify  dev=\(e.deviceID) stateChanged=\(hx(e.stateChanged)) state=\(hx(e.state)) mapChanged=\(hx(e.mapChanged))"
            }

        case XkbEventType.namesNotify:
            if let e = try? XkbNamesNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbNamesNotify           dev=\(e.deviceID) changed=\(hx(e.changed)) changedIndicators=\(hx(e.changedIndicators))"
            }

        case XkbEventType.compatMapNotify:
            if let e = try? XkbCompatMapNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbCompatMapNotify       dev=\(e.deviceID) changedMods=\(hx(e.changedMods)) firstSI=\(e.firstSI) nSI=\(e.nSI) total=\(e.nTotalSI)"
            }

        case XkbEventType.alternateSymsNotify:
            if let e = try? XkbAlternateSymsNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbAlternateSymsNotify   dev=\(e.deviceID) altSymsID=\(e.altSymsID) firstKey=\(e.firstKey) nKeys=\(e.nKeys)"
            }

        case XkbEventType.bellNotify:
            if let e = try? XkbBellNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbBellNotify            dev=\(e.deviceID) class=\(e.bellClass) id=\(e.bellID) percent=\(e.percent) pitch=\(e.pitch) duration=\(e.duration) name=\(hx(e.name)) window=\(hx(e.window))"
            }

        case XkbEventType.actionMessage:
            if let e = try? XkbActionMessageEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbActionMessage         dev=\(e.deviceID) keycode=\(e.keycode) press=\(e.press) followedBy=\(e.keyEventFollows) message=\(e.message)"
            }

        case XkbEventType.slowKeyNotify:
            if let e = try? XkbSlowKeyNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XkbSlowKeyNotify         dev=\(e.deviceID) state=\(e.slowKeyState) keycode=\(e.keycode) delay=\(e.delay)"
            }

        default:
            break
        }
        return nil
    }

    private static func hex(_ v: UInt8) -> String { "0x" + String(v, radix: 16) }
    private static func hex(_ v: UInt16) -> String { "0x" + String(v, radix: 16) }
    private static func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }
    // Single-argument call site picks the right overload via integer type.
    private static func hx(_ v: UInt8) -> String { hex(v) }
    private static func hx(_ v: UInt16) -> String { hex(v) }
    private static func hx(_ v: UInt32) -> String { hex(v) }
}
