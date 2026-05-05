import XCTest
@testable import Framer

final class RequestTests: XCTestCase {

    // MARK: - MapWindow (opcode 8)

    private let mapWindowLSB: [UInt8] = [
        0x08, 0x00, 0x02, 0x00,             // opcode=8, unused, lenIn4=2
        0x05, 0x00, 0x00, 0x10,             // window=0x10000005
    ]

    private let mapWindowMSB: [UInt8] = [
        0x08, 0x00, 0x00, 0x02,
        0x10, 0x00, 0x00, 0x05,
    ]

    func testMapWindowEncodeLSB() {
        let req = MapWindow(window: 0x10000005)
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), mapWindowLSB)
    }

    func testMapWindowEncodeMSB() {
        let req = MapWindow(window: 0x10000005)
        XCTAssertEqual(req.encode(byteOrder: .msbFirst), mapWindowMSB)
    }

    func testMapWindowDecodeLSB() throws {
        let req = try MapWindow.decode(from: mapWindowLSB, byteOrder: .lsbFirst)
        XCTAssertEqual(req.window, 0x10000005)
    }

    func testMapWindowRoundTrip() throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let original = MapWindow(window: 0xDEADBEEF)
            let bytes = original.encode(byteOrder: order)
            let decoded = try MapWindow.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    // MARK: - CreateWindow (opcode 1)

    private let createWindowNoValuesLSB: [UInt8] = [
        0x01, 0x08, 0x08, 0x00,             // opcode=1, depth=8, lenIn4=8
        0x10, 0x00, 0x00, 0x10,             // wid=0x10000010
        0x05, 0x00, 0x00, 0x10,             // parent=0x10000005
        0x64, 0x00, 0x32, 0x00,             // x=100, y=50
        0xC8, 0x00, 0x96, 0x00,             // width=200, height=150
        0x00, 0x00, 0x01, 0x00,             // borderWidth=0, class=InputOutput
        0x23, 0x00, 0x00, 0x00,             // visual=0x23
        0x00, 0x00, 0x00, 0x00,             // valueMask=0
    ]

    func testCreateWindowEncodeNoValuesLSB() {
        let req = CreateWindow(
            depth: 8, wid: 0x10000010, parent: 0x10000005,
            x: 100, y: 50, width: 200, height: 150,
            borderWidth: 0, windowClass: .inputOutput,
            visual: 0x23, valueMask: 0, valueList: []
        )
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), createWindowNoValuesLSB)
    }

    func testCreateWindowDecodeNoValuesLSB() throws {
        let req = try CreateWindow.decode(from: createWindowNoValuesLSB, byteOrder: .lsbFirst)
        XCTAssertEqual(req.depth, 8)
        XCTAssertEqual(req.wid, 0x10000010)
        XCTAssertEqual(req.parent, 0x10000005)
        XCTAssertEqual(req.x, 100)
        XCTAssertEqual(req.y, 50)
        XCTAssertEqual(req.width, 200)
        XCTAssertEqual(req.height, 150)
        XCTAssertEqual(req.windowClass, .inputOutput)
        XCTAssertEqual(req.visual, 0x23)
        XCTAssertEqual(req.valueMask, 0)
        XCTAssertEqual(req.valueList, [])
    }

    func testCreateWindowWithValueListRoundTrip() throws {
        // valueMask = bit 1 (background-pixel) | bit 9 (override-redirect)
        // = 0x202, popcount = 2, so valueList is 8 bytes.
        let valueList: [UInt8] = [
            0xFF, 0xFF, 0xFF, 0x00,         // background-pixel
            0x01, 0x00, 0x00, 0x00,         // override-redirect = 1
        ]
        let original = CreateWindow(
            depth: 24, wid: 0x10000020, parent: 0x10000005,
            x: -10, y: -20, width: 100, height: 100,
            borderWidth: 1, windowClass: .copyFromParent,
            visual: 0, valueMask: 0x202, valueList: valueList
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try CreateWindow.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
            XCTAssertEqual(bytes.count, 32 + 8)
        }
    }

    func testCreateWindowDecodeRejectsInvalidClass() {
        var bad = createWindowNoValuesLSB
        bad[22] = 0x05                      // class field, byte 22 (LSB low byte)
        XCTAssertThrowsError(try CreateWindow.decode(from: bad, byteOrder: .lsbFirst))
    }

    // MARK: - ChangeProperty (opcode 18)

    private let changePropertyXtermMSB: [UInt8] = [
        0x12, 0x00, 0x00, 0x08,             // opcode=18, mode=Replace, lenIn4=8
        0x10, 0x00, 0x00, 0x05,             // window
        0x00, 0x00, 0x00, 0x27,             // property
        0x00, 0x00, 0x00, 0x1F,             // type
        0x08, 0x00, 0x00, 0x00,             // format=8, 3 unused
        0x00, 0x00, 0x00, 0x05,             // dataLength=5
        0x78, 0x74, 0x65, 0x72, 0x6D,       // "xterm"
        0x00, 0x00, 0x00,                   // pad
    ]

    func testChangePropertyEncode() {
        let req = ChangeProperty(
            mode: .replace,
            window: 0x10000005,
            property: 0x27,
            type: 0x1F,
            format: .format8,
            data: Array("xterm".utf8)
        )
        XCTAssertEqual(req.encode(byteOrder: .msbFirst), changePropertyXtermMSB)
    }

    func testChangePropertyDecode() throws {
        let req = try ChangeProperty.decode(from: changePropertyXtermMSB, byteOrder: .msbFirst)
        XCTAssertEqual(req.mode, .replace)
        XCTAssertEqual(req.window, 0x10000005)
        XCTAssertEqual(req.property, 0x27)
        XCTAssertEqual(req.type, 0x1F)
        XCTAssertEqual(req.format, .format8)
        XCTAssertEqual(String(decoding: req.data, as: UTF8.self), "xterm")
    }

    func testChangePropertyFormat32RoundTrip() throws {
        // 3 CARD32 values = 12 bytes, no padding.
        let data: [UInt8] = [
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C,
        ]
        let original = ChangeProperty(
            mode: .append, window: 0xABCDEF01, property: 0x10, type: 0x20,
            format: .format32, data: data
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ChangeProperty.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    // MARK: - GetProperty (opcode 20)

    private let getPropertyLSB: [UInt8] = [
        0x14, 0x00, 0x06, 0x00,             // opcode=20, delete=false, lenIn4=6
        0x05, 0x00, 0x00, 0x10,             // window
        0x27, 0x00, 0x00, 0x00,             // property=0x27
        0x00, 0x00, 0x00, 0x00,             // type=AnyPropertyType
        0x00, 0x00, 0x00, 0x00,             // longOffset=0
        0x00, 0x20, 0x00, 0x00,             // longLength=8192
    ]

    func testGetPropertyEncode() {
        let req = GetProperty(
            delete: false, window: 0x10000005, property: 0x27,
            type: 0, longOffset: 0, longLength: 8192
        )
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), getPropertyLSB)
    }

    func testGetPropertyDecode() throws {
        let req = try GetProperty.decode(from: getPropertyLSB, byteOrder: .lsbFirst)
        XCTAssertFalse(req.delete)
        XCTAssertEqual(req.window, 0x10000005)
        XCTAssertEqual(req.property, 0x27)
        XCTAssertEqual(req.type, 0)
        XCTAssertEqual(req.longOffset, 0)
        XCTAssertEqual(req.longLength, 8192)
    }

    func testGetPropertyDeleteTrueRoundTrip() throws {
        let original = GetProperty(
            delete: true, window: 1, property: 2, type: 3, longOffset: 4, longLength: 5
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try GetProperty.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    // MARK: - OpenFont (opcode 45)

    private let openFontFixedLSB: [UInt8] = [
        0x2D, 0x00, 0x05, 0x00,             // opcode=45, unused, lenIn4=5
        0x01, 0x00, 0x00, 0x20,             // fid=0x20000001
        0x05, 0x00, 0x00, 0x00,             // name length=5, unused
        0x66, 0x69, 0x78, 0x65, 0x64,       // "fixed"
        0x00, 0x00, 0x00,                   // pad
    ]

    func testOpenFontEncode() {
        let req = OpenFont(fid: 0x20000001, name: Array("fixed".utf8))
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), openFontFixedLSB)
    }

    func testOpenFontDecode() throws {
        let req = try OpenFont.decode(from: openFontFixedLSB, byteOrder: .lsbFirst)
        XCTAssertEqual(req.fid, 0x20000001)
        XCTAssertEqual(String(decoding: req.name, as: UTF8.self), "fixed")
    }

    func testOpenFontXLFDRoundTrip() throws {
        let xlfd = "-misc-fixed-medium-r-normal--13-120-75-75-c-70-iso8859-1"
        let original = OpenFont(fid: 0x20000005, name: Array(xlfd.utf8))
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try OpenFont.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
            XCTAssertEqual(bytes.count % 4, 0)
        }
    }

    // MARK: - CreateGC (opcode 55)

    private let createGCEmptyMSB: [UInt8] = [
        0x37, 0x00, 0x00, 0x04,             // opcode=55, unused, lenIn4=4
        0x30, 0x00, 0x00, 0x01,             // cid
        0x10, 0x00, 0x00, 0x05,             // drawable
        0x00, 0x00, 0x00, 0x00,             // valueMask=0
    ]

    func testCreateGCEncodeEmpty() {
        let req = CreateGC(cid: 0x30000001, drawable: 0x10000005, valueMask: 0)
        XCTAssertEqual(req.encode(byteOrder: .msbFirst), createGCEmptyMSB)
    }

    func testCreateGCDecodeEmpty() throws {
        let req = try CreateGC.decode(from: createGCEmptyMSB, byteOrder: .msbFirst)
        XCTAssertEqual(req.cid, 0x30000001)
        XCTAssertEqual(req.drawable, 0x10000005)
        XCTAssertEqual(req.valueMask, 0)
        XCTAssertEqual(req.valueList, [])
    }

    func testCreateGCWithValuesRoundTrip() throws {
        // valueMask = foreground (bit 2) | line-width (bit 4)
        // = 0x14, popcount = 2, valueList = 8 bytes
        let valueList: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,         // foreground = 0
            0x02, 0x00, 0x00, 0x00,         // line-width = 2
        ]
        let original = CreateGC(
            cid: 0x30000010, drawable: 0x10000005,
            valueMask: 0x14, valueList: valueList
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try CreateGC.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    // MARK: - PolyFillRectangle (opcode 70)

    private let polyFillOneRectLSB: [UInt8] = [
        0x46, 0x00, 0x05, 0x00,             // opcode=70, unused, lenIn4=5
        0x05, 0x00, 0x00, 0x10,             // drawable
        0x01, 0x00, 0x00, 0x30,             // gc
        0x0A, 0x00, 0x14, 0x00,             // x=10, y=20
        0x1E, 0x00, 0x28, 0x00,             // width=30, height=40
    ]

    func testPolyFillRectangleEncode() {
        let req = PolyFillRectangle(
            drawable: 0x10000005, gc: 0x30000001,
            rectangles: [Rectangle(x: 10, y: 20, width: 30, height: 40)]
        )
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), polyFillOneRectLSB)
    }

    func testPolyFillRectangleDecode() throws {
        let req = try PolyFillRectangle.decode(from: polyFillOneRectLSB, byteOrder: .lsbFirst)
        XCTAssertEqual(req.drawable, 0x10000005)
        XCTAssertEqual(req.gc, 0x30000001)
        XCTAssertEqual(req.rectangles, [Rectangle(x: 10, y: 20, width: 30, height: 40)])
    }

    func testPolyFillRectangleManyRoundTrip() throws {
        let rects = [
            Rectangle(x: 0, y: 0, width: 100, height: 100),
            Rectangle(x: -5, y: 10, width: 50, height: 25),
            Rectangle(x: 200, y: -300, width: 1, height: 1),
        ]
        let original = PolyFillRectangle(drawable: 0xDEAD0001, gc: 0xBEEF0002, rectangles: rects)
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try PolyFillRectangle.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    // MARK: - ImageText8 (opcode 76)

    private let imageText8HelloLSB: [UInt8] = [
        0x4C, 0x05, 0x06, 0x00,             // opcode=76, n=5, lenIn4=6
        0x05, 0x00, 0x00, 0x10,             // drawable
        0x01, 0x00, 0x00, 0x30,             // gc
        0x0A, 0x00, 0x14, 0x00,             // x=10, y=20
        0x48, 0x65, 0x6C, 0x6C, 0x6F,       // "Hello"
        0x00, 0x00, 0x00,                   // pad
    ]

    func testImageText8Encode() {
        let req = ImageText8(
            drawable: 0x10000005, gc: 0x30000001,
            x: 10, y: 20, string: Array("Hello".utf8)
        )
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), imageText8HelloLSB)
    }

    func testImageText8Decode() throws {
        let req = try ImageText8.decode(from: imageText8HelloLSB, byteOrder: .lsbFirst)
        XCTAssertEqual(req.drawable, 0x10000005)
        XCTAssertEqual(req.gc, 0x30000001)
        XCTAssertEqual(req.x, 10)
        XCTAssertEqual(req.y, 20)
        XCTAssertEqual(String(decoding: req.string, as: UTF8.self), "Hello")
    }

    func testImageText8EmptyStringRoundTrip() throws {
        let original = ImageText8(drawable: 1, gc: 2, x: 0, y: 0, string: [])
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ImageText8.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    func testImageText8NegativeCoordinatesRoundTrip() throws {
        let original = ImageText8(
            drawable: 1, gc: 2, x: -100, y: -200, string: Array("xy".utf8)
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ImageText8.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    // MARK: - Request enum dispatch

    func testRequestDispatchMapWindow() throws {
        let req = try Request.decode(from: mapWindowLSB, byteOrder: .lsbFirst)
        guard case .mapWindow(let m) = req else {
            XCTFail("expected mapWindow, got \(req)")
            return
        }
        XCTAssertEqual(m.window, 0x10000005)
    }

    func testRequestDispatchCreateWindow() throws {
        let req = try Request.decode(from: createWindowNoValuesLSB, byteOrder: .lsbFirst)
        guard case .createWindow = req else {
            XCTFail("expected createWindow")
            return
        }
    }

    func testRequestDispatchAllOpcodes() throws {
        let cases: [(Request, [UInt8], ByteOrder)] = [
            (.mapWindow(MapWindow(window: 0x10000005)), mapWindowLSB, .lsbFirst),
            (.changeProperty(ChangeProperty(
                mode: .replace, window: 0x10000005, property: 0x27, type: 0x1F,
                format: .format8, data: Array("xterm".utf8)
            )), changePropertyXtermMSB, .msbFirst),
            (.getProperty(GetProperty(
                delete: false, window: 0x10000005, property: 0x27,
                type: 0, longOffset: 0, longLength: 8192
            )), getPropertyLSB, .lsbFirst),
            (.openFont(OpenFont(fid: 0x20000001, name: Array("fixed".utf8))),
             openFontFixedLSB, .lsbFirst),
            (.createGC(CreateGC(cid: 0x30000001, drawable: 0x10000005, valueMask: 0)),
             createGCEmptyMSB, .msbFirst),
            (.polyFillRectangle(PolyFillRectangle(
                drawable: 0x10000005, gc: 0x30000001,
                rectangles: [Rectangle(x: 10, y: 20, width: 30, height: 40)]
            )), polyFillOneRectLSB, .lsbFirst),
            (.imageText8(ImageText8(
                drawable: 0x10000005, gc: 0x30000001, x: 10, y: 20,
                string: Array("Hello".utf8)
            )), imageText8HelloLSB, .lsbFirst),
        ]

        for (expected, bytes, order) in cases {
            let decoded = try Request.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(decoded.encode(byteOrder: order), bytes)
        }
    }

    func testRequestDispatchUnknownOpcodeReturnsUnknown() throws {
        // Opcode 120 (unassigned in core protocol), lenIn4=2 → 8 bytes total.
        let bytes: [UInt8] = [
            0x78, 0x00, 0x02, 0x00,
            0xDE, 0xAD, 0xBE, 0xEF,
        ]
        let req = try Request.decode(from: bytes, byteOrder: .lsbFirst)
        guard case .unknown(let op, let body) = req else {
            XCTFail("expected .unknown, got \(req)")
            return
        }
        XCTAssertEqual(op, 120)
        XCTAssertEqual(body, bytes)
    }

    func testRequestUnknownRoundTrip() throws {
        let bytes: [UInt8] = [
            0xAA, 0xBB, 0x02, 0x00,         // opcode=0xAA, second byte arbitrary, lenIn4=2
            0x01, 0x02, 0x03, 0x04,
        ]
        let req = try Request.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), bytes)
    }

    func testRequestUnknownRespectsLengthField() throws {
        // lenIn4=3 → 12 bytes total. Trailing bytes after the request are not consumed.
        let bytes: [UInt8] = [
            0x78, 0x00, 0x03, 0x00,         // opcode=120 (unassigned)
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08,
            0xFF, 0xFF, 0xFF, 0xFF,         // bytes after this request, should not be in the unknown body
        ]
        let req = try Request.decode(from: bytes, byteOrder: .lsbFirst)
        guard case .unknown(_, let body) = req else {
            XCTFail("expected .unknown")
            return
        }
        XCTAssertEqual(body.count, 12)
        XCTAssertEqual(body, Array(bytes.prefix(12)))
    }

    func testRequestDispatchRejectsTruncated() {
        let short: [UInt8] = [0x08, 0x00, 0x02, 0x00, 0x05, 0x00]
        XCTAssertThrowsError(try Request.decode(from: short, byteOrder: .lsbFirst))
    }
}
