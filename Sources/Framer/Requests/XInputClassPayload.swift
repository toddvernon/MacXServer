// XInput v1 input-class trailer payload — used by ListInputDevices reply.
//
// Phase 3 XInput Session 1 (2026-05-30). The reply trailer is laid out as:
//
//   [xDeviceInfo × ndevices]                  // 8 bytes each
//   [class info records] × Σ num_classes      // tagged union, see below
//   [pascal-string device name × ndevices]    // length byte + bytes,
//                                             // contiguous, no per-name pad
//   [trailing pad to 4-byte alignment]
//
// Each class record starts with `class` (1 byte) + `length` (1 byte).
// `length` tells the parser how to skip the record if it doesn't
// recognize the class. R6 defines three classes used here:
//
//   KeyClass(0)      → xKeyInfo            (8 bytes)
//   ButtonClass(1)   → xButtonInfo         (4 bytes)
//   ValuatorClass(2) → xValuatorInfo (8B) + xAxisInfo (12B) × num_axes
//
// Wire layouts from
// reference/X11R6/xc/include/extensions/XIproto.h + XI.h.

// MARK: - Class IDs

public enum XInputClass {
    public static let key: UInt8 = 0
    public static let button: UInt8 = 1
    public static let valuator: UInt8 = 2
    public static let feedback: UInt8 = 3
}

// MARK: - Class info variants

public struct XInputKeyInfo: Equatable, Sendable {
    public var minKeycode: UInt8
    public var maxKeycode: UInt8
    public var numKeys: UInt16

    public init(minKeycode: UInt8, maxKeycode: UInt8, numKeys: UInt16) {
        self.minKeycode = minKeycode; self.maxKeycode = maxKeycode
        self.numKeys = numKeys
    }
}

public struct XInputButtonInfo: Equatable, Sendable {
    public var numButtons: UInt16

    public init(numButtons: UInt16) { self.numButtons = numButtons }
}

public struct XInputAxisInfo: Equatable, Sendable {
    public var resolution: UInt32
    public var minValue: Int32
    public var maxValue: Int32

    public init(resolution: UInt32, minValue: Int32, maxValue: Int32) {
        self.resolution = resolution; self.minValue = minValue; self.maxValue = maxValue
    }
}

public struct XInputValuatorInfo: Equatable, Sendable {
    public var mode: UInt8     // 0=Relative, 1=Absolute
    public var motionBufferSize: UInt32
    public var axes: [XInputAxisInfo]

    public init(mode: UInt8, motionBufferSize: UInt32, axes: [XInputAxisInfo]) {
        self.mode = mode; self.motionBufferSize = motionBufferSize; self.axes = axes
    }
}

/// One class info record. The associated value carries the typed
/// per-class fields; classes we don't recognize get captured as raw
/// bytes for fidelity.
public enum XInputClassInfo: Equatable, Sendable {
    case key(XInputKeyInfo)
    case button(XInputButtonInfo)
    case valuator(XInputValuatorInfo)
    case unknown(class: UInt8, body: [UInt8])
}

// MARK: - Device info header

/// One 8-byte xDeviceInfo header. The name follows in the trailing
/// pascal-string section, *not* inline in this record.
public struct XInputDeviceInfo: Equatable, Sendable {
    public var type: UInt32   // Atom — device type like "MOUSE", "KEYBOARD"
    public var id: UInt8
    public var use: UInt8     // 0=IsXPointer, 1=IsXKeyboard, 2=IsXExtensionDevice
    public var classes: [XInputClassInfo]
    public var name: String

    public init(type: UInt32, id: UInt8, use: UInt8,
                classes: [XInputClassInfo], name: String) {
        self.type = type; self.id = id; self.use = use
        self.classes = classes; self.name = name
    }
}

// MARK: - Trailer codec

/// The ListInputDevices reply trailer. Decode walks the bytes in three
/// passes (device headers, class records, names) and recombines them
/// into a flat `[XInputDeviceInfo]` for ergonomic dumper output.
public enum XInputDeviceListPayload {

    /// Encode the reply trailer. Layout produced is exactly the wire
    /// shape Xlib's `XListInputDevices` parses.
    public static func encode(_ devices: [XInputDeviceInfo], byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)

        // 1) Device headers (8 bytes each)
        for d in devices {
            w.writeUInt32(d.type)
            w.writeUInt8(d.id)
            w.writeUInt8(UInt8(d.classes.count))
            w.writeUInt8(d.use)
            w.writePadding(1)
        }

        // 2) Class records, in order
        for d in devices {
            for c in d.classes {
                encodeClassInfo(c, into: &w, byteOrder: byteOrder)
            }
        }

        // 3) Pascal-string names — length byte + bytes, packed
        var nameByteCount = 0
        for d in devices {
            let bytes = Array(d.name.utf8)
            precondition(bytes.count <= 255, "device name must fit in one length byte")
            w.writeUInt8(UInt8(bytes.count))
            w.writeBytes(bytes)
            nameByteCount += 1 + bytes.count
        }
        // 4) Pad the whole trailer to a 4-byte boundary
        w.writePadding(xPad(nameByteCount))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], ndevices: Int, byteOrder: ByteOrder) throws -> [XInputDeviceInfo] {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)

        // Pass 1: device headers
        struct Header { let type: UInt32; let id: UInt8; let numClasses: UInt8; let use: UInt8 }
        var headers: [Header] = []
        headers.reserveCapacity(ndevices)
        for _ in 0..<ndevices {
            let type = try r.readUInt32()
            let id = try r.readUInt8()
            let numClasses = try r.readUInt8()
            let use = try r.readUInt8()
            try r.skip(1)
            headers.append(Header(type: type, id: id, numClasses: numClasses, use: use))
        }

        // Pass 2: per-device class records
        var classesPerDevice: [[XInputClassInfo]] = []
        classesPerDevice.reserveCapacity(ndevices)
        for h in headers {
            var classes: [XInputClassInfo] = []
            classes.reserveCapacity(Int(h.numClasses))
            for _ in 0..<Int(h.numClasses) {
                classes.append(try decodeClassInfo(reader: &r))
            }
            classesPerDevice.append(classes)
        }

        // Pass 3: pascal-string names
        var names: [String] = []
        names.reserveCapacity(ndevices)
        for _ in 0..<ndevices {
            let len = Int(try r.readUInt8())
            let raw = try r.readBytes(len)
            names.append(String(decoding: raw, as: UTF8.self))
        }

        return zip(zip(headers, classesPerDevice), names).map { pair, name in
            let (h, classes) = pair
            return XInputDeviceInfo(type: h.type, id: h.id, use: h.use,
                                    classes: classes, name: name)
        }
    }

    // MARK: - Class info codec

    private static func encodeClassInfo(_ c: XInputClassInfo, into w: inout ByteWriter, byteOrder: ByteOrder) {
        switch c {
        case .key(let k):
            w.writeUInt8(XInputClass.key); w.writeUInt8(8)   // length=8
            w.writeUInt8(k.minKeycode); w.writeUInt8(k.maxKeycode)
            w.writeUInt16(k.numKeys)
            w.writePadding(2)
        case .button(let b):
            w.writeUInt8(XInputClass.button); w.writeUInt8(4)
            w.writeUInt16(b.numButtons)
        case .valuator(let v):
            let length = 8 + v.axes.count * 12
            w.writeUInt8(XInputClass.valuator); w.writeUInt8(UInt8(length))
            w.writeUInt8(UInt8(v.axes.count)); w.writeUInt8(v.mode)
            w.writeUInt32(v.motionBufferSize)
            for a in v.axes {
                w.writeUInt32(a.resolution)
                w.writeUInt32(UInt32(bitPattern: a.minValue))
                w.writeUInt32(UInt32(bitPattern: a.maxValue))
            }
        case .unknown(let cls, let body):
            w.writeUInt8(cls); w.writeUInt8(UInt8(body.count + 2))
            w.writeBytes(body)
        }
    }

    private static func decodeClassInfo(reader r: inout ByteReader) throws -> XInputClassInfo {
        let cls = try r.readUInt8()
        let length = Int(try r.readUInt8())
        // length includes the 2 bytes already read (class + length).
        let bodyLen = length - 2
        switch cls {
        case XInputClass.key:
            let minKey = try r.readUInt8()
            let maxKey = try r.readUInt8()
            let numKeys = try r.readUInt16()
            try r.skip(2)
            // bodyLen for KeyInfo is 6 (8 total - 2 header). Any extra
            // bytes in some hypothetical future variant get skipped.
            if bodyLen > 6 { try r.skip(bodyLen - 6) }
            return .key(XInputKeyInfo(minKeycode: minKey, maxKeycode: maxKey, numKeys: numKeys))
        case XInputClass.button:
            let numButtons = try r.readUInt16()
            if bodyLen > 2 { try r.skip(bodyLen - 2) }
            return .button(XInputButtonInfo(numButtons: numButtons))
        case XInputClass.valuator:
            let numAxes = try r.readUInt8()
            let mode = try r.readUInt8()
            let motionBufferSize = try r.readUInt32()
            var axes: [XInputAxisInfo] = []
            axes.reserveCapacity(Int(numAxes))
            for _ in 0..<Int(numAxes) {
                let resolution = try r.readUInt32()
                let minVal = Int32(bitPattern: try r.readUInt32())
                let maxVal = Int32(bitPattern: try r.readUInt32())
                axes.append(XInputAxisInfo(resolution: resolution, minValue: minVal, maxValue: maxVal))
            }
            // Trust the explicit length: 6 (valuator header) + 12 × numAxes
            let consumed = 6 + Int(numAxes) * 12
            if bodyLen > consumed { try r.skip(bodyLen - consumed) }
            return .valuator(XInputValuatorInfo(mode: mode, motionBufferSize: motionBufferSize, axes: axes))
        default:
            let body = try r.readBytes(bodyLen)
            return .unknown(class: cls, body: body)
        }
    }
}

// MARK: - OpenDevice's lighter class-info array

/// xInputClassInfo (2 bytes — class + event_type_base) — used by
/// OpenDevice reply, not by ListInputDevices. Distinct from the
/// fuller XInputClassInfo enum above; this just tells the client
/// which event-type-base maps to which class on this device.
public struct XInputOpenDeviceClass: Equatable, Sendable {
    public var inputClass: UInt8
    public var eventTypeBase: UInt8

    public init(inputClass: UInt8, eventTypeBase: UInt8) {
        self.inputClass = inputClass
        self.eventTypeBase = eventTypeBase
    }
}
