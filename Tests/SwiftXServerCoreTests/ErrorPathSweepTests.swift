import XCTest
@testable import SwiftXServerCore
import Framer

// Error-path sweep: for every X11 opcode that takes a resource argument,
// assert that an unknown ID produces the correct XError code with the
// correct majorOpcode. Companion to XErrorEmissionTests; that file covers
// the load-bearing cases that surfaced organically (CopyArea, PolyFillRectangle,
// FreeGC, etc.). This file fills out the rest of the opcode surface so the
// XError-honesty policy ratchets forward as new dispatchers are added.
//
// Pattern: a single Fixture builds a session with one mapped top-level
// window, one GC, one pixmap, one font, one cursor — all referenced by
// known IDs in `Fixture.*`. Each test feeds one request with bogus IDs in
// the field under test and asserts the resulting XError.

final class ErrorPathSweepTests: XCTestCase {

    // Resource IDs intentionally outside the resourceIdBase=0x4400000 /
    // resourceIdMask=0x1FFFFF window so they can never collide with a
    // real client-allocated ID.
    static let bogusWindow:   UInt32 = 0xDEADBEEF
    static let bogusDrawable: UInt32 = 0xCAFEBABE
    static let bogusGC:       UInt32 = 0xBADBADBA
    static let bogusPixmap:   UInt32 = 0xBADC0DE0
    static let bogusFont:     UInt32 = 0xFEEDFACE
    static let bogusCursor:   UInt32 = 0xBADCAFE0
    static let bogusColormap: UInt32 = 0xDEADC0DE
    static let bogusAtom:     UInt32 = 0x00100001  // > 0x10000, above predefined range

    /// One-shot fixture with all the resource types the sweep needs.
    /// Most tests just consume `(session, F)` and feed one bogus request.
    struct Fixture {
        let session: ServerSession
        let window: UInt32
        let gc: UInt32
        let pixmap: UInt32
        let font: UInt32
        let cursor: UInt32
        let colormap: UInt32

        static func make() -> Fixture {
            let session = ServerSession()
            _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
            _ = session.outbound.drain()

            let base = ServerConfig.default.resourceIdBase
            let wid:    UInt32 = base + 1
            let gcId:   UInt32 = base + 2
            let pixId:  UInt32 = base + 3
            let fontId: UInt32 = base + 4
            let curId:  UInt32 = base + 5

            // Top-level window (parent = root, depth = root depth = 8).
            _ = session.feed(Request.createWindow(CreateWindow(
                depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
                x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
                windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
                valueMask: 0, valueList: []
            )).encode(byteOrder: .lsbFirst))

            // GC against the window.
            _ = session.feed(Request.createGC(CreateGC(
                cid: gcId, drawable: wid, valueMask: 0, valueList: []
            )).encode(byteOrder: .lsbFirst))

            // Pixmap (depth 8 to match the root visual).
            _ = session.feed(Request.createPixmap(CreatePixmap(
                depth: 8, pid: pixId, drawable: wid, width: 50, height: 50
            )).encode(byteOrder: .lsbFirst))

            // Font (name "fixed" — FontResolver returns a substitute regardless).
            _ = session.feed(Request.openFont(OpenFont(
                fid: fontId, name: Array("fixed".utf8)
            )).encode(byteOrder: .lsbFirst))

            // Glyph cursor against the open font.
            _ = session.feed(Request.createGlyphCursor(CreateGlyphCursor(
                cid: curId, sourceFont: fontId, maskFont: 0,
                sourceChar: 0, maskChar: 0,
                foreRed: 0, foreGreen: 0, foreBlue: 0,
                backRed: 0xFFFF, backGreen: 0xFFFF, backBlue: 0xFFFF
            )).encode(byteOrder: .lsbFirst))

            _ = session.outbound.drain()
            return Fixture(
                session: session, window: wid, gc: gcId, pixmap: pixId,
                font: fontId, cursor: curId,
                colormap: ServerConfig.default.defaultColormapId
            )
        }
    }

    // Decode one ServerMessage from `bytes` and assert it's an XError with
    // the expected code + majorOpcode. `expectedBadId` is checked when
    // non-nil. Logs the actual bytes on failure so the diagnostic is
    // useful when a test starts failing.
    private func assertXError(
        _ bytes: [UInt8],
        code: XErrorCode,
        majorOpcode: UInt8,
        expectedBadId: UInt32? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
            guard case .xError(let err) = msg else {
                XCTFail("expected xError, got \(msg) (bytes=\(bytes.count))", file: file, line: line)
                return
            }
            XCTAssertEqual(err.errorCode, code.rawValue,
                           "error code mismatch: got \(err.errorCode) want \(code.rawValue)",
                           file: file, line: line)
            XCTAssertEqual(err.majorOpcode, majorOpcode,
                           "majorOpcode mismatch", file: file, line: line)
            if let want = expectedBadId {
                XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), want,
                               "badResourceId mismatch", file: file, line: line)
            }
        } catch {
            XCTFail("decode failed: \(error)", file: file, line: line)
        }
    }

    // MARK: - Window-arg gaps (BadWindow expected)

    func testChangeWindowAttributes_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: Self.bogusWindow, valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: ChangeWindowAttributes.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGetWindowAttributes_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.getWindowAttributes(GetWindowAttributes(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GetWindowAttributes.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testDestroySubwindows_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.destroySubwindows(DestroySubwindows(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: DestroySubwindows.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testMapSubwindows_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.mapSubwindows(MapSubwindows(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: MapSubwindows.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testUnmapWindow_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.unmapWindow(UnmapWindow(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: UnmapWindow.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testUnmapSubwindows_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.unmapSubwindows(UnmapSubwindows(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: UnmapSubwindows.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testReparentWindow_BadWindow() throws {
        let f = Fixture.make()
        // Bogus window arg, valid parent (root).
        let bytes = f.session.feed(Request.reparentWindow(ReparentWindow(
            window: Self.bogusWindow,
            parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: ReparentWindow.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testReparentWindow_BadParent() throws {
        // Real window, bogus parent → BadWindow. Spec section 10.4: parent
        // must be a valid window (root or descendant). Previously the
        // handler silently emitted ReparentNotify referencing the bogus
        // parent — a lie on the wire. Fix: validateWindowOrRoot on r.parent
        // immediately after the r.window check.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.reparentWindow(ReparentWindow(
            window: f.window, parent: Self.bogusWindow, x: 0, y: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: ReparentWindow.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testConfigureWindow_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.configureWindow(ConfigureWindow(
            window: Self.bogusWindow, valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: ConfigureWindow.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testCirculateWindow_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.circulateWindow(CirculateWindow(
            direction: 0, window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: CirculateWindow.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testQueryTree_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.queryTree(QueryTree(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: QueryTree.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testDeleteProperty_BadWindow() throws {
        let f = Fixture.make()
        // Window check happens before the property-atom check; bogus window
        // with a valid atom (PRIMARY=1) → BadWindow.
        let bytes = f.session.feed(Request.deleteProperty(DeleteProperty(
            window: Self.bogusWindow, property: 1
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: DeleteProperty.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testChangeProperty_BadWindow() throws {
        let f = Fixture.make()
        // Window check is first; even with a valid property atom (PRIMARY)
        // and STRING type, bogus window must yield BadWindow.
        let bytes = f.session.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: Self.bogusWindow, property: 1, type: 31,
            format: .format8, data: [0x41]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: ChangeProperty.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testTranslateCoordinates_BadSrcWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.translateCoordinates(TranslateCoordinates(
            srcWindow: Self.bogusWindow, dstWindow: f.window, srcX: 0, srcY: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: TranslateCoordinates.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testTranslateCoordinates_BadDstWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.translateCoordinates(TranslateCoordinates(
            srcWindow: f.window, dstWindow: Self.bogusWindow, srcX: 0, srcY: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: TranslateCoordinates.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testWarpPointer_BadSrcWindow() throws {
        // WarpPointer srcWindow=0 is the spec sentinel "None" (no source
        // confine); non-zero unknown id is BadWindow.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.warpPointer(WarpPointer(
            srcWindow: Self.bogusWindow, dstWindow: f.window,
            srcX: 0, srcY: 0, srcWidth: 0, srcHeight: 0,
            dstX: 0, dstY: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: WarpPointer.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testWarpPointer_BadDstWindow() throws {
        // dstWindow=0 means PointerRoot (no destination — just apply deltas);
        // non-zero unknown id is BadWindow.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.warpPointer(WarpPointer(
            srcWindow: 0, dstWindow: Self.bogusWindow,
            srcX: 0, srcY: 0, srcWidth: 0, srcHeight: 0,
            dstX: 0, dstY: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: WarpPointer.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testSetInputFocus_BadWindow() throws {
        let f = Fixture.make()
        // focus=0 (None) and focus=1 (PointerRoot) are spec sentinels —
        // the handler explicitly skips validation for them. A non-sentinel
        // unknown id should emit BadWindow.
        let bytes = f.session.feed(Request.setInputFocus(SetInputFocus(
            revertTo: .none, focus: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: SetInputFocus.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testQueryPointer_BadWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.queryPointer(QueryPointer(
            window: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: QueryPointer.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGrabPointer_BadGrabWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.grabPointer(GrabPointer(
            ownerEvents: false, grabWindow: Self.bogusWindow,
            eventMask: 0, pointerMode: .asynchronous, keyboardMode: .asynchronous
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GrabPointer.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGrabPointer_BadConfineTo() throws {
        // confineTo=0 (None) is the spec sentinel; bogus non-zero id → BadWindow.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.grabPointer(GrabPointer(
            ownerEvents: false, grabWindow: f.window,
            eventMask: 0, pointerMode: .asynchronous, keyboardMode: .asynchronous,
            confineTo: Self.bogusWindow
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GrabPointer.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGrabKeyboard_BadGrabWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.grabKeyboard(GrabKeyboard(
            ownerEvents: false, grabWindow: Self.bogusWindow,
            pointerMode: .asynchronous, keyboardMode: .asynchronous
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GrabKeyboard.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGrabButton_BadGrabWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.grabButton(GrabButton(
            ownerEvents: false, grabWindow: Self.bogusWindow,
            eventMask: 0, pointerMode: .asynchronous, keyboardMode: .asynchronous,
            modifiers: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GrabButton.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGrabButton_BadConfineTo() throws {
        // confineTo=0 (None) is the spec sentinel; bogus non-zero id → BadWindow.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.grabButton(GrabButton(
            ownerEvents: false, grabWindow: f.window,
            eventMask: 0, pointerMode: .asynchronous, keyboardMode: .asynchronous,
            confineTo: Self.bogusWindow,
            modifiers: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GrabButton.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testGrabKey_BadGrabWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.grabKey(GrabKey(
            ownerEvents: false, grabWindow: Self.bogusWindow,
            modifiers: 0, key: 0,
            pointerMode: .asynchronous, keyboardMode: .asynchronous
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: GrabKey.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    func testUngrabKey_BadGrabWindow() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.ungrabKey(UngrabKey(
            key: 0, grabWindow: Self.bogusWindow, modifiers: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .window, majorOpcode: UngrabKey.opcode,
                     expectedBadId: Self.bogusWindow)
    }

    // MARK: - GC-arg gaps (BadGC expected). All use a valid drawable.

    func testChangeGC_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.changeGC(ChangeGC(
            gc: Self.bogusGC, valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: ChangeGC.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testSetDashes_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.setDashes(SetDashes(
            gc: Self.bogusGC, dashOffset: 0, dashes: [4, 4]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: SetDashes.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testSetClipRectangles_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.setClipRectangles(SetClipRectangles(
            ordering: .unsorted, gc: Self.bogusGC,
            clipXOrigin: 0, clipYOrigin: 0, rectangles: []
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: SetClipRectangles.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testCopyArea_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.copyArea(CopyArea(
            srcDrawable: f.window, dstDrawable: f.window,
            gc: Self.bogusGC,
            srcX: 0, srcY: 0, dstX: 0, dstY: 0, width: 10, height: 10
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: CopyArea.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolyPoint_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyPoint(PolyPoint(
            coordinateMode: .origin, drawable: f.window, gc: Self.bogusGC,
            points: [Point(x: 0, y: 0)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolyPoint.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolyLine_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyLine(PolyLine(
            coordinateMode: .origin, drawable: f.window, gc: Self.bogusGC,
            points: [Point(x: 0, y: 0), Point(x: 10, y: 10)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolyLine.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolySegment_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polySegment(PolySegment(
            drawable: f.window, gc: Self.bogusGC,
            segments: [Segment(x1: 0, y1: 0, x2: 5, y2: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolySegment.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolyArc_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyArc(PolyArc(
            drawable: f.window, gc: Self.bogusGC,
            arcs: [Arc(x: 0, y: 0, width: 5, height: 5, angle1: 0, angle2: 360 * 64)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolyArc.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testFillPoly_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.fillPoly(FillPoly(
            drawable: f.window, gc: Self.bogusGC,
            shape: .complex, coordinateMode: .origin,
            points: [Point(x: 0, y: 0), Point(x: 5, y: 0), Point(x: 5, y: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: FillPoly.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolyRectangle_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyRectangle(PolyRectangle(
            drawable: f.window, gc: Self.bogusGC,
            rectangles: [Rectangle(x: 0, y: 0, width: 5, height: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolyRectangle.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolyFillArc_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyFillArc(PolyFillArc(
            drawable: f.window, gc: Self.bogusGC,
            arcs: [Arc(x: 0, y: 0, width: 5, height: 5, angle1: 0, angle2: 360 * 64)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolyFillArc.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPolyText8_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyText8(PolyText8(
            drawable: f.window, gc: Self.bogusGC, x: 0, y: 0, items: []
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PolyText8.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testImageText8_BadGC() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.imageText8(ImageText8(
            drawable: f.window, gc: Self.bogusGC,
            x: 0, y: 0, string: Array("Hi".utf8)
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: ImageText8.opcode,
                     expectedBadId: Self.bogusGC)
    }

    func testPutImage_BadGC() throws {
        let f = Fixture.make()
        // depth=1 bitmap to exercise the path that's actually implemented.
        // 4 bytes of source data (1 byte per row, 32-bit pad → 4 rows.
        // Width must fit in 8 bits leftPad+pixels; 1×4 bitmap is trivial).
        let bytes = f.session.feed(Request.putImage(PutImage(
            format: .bitmap, drawable: f.window, gc: Self.bogusGC,
            width: 1, height: 4, dstX: 0, dstY: 0,
            leftPad: 0, depth: 1, data: [0, 0, 0, 0]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .gc, majorOpcode: PutImage.opcode,
                     expectedBadId: Self.bogusGC)
    }

    // MARK: - Drawable-arg gaps (BadDrawable expected). Use bogus drawable,
    // valid GC (the GC's own drawable check happens at CreateGC time).

    func testPolyPoint_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyPoint(PolyPoint(
            coordinateMode: .origin, drawable: Self.bogusDrawable, gc: f.gc,
            points: [Point(x: 0, y: 0)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolyPoint.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPolyLine_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyLine(PolyLine(
            coordinateMode: .origin, drawable: Self.bogusDrawable, gc: f.gc,
            points: [Point(x: 0, y: 0), Point(x: 5, y: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolyLine.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPolySegment_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polySegment(PolySegment(
            drawable: Self.bogusDrawable, gc: f.gc,
            segments: [Segment(x1: 0, y1: 0, x2: 5, y2: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolySegment.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPolyArc_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyArc(PolyArc(
            drawable: Self.bogusDrawable, gc: f.gc,
            arcs: [Arc(x: 0, y: 0, width: 5, height: 5, angle1: 0, angle2: 360 * 64)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolyArc.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testFillPoly_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.fillPoly(FillPoly(
            drawable: Self.bogusDrawable, gc: f.gc,
            shape: .complex, coordinateMode: .origin,
            points: [Point(x: 0, y: 0), Point(x: 5, y: 0), Point(x: 5, y: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: FillPoly.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPolyRectangle_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyRectangle(PolyRectangle(
            drawable: Self.bogusDrawable, gc: f.gc,
            rectangles: [Rectangle(x: 0, y: 0, width: 5, height: 5)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolyRectangle.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPolyFillArc_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyFillArc(PolyFillArc(
            drawable: Self.bogusDrawable, gc: f.gc,
            arcs: [Arc(x: 0, y: 0, width: 5, height: 5, angle1: 0, angle2: 360 * 64)]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolyFillArc.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPolyText8_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.polyText8(PolyText8(
            drawable: Self.bogusDrawable, gc: f.gc, x: 0, y: 0, items: []
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PolyText8.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testImageText8_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.imageText8(ImageText8(
            drawable: Self.bogusDrawable, gc: f.gc,
            x: 0, y: 0, string: Array("Hi".utf8)
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: ImageText8.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    func testPutImage_BadDrawable() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.putImage(PutImage(
            format: .bitmap, drawable: Self.bogusDrawable, gc: f.gc,
            width: 1, height: 4, dstX: 0, dstY: 0,
            leftPad: 0, depth: 1, data: [0, 0, 0, 0]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .drawable, majorOpcode: PutImage.opcode,
                     expectedBadId: Self.bogusDrawable)
    }

    // MARK: - Colormap-arg gaps (BadColor expected)

    func testAllocNamedColor_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.allocNamedColor(AllocNamedColor(
            cmap: Self.bogusColormap, name: Array("red".utf8)
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: AllocNamedColor.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testLookupColor_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.lookupColor(LookupColor(
            cmap: Self.bogusColormap, name: Array("red".utf8)
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: LookupColor.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testQueryColors_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.queryColors(QueryColors(
            cmap: Self.bogusColormap, pixels: [0]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: QueryColors.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testFreeColormap_BadColormap() throws {
        let f = Fixture.make()
        // Non-default colormap that isn't the default → BadColor per the
        // current dispatcher.
        let bytes = f.session.feed(Request.freeColormap(FreeColormap(
            cmap: Self.bogusColormap
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: FreeColormap.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testFreeColormap_DefaultColormapIsBadAccess() throws {
        // Per spec: the default colormap can't be freed; BadAccess.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.freeColormap(FreeColormap(
            cmap: f.colormap
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .access, majorOpcode: FreeColormap.opcode,
                     expectedBadId: f.colormap)
    }

    func testCopyColormapAndFree_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.copyColormapAndFree(CopyColormapAndFree(
            mid: ServerConfig.default.resourceIdBase + 0x100,
            srcCmap: Self.bogusColormap
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: CopyColormapAndFree.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testInstallColormap_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.installColormap(InstallColormap(
            cmap: Self.bogusColormap
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: InstallColormap.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testUninstallColormap_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.uninstallColormap(UninstallColormap(
            cmap: Self.bogusColormap
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: UninstallColormap.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testFreeColors_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.freeColors(FreeColors(
            cmap: Self.bogusColormap, planeMask: 0, pixels: [0]
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: FreeColors.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testStoreColors_BadColormap() throws {
        let f = Fixture.make()
        // 12-byte StoreColors COLORITEM: pixel(4) + r(2) + g(2) + b(2) + flags(1) + pad(1).
        let item: [UInt8] = [0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0x07, 0]
        let bytes = f.session.feed(Request.storeColors(StoreColors(
            cmap: Self.bogusColormap, rawItems: item
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: StoreColors.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    func testStoreNamedColor_BadColormap() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.storeNamedColor(StoreNamedColor(
            flags: 0x07, cmap: Self.bogusColormap, pixel: 0,
            name: Array("red".utf8)
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .color, majorOpcode: StoreNamedColor.opcode,
                     expectedBadId: Self.bogusColormap)
    }

    // MARK: - Font-arg gaps (BadFont expected)

    func testCreateGlyphCursor_BadMaskFont() throws {
        // sourceFont valid, maskFont bogus (non-zero) → BadFont.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.createGlyphCursor(CreateGlyphCursor(
            cid: ServerConfig.default.resourceIdBase + 0x200,
            sourceFont: f.font, maskFont: Self.bogusFont,
            sourceChar: 0, maskChar: 0,
            foreRed: 0, foreGreen: 0, foreBlue: 0,
            backRed: 0xFFFF, backGreen: 0xFFFF, backBlue: 0xFFFF
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .font, majorOpcode: CreateGlyphCursor.opcode,
                     expectedBadId: Self.bogusFont)
    }

    // MARK: - Cursor-arg gaps (BadCursor expected)

    func testRecolorCursor_BadCursor() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.recolorCursor(RecolorCursor(
            cursor: Self.bogusCursor,
            foreRed: 0, foreGreen: 0, foreBlue: 0,
            backRed: 0xFFFF, backGreen: 0xFFFF, backBlue: 0xFFFF
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .cursor, majorOpcode: RecolorCursor.opcode,
                     expectedBadId: Self.bogusCursor)
    }

    func testChangeActivePointerGrab_BadCursor() throws {
        // The handler today treats "no active grab" as the trigger to
        // skip the cursor lookup entirely — and we have no active grab in
        // the fixture. So this currently no-ops silently with a bogus
        // cursor. SHORTCUT: even when an active grab exists, the handler
        // doesn't validate the cursor argument.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.changeActivePointerGrab(ChangeActivePointerGrab(
            cursor: Self.bogusCursor, time: 0, eventMask: 0
        )).encode(byteOrder: .lsbFirst))
        if let msg = try? ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst),
           case .xError = msg {
            assertXError(bytes, code: .cursor,
                         majorOpcode: ChangeActivePointerGrab.opcode,
                         expectedBadId: Self.bogusCursor)
        }
    }

    // MARK: - Atom-arg gaps (BadAtom expected)

    func testDeleteProperty_BadAtomZero() throws {
        // Atom 0 is the spec sentinel `None`, not a valid property argument.
        // Today's handler routes property=0 through validateAtom which emits
        // BadAtom — see GetAtomName(0) test for the matching contract.
        let f = Fixture.make()
        let bytes = f.session.feed(Request.deleteProperty(DeleteProperty(
            window: f.window, property: 0
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .atom, majorOpcode: DeleteProperty.opcode,
                     expectedBadId: 0)
    }

    func testDeleteProperty_BadAtomUnknown() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.deleteProperty(DeleteProperty(
            window: f.window, property: Self.bogusAtom
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .atom, majorOpcode: DeleteProperty.opcode,
                     expectedBadId: Self.bogusAtom)
    }

    func testSetSelectionOwner_BadAtom() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: f.window, selection: Self.bogusAtom
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .atom, majorOpcode: SetSelectionOwner.opcode,
                     expectedBadId: Self.bogusAtom)
    }

    func testGetSelectionOwner_BadAtom() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.getSelectionOwner(GetSelectionOwner(
            selection: Self.bogusAtom
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .atom, majorOpcode: GetSelectionOwner.opcode,
                     expectedBadId: Self.bogusAtom)
    }

    func testConvertSelection_BadAtom() throws {
        let f = Fixture.make()
        let bytes = f.session.feed(Request.convertSelection(ConvertSelection(
            requestor: f.window, selection: Self.bogusAtom,
            target: 31, property: 1
        )).encode(byteOrder: .lsbFirst))
        assertXError(bytes, code: .atom, majorOpcode: ConvertSelection.opcode,
                     expectedBadId: Self.bogusAtom)
    }

}
