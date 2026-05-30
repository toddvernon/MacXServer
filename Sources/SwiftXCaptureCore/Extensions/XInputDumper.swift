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

        // Session 2 Tier B + C
        case XInputMinor.setDeviceMode:
            if let r = try? XInputSetDeviceMode.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSetDeviceMode      device=\(r.deviceID) mode=\(r.mode)"
            }
        case XInputMinor.selectExtensionEvent:
            if let r = try? XInputSelectExtensionEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSelectExtensionEvent window=\(hx(r.window)) classes=\(r.classes.count)"
            }
        case XInputMinor.getSelectedExtensionEvents:
            if let r = try? XInputGetSelectedExtensionEvents.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetSelectedExtensionEvents window=\(hx(r.window))"
            }
        case XInputMinor.changeDeviceDontPropagateList:
            if let r = try? XInputChangeDeviceDontPropagateList.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputChangeDeviceDontPropagateList window=\(hx(r.window)) mode=\(r.mode) classes=\(r.classes.count)"
            }
        case XInputMinor.getDeviceDontPropagateList:
            if let r = try? XInputGetDeviceDontPropagateList.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceDontPropagateList window=\(hx(r.window))"
            }
        case XInputMinor.getDeviceMotionEvents:
            if let r = try? XInputGetDeviceMotionEvents.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceMotionEvents device=\(r.deviceID) start=\(r.start) stop=\(r.stop)"
            }
        case XInputMinor.changeKeyboardDevice:
            if let r = try? XInputChangeKeyboardDevice.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputChangeKeyboardDevice device=\(r.deviceID)"
            }
        case XInputMinor.changePointerDevice:
            if let r = try? XInputChangePointerDevice.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputChangePointerDevice device=\(r.deviceID) xAxis=\(r.xAxis) yAxis=\(r.yAxis)"
            }
        case XInputMinor.grabDevice:
            if let r = try? XInputGrabDevice.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGrabDevice         device=\(r.deviceID) window=\(hx(r.grabWindow)) classes=\(r.classes.count) thisMode=\(r.thisDeviceMode) otherMode=\(r.otherDevicesMode) owner=\(r.ownerEvents)"
            }
        case XInputMinor.ungrabDevice:
            if let r = try? XInputUngrabDevice.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputUngrabDevice       device=\(r.deviceID)"
            }
        case XInputMinor.grabDeviceKey:
            if let r = try? XInputGrabDeviceKey.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGrabDeviceKey      grabbed=\(r.grabbedDevice) modDev=\(r.modifierDevice) window=\(hx(r.grabWindow)) key=\(r.key) modifiers=\(hx(r.modifiers)) classes=\(r.classes.count)"
            }
        case XInputMinor.ungrabDeviceKey:
            if let r = try? XInputUngrabDeviceKey.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputUngrabDeviceKey    grabbed=\(r.grabbedDevice) modDev=\(r.modifierDevice) window=\(hx(r.grabWindow)) key=\(r.key) modifiers=\(hx(r.modifiers))"
            }
        case XInputMinor.grabDeviceButton:
            if let r = try? XInputGrabDeviceButton.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGrabDeviceButton   grabbed=\(r.grabbedDevice) modDev=\(r.modifierDevice) window=\(hx(r.grabWindow)) button=\(r.button) modifiers=\(hx(r.modifiers)) classes=\(r.classes.count)"
            }
        case XInputMinor.ungrabDeviceButton:
            if let r = try? XInputUngrabDeviceButton.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputUngrabDeviceButton grabbed=\(r.grabbedDevice) modDev=\(r.modifierDevice) window=\(hx(r.grabWindow)) button=\(r.button) modifiers=\(hx(r.modifiers))"
            }
        case XInputMinor.allowDeviceEvents:
            if let r = try? XInputAllowDeviceEvents.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputAllowDeviceEvents  device=\(r.deviceID) mode=\(r.mode)"
            }
        case XInputMinor.getDeviceFocus:
            if let r = try? XInputGetDeviceFocus.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceFocus     device=\(r.deviceID)"
            }
        case XInputMinor.setDeviceFocus:
            if let r = try? XInputSetDeviceFocus.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSetDeviceFocus     device=\(r.deviceID) focus=\(hx(r.focus)) revertTo=\(r.revertTo)"
            }
        case XInputMinor.getFeedbackControl:
            if let r = try? XInputGetFeedbackControl.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetFeedbackControl device=\(r.deviceID)"
            }
        case XInputMinor.changeFeedbackControl:
            if let r = try? XInputChangeFeedbackControl.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputChangeFeedbackControl device=\(r.deviceID) feedback=\(r.feedbackID) mask=\(hx(r.mask)) ctl=\(feedbackCtlName(r.control))"
            }
        case XInputMinor.getDeviceKeyMapping:
            if let r = try? XInputGetDeviceKeyMapping.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceKeyMapping device=\(r.deviceID) firstKeyCode=\(r.firstKeyCode) count=\(r.count)"
            }
        case XInputMinor.changeDeviceKeyMapping:
            if let r = try? XInputChangeDeviceKeyMapping.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputChangeDeviceKeyMapping device=\(r.deviceID) firstKeyCode=\(r.firstKeyCode) perKey=\(r.keySymsPerKeyCode) keys=\(r.keyCodes) keysyms=\(r.keysyms.count)"
            }
        case XInputMinor.getDeviceModifierMapping:
            if let r = try? XInputGetDeviceModifierMapping.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceModifierMapping device=\(r.deviceID)"
            }
        case XInputMinor.setDeviceModifierMapping:
            if let r = try? XInputSetDeviceModifierMapping.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSetDeviceModifierMapping device=\(r.deviceID) perMod=\(r.numKeyPerModifier) keycodes=\(r.keycodes.count)"
            }
        case XInputMinor.getDeviceButtonMapping:
            if let r = try? XInputGetDeviceButtonMapping.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceButtonMapping device=\(r.deviceID)"
            }
        case XInputMinor.setDeviceButtonMapping:
            if let r = try? XInputSetDeviceButtonMapping.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSetDeviceButtonMapping device=\(r.deviceID) map=\(r.map.count)b"
            }
        case XInputMinor.queryDeviceState:
            if let r = try? XInputQueryDeviceState.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputQueryDeviceState   device=\(r.deviceID)"
            }
        case XInputMinor.sendExtensionEvent:
            if let r = try? XInputSendExtensionEvent.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSendExtensionEvent device=\(r.deviceID) dst=\(hx(r.destination)) events=\(r.events.count) classes=\(r.classes.count) propagate=\(r.propagate)"
            }
        case XInputMinor.deviceBell:
            if let r = try? XInputDeviceBell.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputDeviceBell         device=\(r.deviceID) feedback=\(r.feedbackID) class=\(r.feedbackClass) percent=\(r.percent)"
            }
        case XInputMinor.setDeviceValuators:
            if let r = try? XInputSetDeviceValuators.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputSetDeviceValuators device=\(r.deviceID) first=\(r.firstValuator) values=\(r.valuators.count)"
            }
        case XInputMinor.getDeviceControl:
            if let r = try? XInputGetDeviceControl.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputGetDeviceControl   device=\(r.deviceID) control=\(r.control)"
            }
        case XInputMinor.changeDeviceControl:
            if let r = try? XInputChangeDeviceControl.decode(from: bytes, byteOrder: byteOrder) {
                return "XInputChangeDeviceControl device=\(r.deviceID) control=\(r.control) ctl=\(deviceCtlName(r.ctl))"
            }

        default:
            break
        }
        return nil
    }

    private static func feedbackCtlName(_ c: XInputFeedbackCtl) -> String {
        switch c {
        case .kbd:     return "Kbd"
        case .ptr:     return "Ptr"
        case .string:  return "String"
        case .integer: return "Integer"
        case .bell:    return "Bell"
        case .led:     return "Led"
        case .unknown(let cls, _, _): return "unknown(\(cls))"
        }
    }

    private static func deviceCtlName(_ c: XInputDeviceCtl) -> String {
        switch c {
        case .resolution: return "Resolution"
        case .unknown(let control, _): return "unknown(\(control))"
        }
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
