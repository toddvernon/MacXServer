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

    func testGetIndicatorMapReplyHeaderOnly() throws {
        try roundTrip(XkbGetIndicatorMapReply(
            sequenceNumber: 19, deviceID: 3,
            which: 0xFFFFFFFF,
            nRealIndicators: 3, nIndicators: 32,
            trailer: []),
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
