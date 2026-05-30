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

    // MARK: - Session 2 Tier B + C requests

    func testSetDeviceModeReqAndReply() throws {
        try roundTrip(XInputSetDeviceMode(deviceID: 3, mode: 1),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSetDeviceMode.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputSetDeviceModeReply(sequenceNumber: 5, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputSetDeviceModeReply.decode(from: $0, byteOrder: $1) })
    }

    func testSelectExtensionEvent() throws {
        try roundTrip(XInputSelectExtensionEvent(
            window: 0x10000005,
            classes: [0x12345678, 0x9ABCDEF0]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSelectExtensionEvent.decode(from: $0, byteOrder: $1) })
    }

    func testGetSelectedExtensionEventsReqAndReply() throws {
        try roundTrip(XInputGetSelectedExtensionEvents(window: 0x10000005),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetSelectedExtensionEvents.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetSelectedExtensionEventsReply(
            sequenceNumber: 7,
            thisClient: [0xAAAA_BBBB],
            allClients: [0x1111_2222, 0x3333_4444]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetSelectedExtensionEventsReply.decode(from: $0, byteOrder: $1) })
    }

    func testChangeDontPropagateList() throws {
        try roundTrip(XInputChangeDeviceDontPropagateList(
            window: 0x10000005, mode: 0,
            classes: [0xDEADBEEF, 0xFEEDFACE]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputChangeDeviceDontPropagateList.decode(from: $0, byteOrder: $1) })
    }

    func testGetDontPropagateListReqAndReply() throws {
        try roundTrip(XInputGetDeviceDontPropagateList(window: 0x10000005),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceDontPropagateList.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceDontPropagateListReply(
            sequenceNumber: 11, classes: [0xDEADBEEF]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceDontPropagateListReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetDeviceMotionEventsReqAndReply() throws {
        try roundTrip(XInputGetDeviceMotionEvents(
            start: 100, stop: 999, deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceMotionEvents.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceMotionEventsReply(
            sequenceNumber: 13, axes: 2, mode: 0,
            samples: [
                XInputDeviceMotionSample(time: 100, axes: [10, 20]),
                XInputDeviceMotionSample(time: 200, axes: [-15, 30]),
                XInputDeviceMotionSample(time: 300, axes: [-5, 45]),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceMotionEventsReply.decode(from: $0, byteOrder: $1) })
    }

    func testChangeKeyboardDeviceReqAndReply() throws {
        try roundTrip(XInputChangeKeyboardDevice(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputChangeKeyboardDevice.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputChangeKeyboardDeviceReply(sequenceNumber: 15, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputChangeKeyboardDeviceReply.decode(from: $0, byteOrder: $1) })
    }

    func testChangePointerDeviceReqAndReply() throws {
        try roundTrip(XInputChangePointerDevice(xAxis: 0, yAxis: 1, deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputChangePointerDevice.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputChangePointerDeviceReply(sequenceNumber: 17, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputChangePointerDeviceReply.decode(from: $0, byteOrder: $1) })
    }

    func testGrabDeviceReqAndReply() throws {
        try roundTrip(XInputGrabDevice(
            grabWindow: 0x10000005, time: 99999,
            thisDeviceMode: 1, otherDevicesMode: 0,
            ownerEvents: true, deviceID: 3,
            classes: [0xDEAD, 0xBEEF]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGrabDevice.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGrabDeviceReply(sequenceNumber: 19, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGrabDeviceReply.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabDevice() throws {
        try roundTrip(XInputUngrabDevice(time: 99999, deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputUngrabDevice.decode(from: $0, byteOrder: $1) })
    }

    func testGrabDeviceKey() throws {
        try roundTrip(XInputGrabDeviceKey(
            grabWindow: 0x10000005, modifiers: 0x0007,
            modifierDevice: 2, grabbedDevice: 3,
            key: 24,
            thisDeviceMode: 1, otherDevicesMode: 0,
            ownerEvents: true,
            classes: [0xDEAD, 0xBEEF]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGrabDeviceKey.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabDeviceKey() throws {
        try roundTrip(XInputUngrabDeviceKey(
            grabWindow: 0x10000005, modifiers: 0x0007,
            modifierDevice: 2, key: 24, grabbedDevice: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputUngrabDeviceKey.decode(from: $0, byteOrder: $1) })
    }

    func testGrabDeviceButton() throws {
        try roundTrip(XInputGrabDeviceButton(
            grabWindow: 0x10000005, grabbedDevice: 3, modifierDevice: 2,
            modifiers: 0x0007,
            thisDeviceMode: 1, otherDevicesMode: 0,
            button: 1, ownerEvents: true,
            classes: [0xDEAD, 0xBEEF]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGrabDeviceButton.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabDeviceButton() throws {
        try roundTrip(XInputUngrabDeviceButton(
            grabWindow: 0x10000005, modifiers: 0x0007,
            modifierDevice: 2, button: 1, grabbedDevice: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputUngrabDeviceButton.decode(from: $0, byteOrder: $1) })
    }

    func testAllowDeviceEvents() throws {
        try roundTrip(XInputAllowDeviceEvents(time: 99999, mode: 2, deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputAllowDeviceEvents.decode(from: $0, byteOrder: $1) })
    }

    func testGetDeviceFocusReqAndReply() throws {
        try roundTrip(XInputGetDeviceFocus(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceFocus.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceFocusReply(
            sequenceNumber: 21, focus: 0x10000005, time: 99999, revertTo: 1),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceFocusReply.decode(from: $0, byteOrder: $1) })
    }

    func testSetDeviceFocus() throws {
        try roundTrip(XInputSetDeviceFocus(
            focus: 0x10000005, time: 99999, revertTo: 1, deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSetDeviceFocus.decode(from: $0, byteOrder: $1) })
    }

    func testGetFeedbackControlReqAndReply() throws {
        try roundTrip(XInputGetFeedbackControl(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetFeedbackControl.decode(from: $0, byteOrder: $1) })

        let feedbacks: [XInputFeedbackState] = [
            .kbd(XInputKbdFeedbackState(
                id: 0, pitch: 400, duration: 100,
                ledMask: 0x0F, ledValues: 0x05,
                globalAutoRepeat: true, click: 50, percent: 75,
                autoRepeats: Array(repeating: 0xFF, count: 32))),
            .ptr(XInputPtrFeedbackState(
                id: 1, accelNum: 2, accelDenom: 1, threshold: 4)),
            .integer(XInputIntegerFeedbackState(
                id: 2, resolution: 100, minValue: 0, maxValue: 1000)),
            .led(XInputLedFeedbackState(id: 3, ledMask: 0x07, ledValues: 0x03)),
            .bell(XInputBellFeedbackState(id: 4, percent: 75, pitch: 400, duration: 100)),
            .string(XInputStringFeedbackState(
                id: 5, maxSymbols: 16, numSymsSupported: 2,
                keysyms: [0xFF01, 0xFF02])),
        ]
        try roundTrip(XInputGetFeedbackControlReply(sequenceNumber: 23, feedbacks: feedbacks),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetFeedbackControlReply.decode(from: $0, byteOrder: $1) })
    }

    func testChangeFeedbackControl() throws {
        let ctl = XInputFeedbackCtl.kbd(XInputKbdFeedbackCtl(
            id: 0, key: 24, autoRepeatMode: 1,
            click: 50, percent: 75,
            pitch: 400, duration: 100,
            ledMask: 0x0F, ledValues: 0x05))
        try roundTrip(XInputChangeFeedbackControl(
            mask: 0x7F, deviceID: 3, feedbackID: 0, control: ctl),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputChangeFeedbackControl.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceKeyMapping() throws {
        try roundTrip(XInputGetDeviceKeyMapping(deviceID: 3, firstKeyCode: 8, count: 240),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceKeyMapping.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceKeyMappingReply(
            sequenceNumber: 25, keySymsPerKeyCode: 4,
            keysyms: [0xFF01, 0xFF02, 0xFF03, 0xFF04]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceKeyMappingReply.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputChangeDeviceKeyMapping(
            deviceID: 3, firstKeyCode: 8, keySymsPerKeyCode: 4, keyCodes: 1,
            keysyms: [0xFF01, 0xFF02, 0xFF03, 0xFF04]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputChangeDeviceKeyMapping.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceModifierMapping() throws {
        try roundTrip(XInputGetDeviceModifierMapping(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceModifierMapping.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceModifierMappingReply(
            sequenceNumber: 27, numKeyPerModifier: 2,
            keycodes: Array(repeating: 0, count: 16)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceModifierMappingReply.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputSetDeviceModifierMapping(
            deviceID: 3, numKeyPerModifier: 2,
            keycodes: Array(repeating: 0, count: 16)),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSetDeviceModifierMapping.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputSetDeviceModifierMappingReply(sequenceNumber: 29, success: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputSetDeviceModifierMappingReply.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceButtonMapping() throws {
        try roundTrip(XInputGetDeviceButtonMapping(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceButtonMapping.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceButtonMappingReply(
            sequenceNumber: 31, map: [1, 2, 3, 4, 5]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceButtonMappingReply.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputSetDeviceButtonMapping(deviceID: 3, map: [1, 2, 3, 4, 5]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSetDeviceButtonMapping.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputSetDeviceButtonMappingReply(sequenceNumber: 33, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputSetDeviceButtonMappingReply.decode(from: $0, byteOrder: $1) })
    }

    func testQueryDeviceStateReqAndReply() throws {
        try roundTrip(XInputQueryDeviceState(deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputQueryDeviceState.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputQueryDeviceStateReply(
            sequenceNumber: 35,
            classes: [
                .key(XInputKeyState(
                    numKeys: 248,
                    keys: (0..<32).map { UInt8($0) })),
                .button(XInputButtonState(
                    numButtons: 5,
                    buttons: (0..<32).map { UInt8($0 + 100) })),
                .valuator(XInputValuatorState(
                    mode: 1, values: [100, -50, 200])),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputQueryDeviceStateReply.decode(from: $0, byteOrder: $1) })
    }

    func testSendExtensionEvent() throws {
        let event = [UInt8](repeating: 0xAB, count: 32)
        try roundTrip(XInputSendExtensionEvent(
            destination: 0x10000005, deviceID: 3, propagate: true,
            events: [event, event],
            classes: [0xDEAD, 0xBEEF]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSendExtensionEvent.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceBell() throws {
        try roundTrip(XInputDeviceBell(
            deviceID: 3, feedbackID: 0, feedbackClass: 0, percent: 75),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputDeviceBell.decode(from: $0, byteOrder: $1) })
        // Negative percent.
        try roundTrip(XInputDeviceBell(
            deviceID: 3, feedbackID: 0, feedbackClass: 0, percent: -50),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputDeviceBell.decode(from: $0, byteOrder: $1) })
    }

    func testSetDeviceValuators() throws {
        try roundTrip(XInputSetDeviceValuators(
            deviceID: 3, firstValuator: 0,
            valuators: [100, -50, 200]),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputSetDeviceValuators.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputSetDeviceValuatorsReply(sequenceNumber: 37, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputSetDeviceValuatorsReply.decode(from: $0, byteOrder: $1) })
    }

    func testDeviceControl() throws {
        try roundTrip(XInputGetDeviceControl(control: 1, deviceID: 3),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputGetDeviceControl.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputGetDeviceControlReply(
            sequenceNumber: 39, status: 0,
            state: .resolution(XInputDeviceResolutionState(
                resolutions: [100, 200, 300],
                minResolutions: [10, 20, 30],
                maxResolutions: [1000, 2000, 3000]))),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputGetDeviceControlReply.decode(from: $0, byteOrder: $1) })

        try roundTrip(XInputChangeDeviceControl(
            control: 1, deviceID: 3,
            ctl: .resolution(XInputDeviceResolutionCtl(
                firstValuator: 0, resolutions: [100, 200, 300]))),
            encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
            decode: { try XInputChangeDeviceControl.decode(from: $0, byteOrder: $1) })
        try roundTrip(XInputChangeDeviceControlReply(sequenceNumber: 41, status: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try XInputChangeDeviceControlReply.decode(from: $0, byteOrder: $1) })
    }

    func testFeedbackCtlOtherVariants() throws {
        // Round-trip each non-kbd FeedbackCtl variant.
        for ctl: XInputFeedbackCtl in [
            .ptr(XInputPtrFeedbackCtl(id: 1, num: 2, denom: 1, thresh: 4)),
            .integer(XInputIntegerFeedbackCtl(id: 2, intToDisplay: 12345)),
            .string(XInputStringFeedbackCtl(id: 3, keysyms: [0xFF01, 0xFF02])),
            .bell(XInputBellFeedbackCtl(id: 4, percent: 75, pitch: 400, duration: 100)),
            .led(XInputLedFeedbackCtl(id: 5, ledMask: 0x07, ledValues: 0x03)),
        ] {
            try roundTrip(XInputChangeFeedbackControl(
                mask: 0x01, deviceID: 3, feedbackID: 0, control: ctl),
                encode: { $0.encode(majorOpcode: 131, byteOrder: $1) },
                decode: { try XInputChangeFeedbackControl.decode(from: $0, byteOrder: $1) })
        }
    }
}
