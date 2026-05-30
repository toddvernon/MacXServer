// Phase 1 decoder coverage (2026-05-30) — five core events that didn't have
// typed decoders yet. Four of them are window-manager-side notifications
// (ConfigureRequest, ResizeRequest, CirculateRequest, GravityNotify) and
// one is colormap state (ColormapNotify). All are 32-byte events per the
// X11R6 protocol spec. Wire layouts verified against
// `reference/X11R6/xc/include/Xproto.h`.

// MARK: - ConfigureRequest (code 23)

/// A child window is asking its parent to configure it. The parent
/// (typically a WM) sees this and decides whether to honor, modify, or
/// drop the request. Wire layout:
///   type(1) + stackMode(1) + seq(2) +
///   parent(4) + window(4) + sibling(4) +
///   x(2) + y(2) + width(2) + height(2) + borderWidth(2) + valueMask(2) +
///   4 bytes of trailing pad.
public struct ConfigureRequestEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var stackMode: UInt8            // 0=Above, 1=Below, 2=TopIf, 3=BottomIf, 4=Opposite
    public var parent: UInt32
    public var window: UInt32
    public var sibling: UInt32             // 0 = None
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public var valueMask: UInt16

    public init(sequenceNumber: UInt16, stackMode: UInt8,
                parent: UInt32, window: UInt32, sibling: UInt32,
                x: Int16, y: Int16, width: UInt16, height: UInt16,
                borderWidth: UInt16, valueMask: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.stackMode = stackMode
        self.parent = parent
        self.window = window
        self.sibling = sibling
        self.x = x; self.y = y
        self.width = width; self.height = height
        self.borderWidth = borderWidth
        self.valueMask = valueMask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(23); w.writeUInt8(stackMode); w.writeUInt16(sequenceNumber)
        w.writeUInt32(parent); w.writeUInt32(window); w.writeUInt32(sibling)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt16(borderWidth); w.writeUInt16(valueMask)
        w.writePadding(4)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ConfigureRequestEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let stackMode = try r.readUInt8()
        let seq = try r.readUInt16()
        let parent = try r.readUInt32()
        let window = try r.readUInt32()
        let sibling = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let borderWidth = try r.readUInt16()
        let valueMask = try r.readUInt16()
        return ConfigureRequestEvent(
            sequenceNumber: seq, stackMode: stackMode,
            parent: parent, window: window, sibling: sibling,
            x: x, y: y, width: width, height: height,
            borderWidth: borderWidth, valueMask: valueMask
        )
    }
}

// MARK: - GravityNotify (code 24)

/// Emitted when a window is moved because its parent was resized and the
/// window's bit-gravity caused it to shift. Wire layout:
///   type(1) + pad(1) + seq(2) + event(4) + window(4) + x(2) + y(2) +
///   16 bytes of trailing pad.
public struct GravityNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var window: UInt32
    public var x: Int16
    public var y: Int16

    public init(sequenceNumber: UInt16, event: UInt32, window: UInt32, x: Int16, y: Int16) {
        self.sequenceNumber = sequenceNumber
        self.event = event; self.window = window
        self.x = x; self.y = y
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(24); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GravityNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32()
        let window = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        return GravityNotifyEvent(sequenceNumber: seq, event: event, window: window, x: x, y: y)
    }
}

// MARK: - ResizeRequest (code 25)

/// A client called XResizeWindow on a top-level — the parent (typically
/// the WM) gets this so it can size-policy the request. Wire layout:
///   type(1) + pad(1) + seq(2) + window(4) + width(2) + height(2) +
///   20 bytes of trailing pad.
public struct ResizeRequestEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var window: UInt32
    public var width: UInt16
    public var height: UInt16

    public init(sequenceNumber: UInt16, window: UInt32, width: UInt16, height: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.window = window
        self.width = width; self.height = height
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(25); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(window)
        w.writeUInt16(width); w.writeUInt16(height)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ResizeRequestEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let window = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return ResizeRequestEvent(sequenceNumber: seq, window: window, width: width, height: height)
    }
}

// MARK: - CirculateRequest (code 27)

/// A client called XCirculateSubwindows on this window's parent. The
/// parent (typically the WM) receives this so it can policy-decide
/// whether to honor the restack. Wire layout per X11 spec encoding §11:
///   type(1) + pad(1) + seq(2) + parent(4) + window(4) +
///   unused(4) + place(1) + 15 bytes of trailing pad.
///
/// The third 4-byte slot is unused on the wire for CirculateRequest.
/// (Xproto.h reuses the CirculateNotify union, which has three WINDOW
/// fields plus place; the comment in that header notes that the first
/// `event` slot holds the parent for the Request flavor.)
public struct CirculateRequestEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var parent: UInt32
    public var window: UInt32
    public var place: UInt8     // 0 = Top, 1 = Bottom

    public init(sequenceNumber: UInt16, parent: UInt32, window: UInt32, place: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.parent = parent
        self.window = window
        self.place = place
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(27); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(parent); w.writeUInt32(window)
        w.writeUInt32(0)             // unused per spec
        w.writeUInt8(place)
        w.writePadding(15)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CirculateRequestEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let parent = try r.readUInt32()
        let window = try r.readUInt32()
        _ = try r.readUInt32()
        let place = try r.readUInt8()
        return CirculateRequestEvent(sequenceNumber: seq, parent: parent, window: window, place: place)
    }
}

// MARK: - ColormapNotify (code 32)

/// Sent on colormap install/uninstall and on CWColormap attribute changes.
/// Wire layout:
///   type(1) + pad(1) + seq(2) + window(4) + colormap(4) +
///   new(1) + state(1) + 18 bytes of trailing pad.
public struct ColormapNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var window: UInt32
    public var colormap: UInt32      // 0 = None
    /// false = colormap is being installed/uninstalled (state change);
    /// true = the window's colormap attribute was changed to a new colormap.
    public var isNew: Bool
    public var state: UInt8          // 0 = Uninstalled, 1 = Installed

    public init(sequenceNumber: UInt16, window: UInt32, colormap: UInt32, isNew: Bool, state: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.window = window
        self.colormap = colormap
        self.isNew = isNew
        self.state = state
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(32); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(window); w.writeUInt32(colormap)
        w.writeUInt8(isNew ? 1 : 0); w.writeUInt8(state)
        w.writePadding(18)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ColormapNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let window = try r.readUInt32()
        let colormap = try r.readUInt32()
        let isNew = try r.readUInt8() != 0
        let state = try r.readUInt8()
        return ColormapNotifyEvent(sequenceNumber: seq, window: window, colormap: colormap,
                                   isNew: isNew, state: state)
    }
}
