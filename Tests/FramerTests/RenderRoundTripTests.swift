import XCTest
@testable import Framer

// RENDER Phase 3 Session 1 round-trip tests. Tier A backbone +
// QueryPictFormats reply walker. CompositeGlyphs/AddGlyphs land in
// Session 2 with their own tests.

final class RenderRoundTripTests: XCTestCase {

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

    func testQueryVersion() throws {
        try roundTrip(RenderQueryVersion(majorVersion: 0, minorVersion: 11),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderQueryVersion.decode(from: $0, byteOrder: $1) })
    }

    func testQueryPictFormats() throws {
        try roundTrip(RenderQueryPictFormats(),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderQueryPictFormats.decode(from: $0, byteOrder: $1) })
    }

    func testCreatePictureEmptyMask() throws {
        try roundTrip(RenderCreatePicture(
            pid: 0x40000001, drawable: 0x10000005,
            format: 0x20000020, valueMask: 0, valueList: []),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCreatePicture.decode(from: $0, byteOrder: $1) })
    }

    func testCreatePictureWithValueList() throws {
        // CPRepeat (bit 0) + CPClipMask (bit 6) set; 2 values.
        let valueMask: UInt32 = (1 << 0) | (1 << 6)
        let valueList: [UInt8] = [
            0, 0, 0, 1,        // Repeat = 1 (RepeatNormal)
            0, 0, 0, 0,        // ClipMask = None
        ]
        try roundTrip(RenderCreatePicture(
            pid: 0x40000001, drawable: 0x10000005,
            format: 0x20000020,
            valueMask: valueMask, valueList: valueList),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCreatePicture.decode(from: $0, byteOrder: $1) })
    }

    func testChangePicture() throws {
        let valueMask: UInt32 = (1 << 4) | (1 << 5)   // CPClipXOrigin + CPClipYOrigin
        let valueList: [UInt8] = [
            0, 0, 0, 10,
            0, 0, 0, 20,
        ]
        try roundTrip(RenderChangePicture(
            picture: 0x40000001, valueMask: valueMask, valueList: valueList),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderChangePicture.decode(from: $0, byteOrder: $1) })
    }

    func testSetPictureClipRectangles() throws {
        try roundTrip(RenderSetPictureClipRectangles(
            picture: 0x40000001, xOrigin: 5, yOrigin: 10,
            rectangles: [
                Rectangle(x: 0, y: 0, width: 100, height: 50),
                Rectangle(x: 100, y: 50, width: 200, height: 150),
            ]),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderSetPictureClipRectangles.decode(from: $0, byteOrder: $1) })
    }

    func testFreePicture() throws {
        try roundTrip(RenderFreePicture(picture: 0x40000001),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderFreePicture.decode(from: $0, byteOrder: $1) })
    }

    func testComposite() throws {
        try roundTrip(RenderComposite(
            op: 3,    // PictOpOver
            src: 0x40000001, mask: 0, dst: 0x40000002,
            xSrc: 0, ySrc: 0,
            xMask: 0, yMask: 0,
            xDst: 100, yDst: 200,
            width: 320, height: 240),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderComposite.decode(from: $0, byteOrder: $1) })
        // Negative-coordinate variant + non-zero mask.
        try roundTrip(RenderComposite(
            op: 12,   // PictOpAdd
            src: 0x40000001, mask: 0x40000003, dst: 0x40000002,
            xSrc: -5, ySrc: -10,
            xMask: 1, yMask: 2,
            xDst: -100, yDst: -200,
            width: 16, height: 16),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderComposite.decode(from: $0, byteOrder: $1) })
    }

    func testCreateAndFreeGlyphSet() throws {
        try roundTrip(RenderCreateGlyphSet(gsid: 0x40000010, format: 0x20000020),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCreateGlyphSet.decode(from: $0, byteOrder: $1) })
        try roundTrip(RenderFreeGlyphSet(glyphset: 0x40000010),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderFreeGlyphSet.decode(from: $0, byteOrder: $1) })
    }

    func testFreeGlyphs() throws {
        try roundTrip(RenderFreeGlyphs(
            glyphset: 0x40000010,
            glyphIDs: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE]),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderFreeGlyphs.decode(from: $0, byteOrder: $1) })
    }

    func testSetPictureTransform() throws {
        // Identity matrix in 16.16 fixed.
        let identity: [Int32] = [
            0x10000, 0,       0,
            0,       0x10000, 0,
            0,       0,       0x10000,
        ]
        try roundTrip(RenderSetPictureTransform(picture: 0x40000001, matrix: identity),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderSetPictureTransform.decode(from: $0, byteOrder: $1) })
        // Scale 2x with translation and negative values.
        let scaled: [Int32] = [
            0x20000, 0, 100 * 0x10000,
            0, 0x20000, -50 * 0x10000,
            0, 0, 0x10000,
        ]
        try roundTrip(RenderSetPictureTransform(picture: 0x40000001, matrix: scaled),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderSetPictureTransform.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Replies

    func testQueryVersionReply() throws {
        try roundTrip(RenderQueryVersionReply(
            sequenceNumber: 3, majorVersion: 0, minorVersion: 11),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RenderQueryVersionReply.decode(from: $0, byteOrder: $1) })
    }

    func testQueryPictFormatsReplyEmpty() throws {
        try roundTrip(RenderQueryPictFormatsReply(
            sequenceNumber: 5,
            formats: [],
            screens: [],
            subpixels: []),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RenderQueryPictFormatsReply.decode(from: $0, byteOrder: $1) })
    }

    func testQueryPictFormatsReplyFull() throws {
        // Realistic shape: two formats, one screen with two depths
        // (24 and 32), each with one visual, and one subpixel value.
        let direct24 = RenderDirectFormat(
            red: 16, redMask: 0xFF,
            green: 8, greenMask: 0xFF,
            blue: 0, blueMask: 0xFF,
            alpha: 0, alphaMask: 0
        )
        let direct32 = RenderDirectFormat(
            red: 16, redMask: 0xFF,
            green: 8, greenMask: 0xFF,
            blue: 0, blueMask: 0xFF,
            alpha: 24, alphaMask: 0xFF
        )
        let formats = [
            RenderPictFormatInfo(id: 0x20000020, type: 1, depth: 24,
                                 direct: direct24, colormap: 0),
            RenderPictFormatInfo(id: 0x20000021, type: 1, depth: 32,
                                 direct: direct32, colormap: 0),
        ]
        let screens = [
            RenderPictScreen(
                depths: [
                    RenderPictDepth(depth: 24, visuals: [
                        RenderPictVisual(visual: 0x21, format: 0x20000020),
                    ]),
                    RenderPictDepth(depth: 32, visuals: [
                        RenderPictVisual(visual: 0x22, format: 0x20000021),
                    ]),
                ],
                fallback: 0x20000020
            ),
        ]
        try roundTrip(RenderQueryPictFormatsReply(
            sequenceNumber: 7,
            formats: formats, screens: screens,
            subpixels: [1]),   // SubPixelHorizontalRGB
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RenderQueryPictFormatsReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Session 2: glyph stack + filter/index queries

    func testQueryPictIndexValuesReqAndReply() throws {
        try roundTrip(RenderQueryPictIndexValues(format: 0x20000020),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderQueryPictIndexValues.decode(from: $0, byteOrder: $1) })
        try roundTrip(RenderQueryPictIndexValuesReply(
            sequenceNumber: 9,
            values: [
                RenderIndexValue(pixel: 0, red: 0, green: 0, blue: 0, alpha: 0xFFFF),
                RenderIndexValue(pixel: 1, red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF, alpha: 0xFFFF),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RenderQueryPictIndexValuesReply.decode(from: $0, byteOrder: $1) })
    }

    func testQueryFiltersReqAndReply() throws {
        try roundTrip(RenderQueryFilters(drawable: 0x10000005),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderQueryFilters.decode(from: $0, byteOrder: $1) })
        try roundTrip(RenderQueryFiltersReply(
            sequenceNumber: 11,
            aliases: [0, 1, 2],   // 3 × 2 = 6 bytes, pads 2
            filters: ["nearest", "bilinear", "fast", "good", "best", "convolution"]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RenderQueryFiltersReply.decode(from: $0, byteOrder: $1) })
    }

    func testAddGlyphs() throws {
        let payload = RenderAddGlyphsPayload(
            glyphIDs: [0x100, 0x200, 0x300],
            glyphInfos: [
                RenderGlyphInfo(width: 8, height: 12, x: 0, y: -10, xOff: 8, yOff: 0),
                RenderGlyphInfo(width: 10, height: 14, x: 0, y: -12, xOff: 10, yOff: 0),
                RenderGlyphInfo(width: 6, height: 10, x: -1, y: -8, xOff: 6, yOff: 0),
            ],
            // Synthetic bitmap blob (already padded to 4-byte boundary).
            bitmapData: Array(repeating: 0xFF, count: 96))
        try roundTrip(RenderAddGlyphs(glyphset: 0x40000010, payload: payload),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderAddGlyphs.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - CompositeGlyphs variants

    func testCompositeGlyphs8SimpleDraw() throws {
        let elts: [RenderGlyphElt] = [
            .draw(deltax: 0, deltay: 0, glyphIDs: [0x41, 0x42, 0x43, 0x44, 0x45]),
        ]
        try roundTrip(RenderCompositeGlyphs(
            idSize: .bits8, op: 3,
            src: 0x40000001, dst: 0x40000002,
            maskFormat: 0x20000020, glyphset: 0x40000010,
            xSrc: 100, ySrc: 200, elts: elts),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCompositeGlyphs.decode(from: $0, byteOrder: $1) })
    }

    func testCompositeGlyphs8WithPadVariations() throws {
        // 8-bit IDs: len=1 → 3 bytes pad, len=3 → 1 byte pad, len=4 → 0 pad.
        for n in [1, 2, 3, 4, 5, 7] {
            let ids = (0..<n).map { UInt32(0x41 + $0) }
            let elts: [RenderGlyphElt] = [
                .draw(deltax: Int16(n), deltay: -Int16(n), glyphIDs: ids),
            ]
            try roundTrip(RenderCompositeGlyphs(
                idSize: .bits8, op: 3,
                src: 0x40000001, dst: 0x40000002,
                maskFormat: 0, glyphset: 0x40000010,
                xSrc: 0, ySrc: 0, elts: elts),
                encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
                decode: { try RenderCompositeGlyphs.decode(from: $0, byteOrder: $1) })
        }
    }

    func testCompositeGlyphs16PadVariations() throws {
        // 16-bit IDs: len=1 → (4 - 2%4)%4 = 2 byte pad; len=2 → 0 pad;
        // len=3 → 2 byte pad; len=4 → 0 pad.
        for n in [1, 2, 3, 4] {
            let ids = (0..<n).map { UInt32(0x100 + $0) }
            let elts: [RenderGlyphElt] = [
                .draw(deltax: 0, deltay: 0, glyphIDs: ids),
            ]
            try roundTrip(RenderCompositeGlyphs(
                idSize: .bits16, op: 3,
                src: 0x40000001, dst: 0x40000002,
                maskFormat: 0, glyphset: 0x40000010,
                xSrc: 0, ySrc: 0, elts: elts),
                encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
                decode: { try RenderCompositeGlyphs.decode(from: $0, byteOrder: $1) })
        }
    }

    func testCompositeGlyphs32() throws {
        // 32-bit IDs always 0 pad.
        let elts: [RenderGlyphElt] = [
            .draw(deltax: 100, deltay: 50,
                  glyphIDs: [0x10001, 0x20002, 0x30003]),
        ]
        try roundTrip(RenderCompositeGlyphs(
            idSize: .bits32, op: 3,
            src: 0x40000001, dst: 0x40000002,
            maskFormat: 0, glyphset: 0x40000010,
            xSrc: 0, ySrc: 0, elts: elts),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCompositeGlyphs.decode(from: $0, byteOrder: $1) })
    }

    func testCompositeGlyphsWithGlyphsetSwitch() throws {
        // The risky case: a glyphset switch in the middle of a stream.
        // Mishandling this misaligns every following elt.
        let elts: [RenderGlyphElt] = [
            .draw(deltax: 0, deltay: 0, glyphIDs: [0x41, 0x42, 0x43]),
            .glyphsetSwitch(deltax: 0, deltay: 0, glyphset: 0x40000020),
            .draw(deltax: 5, deltay: 0, glyphIDs: [0x44]),
            .glyphsetSwitch(deltax: 0, deltay: 0, glyphset: 0x40000030),
            .draw(deltax: 10, deltay: -5, glyphIDs: [0x45, 0x46]),
        ]
        try roundTrip(RenderCompositeGlyphs(
            idSize: .bits8, op: 3,
            src: 0x40000001, dst: 0x40000002,
            maskFormat: 0x20000020, glyphset: 0x40000010,
            xSrc: 0, ySrc: 0, elts: elts),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCompositeGlyphs.decode(from: $0, byteOrder: $1) })
    }

    func testCompositeGlyphsEmptyStream() throws {
        try roundTrip(RenderCompositeGlyphs(
            idSize: .bits8, op: 0,
            src: 0x40000001, dst: 0x40000002,
            maskFormat: 0, glyphset: 0x40000010,
            xSrc: 0, ySrc: 0, elts: []),
            encode: { $0.encode(majorOpcode: 139, byteOrder: $1) },
            decode: { try RenderCompositeGlyphs.decode(from: $0, byteOrder: $1) })
    }

    func testQueryPictFormatsReplyMultipleScreens() throws {
        // Stress the per-screen nDepths walking — two screens with
        // different depth counts.
        let direct = RenderDirectFormat(
            red: 16, redMask: 0xFF,
            green: 8, greenMask: 0xFF,
            blue: 0, blueMask: 0xFF,
            alpha: 0, alphaMask: 0
        )
        let formats = [
            RenderPictFormatInfo(id: 0x20000020, type: 1, depth: 24,
                                 direct: direct, colormap: 0),
        ]
        let screens = [
            // Screen 0: 2 depths
            RenderPictScreen(
                depths: [
                    RenderPictDepth(depth: 24, visuals: [
                        RenderPictVisual(visual: 0x21, format: 0x20000020),
                        RenderPictVisual(visual: 0x22, format: 0x20000020),
                    ]),
                    RenderPictDepth(depth: 32, visuals: []),
                ],
                fallback: 0x20000020
            ),
            // Screen 1: 1 depth, 3 visuals
            RenderPictScreen(
                depths: [
                    RenderPictDepth(depth: 24, visuals: [
                        RenderPictVisual(visual: 0x31, format: 0x20000020),
                        RenderPictVisual(visual: 0x32, format: 0x20000020),
                        RenderPictVisual(visual: 0x33, format: 0x20000020),
                    ]),
                ],
                fallback: 0x20000020
            ),
        ]
        try roundTrip(RenderQueryPictFormatsReply(
            sequenceNumber: 11,
            formats: formats, screens: screens,
            subpixels: [1, 2]),   // one per screen
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RenderQueryPictFormatsReply.decode(from: $0, byteOrder: $1) })
    }
}
