import Framer

// XInput v1 extension dumper.
//
// Phase 3 XInput Session 1 (2026-05-30): Tier A (the 4 enumeration
// requests every Xlib client emits at startup) + all 15 events.
// Session 2 brings in Tier B + C (the remaining 31 ops).
//
// XInput v1 reserves a contiguous 15-event range from `firstEvent`.
// XkbDumper.eventCount = 1 because XKB shares one code; XInput uses
// the more conventional pattern, so eventCount = 15.

public enum XInputDumper: ExtensionDumper {
    public static let extensionName = "XInputExtension"
    public static let eventCount = 15

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {

        case XInputMinor.getExtensionVersion:
            if let r = try? XInputGetExtensionVersion.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetExtensionVersion name=\"\(r.name)\""
            }

        case XInputMinor.listInputDevices:
            return "XInputListInputDevices"

        case XInputMinor.openDevice:
            if let r = try? XInputOpenDevice.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputOpenDevice         device=\(r.deviceID)"
            }

        case XInputMinor.closeDevice:
            if let r = try? XInputCloseDevice.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputCloseDevice        device=\(r.deviceID)"
            }

        default:
            break
        }
        return nil
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        // XInput uses absolute_code - firstEvent as the offset. eventCount=15.
        guard bytes.count >= 1 else { return nil }
        let offset = (bytes[0] & 0x7F) &- firstEvent
        switch offset {

        case XInputEventType.deviceValuator:
            if let e = try? XInputDeviceValuatorEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputDeviceValuator     dev=\(e.deviceID) state=\(hx(e.deviceState)) valuators=\(e.numValuators)+\(e.firstValuator)"
            }

        case XInputEventType.deviceKeyPress, XInputEventType.deviceKeyRelease,
             XInputEventType.deviceButtonPress, XInputEventType.deviceButtonRelease,
             XInputEventType.deviceMotionNotify,
             XInputEventType.proximityIn, XInputEventType.proximityOut:
            if let e = try? XInputDeviceKeyButtonPointerEvent.decode(from: bytes, byteOrder: byteOrder) {
                let name = subEventName(offset)
                return "XInput\(name)  dev=\(e.deviceID) detail=\(e.detail) at \(pt(e.eventX, e.eventY)) root=\(pt(e.rootX, e.rootY)) state=\(hx(e.state))"
            }

        case XInputEventType.deviceFocusIn, XInputEventType.deviceFocusOut:
            if let e = try? XInputDeviceFocusEvent.decode(from: bytes, byteOrder: byteOrder) {
                let name = offset == XInputEventType.deviceFocusIn ? "DeviceFocusIn" : "DeviceFocusOut"
                return "XInput\(name)       dev=\(e.deviceID) window=\(hx(e.window)) detail=\(e.detail) mode=\(e.mode)"
            }

        case XInputEventType.deviceStateNotify:
            if let e = try? XInputDeviceStateNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputDeviceStateNotify  dev=\(e.deviceID) keys=\(e.numKeys) buttons=\(e.numButtons) valuators=\(e.numValuators) classesReported=\(hx(e.classesReported))"
            }

        case XInputEventType.deviceMappingNotify:
            if let e = try? XInputDeviceMappingNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputDeviceMappingNotify dev=\(e.deviceID) request=\(e.request) firstKey=\(e.firstKeyCode) count=\(e.count)"
            }

        case XInputEventType.changeDeviceNotify:
            if let e = try? XInputChangeDeviceNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                let req = e.request == 0 ? "NewPointer" : e.request == 1 ? "NewKeyboard" : e.request == 2 ? "DeviceEnabled" : "request=\(e.request)"
                return "XInputChangeDeviceNotify dev=\(e.deviceID) \(req)"
            }

        case XInputEventType.deviceKeyStateNotify:
            if let e = try? XInputDeviceKeyStateNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputDeviceKeyStateNotify  dev=\(e.deviceID) (28 byte key bitmap)"
            }

        case XInputEventType.deviceButtonStateNotify:
            if let e = try? XInputDeviceButtonStateNotifyEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputDeviceButtonStateNotify dev=\(e.deviceID) (28 byte button bitmap)"
            }

        default:
            break
        }
        return nil
    }

    // MARK: - Helpers

    private static func subEventName(_ offset: UInt8) -> String {
        switch offset {
        case XInputEventType.deviceKeyPress:      return "DeviceKeyPress      "
        case XInputEventType.deviceKeyRelease:    return "DeviceKeyRelease    "
        case XInputEventType.deviceButtonPress:   return "DeviceButtonPress   "
        case XInputEventType.deviceButtonRelease: return "DeviceButtonRelease "
        case XInputEventType.deviceMotionNotify:  return "DeviceMotionNotify  "
        case XInputEventType.proximityIn:         return "ProximityIn         "
        case XInputEventType.proximityOut:        return "ProximityOut        "
        default:                                  return "Event#\(offset)            "
        }
    }

    private static func hx(_ v: UInt8) -> String { "0x" + String(v, radix: 16) }
    private static func hx(_ v: UInt16) -> String { "0x" + String(v, radix: 16) }
    private static func hx(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }

    private static func pt(_ x: Int16, _ y: Int16) -> String { "(\(x),\(y))" }
}
