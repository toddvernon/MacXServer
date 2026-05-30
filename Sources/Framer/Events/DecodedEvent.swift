// Typed event dispatch. Reads the raw 32 bytes of an Event (or the bytes from
// a ServerMessage.event) and produces a structured value with named fields.
//
// SendEvent flag: the high bit of byte 0 tells us this event was synthesized
// by another client via XSendEvent. We strip it for dispatch (the body layout
// is identical) but preserve it via the wasSendEvent property.

public enum DecodedEvent: Equatable, Sendable {
    case keyPress(InputEvent)
    case keyRelease(InputEvent)
    case buttonPress(InputEvent)
    case buttonRelease(InputEvent)
    case motionNotify(InputEvent)
    case enterNotify(CrossingEvent)
    case leaveNotify(CrossingEvent)
    case focusIn(FocusEvent)
    case focusOut(FocusEvent)
    case keymapNotify(KeymapNotifyEvent)
    case expose(ExposeEvent)
    case graphicsExposure(GraphicsExposureEvent)
    case noExposure(NoExposureEvent)
    case visibilityNotify(VisibilityNotifyEvent)
    case createNotify(CreateNotifyEvent)
    case destroyNotify(DestroyNotifyEvent)
    case unmapNotify(UnmapNotifyEvent)
    case mapNotify(MapNotifyEvent)
    case mapRequest(MapRequestEvent)
    case reparentNotify(ReparentNotifyEvent)
    case configureNotify(ConfigureNotifyEvent)
    case circulateNotify(CirculateNotifyEvent)
    case propertyNotify(PropertyNotifyEvent)
    case selectionClear(SelectionClearEvent)
    case selectionRequest(SelectionRequestEvent)
    case selectionNotify(SelectionNotifyEvent)
    case clientMessage(ClientMessageEvent)
    case mappingNotify(MappingNotifyEvent)
    // Phase 1 (2026-05-30) — WM-side notifications + colormap state.
    case configureRequest(ConfigureRequestEvent)
    case gravityNotify(GravityNotifyEvent)
    case resizeRequest(ResizeRequestEvent)
    case circulateRequest(CirculateRequestEvent)
    case colormapNotify(ColormapNotifyEvent)
    case unknown(code: UInt8, bytes: [UInt8])

    public static func decode(from event: Event, byteOrder: ByteOrder) throws -> DecodedEvent {
        return try decode(from: event.bytes, byteOrder: byteOrder)
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> DecodedEvent {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        let code = bytes[0] & 0x7F
        switch code {
        case 2:  return .keyPress(try InputEvent.decode(from: bytes, byteOrder: byteOrder))
        case 3:  return .keyRelease(try InputEvent.decode(from: bytes, byteOrder: byteOrder))
        case 4:  return .buttonPress(try InputEvent.decode(from: bytes, byteOrder: byteOrder))
        case 5:  return .buttonRelease(try InputEvent.decode(from: bytes, byteOrder: byteOrder))
        case 6:  return .motionNotify(try InputEvent.decode(from: bytes, byteOrder: byteOrder))
        case 7:  return .enterNotify(try CrossingEvent.decode(from: bytes, byteOrder: byteOrder))
        case 8:  return .leaveNotify(try CrossingEvent.decode(from: bytes, byteOrder: byteOrder))
        case 9:  return .focusIn(try FocusEvent.decode(from: bytes, byteOrder: byteOrder))
        case 10: return .focusOut(try FocusEvent.decode(from: bytes, byteOrder: byteOrder))
        case 11: return .keymapNotify(try KeymapNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 12: return .expose(try ExposeEvent.decode(from: bytes, byteOrder: byteOrder))
        case 13: return .graphicsExposure(try GraphicsExposureEvent.decode(from: bytes, byteOrder: byteOrder))
        case 14: return .noExposure(try NoExposureEvent.decode(from: bytes, byteOrder: byteOrder))
        case 15: return .visibilityNotify(try VisibilityNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 16: return .createNotify(try CreateNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 17: return .destroyNotify(try DestroyNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 18: return .unmapNotify(try UnmapNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 19: return .mapNotify(try MapNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 20: return .mapRequest(try MapRequestEvent.decode(from: bytes, byteOrder: byteOrder))
        case 21: return .reparentNotify(try ReparentNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 22: return .configureNotify(try ConfigureNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 23: return .configureRequest(try ConfigureRequestEvent.decode(from: bytes, byteOrder: byteOrder))
        case 24: return .gravityNotify(try GravityNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 25: return .resizeRequest(try ResizeRequestEvent.decode(from: bytes, byteOrder: byteOrder))
        case 26: return .circulateNotify(try CirculateNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 27: return .circulateRequest(try CirculateRequestEvent.decode(from: bytes, byteOrder: byteOrder))
        case 28: return .propertyNotify(try PropertyNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 32: return .colormapNotify(try ColormapNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 29: return .selectionClear(try SelectionClearEvent.decode(from: bytes, byteOrder: byteOrder))
        case 30: return .selectionRequest(try SelectionRequestEvent.decode(from: bytes, byteOrder: byteOrder))
        case 31: return .selectionNotify(try SelectionNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        case 33: return .clientMessage(try ClientMessageEvent.decode(from: bytes, byteOrder: byteOrder))
        case 34: return .mappingNotify(try MappingNotifyEvent.decode(from: bytes, byteOrder: byteOrder))
        default:
            return .unknown(code: code, bytes: Array(bytes.prefix(32)))
        }
    }
}
