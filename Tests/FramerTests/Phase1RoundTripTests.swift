import XCTest
@testable import Framer

// Phase 1 decoder-coverage opcodes (2026-05-29). Each test encodes a
// representative value, decodes it, asserts field equality and
// byte-identical re-encode, in both byte orders.

final class Phase1RoundTripTests: XCTestCase {

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

    // MARK: - Requests

    func testChangeSaveSet() throws {
        try roundTrip(ChangeSaveSet(mode: .insert, window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeSaveSet.decode(from: $0, byteOrder: $1) })
        try roundTrip(ChangeSaveSet(mode: .delete, window: 0xDEADBEEF),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeSaveSet.decode(from: $0, byteOrder: $1) })
    }

    func testListProperties() throws {
        try roundTrip(ListProperties(window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListProperties.decode(from: $0, byteOrder: $1) })
    }

    func testSetFontPath() throws {
        try roundTrip(SetFontPath(path: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetFontPath.decode(from: $0, byteOrder: $1) })
        try roundTrip(SetFontPath(path: ["/usr/share/fonts/X11/misc"]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetFontPath.decode(from: $0, byteOrder: $1) })
        try roundTrip(SetFontPath(path: ["a", "bb", "ccc", "/var/x/fonts"]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetFontPath.decode(from: $0, byteOrder: $1) })
    }

    func testGetFontPath() throws {
        try roundTrip(GetFontPath(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetFontPath.decode(from: $0, byteOrder: $1) })
    }

    func testCopyGC() throws {
        try roundTrip(CopyGC(srcGC: 0x10000020, dstGC: 0x10000021, valueMask: 0x0000_7FFF),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CopyGC.decode(from: $0, byteOrder: $1) })
    }

    func testChangeKeyboardMapping() throws {
        // 2 keycodes × 3 keysyms each = 6 keysyms.
        try roundTrip(ChangeKeyboardMapping(
            firstKeyCode: 8, keysymsPerKeycode: 3,
            keysyms: [0x61, 0x41, 0, 0x62, 0x42, 0]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeKeyboardMapping.decode(from: $0, byteOrder: $1) })
    }

    func testChangeKeyboardControl() throws {
        // Empty value list, mask=0 — degenerate but legal.
        try roundTrip(ChangeKeyboardControl(valueMask: 0, valueList: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeKeyboardControl.decode(from: $0, byteOrder: $1) })
        // Two bits set → two CARD32 slots.
        try roundTrip(ChangeKeyboardControl(
            valueMask: 0b0010_0001,
            valueList: [50, 0, 0, 0, 1, 0, 0, 0]),  // key-click-percent=50, led-mode=On
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeKeyboardControl.decode(from: $0, byteOrder: $1) })
    }

    func testGetKeyboardControl() throws {
        try roundTrip(GetKeyboardControl(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetKeyboardControl.decode(from: $0, byteOrder: $1) })
    }

    func testChangePointerControl() throws {
        try roundTrip(ChangePointerControl(
            accelerationNumerator: 2, accelerationDenominator: 1,
            threshold: 4, doAcceleration: true, doThreshold: false),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangePointerControl.decode(from: $0, byteOrder: $1) })
        // Negative INT16s: "default" sentinel (-1) with do-bits set.
        try roundTrip(ChangePointerControl(
            accelerationNumerator: -1, accelerationDenominator: -1,
            threshold: -1, doAcceleration: true, doThreshold: true),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangePointerControl.decode(from: $0, byteOrder: $1) })
    }

    func testGetPointerControl() throws {
        try roundTrip(GetPointerControl(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetPointerControl.decode(from: $0, byteOrder: $1) })
    }

    func testChangeHosts() throws {
        try roundTrip(ChangeHosts(mode: .insert, family: .internet,
                                  address: [192, 168, 1, 42]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeHosts.decode(from: $0, byteOrder: $1) })
        // IPv6 — 16 bytes, no extra padding needed.
        try roundTrip(ChangeHosts(mode: .delete, family: .internetV6,
                                  address: Array(repeating: 0xAB, count: 16)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeHosts.decode(from: $0, byteOrder: $1) })
    }

    func testListHosts() throws {
        try roundTrip(ListHosts(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListHosts.decode(from: $0, byteOrder: $1) })
    }

    func testSetAccessControl() throws {
        try roundTrip(SetAccessControl(mode: .disable),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetAccessControl.decode(from: $0, byteOrder: $1) })
        try roundTrip(SetAccessControl(mode: .enable),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetAccessControl.decode(from: $0, byteOrder: $1) })
    }

    func testRotateProperties() throws {
        try roundTrip(RotateProperties(window: 0x10000005, delta: 1,
                                       properties: [0x91, 0x9A, 0xBE]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RotateProperties.decode(from: $0, byteOrder: $1) })
        // Negative delta (rotate the other way).
        try roundTrip(RotateProperties(window: 0x10000005, delta: -2,
                                       properties: [0x91, 0x9A]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RotateProperties.decode(from: $0, byteOrder: $1) })
    }

    func testSetPointerMapping() throws {
        try roundTrip(SetPointerMapping(map: [1, 2, 3]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetPointerMapping.decode(from: $0, byteOrder: $1) })
        // 5-button mouse with the standard scroll-wheel mapping.
        try roundTrip(SetPointerMapping(map: [1, 2, 3, 4, 5]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetPointerMapping.decode(from: $0, byteOrder: $1) })
    }

    func testSetModifierMapping() throws {
        // 8 modifier slots × 2 keycodes per modifier = 16 bytes.
        try roundTrip(SetModifierMapping(keycodesPerModifier: 2,
                                         keycodes: Array(repeating: 0, count: 16)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetModifierMapping.decode(from: $0, byteOrder: $1) })
        // 8 × 4 = 32 bytes.
        try roundTrip(SetModifierMapping(keycodesPerModifier: 4,
                                         keycodes: (0..<32).map { UInt8($0 + 10) }),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetModifierMapping.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Replies

    func testListPropertiesReply() throws {
        try roundTrip(ListPropertiesReply(sequenceNumber: 42, atoms: [0x91, 0x9A]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListPropertiesReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetFontPathReply() throws {
        try roundTrip(GetFontPathReply(sequenceNumber: 7,
                                       path: ["/usr/share/fonts/X11/misc",
                                              "/usr/share/fonts/X11/100dpi"]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetFontPathReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetKeyboardControlReply() throws {
        try roundTrip(GetKeyboardControlReply(
            sequenceNumber: 11, globalAutoRepeat: true,
            ledMask: 0x0F, keyClickPercent: 50, bellPercent: 75,
            bellPitch: 400, bellDuration: 100,
            autoRepeats: Array(repeating: 0xFF, count: 32)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetKeyboardControlReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetPointerControlReply() throws {
        try roundTrip(GetPointerControlReply(
            sequenceNumber: 19,
            accelerationNumerator: 3, accelerationDenominator: 2,
            threshold: 5),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetPointerControlReply.decode(from: $0, byteOrder: $1) })
    }

    func testListHostsReply() throws {
        try roundTrip(ListHostsReply(sequenceNumber: 23, enabled: true, hosts: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListHostsReply.decode(from: $0, byteOrder: $1) })
        try roundTrip(ListHostsReply(
            sequenceNumber: 24, enabled: false,
            hosts: [
                .init(family: .internet, address: [10, 0, 0, 1]),
                .init(family: .internet, address: [192, 168, 1, 5]),
                .init(family: .internetV6, address: Array(repeating: 0x42, count: 16)),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListHostsReply.decode(from: $0, byteOrder: $1) })
    }

    func testSetMappingReply() throws {
        for status: UInt8 in [0, 1, 2] {
            try roundTrip(SetMappingReply(sequenceNumber: 5, status: status),
                encode: { $0.encode(byteOrder: $1) },
                decode: { try SetMappingReply.decode(from: $0, byteOrder: $1) })
        }
    }

    // MARK: - Events

    func testConfigureRequestEvent() throws {
        try roundTrip(ConfigureRequestEvent(
            sequenceNumber: 99, stackMode: 0,
            parent: 0x10000005, window: 0x10000010, sibling: 0x10000020,
            x: 100, y: 200, width: 640, height: 480,
            borderWidth: 2, valueMask: 0x007F),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ConfigureRequestEvent.decode(from: $0, byteOrder: $1) })
    }

    func testGravityNotifyEvent() throws {
        try roundTrip(GravityNotifyEvent(
            sequenceNumber: 12, event: 0x10000005, window: 0x10000010,
            x: -3, y: 7),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GravityNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testResizeRequestEvent() throws {
        try roundTrip(ResizeRequestEvent(
            sequenceNumber: 21, window: 0x10000010, width: 800, height: 600),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ResizeRequestEvent.decode(from: $0, byteOrder: $1) })
    }

    func testCirculateRequestEvent() throws {
        try roundTrip(CirculateRequestEvent(
            sequenceNumber: 33, parent: 0x10000005, window: 0x10000010, place: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CirculateRequestEvent.decode(from: $0, byteOrder: $1) })
        try roundTrip(CirculateRequestEvent(
            sequenceNumber: 34, parent: 0x10000005, window: 0x10000010, place: 1),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CirculateRequestEvent.decode(from: $0, byteOrder: $1) })
    }

    func testColormapNotifyEvent() throws {
        try roundTrip(ColormapNotifyEvent(
            sequenceNumber: 41, window: 0x10000010, colormap: 0x20000001,
            isNew: true, state: 1),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ColormapNotifyEvent.decode(from: $0, byteOrder: $1) })
        try roundTrip(ColormapNotifyEvent(
            sequenceNumber: 42, window: 0x10000010, colormap: 0,
            isNew: false, state: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ColormapNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    /// Each new event must round-trip through `DecodedEvent.decode` (the
    /// top-level dispatch by code byte), not just its own struct method.
    func testEventsThroughDecodedEventDispatch() throws {
        let cases: [(DecodedEvent, [UInt8])] = [
            (.configureRequest(ConfigureRequestEvent(
                sequenceNumber: 1, stackMode: 0, parent: 1, window: 2, sibling: 3,
                x: 0, y: 0, width: 100, height: 100, borderWidth: 0, valueMask: 0)),
             ConfigureRequestEvent(sequenceNumber: 1, stackMode: 0, parent: 1, window: 2, sibling: 3,
                x: 0, y: 0, width: 100, height: 100, borderWidth: 0, valueMask: 0).encode(byteOrder: .msbFirst)),
            (.gravityNotify(GravityNotifyEvent(sequenceNumber: 2, event: 1, window: 2, x: 0, y: 0)),
             GravityNotifyEvent(sequenceNumber: 2, event: 1, window: 2, x: 0, y: 0).encode(byteOrder: .msbFirst)),
            (.resizeRequest(ResizeRequestEvent(sequenceNumber: 3, window: 1, width: 10, height: 20)),
             ResizeRequestEvent(sequenceNumber: 3, window: 1, width: 10, height: 20).encode(byteOrder: .msbFirst)),
            (.circulateRequest(CirculateRequestEvent(sequenceNumber: 4, parent: 1, window: 2, place: 0)),
             CirculateRequestEvent(sequenceNumber: 4, parent: 1, window: 2, place: 0).encode(byteOrder: .msbFirst)),
            (.colormapNotify(ColormapNotifyEvent(sequenceNumber: 5, window: 1, colormap: 2, isNew: true, state: 1)),
             ColormapNotifyEvent(sequenceNumber: 5, window: 1, colormap: 2, isNew: true, state: 1).encode(byteOrder: .msbFirst)),
        ]
        for (expected, wire) in cases {
            let decoded = try DecodedEvent.decode(from: wire, byteOrder: .msbFirst)
            XCTAssertEqual(decoded, expected, "DecodedEvent dispatch for \(expected)")
        }
    }

    // MARK: - Through the Request dispatch

    /// Sanity: each new opcode round-trips through the top-level
    /// `Request.decode(from:byteOrder:)` dispatch, not just its own static
    /// method. Guards against forgotten enum-case wiring in Request.swift.
    func testThroughRequestDispatch() throws {
        let cases: [(Request, UInt8)] = [
            (.changeSaveSet(ChangeSaveSet(mode: .insert, window: 0x100)), 6),
            (.listProperties(ListProperties(window: 0x100)), 21),
            (.setFontPath(SetFontPath(path: ["a"])), 51),
            (.getFontPath(GetFontPath()), 52),
            (.copyGC(CopyGC(srcGC: 1, dstGC: 2, valueMask: 4)), 57),
            (.changeKeyboardMapping(ChangeKeyboardMapping(
                firstKeyCode: 8, keysymsPerKeycode: 2, keysyms: [0, 0])), 100),
            (.changeKeyboardControl(ChangeKeyboardControl(valueMask: 0, valueList: [])), 102),
            (.getKeyboardControl(GetKeyboardControl()), 103),
            (.changePointerControl(ChangePointerControl(
                accelerationNumerator: 1, accelerationDenominator: 1,
                threshold: 1, doAcceleration: true, doThreshold: true)), 105),
            (.getPointerControl(GetPointerControl()), 106),
            (.changeHosts(ChangeHosts(mode: .insert, family: .internet, address: [1,2,3,4])), 109),
            (.listHosts(ListHosts()), 110),
            (.setAccessControl(SetAccessControl(mode: .enable)), 111),
            (.rotateProperties(RotateProperties(window: 0x100, delta: 1, properties: [0x91])), 114),
            (.setPointerMapping(SetPointerMapping(map: [1, 2, 3])), 116),
            (.setModifierMapping(SetModifierMapping(
                keycodesPerModifier: 2, keycodes: Array(repeating: 0, count: 16))), 118),
        ]
        for (req, expectedOpcode) in cases {
            for order in [ByteOrder.lsbFirst, .msbFirst] {
                let bytes = req.encode(byteOrder: order)
                XCTAssertEqual(bytes[0], expectedOpcode, "wire opcode for \(req) in \(order)")
                let decoded = try Request.decode(from: bytes, byteOrder: order)
                XCTAssertEqual(decoded, req, "Request.decode round-trip for \(req) in \(order)")
            }
        }
    }
}
