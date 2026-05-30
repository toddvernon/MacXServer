import XCTest
@testable import Framer

// XKB Phase 3 Session 1 (2026-05-30) round-trip tests. Each test
// encodes a representative value, decodes the bytes, asserts field
// equality + byte-identical re-encode in both byte orders.

final class XkbRoundTripTests: XCTestCase {

    private func roundTrip<T: Equatable>(
        _ original: T,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count % 4, 0, "\(T.self) bytes must be 4-byte aligned", file: file, line: line)
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "\(T.self) field equality fails in \(order)", file: file, line: line)
            XCTAssertEqual(bytes, encode(decoded, order), "\(T.self) byte-identical round-trip fails in \(order)", file: file, line: line)
        }
    }

    // MARK: - Tier A requests

    func testUseExtension() throws {
        try roundTrip(XkbUseExtension(wantedMajor: 1, wantedMinor: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbUseExtension.decode(from: $0, byteOrder: $1) })
    }

    func testSelectEventsNoTrailer() throws {
        try roundTrip(XkbSelectEvents(
            deviceSpec: 0x0100, affectWhich: 0xFFFF,
            clear: 0, selectAll: 0xFFFF,
            affectMap: 0, map: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSelectEvents.decode(from: $0, byteOrder: $1) })
    }

    func testSelectEventsWithTrailer() throws {
        try roundTrip(XkbSelectEvents(
            deviceSpec: 0x0100, affectWhich: 0xFFFF,
            clear: 0, selectAll: 0, affectMap: 0, map: 0,
            detailTrailer: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSelectEvents.decode(from: $0, byteOrder: $1) })
    }

    func testGetState() throws {
        try roundTrip(XkbGetState(deviceSpec: 0x0100),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetState.decode(from: $0, byteOrder: $1) })
    }

    func testGetControls() throws {
        try roundTrip(XkbGetControls(deviceSpec: 0x0100),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetControls.decode(from: $0, byteOrder: $1) })
    }

    func testGetMap() throws {
        try roundTrip(XkbGetMap(
            deviceSpec: 0x0100, full: 0x00FF, partial: 0,
            firstType: 0, nTypes: 4,
            firstKeySym: 8, nKeySyms: 240,
            firstKeyAction: 8, nKeyActions: 240,
            firstKeyBehavior: 0, nKeyBehaviors: 0,
            virtualMods: 0xFFFF,
            firstKeyExplicit: 0, nKeyExplicit: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetMap.decode(from: $0, byteOrder: $1) })
    }

    func testGetNames() throws {
        try roundTrip(XkbGetNames(deviceSpec: 0x0100, which: 0xFFFFFFFF),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetNames.decode(from: $0, byteOrder: $1) })
    }

    func testGetIndicatorMap() throws {
        try roundTrip(XkbGetIndicatorMap(deviceSpec: 0x0100, which: 0xFFFFFFFF),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetIndicatorMap.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Tier A replies

    func testUseExtensionReply() throws {
        try roundTrip(XkbUseExtensionReply(
            sequenceNumber: 5, supported: true,
            serverMajor: 1, serverMinor: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbUseExtensionReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetStateReply() throws {
        try roundTrip(XkbGetStateReply(
            sequenceNumber: 7, deviceID: 3,
            mods: 0x05, baseMods: 0x01,
            latchedMods: 0, lockedMods: 0x04,
            group: 0, baseGroup: 0,
            latchedGroup: 0, lockedGroup: 0,
            compatState: 0x05),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetStateReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetControlsReply() throws {
        try roundTrip(XkbGetControlsReply(
            sequenceNumber: 11, deviceID: 3,
            mouseKeysDfltBtn: 1, numGroups: 1,
            internalMods: 0, ignoreLockMods: 0,
            internalRealMods: 0, ignoreLockRealMods: 0,
            internalVirtualMods: 0, ignoreLockVirtualMods: 0,
            enabledControls: 0x0000_07FF,
            repeatDelay: 500, repeatInterval: 30,
            slowKeysDelay: 0, debounceDelay: 0,
            mouseKeysDelay: 160, mouseKeysInterval: 40,
            mouseKeysTimeToMax: 30, mouseKeysMaxSpeed: 10,
            mouseKeysCurve: 0,
            accessXTimeout: 120, accessXTimeoutMask: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetControlsReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetMapReplyEmptyPayload() throws {
        // All counts zero → trailer is empty.
        try roundTrip(XkbGetMapReply(
            sequenceNumber: 13, deviceID: 3,
            minKeyCode: 8, maxKeyCode: 255,
            present: 0,
            firstType: 0, nTypes: 0, totalTypes: 16,
            firstKeySym: 0, nKeySyms: 0,
            firstKeyAction: 0, nKeyActions: 0,
            totalKeyBehaviors: 0,
            virtualMods: 0,
            totalSyms: 0, totalActions: 0,
            totalKeyExplicit: 0,
            payload: .empty),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetMapReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetMapReplyWithTypedPayload() throws {
        // A representative mid-sized payload exercising every section.
        let kt = XkbKeyType(
            mask: 0x07, realMods: 0x05, virtualMods: 0,
            groupWidth: 2,
            mapEntries: [
                XkbKTMapEntry(active: true, mask: 0x01, level: 0, realMods: 0x01, virtualMods: 0),
                XkbKTMapEntry(active: true, mask: 0x02, level: 1, realMods: 0x02, virtualMods: 0),
            ])
        let sm = XkbSymMap(ktIndex: 0, groupInfo: 0x10,
                           syms: [0xFF01, 0xFF02, 0xFF03])
        let payload = XkbMapPayload(
            keyTypes: [kt],
            keySyms: [sm],
            actionsPerKey: [2, 0, 1],          // 3 keys covered; one with 2, one with 0, one with 1
            actions: [
                XkbAction(type: 1, data: [0,0,0,0,0,0,0]),
                XkbAction(type: 2, data: [1,2,3,4,5,6,7]),
                XkbAction(type: 3, data: [9,9,9,9,9,9,9]),
            ],
            behaviors: [XkbBehavior(key: 8, type: 1, data: 0)],
            virtualMods: [0x10, 0x20],          // two set bits → two values
            explicits: [XkbExplicit(key: 24, explicit: 0x01)]
        )
        try roundTrip(XkbGetMapReply(
            sequenceNumber: 14, deviceID: 3,
            minKeyCode: 8, maxKeyCode: 255,
            present: 0x00FF,
            firstType: 0, nTypes: 1, totalTypes: 4,
            firstKeySym: 8, nKeySyms: 1,
            firstKeyAction: 8, nKeyActions: 3,
            totalKeyBehaviors: 1,
            virtualMods: 0b0000_0000_0000_0011,   // popcount=2 matches virtualMods.count
            totalSyms: 3, totalActions: 3,
            totalKeyExplicit: 1,
            payload: payload),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetMapReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetMapReplyWithPreserves() throws {
        // KeyType with `preserves` set (the conditional preserve array).
        let kt = XkbKeyType(
            mask: 0x07, realMods: 0x05, virtualMods: 0,
            groupWidth: 2,
            mapEntries: [
                XkbKTMapEntry(active: true, mask: 0x01, level: 0, realMods: 0x01, virtualMods: 0),
                XkbKTMapEntry(active: true, mask: 0x02, level: 1, realMods: 0x02, virtualMods: 0),
            ],
            preserves: [
                XkbKTPreserveEntry(mask: 0x01, realMods: 0x01, virtualMods: 0),
                XkbKTPreserveEntry(mask: 0x02, realMods: 0x02, virtualMods: 0),
            ])
        try roundTrip(XkbGetMapReply(
            sequenceNumber: 15, deviceID: 3,
            minKeyCode: 8, maxKeyCode: 255,
            present: 0x0001,
            firstType: 0, nTypes: 1, totalTypes: 1,
            firstKeySym: 0, nKeySyms: 0,
            firstKeyAction: 0, nKeyActions: 0,
            totalKeyBehaviors: 0,
            virtualMods: 0,
            totalSyms: 0, totalActions: 0,
            totalKeyExplicit: 0,
            payload: XkbMapPayload(keyTypes: [kt])),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetMapReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetNamesReplyHeaderOnly() throws {
        try roundTrip(XkbGetNamesReply(
            sequenceNumber: 17, deviceID: 3,
            which: 0xFFFFFFFF,
            nTypes: 4, modifiers: 0, virtualMods: 0,
            firstKey: 8, nKeys: 240,
            nRadioGroups: 0, nCharSets: 0,
            indicators: 0x0000_00FF,
            trailer: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetNamesReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetIndicatorMapReplyEmpty() throws {
        try roundTrip(XkbGetIndicatorMapReply(
            sequenceNumber: 19, deviceID: 3,
            which: 0,
            nRealIndicators: 3, nIndicators: 32,
            maps: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetIndicatorMapReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetIndicatorMapReplyWithMaps() throws {
        try roundTrip(XkbGetIndicatorMapReply(
            sequenceNumber: 20, deviceID: 3,
            which: 0b0111,    // 3 indicators
            nRealIndicators: 3, nIndicators: 32,
            maps: [
                XkbIndicatorMapEntry(flags: 0x01, whichGroups: 0x02, groups: 0x03,
                                     whichMods: 0x04, mods: 0x05, realMods: 0x06,
                                     virtualMods: 0x0007, ctrls: 0x0000_0008),
                XkbIndicatorMapEntry(flags: 0x11, whichGroups: 0x12, groups: 0x13,
                                     whichMods: 0x14, mods: 0x15, realMods: 0x16,
                                     virtualMods: 0x0017, ctrls: 0x0000_0018),
                XkbIndicatorMapEntry(flags: 0x21, whichGroups: 0x22, groups: 0x23,
                                     whichMods: 0x24, mods: 0x25, realMods: 0x26,
                                     virtualMods: 0x0027, ctrls: 0x0000_0028),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetIndicatorMapReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Events (all 11)

    func testStateNotifyEvent() throws {
        try roundTrip(XkbStateNotifyEvent(
            type: 85, sequenceNumber: 3, time: 12345, deviceID: 3,
            mods: 0x05, baseMods: 0x01,
            latchedMods: 0, lockedMods: 0x04,
            group: 0, baseGroup: 0,
            latchedGroup: 0, lockedGroup: 0,
            compatState: 0x05,
            keycode: 24, eventType: 4,
            requestMajor: 135, requestMinor: 4,
            changed: 0x000F),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbStateNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testMapNotifyEvent() throws {
        try roundTrip(XkbMapNotifyEvent(
            type: 85, sequenceNumber: 4, time: 12345, deviceID: 3,
            changed: 0x000F,
            firstType: 0, nTypes: 4,
            firstKeySym: 8, nKeySyms: 240,
            firstKeyAction: 0, nKeyActions: 0,
            firstKeyBehavior: 0, nKeyBehaviors: 0,
            virtualMods: 0,
            firstKeyExplicit: 0, nKeyExplicit: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbMapNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testControlsNotifyEvent() throws {
        try roundTrip(XkbControlsNotifyEvent(
            type: 85, sequenceNumber: 5, time: 12345, deviceID: 3,
            changedControls: 0x07FF, enabledControls: 0x0003,
            enabledControlChanges: 0x0001,
            keycode: 0, eventType: 0,
            requestMajor: 135, requestMinor: 7),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbControlsNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testIndicatorNotifyEvents() throws {
        for sub in [XkbEventType.indicatorStateNotify, XkbEventType.indicatorMapNotify] {
            try roundTrip(XkbIndicatorNotifyEvent(
                type: 85, xkbType: sub,
                sequenceNumber: 6, time: 12345, deviceID: 3,
                stateChanged: 0x000F, state: 0x0001, mapChanged: 0),
                encode: { $0.encode(byteOrder: $1) },
                decode: { try XkbIndicatorNotifyEvent.decode(from: $0, byteOrder: $1) })
        }
    }

    func testNamesNotifyEvent() throws {
        try roundTrip(XkbNamesNotifyEvent(
            type: 85, sequenceNumber: 7, time: 12345, deviceID: 3,
            changed: 0x00FF,
            firstType: 0, nTypes: 4,
            firstLevelName: 0, nLevelNames: 4,
            firstRadioGroup: 0, nRadioGroups: 0,
            nCharSets: 0, changedMods: 0x01,
            changedVirtualMods: 0,
            changedIndicators: 0x0000_00FF),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbNamesNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testCompatMapNotifyEvent() throws {
        try roundTrip(XkbCompatMapNotifyEvent(
            type: 85, sequenceNumber: 8, time: 12345, deviceID: 3,
            changedMods: 0x01, changedVirtualMods: 0,
            firstSI: 0, nSI: 4, nTotalSI: 16),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbCompatMapNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testBellNotifyEvent() throws {
        try roundTrip(XkbBellNotifyEvent(
            type: 85, sequenceNumber: 9, time: 12345, deviceID: 3,
            bellClass: 1, bellID: 0, percent: 75,
            pitch: 400, duration: 100,
            name: 0x12345678, window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbBellNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testAlternateSymsNotifyEvent() throws {
        try roundTrip(XkbAlternateSymsNotifyEvent(
            type: 85, sequenceNumber: 10, time: 12345, deviceID: 3,
            altSymsID: 2, firstKey: 8, nKeys: 240),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbAlternateSymsNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testActionMessageEvent() throws {
        try roundTrip(XkbActionMessageEvent(
            type: 85, sequenceNumber: 11, time: 12345, deviceID: 3,
            keycode: 24, press: true, keyEventFollows: false,
            message: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbActionMessageEvent.decode(from: $0, byteOrder: $1) })
    }

    func testSlowKeyNotifyEvent() throws {
        try roundTrip(XkbSlowKeyNotifyEvent(
            type: 85, sequenceNumber: 12, time: 12345, deviceID: 3,
            slowKeyState: 1, keycode: 24, delay: 250),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbSlowKeyNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - XkbSetMap + XkbMapPayload (Session 2)

    func testSetMapEmptyPayload() throws {
        try roundTrip(XkbSetMap(
            deviceSpec: 0x0100, present: 0, resize: 0,
            firstType: 0, nTypes: 0,
            firstKeySym: 0, nKeySyms: 0,
            firstKeyAction: 0, nKeyActions: 0,
            totalKeyBehaviors: 0,
            virtualMods: 0,
            totalKeyExplicit: 0,
            totalSyms: 0, totalActions: 0,
            payload: .empty),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetMap.decode(from: $0, byteOrder: $1) })
    }

    func testSetMapMixedPayload() throws {
        // Mirror the GetMap reply test but on the request side.
        let kt = XkbKeyType(
            mask: 0x07, realMods: 0x05, virtualMods: 0, groupWidth: 2,
            mapEntries: [
                XkbKTMapEntry(active: true, mask: 0x01, level: 0, realMods: 0x01, virtualMods: 0),
            ])
        let payload = XkbMapPayload(
            keyTypes: [kt],
            keySyms: [XkbSymMap(ktIndex: 0, groupInfo: 0, syms: [0xFF01])],
            actionsPerKey: [1, 0],
            actions: [XkbAction(type: 1, data: [0,0,0,0,0,0,0])],
            behaviors: [XkbBehavior(key: 8, type: 1, data: 0)],
            virtualMods: [0x10],
            explicits: [XkbExplicit(key: 24, explicit: 0x01)]
        )
        try roundTrip(XkbSetMap(
            deviceSpec: 0x0100,
            present: 0x00FF, resize: 0,
            firstType: 0, nTypes: 1,
            firstKeySym: 8, nKeySyms: 1,
            firstKeyAction: 8, nKeyActions: 2,
            totalKeyBehaviors: 1,
            virtualMods: 0b1,           // popcount=1
            totalKeyExplicit: 1,
            totalSyms: 1, totalActions: 1,
            payload: payload),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetMap.decode(from: $0, byteOrder: $1) })
    }

    func testMapPayloadAlignment() throws {
        // Pathological alignment cases: trigger non-zero pad in each
        // padded section.
        // actionsPerKey count=3 → 1 byte pad. virtualMods count=3 →
        // 1 byte pad. explicits count=3 → 2 bytes pad (6 bytes total
        // → next 4-byte boundary).
        let payload = XkbMapPayload(
            actionsPerKey: [1, 1, 1],
            actions: [
                XkbAction(type: 1, data: [0,0,0,0,0,0,0]),
                XkbAction(type: 2, data: [0,0,0,0,0,0,0]),
                XkbAction(type: 3, data: [0,0,0,0,0,0,0]),
            ],
            virtualMods: [0xA, 0xB, 0xC],
            explicits: [
                XkbExplicit(key: 8, explicit: 1),
                XkbExplicit(key: 9, explicit: 2),
                XkbExplicit(key: 10, explicit: 3),
            ]
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = payload.encode(byteOrder: order)
            XCTAssertEqual(bytes.count % 4, 0, "payload bytes must be 4-byte aligned in \(order)")
            let decoded = try XkbMapPayload.decode(
                from: bytes,
                nTypes: 0, nKeySyms: 0,
                nKeyActions: 3, totalKeyBehaviors: 0,
                virtualModsBitmap: 0b111,   // popcount=3
                totalKeyExplicit: 3,
                byteOrder: order
            )
            XCTAssertEqual(decoded, payload, "payload round-trip in \(order)")
            XCTAssertEqual(payload.encode(byteOrder: order), bytes, "byte-identical re-encode in \(order)")
        }
    }

    // MARK: - Session 3 Tier B requests

    func testLatchLockState() throws {
        try roundTrip(XkbLatchLockState(
            deviceSpec: 0x0100,
            affectModLocks: 0xFF, modLocks: 0x04,
            lockGroup: true, groupLock: 1,
            affectModLatches: 0xFF, modLatches: 0x01,
            latchGroup: false, groupLatch: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbLatchLockState.decode(from: $0, byteOrder: $1) })
    }

    func testSetControls() throws {
        try roundTrip(XkbSetControls(
            deviceSpec: 0x0100,
            affectInternalRealMods: 0xFF, internalRealMods: 0x01,
            affectIgnoreLockRealMods: 0xFF, ignoreLockRealMods: 0x00,
            affectInternalVirtualMods: 0xFFFF, internalVirtualMods: 0x0001,
            affectIgnoreLockVirtualMods: 0xFFFF, ignoreLockVirtualMods: 0,
            mouseKeysDfltBtn: 1,
            affectEnabledControls: 0x07FF, enabledControls: 0x0003, changeControls: 0x0001,
            repeatDelay: 500, repeatInterval: 30,
            slowKeysDelay: 0, debounceDelay: 0,
            mouseKeysDelay: 160, mouseKeysInterval: 40,
            mouseKeysTimeToMax: 30, mouseKeysMaxSpeed: 10,
            mouseKeysCurve: 0,
            accessXTimeout: 120, accessXTimeoutMask: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetControls.decode(from: $0, byteOrder: $1) })
    }

    func testBell() throws {
        try roundTrip(XkbBell(
            deviceSpec: 0x0100, bellClass: 1, bellID: 0,
            percent: 75, doOverride: false,
            name: 0x12345678, window: 0x10000005),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbBell.decode(from: $0, byteOrder: $1) })
        // Negative percent (clamp-down request).
        try roundTrip(XkbBell(
            deviceSpec: 0x0100, bellClass: 0, bellID: 0,
            percent: -50, doOverride: true,
            name: 0, window: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbBell.decode(from: $0, byteOrder: $1) })
    }

    func testSendEvent() throws {
        let synth = [UInt8](repeating: 0xAB, count: 32)
        try roundTrip(XkbSendEvent(
            propagate: true, synthesizeClick: false,
            destination: 0x10000005, eventMask: 0xFFFFFFFF,
            eventBytes: synth),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSendEvent.decode(from: $0, byteOrder: $1) })
    }

    func testGetIndicatorState() throws {
        try roundTrip(XkbGetIndicatorState(deviceSpec: 0x0100),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetIndicatorState.decode(from: $0, byteOrder: $1) })
    }

    func testSetIndicatorMap() throws {
        try roundTrip(XkbSetIndicatorMap(
            deviceSpec: 0x0100,
            which: 0b0111,
            maps: [
                XkbIndicatorMapEntry(flags: 0x01, whichGroups: 0, groups: 0,
                                     whichMods: 0, mods: 0, realMods: 0,
                                     virtualMods: 0, ctrls: 0),
                XkbIndicatorMapEntry(flags: 0x02, whichGroups: 0, groups: 0,
                                     whichMods: 0, mods: 0, realMods: 0,
                                     virtualMods: 0, ctrls: 0),
                XkbIndicatorMapEntry(flags: 0x03, whichGroups: 0, groups: 0,
                                     whichMods: 0, mods: 0, realMods: 0,
                                     virtualMods: 0, ctrls: 0),
            ]),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetIndicatorMap.decode(from: $0, byteOrder: $1) })
    }

    func testGetCompatMap() throws {
        try roundTrip(XkbGetCompatMap(
            deviceSpec: 0x0100, virtualMods: 0,
            mods: 0x01, getAllSI: true,
            firstSI: 0, nSI: 16),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetCompatMap.decode(from: $0, byteOrder: $1) })
    }

    func testSetCompatMapEmpty() throws {
        try roundTrip(XkbSetCompatMap(
            deviceSpec: 0x0100, recomputeActions: false, truncateSI: false,
            mods: 0, virtualMods: 0,
            firstSI: 0, nSI: 0,
            payload: .empty),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetCompatMap.decode(from: $0, byteOrder: $1) })
    }

    func testSetCompatMapWithSymInterpretsAndGroupCompat() throws {
        let payload = XkbCompatPayload(
            symInterprets: [
                XkbSymInterpret(sym: 0xFF01, mods: 0x01, match: 0x02,
                                virtualMod: 0x03, flags: 0x04,
                                actionType: 0x05, actionData: [1,2,3,4,5,6,7]),
                XkbSymInterpret(sym: 0xFF02, mods: 0, match: 0,
                                virtualMod: 0, flags: 0,
                                actionType: 0, actionData: [0,0,0,0,0,0,0]),
            ],
            groupCompat: [
                XkbModCompat(mods: 0x01, groups: 0x01),
                XkbModCompat(mods: 0x02, groups: 0x02),
                XkbModCompat(mods: 0x03, groups: 0x03),
                XkbModCompat(mods: 0x04, groups: 0x04),
            ]
        )
        try roundTrip(XkbSetCompatMap(
            deviceSpec: 0x0100, recomputeActions: true, truncateSI: false,
            mods: 0x01, virtualMods: 0,
            firstSI: 0, nSI: 2,
            payload: payload),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetCompatMap.decode(from: $0, byteOrder: $1) })
    }

    func testSetNames() throws {
        try roundTrip(XkbSetNames(
            deviceSpec: 0x0100, which: 0xFFFFFFFF,
            firstType: 0, nTypes: 0,
            firstKTLevel: 0, nKTLevels: 0,
            indicators: 0, modifiers: 0,
            virtualMods: 0,
            nRadioGroups: 0, nCharSets: 0,
            firstKey: 0, nKeys: 0,
            resize: 0,
            trailer: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetNames.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Session 3 Tier B replies

    func testGetIndicatorStateReply() throws {
        try roundTrip(XkbGetIndicatorStateReply(
            sequenceNumber: 23, deviceID: 3, state: 0x0000_000F),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetIndicatorStateReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetCompatMapReply() throws {
        let payload = XkbCompatPayload(
            symInterprets: [
                XkbSymInterpret(sym: 0xFF01, mods: 0x01, match: 0x02,
                                virtualMod: 0x03, flags: 0x04,
                                actionType: 0x05, actionData: [1,2,3,4,5,6,7]),
            ],
            groupCompat: [
                XkbModCompat(mods: 0x01, groups: 0x01),
                XkbModCompat(mods: 0x02, groups: 0x02),
                XkbModCompat(mods: 0x03, groups: 0x03),
                XkbModCompat(mods: 0x04, groups: 0x04),
            ]
        )
        try roundTrip(XkbGetCompatMapReply(
            sequenceNumber: 25, deviceID: 3,
            mods: 0x01, virtualMods: 0,
            firstSI: 0, nSI: 1, nTotalSI: 16,
            payload: payload),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetCompatMapReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Session 3 Tier C

    func testListAlternateSymsReqAndReply() throws {
        try roundTrip(XkbListAlternateSyms(
            deviceSpec: 0x0100, name: 0x91, charset: 0x9A),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbListAlternateSyms.decode(from: $0, byteOrder: $1) })
        try roundTrip(XkbListAlternateSymsReply(
            sequenceNumber: 27, deviceID: 3,
            nAlternateSyms: 4,
            indices: Array(repeating: UInt8(0x55), count: 20)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbListAlternateSymsReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetAlternateSyms() throws {
        try roundTrip(XkbGetAlternateSyms(
            deviceSpec: 0x0100, index: 2, firstKey: 8, nKeys: 248),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetAlternateSyms.decode(from: $0, byteOrder: $1) })
        try roundTrip(XkbGetAlternateSymsReply(
            sequenceNumber: 29, deviceID: 3,
            name: 0x91, index: 2, nCharSets: 1,
            firstKey: 8, nKeys: 10,
            totalSyms: 3, syms: [0xFF01, 0xFF02, 0xFF03]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetAlternateSymsReply.decode(from: $0, byteOrder: $1) })
    }

    func testSetAlternateSyms() throws {
        try roundTrip(XkbSetAlternateSyms(
            deviceSpec: 0x0100, create: true, replace: 0,
            present: 0x00FF, name: 0x91,
            nCharSets: 1, firstKey: 8, nKeys: 4,
            syms: [0xFF01, 0xFF02, 0xFF03, 0xFF04]),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetAlternateSyms.decode(from: $0, byteOrder: $1) })
    }

    func testGetGeometryReqAndReply() throws {
        try roundTrip(XkbGetGeometry(deviceSpec: 0x0100, name: 0),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbGetGeometry.decode(from: $0, byteOrder: $1) })
        try roundTrip(XkbGetGeometryReply(
            sequenceNumber: 31, deviceID: 3,
            name: 0x91, width: 400, height: 150,
            shape: 0, color: 1,
            nShapes: 2, nSections: 3,
            nPoints: 4, nOutlines: 5,
            nColors: 6, nDoodads: 7,
            nLabels: 8, nFonts: 9,
            trailer: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbGetGeometryReply.decode(from: $0, byteOrder: $1) })
    }

    func testSetGeometry() throws {
        try roundTrip(XkbSetGeometry(
            deviceSpec: 0x0100, nShapes: 2, nSections: 3,
            name: 0x91, widthMM: 400, heightMM: 150,
            trailer: [0x01, 0x02, 0x03, 0x04]),
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetGeometry.decode(from: $0, byteOrder: $1) })
    }

    func testSetDebuggingFlagsReqAndReply() throws {
        try roundTrip(XkbSetDebuggingFlags(
            mask: 0x01, flags: 0x01, disableLocks: 0,
            message: [0x68, 0x65, 0x6c, 0x6c, 0x6f]),   // "hello"
            encode: { $0.encode(majorOpcode: 135, byteOrder: $1) },
            decode: { try XkbSetDebuggingFlags.decode(from: $0, byteOrder: $1) })
        try roundTrip(XkbSetDebuggingFlagsReply(
            sequenceNumber: 33, disableLocks: 0, currentFlags: 0x01),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XkbSetDebuggingFlagsReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Common event header decode

    func testAnyEventDecode() throws {
        let ev = XkbBellNotifyEvent(
            type: 85, sequenceNumber: 17, time: 99999, deviceID: 2,
            bellClass: 0, bellID: 0, percent: 50,
            pitch: 440, duration: 200, name: 0, window: 0)
        let bytes = ev.encode(byteOrder: .msbFirst)
        let any = try XkbAnyEvent.decode(from: bytes, byteOrder: .msbFirst)
        XCTAssertEqual(any.type, 85)
        XCTAssertEqual(any.xkbType, XkbEventType.bellNotify)
        XCTAssertEqual(any.sequenceNumber, 17)
        XCTAssertEqual(any.deviceID, 2)
    }
}
