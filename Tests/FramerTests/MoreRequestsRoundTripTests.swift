import XCTest
@testable import Framer

// Parameterized round-trip tests for the second batch of opcodes. Each test
// constructs a value, encodes it, decodes it, and verifies the round-trip is
// byte-identical and field-equal in both byte orders. Hand-crafted byte
// fixtures live in dedicated test files (RequestTests, InternAtomTests, etc.)
// for the trickier opcodes; this file is bulk coverage.

final class MoreRequestsRoundTripTests: XCTestCase {

    private func roundTrip<T: Equatable>(
        _ original: T,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count % 4, 0, "request bytes must be 4-byte aligned")
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "field equality fails for \(T.self) in \(order)")
            XCTAssertEqual(bytes, encode(decoded, order), "byte-identical round-trip fails for \(T.self) in \(order)")
        }
    }

    // MARK: - Single ID requests

    func testDestroyWindow() throws {
        try roundTrip(DestroyWindow(window: 0xABCDEF01),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try DestroyWindow.decode(from: $0, byteOrder: $1) })
    }

    func testMapSubwindows() throws {
        try roundTrip(MapSubwindows(window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try MapSubwindows.decode(from: $0, byteOrder: $1) })
    }

    func testUnmapWindow() throws {
        try roundTrip(UnmapWindow(window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UnmapWindow.decode(from: $0, byteOrder: $1) })
    }

    func testGetGeometry() throws {
        try roundTrip(GetGeometry(drawable: 0x10000010),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetGeometry.decode(from: $0, byteOrder: $1) })
    }

    func testQueryTree() throws {
        try roundTrip(QueryTree(window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryTree.decode(from: $0, byteOrder: $1) })
    }

    func testGetAtomName() throws {
        try roundTrip(GetAtomName(atom: 0x47),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetAtomName.decode(from: $0, byteOrder: $1) })
    }

    func testGetSelectionOwner() throws {
        try roundTrip(GetSelectionOwner(selection: 0x91),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetSelectionOwner.decode(from: $0, byteOrder: $1) })
    }

    func testCloseFont() throws {
        try roundTrip(CloseFont(font: 0x20000001),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CloseFont.decode(from: $0, byteOrder: $1) })
    }

    func testQueryFont() throws {
        try roundTrip(QueryFont(font: 0x20000001),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryFont.decode(from: $0, byteOrder: $1) })
    }

    func testFreePixmap() throws {
        try roundTrip(FreePixmap(pixmap: 0x10000020),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try FreePixmap.decode(from: $0, byteOrder: $1) })
    }

    func testFreeGC() throws {
        try roundTrip(FreeGC(gc: 0x30000001),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try FreeGC.decode(from: $0, byteOrder: $1) })
    }

    func testFreeCursor() throws {
        try roundTrip(FreeCursor(cursor: 0x40000001),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try FreeCursor.decode(from: $0, byteOrder: $1) })
    }

    func testQueryPointer() throws {
        try roundTrip(QueryPointer(window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryPointer.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Header-only requests

    func testGrabServer() throws {
        try roundTrip(GrabServer(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GrabServer.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabServer() throws {
        try roundTrip(UngrabServer(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UngrabServer.decode(from: $0, byteOrder: $1) })
    }

    func testGetInputFocus() throws {
        try roundTrip(GetInputFocus(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetInputFocus.decode(from: $0, byteOrder: $1) })
    }

    func testGetModifierMapping() throws {
        try roundTrip(GetModifierMapping(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetModifierMapping.decode(from: $0, byteOrder: $1) })
    }

    func testListExtensions() throws {
        try roundTrip(ListExtensions(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListExtensions.decode(from: $0, byteOrder: $1) })
    }

    func testNoOperation() throws {
        try roundTrip(NoOperation(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try NoOperation.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Additional opcodes (added 2026-05-14 to close framer gaps)

    func testUngrabButton() throws {
        try roundTrip(UngrabButton(button: 1, grabWindow: 0xABCDEF01, modifiers: 0x4),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UngrabButton.decode(from: $0, byteOrder: $1) })
        // AnyButton + AnyModifier
        try roundTrip(UngrabButton(button: 0, grabWindow: 0xABCDEF01, modifiers: 0x8000),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UngrabButton.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabKey() throws {
        try roundTrip(UngrabKey(key: 24, grabWindow: 0xABCDEF01, modifiers: 0x4),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UngrabKey.decode(from: $0, byteOrder: $1) })
    }

    func testGetMotionEvents() throws {
        try roundTrip(GetMotionEvents(window: 0x10000005, start: 1000, stop: 2000),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetMotionEvents.decode(from: $0, byteOrder: $1) })
    }

    func testAllocColorCells() throws {
        try roundTrip(AllocColorCells(contiguous: true, cmap: 0x21, colors: 16, planes: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try AllocColorCells.decode(from: $0, byteOrder: $1) })
        try roundTrip(AllocColorCells(contiguous: false, cmap: 0x21, colors: 4, planes: 2),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try AllocColorCells.decode(from: $0, byteOrder: $1) })
    }

    func testSetCloseDownMode() throws {
        try roundTrip(SetCloseDownMode(mode: 1),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetCloseDownMode.decode(from: $0, byteOrder: $1) })
    }

    func testKillClient() throws {
        try roundTrip(KillClient(resource: 0xDEADBEEF),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try KillClient.decode(from: $0, byteOrder: $1) })
    }

    func testGetScreenSaver() throws {
        try roundTrip(GetScreenSaver(),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetScreenSaver.decode(from: $0, byteOrder: $1) })
    }

    func testSetScreenSaver() throws {
        try roundTrip(
            SetScreenSaver(timeout: 600, interval: 60, preferBlanking: 1, allowExposures: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetScreenSaver.decode(from: $0, byteOrder: $1) })
        // Negative timeout (-1 = restore default) is spec-legal.
        try roundTrip(
            SetScreenSaver(timeout: -1, interval: -1, preferBlanking: 2, allowExposures: 2),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetScreenSaver.decode(from: $0, byteOrder: $1) })
    }

    func testForceScreenSaver() throws {
        try roundTrip(ForceScreenSaver(mode: 0),  // Reset
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ForceScreenSaver.decode(from: $0, byteOrder: $1) })
        try roundTrip(ForceScreenSaver(mode: 1),  // Activate
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ForceScreenSaver.decode(from: $0, byteOrder: $1) })
    }

    func testGetImage() throws {
        try roundTrip(
            GetImage(format: .zPixmap, drawable: 0x4400001,
                     x: 0, y: 0, width: 100, height: 100, planeMask: 0xFFFFFFFF),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetImage.decode(from: $0, byteOrder: $1) })
        // Negative x/y signed-coverage, XYPixmap, partial planemask.
        try roundTrip(
            GetImage(format: .xyPixmap, drawable: 0x4400001,
                     x: -5, y: -10, width: 1, height: 1, planeMask: 0x000000FF),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetImage.decode(from: $0, byteOrder: $1) })
    }

    func testImageText16() throws {
        // ASCII range — row=0 for every char (CHAR2B = (0x00, 'H') etc).
        try roundTrip(
            ImageText16(drawable: 0x4400003, gc: 0x4400004, x: 10, y: 20,
                        characters: [0x0048, 0x0049]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ImageText16.decode(from: $0, byteOrder: $1) })
        // CJK range — k14 / k24 test data lives in row > 0.
        try roundTrip(
            ImageText16(drawable: 0x4400003, gc: 0x4400004, x: -5, y: 200,
                        characters: [0x2121, 0x2122, 0x2123]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ImageText16.decode(from: $0, byteOrder: $1) })
    }

    func testCopyPlane() throws {
        // Typical use: depth-1 source pixmap → depth-N dst, bitPlane=1.
        try roundTrip(
            CopyPlane(srcDrawable: 0x4400010, dstDrawable: 0x4400020, gc: 0x4400030,
                      srcX: 0, srcY: 0, dstX: 50, dstY: 60,
                      width: 100, height: 100, bitPlane: 1),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CopyPlane.decode(from: $0, byteOrder: $1) })
        // deepcopyplane: src is depth-8 window, bitPlane is some power of two
        // in the [1..128] range. Negative srcX/Y / dstX/Y signed coverage.
        try roundTrip(
            CopyPlane(srcDrawable: 0x4400011, dstDrawable: 0x4400021, gc: 0x4400031,
                      srcX: -1, srcY: -2, dstX: -3, dstY: -4,
                      width: 500, height: 500, bitPlane: 0x80),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CopyPlane.decode(from: $0, byteOrder: $1) })
    }

    func testPolyText16() throws {
        // One TEXTITEM16: length=2 (CHAR2B chars), delta=0, 4 bytes char data.
        let items: [UInt8] = [
            2,          // length
            0,          // delta
            0x00, 0x48, // 'H'
            0x00, 0x69  // 'i'
        ]
        try roundTrip(
            PolyText16(drawable: 0x4400003, gc: 0x4400004, x: 10, y: 20,
                       items: items + [0, 0]),   // pad to 4-byte
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolyText16.decode(from: $0, byteOrder: $1) })
    }

    func testGetImageReply() throws {
        // 4-byte data path (4 pixels at depth 8, exactly fills one 32-bit unit).
        try roundTrip(
            GetImageReply(sequenceNumber: 0xABCD, depth: 8, visual: 0x22,
                          imageData: [0x01, 0x02, 0x03, 0x04]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetImageReply.decode(from: $0, byteOrder: $1) })
        // Unpadded payload — 5 bytes encodes with 3 bytes of pad; decode
        // returns the 8-byte padded buffer (caller-visible payload length is
        // (reply.imageData.count) which after round-trip will be 8). We
        // construct the original with the post-padded length to keep the
        // round-trip equality clean.
        try roundTrip(
            GetImageReply(sequenceNumber: 1, depth: 8, visual: 0x22,
                          imageData: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0, 0, 0]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetImageReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Structured requests

    func testReparentWindow() throws {
        try roundTrip(
            ReparentWindow(window: 0x10000010, parent: 0x10000005, x: 50, y: -10),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ReparentWindow.decode(from: $0, byteOrder: $1) })
    }

    func testConfigureWindow() throws {
        // valueMask bit 0 (x) | bit 2 (width) → 0x05, popcount=2, valueList=8 bytes
        let valueList: [UInt8] = [
            0x00, 0x64, 0x00, 0x00,             // x = 100
            0x01, 0x90, 0x00, 0x00,             // width = 400
        ]
        try roundTrip(
            ConfigureWindow(window: 0x10000010, valueMask: 0x05, valueList: valueList),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ConfigureWindow.decode(from: $0, byteOrder: $1) })
    }

    func testDeleteProperty() throws {
        try roundTrip(
            DeleteProperty(window: 0x10000005, property: 0x91),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try DeleteProperty.decode(from: $0, byteOrder: $1) })
    }

    func testSetSelectionOwner() throws {
        try roundTrip(
            SetSelectionOwner(owner: 0x10000010, selection: 0x91, time: 12345),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetSelectionOwner.decode(from: $0, byteOrder: $1) })
    }

    func testGrabPointer() throws {
        try roundTrip(
            GrabPointer(
                ownerEvents: false, grabWindow: 0x10000005, eventMask: 0x4,
                pointerMode: .asynchronous, keyboardMode: .asynchronous,
                confineTo: 0, cursor: 0, time: 0
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GrabPointer.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabPointer() throws {
        try roundTrip(UngrabPointer(time: 999),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UngrabPointer.decode(from: $0, byteOrder: $1) })
    }

    func testGrabButton() throws {
        try roundTrip(
            GrabButton(
                ownerEvents: true, grabWindow: 0x10000005, eventMask: 0x4,
                pointerMode: .asynchronous, keyboardMode: .asynchronous,
                button: 1, modifiers: 0x8000
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GrabButton.decode(from: $0, byteOrder: $1) })
    }

    func testGrabKeyboard() throws {
        try roundTrip(
            GrabKeyboard(
                ownerEvents: true, grabWindow: 0x10000005, time: 0,
                pointerMode: .asynchronous, keyboardMode: .synchronous
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GrabKeyboard.decode(from: $0, byteOrder: $1) })
    }

    func testUngrabKeyboard() throws {
        try roundTrip(UngrabKeyboard(time: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try UngrabKeyboard.decode(from: $0, byteOrder: $1) })
    }

    func testAllowEvents() throws {
        try roundTrip(AllowEvents(mode: .replayPointer, time: 12345),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try AllowEvents.decode(from: $0, byteOrder: $1) })
    }

    func testTranslateCoordinates() throws {
        try roundTrip(
            TranslateCoordinates(srcWindow: 0x10000005, dstWindow: 0x10000010, srcX: -50, srcY: 100),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try TranslateCoordinates.decode(from: $0, byteOrder: $1) })
    }

    func testWarpPointer() throws {
        try roundTrip(
            WarpPointer(
                srcWindow: 0, dstWindow: 0x10000005,
                srcX: 0, srcY: 0, srcWidth: 0, srcHeight: 0,
                dstX: 100, dstY: 200
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try WarpPointer.decode(from: $0, byteOrder: $1) })
    }

    func testSetInputFocus() throws {
        try roundTrip(SetInputFocus(revertTo: .parent, focus: 0x10000005, time: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetInputFocus.decode(from: $0, byteOrder: $1) })
    }

    func testCreatePixmap() throws {
        try roundTrip(
            CreatePixmap(depth: 8, pid: 0x50000001, drawable: 0x10000005, width: 16, height: 16),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CreatePixmap.decode(from: $0, byteOrder: $1) })
    }

    func testClearArea() throws {
        try roundTrip(
            ClearArea(exposures: true, window: 0x10000005, x: 10, y: 20, width: 100, height: 50),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ClearArea.decode(from: $0, byteOrder: $1) })
    }

    func testCopyArea() throws {
        try roundTrip(
            CopyArea(
                srcDrawable: 0x10000005, dstDrawable: 0x50000001, gc: 0x30000001,
                srcX: 0, srcY: 0, dstX: 100, dstY: 100, width: 50, height: 50
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CopyArea.decode(from: $0, byteOrder: $1) })
    }

    func testPolyLine() throws {
        try roundTrip(
            PolyLine(
                coordinateMode: .origin, drawable: 0x10000005, gc: 0x30000001,
                points: [Point(x: 0, y: 0), Point(x: 100, y: 50), Point(x: 200, y: 200)]
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolyLine.decode(from: $0, byteOrder: $1) })
    }

    func testPutImage() throws {
        // 16 bytes of pixel data, 4-byte aligned so the round-trip is also field-equal.
        let data: [UInt8] = (0..<16).map { UInt8($0) }
        try roundTrip(
            PutImage(
                format: .zPixmap, drawable: 0x10000005, gc: 0x30000001,
                width: 4, height: 4, dstX: 0, dstY: 0,
                leftPad: 0, depth: 8, data: data
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PutImage.decode(from: $0, byteOrder: $1) })
    }

    func testAllocColor() throws {
        try roundTrip(
            AllocColor(cmap: 0x60000001, red: 0xFFFF, green: 0x0000, blue: 0xAAAA),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try AllocColor.decode(from: $0, byteOrder: $1) })
    }

    func testQueryColors() throws {
        try roundTrip(
            QueryColors(cmap: 0x60000001, pixels: [0x00FFFFFF, 0x00000000, 0x000000FF]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryColors.decode(from: $0, byteOrder: $1) })
    }

    func testCreateGlyphCursor() throws {
        try roundTrip(
            CreateGlyphCursor(
                cid: 0x40000001, sourceFont: 0x20000001, maskFont: 0,
                sourceChar: 64, maskChar: 0,
                foreRed: 0, foreGreen: 0, foreBlue: 0,
                backRed: 0xFFFF, backGreen: 0xFFFF, backBlue: 0xFFFF
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try CreateGlyphCursor.decode(from: $0, byteOrder: $1) })
    }

    func testRecolorCursor() throws {
        try roundTrip(
            RecolorCursor(
                cursor: 0x40000001,
                foreRed: 0, foreGreen: 0, foreBlue: 0,
                backRed: 0xFFFF, backGreen: 0xFFFF, backBlue: 0xFFFF
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try RecolorCursor.decode(from: $0, byteOrder: $1) })
    }

    func testGetKeyboardMapping() throws {
        try roundTrip(GetKeyboardMapping(firstKeycode: 8, count: 248),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetKeyboardMapping.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Dispatch coverage

    func testRequestDispatchCoversAllNew() throws {
        let cases: [Request] = [
            .destroyWindow(DestroyWindow(window: 1)),
            .destroySubwindows(DestroySubwindows(window: 1)),
            .reparentWindow(ReparentWindow(window: 1, parent: 2, x: 0, y: 0)),
            .mapSubwindows(MapSubwindows(window: 1)),
            .unmapWindow(UnmapWindow(window: 1)),
            .unmapSubwindows(UnmapSubwindows(window: 1)),
            .configureWindow(ConfigureWindow(window: 1, valueMask: 0)),
            .getGeometry(GetGeometry(drawable: 1)),
            .queryTree(QueryTree(window: 1)),
            .getAtomName(GetAtomName(atom: 1)),
            .deleteProperty(DeleteProperty(window: 1, property: 2)),
            .setSelectionOwner(SetSelectionOwner(owner: 1, selection: 2)),
            .getSelectionOwner(GetSelectionOwner(selection: 1)),
            .grabPointer(GrabPointer(
                ownerEvents: false, grabWindow: 1, eventMask: 0,
                pointerMode: .asynchronous, keyboardMode: .asynchronous
            )),
            .ungrabPointer(UngrabPointer()),
            .grabKeyboard(GrabKeyboard(
                ownerEvents: false, grabWindow: 1,
                pointerMode: .asynchronous, keyboardMode: .asynchronous
            )),
            .ungrabKeyboard(UngrabKeyboard()),
            .allowEvents(AllowEvents(mode: .asyncBoth)),
            .grabServer(GrabServer()),
            .ungrabServer(UngrabServer()),
            .queryPointer(QueryPointer(window: 1)),
            .translateCoordinates(TranslateCoordinates(srcWindow: 1, dstWindow: 2, srcX: 0, srcY: 0)),
            .warpPointer(WarpPointer(
                srcWindow: 0, dstWindow: 1, srcX: 0, srcY: 0,
                srcWidth: 0, srcHeight: 0, dstX: 0, dstY: 0
            )),
            .setInputFocus(SetInputFocus(revertTo: .parent, focus: 1)),
            .getInputFocus(GetInputFocus()),
            .queryKeymap(QueryKeymap()),
            .closeFont(CloseFont(font: 1)),
            .queryFont(QueryFont(font: 1)),
            .createPixmap(CreatePixmap(depth: 8, pid: 1, drawable: 2, width: 1, height: 1)),
            .freePixmap(FreePixmap(pixmap: 1)),
            .freeGC(FreeGC(gc: 1)),
            .clearArea(ClearArea(exposures: false, window: 1, x: 0, y: 0, width: 1, height: 1)),
            .copyArea(CopyArea(
                srcDrawable: 1, dstDrawable: 2, gc: 3,
                srcX: 0, srcY: 0, dstX: 0, dstY: 0, width: 1, height: 1
            )),
            .polyLine(PolyLine(coordinateMode: .origin, drawable: 1, gc: 2, points: [])),
            .putImage(PutImage(
                format: .zPixmap, drawable: 1, gc: 2,
                width: 0, height: 0, dstX: 0, dstY: 0,
                leftPad: 0, depth: 8, data: []
            )),
            .allocColor(AllocColor(cmap: 1, red: 0, green: 0, blue: 0)),
            .queryColors(QueryColors(cmap: 1, pixels: [])),
            .createGlyphCursor(CreateGlyphCursor(
                cid: 1, sourceFont: 2, maskFont: 0,
                sourceChar: 0, maskChar: 0,
                foreRed: 0, foreGreen: 0, foreBlue: 0,
                backRed: 0, backGreen: 0, backBlue: 0
            )),
            .freeCursor(FreeCursor(cursor: 1)),
            .recolorCursor(RecolorCursor(
                cursor: 1,
                foreRed: 0, foreGreen: 0, foreBlue: 0,
                backRed: 0, backGreen: 0, backBlue: 0
            )),
            .listExtensions(ListExtensions()),
            .getKeyboardMapping(GetKeyboardMapping(firstKeycode: 8, count: 1)),
            .getModifierMapping(GetModifierMapping()),
            .getPointerMapping(GetPointerMapping()),
        ]
        for original in cases {
            for order in [ByteOrder.lsbFirst, .msbFirst] {
                let bytes = original.encode(byteOrder: order)
                let decoded = try Request.decode(from: bytes, byteOrder: order)
                XCTAssertEqual(original, decoded, "dispatch round-trip failed for \(original) in \(order)")
            }
        }
    }
}
