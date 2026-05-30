import XCTest
@testable import Framer

// XInput v1 Phase 3 Session 1 round-trip tests.

final class XInputRoundTripTests: XCTestCase {

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

    func testGetExtensionVersion() throws {
        try roundTrip(XInputGetExtensionVersion(name: "XInputExtension"),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetExtensionVersion.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetExtensionVersion(name: ""),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetExtensionVersion.decode(from: $0, byteOrder: $1) })
    }

    func testListInputDevicesReq() throws {
        try roundTrip(XInputListInputDevices(),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputListInputDevices.decode(from: $0, byteOrder: $1) })
    }

    func testOpenDevice() throws {
        try roundTrip(XInputOpenDevice(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputOpenDevice.decode(from: $0, byteOrder: $1) })
    }

    func testCloseDevice() throws {
        try roundTrip(XInputCloseDevice(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputCloseDevice.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Tier A replies

    func testGetExtensionVersionReply() throws {
        try roundTrip(XInputGetExtensionVersionReply(
            sequenceNumber: 3, majorVersion: 1, minorVersion: 0, present: true),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetExtensionVersionReply.decode(from: $0, byteOrder: $1) })
    }

    func testListInputDevicesReplyEmpty() throws {
        try roundTrip(XInputListInputDevicesReply(sequenceNumber: 7, devices: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputListInputDevicesReply.decode(from: $0, byteOrder: $1) })
    }

    func testListInputDevicesReplyMixedDevices() throws {
        // Three devices exercising all three class shapes + name lengths.
        let devices = [
            XInputDeviceInfo(
                type: 0x91, id: 2, use: 1,
                classes: [
                    .key(XInputKeyInfo(minKeycode: 8, maxKeycode: 255, numKeys: 248)),
                ],
                name: "core-keyboard"
            ),
            XInputDeviceInfo(
                type: 0x92, id: 3, use: 0,
                classes: [
                    .button(XInputButtonInfo(numButtons: 5)),
                    .valuator(XInputValuatorInfo(
                        mode: 1, motionBufferSize: 256,
                        axes: [
                            XInputAxisInfo(resolution: 100, minValue: 0, maxValue: 1920),
                            XInputAxisInfo(resolution: 100, minValue: 0, maxValue: 1080),
                        ]
                    )),
                ],
                name: "core-pointer"
            ),
            XInputDeviceInfo(
                type: 0x93, id: 7, use: 2,
                classes: [
                    .unknown(class: 9, body: [0x01, 0x02]),
                ],
                name: "x"
            ),
        ]
        try roundTrip(XInputListInputDevicesReply(sequenceNumber: 11, devices: devices),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputListInputDevicesReply.decode(from: $0, byteOrder: $1) })
    }

    func testOpenDeviceReply() throws {
        try roundTrip(XInputOpenDeviceReply(
            sequenceNumber: 13,
            classes: [
                XInputOpenDeviceClass(inputClass: 0, eventTypeBase: 73),  // Key
                XInputOpenDeviceClass(inputClass: 1, eventTypeBase: 75),  // Button
                XInputOpenDeviceClass(inputClass: 2, eventTypeBase: 77),  // Valuator
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputOpenDeviceReply.decode(from: $0, byteOrder: $1) })
        // Zero classes - test the empty trailer path.
        try roundTrip(XInputOpenDeviceReply(sequenceNumber: 14, classes: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputOpenDeviceReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Events (all 15)

    func testDeviceValuatorEvent() throws {
        try roundTrip(XInputDeviceValuatorEvent(
            type: 100, deviceID: 3, sequenceNumber: 5,
            deviceState: 0x0010, numValuators: 2, firstValuator: 0,
            valuators: [100, 200, 0, 0, 0, 0]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputDeviceValuatorEvent.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceKeyButtonPointerEvents() throws {
        // Six event offsets share this struct. Run all 7 of them
        // (incl. proximity in/out) through the same codec.
        for type: UInt8 in [101, 102, 103, 104, 105, 108, 109] {
            try roundTrip(XInputDeviceKeyButtonPointerEvent(
                type: type, detail: 24, sequenceNumber: 7,
                time: 99999,
                root: 0x10000005, event: 0x10000010, child: 0,
                rootX: 100, rootY: 200,
                eventX: 50, eventY: 75,
                state: 0x0005, sameScreen: true, deviceID: 3),
                encode: { $0.encode(byteOrder: $1) },
                decode: { try XInputDeviceKeyButtonPointerEvent.decode(from: $0, byteOrder: $1) })
        }
    }

    func testDeviceFocusEvents() throws {
        for type: UInt8 in [106, 107] {
            try roundTrip(XInputDeviceFocusEvent(
                type: type, detail: 3, sequenceNumber: 9,
                time: 99999, window: 0x10000010,
                mode: 1, deviceID: 3),
                encode: { $0.encode(byteOrder: $1) },
                decode: { try XInputDeviceFocusEvent.decode(from: $0, byteOrder: $1) })
        }
    }

    func testDeviceStateNotifyEvent() throws {
        try roundTrip(XInputDeviceStateNotifyEvent(
            type: 110, deviceID: 3, sequenceNumber: 11, time: 99999,
            numKeys: 248, numButtons: 5, numValuators: 2,
            classesReported: 0b1000_0011,    // proximity-in + 3 classes
            buttons: [0x01, 0x02, 0x03, 0x04],
            keys: [0xAA, 0xBB, 0xCC, 0xDD],
            valuator0: 100, valuator1: 200, valuator2: 300),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputDeviceStateNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceKeyStateNotifyEvent() throws {
        let keys = (0..<28).map { UInt8($0) }
        try roundTrip(XInputDeviceKeyStateNotifyEvent(
            type: 113, deviceID: 3, sequenceNumber: 13, keys: keys),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputDeviceKeyStateNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceButtonStateNotifyEvent() throws {
        let buttons = (0..<28).map { UInt8($0 + 100) }
        try roundTrip(XInputDeviceButtonStateNotifyEvent(
            type: 114, deviceID: 3, sequenceNumber: 15, buttons: buttons),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputDeviceButtonStateNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceMappingNotifyEvent() throws {
        try roundTrip(XInputDeviceMappingNotifyEvent(
            type: 111, deviceID: 3, sequenceNumber: 17,
            request: 1, firstKeyCode: 8, count: 248, time: 99999),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputDeviceMappingNotifyEvent.decode(from: $0, byteOrder: $1) })
    }

    func testChangeDeviceNotifyEvent() throws {
        try roundTrip(XInputChangeDeviceNotifyEvent(
            type: 112, deviceID: 3, sequenceNumber: 19, time: 99999, request: 1),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputChangeDeviceNotifyEvent.decode(from: $0, byteOrder: $1) })
    }
}
