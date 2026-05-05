import XCTest
@testable import Framer

final class DecodedEventTests: XCTestCase {

    private func roundTripEvent<T: Equatable>(
        _ original: T,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count, 32, "events must be 32 bytes")
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "field equality fails for \(T.self) in \(order)")
            XCTAssertEqual(bytes, encode(decoded, order), "byte-identical fails for \(T.self) in \(order)")
        }
    }

    func testInputEvent() throws {
        let original = InputEvent(
            detail: 37, sequenceNumber: 100, time: 12345,
            root: 0x00000050, event: 0x10000020, child: 0,
            rootX: 400, rootY: 300, eventX: 100, eventY: 50,
            state: 0x4, sameScreen: true
        )
        try roundTripEvent(original,
            encode: { $0.encode(code: 2, byteOrder: $1) },
            decode: { try InputEvent.decode(from: $0, byteOrder: $1) })
    }

    func testCrossingEvent() throws {
        let original = CrossingEvent(
            detail: .nonlinear, sequenceNumber: 5, time: 0,
            root: 0x50, event: 0x10000020, child: 0,
            rootX: 0, rootY: 0, eventX: 0, eventY: 0,
            state: 0, mode: .normal, sameScreen: true, focus: false
        )
        try roundTripEvent(original,
            encode: { $0.encode(code: 7, byteOrder: $1) },
            decode: { try CrossingEvent.decode(from: $0, byteOrder: $1) })
    }

    func testFocusEvent() throws {
        let original = FocusEvent(detail: .ancestor, sequenceNumber: 7, event: 0x10000005, mode: .normal)
        try roundTripEvent(original,
            encode: { $0.encode(code: 9, byteOrder: $1) },
            decode: { try FocusEvent.decode(from: $0, byteOrder: $1) })
    }

    func testKeymapNotifyEvent() throws {
        let original = KeymapNotifyEvent(keys: Array(repeating: UInt8(0xAA), count: 31))
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try KeymapNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testExposeEvent() throws {
        let original = ExposeEvent(sequenceNumber: 12, window: 0x10000020, x: 10, y: 20, width: 100, height: 50, count: 0)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ExposeEvent.decode(from: $0, byteOrder: $1) })
    }

    func testVisibilityNotifyEvent() throws {
        let original = VisibilityNotifyEvent(sequenceNumber: 3, window: 0x10000020, state: .partiallyObscured)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try VisibilityNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testCreateNotifyEvent() throws {
        let original = CreateNotifyEvent(
            sequenceNumber: 1, parent: 0x10000005, window: 0x10000020,
            x: 0, y: 0, width: 800, height: 600, borderWidth: 1, overrideRedirect: false
        )
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CreateNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testDestroyNotifyEvent() throws {
        let original = DestroyNotifyEvent(sequenceNumber: 99, event: 0x10000020, window: 0x10000020)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try DestroyNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testUnmapNotifyEvent() throws {
        let original = UnmapNotifyEvent(sequenceNumber: 50, event: 0x10000020, window: 0x10000020, fromConfigure: false)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UnmapNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testMapNotifyEvent() throws {
        let original = MapNotifyEvent(sequenceNumber: 50, event: 0x10000020, window: 0x10000020, overrideRedirect: false)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try MapNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testMapRequestEvent() throws {
        let original = MapRequestEvent(sequenceNumber: 1, parent: 0x10000005, window: 0x10000020)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try MapRequestEvent.decode(from: $0, byteOrder: $1) })
    }

    func testReparentNotifyEvent() throws {
        let original = ReparentNotifyEvent(
            sequenceNumber: 5, event: 0x10000020, window: 0x10000020, parent: 0x10000010,
            x: 0, y: 0, overrideRedirect: false
        )
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ReparentNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testConfigureNotifyEvent() throws {
        let original = ConfigureNotifyEvent(
            sequenceNumber: 7, event: 0x10000020, window: 0x10000020, aboveSibling: 0,
            x: 100, y: 50, width: 800, height: 600, borderWidth: 0, overrideRedirect: false
        )
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ConfigureNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testPropertyNotifyEvent() throws {
        let original = PropertyNotifyEvent(
            sequenceNumber: 10, window: 0x10000020, atom: 0x91, time: 12345, state: .newValue
        )
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PropertyNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testMappingNotifyEvent() throws {
        let original = MappingNotifyEvent(sequenceNumber: 1, request: .keyboard, firstKeycode: 8, count: 248)
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try MappingNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testSelectionEvents() throws {
        let clear = SelectionClearEvent(sequenceNumber: 1, time: 100, owner: 0x20, selection: 0x1)
        try roundTripEvent(clear,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SelectionClearEvent.decode(from: $0, byteOrder: $1) })

        let req = SelectionRequestEvent(
            sequenceNumber: 2, time: 100, owner: 0x20, requestor: 0x30,
            selection: 0x1, target: 0x86, property: 0xA6
        )
        try roundTripEvent(req,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SelectionRequestEvent.decode(from: $0, byteOrder: $1) })

        let notify = SelectionNotifyEvent(
            sequenceNumber: 3, time: 100, requestor: 0x30,
            selection: 0x1, target: 0x86, property: 0xA6
        )
        try roundTripEvent(notify,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SelectionNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testClientMessageEvent() throws {
        let data: [UInt8] = (0..<20).map { UInt8($0) }
        let original = ClientMessageEvent(
            sequenceNumber: 1, format: .format32, window: 0x10000020, type: 0x91, data: data
        )
        try roundTripEvent(original,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ClientMessageEvent.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Dispatch

    func testDispatchKeyPress() throws {
        let body = InputEvent(
            detail: 37, sequenceNumber: 1, time: 0,
            root: 0, event: 0x10, child: 0,
            rootX: 0, rootY: 0, eventX: 0, eventY: 0,
            state: 0, sameScreen: true
        )
        let bytes = body.encode(code: 2, byteOrder: .msbFirst)
        let decoded = try DecodedEvent.decode(from: bytes, byteOrder: .msbFirst)
        guard case .keyPress(let e) = decoded else {
            XCTFail("expected keyPress")
            return
        }
        XCTAssertEqual(e.detail, 37)
    }

    func testDispatchSendEventStripsHighBit() throws {
        var bytes = InputEvent(
            detail: 37, sequenceNumber: 1, time: 0,
            root: 0, event: 0x10, child: 0,
            rootX: 0, rootY: 0, eventX: 0, eventY: 0,
            state: 0, sameScreen: true
        ).encode(code: 2, byteOrder: .msbFirst)
        bytes[0] |= 0x80
        let decoded = try DecodedEvent.decode(from: bytes, byteOrder: .msbFirst)
        if case .keyPress = decoded {} else { XCTFail("expected keyPress despite SendEvent flag") }
    }

    func testDispatchUnknownCode() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 100
        let decoded = try DecodedEvent.decode(from: bytes, byteOrder: .lsbFirst)
        guard case .unknown(let code, _) = decoded else {
            XCTFail("expected unknown")
            return
        }
        XCTAssertEqual(code, 100)
    }
}
