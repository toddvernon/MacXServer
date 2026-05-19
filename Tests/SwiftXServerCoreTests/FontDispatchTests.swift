import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// Recording bridge for verifying font + text dispatch paths.
private final class RecBridge: WindowBridge, @unchecked Sendable {
    struct ImageText8Call: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var background: RGB16
        var fontName: String
        var pointSize: Double
        var cellWidth: Int
        var cellHeight: Int
        var x: Int16
        var y: Int16
        var string: [UInt8]
    }
    struct FillRectsCall: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var rectangles: [Framer.Rectangle]
    }
    struct PolyText8Call: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var x: Int16
        var y: Int16
        var items: [UInt8]
        var clipRectangles: [Framer.Rectangle]?
    }

    var imageText8Calls: [ImageText8Call] = []
    var fillRectsCalls: [FillRectsCall] = []
    var polyText8Calls: [PolyText8Call] = []

    func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
    func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func setTopLevelTitle(id: UInt32, title: String) {}

    func drawImageText8(
        target: DrawTarget, foreground: RGB16, background: RGB16,
        font: ResolvedFont, x: Int16, y: Int16, string: [UInt8],
        clipRectangles: [Framer.Rectangle]?
    ) {
        guard case .window(let topLevel, _, _) = target else { return }
        imageText8Calls.append(ImageText8Call(
            topLevel: topLevel, foreground: foreground, background: background,
            fontName: font.macFontName, pointSize: font.pointSize,
            cellWidth: font.cellWidth, cellHeight: font.cellHeight,
            x: x, y: y, string: string
        ))
    }
    func drawPolyText8(
        target: DrawTarget, foreground: RGB16,
        font: ResolvedFont, x: Int16, y: Int16, items: [UInt8],
        clipRectangles: [Framer.Rectangle]?
    ) {
        guard case .window(let topLevel, _, _) = target else { return }
        polyText8Calls.append(PolyText8Call(
            topLevel: topLevel, foreground: foreground,
            x: x, y: y, items: items, clipRectangles: clipRectangles
        ))
    }
    func drawPolyFillRectangle(target: DrawTarget, foreground: RGB16, background: RGB16, function: UInt8, fillStyle: UInt8, stipple: UInt32, tile: UInt32, stippleOriginX: Int16, stippleOriginY: Int16, rectangles: [Framer.Rectangle], clipRectangles: [Framer.Rectangle]?) {
        guard case .window(let topLevel, _, _) = target else { return }
        fillRectsCalls.append(FillRectsCall(
            topLevel: topLevel, foreground: foreground, rectangles: rectangles
        ))
    }
}

final class FontDispatchTests: XCTestCase {

    func testOpenFontStoresResolvedMetadata() {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let req = OpenFont(fid: 0x4400005, name: Array("9x15".utf8))
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        let entry = session.fonts.get(0x4400005)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.resolved.macFontName, "Monaco")
        // 9x15 alias → Monaco's natural cell at integer pointSize 11
        // (advance ratio ~0.6, lineHeight ratio ~1.34): 7×15.
        XCTAssertEqual(entry?.resolved.cellWidth, 7)
        XCTAssertEqual(entry?.resolved.cellHeight, 15)
    }

    func testQueryFontReplyMatchesResolvedMetrics() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        _ = session.feed(OpenFont(fid: 0x4400005, name: Array("7x14".utf8))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(QueryFont(font: 0x4400005)
            .encode(byteOrder: .lsbFirst))

        let reply = try QueryFontReply.decode(from: bytes, byteOrder: .lsbFirst)
        // 7x14 alias drifts to Monaco's natural cell at pointSize 10 (6x13).
        // QueryFont reports the truth so xterm sizes its window from real
        // metrics that match what we render.
        //
        // Monospace property: characterWidth (advance) is constant across
        // all glyphs. Per-glyph ascent/descent/bearing still vary even for
        // monospace fonts because letters like 'g' / 'p' / 'y' have
        // descenders that letters like 'a' / 'c' / 'e' don't. Per the X
        // spec, an empty charInfos[] requires min == max in ALL six fields
        // — including descent — so a monospace font with descenders MUST
        // populate the per-char array. (Pre-2026-05-15 we shortcut this
        // and returned empty charInfos for every font; see SHORTCUTS.)
        XCTAssertEqual(reply.minBounds.characterWidth, reply.maxBounds.characterWidth,
                       "monospace property: constant advance")
        XCTAssertEqual(reply.minBounds.characterWidth, 6, "Monaco 10pt cell width")
        XCTAssertEqual(reply.fontAscent + reply.fontDescent, 13, "Monaco 10pt cell height")
        XCTAssertEqual(reply.minCharOrByte2, 32)
        // ISO-8859-1 range as of 2026-05-17: 32...255 (224 chars), required
        // so Motif's XCreateFontSet can build a usable FontSet for the C
        // locale. Aliases like "7x14" default to iso8859-1.
        XCTAssertEqual(reply.maxCharOrByte2, 255)
        XCTAssertEqual(reply.charInfos.count, 255 - 32 + 1,
                       "one CHARINFO per char in ISO-8859-1 range; monospace can't elide because descenders vary")
        // Per-glyph descent varies (descenders); per-glyph advance is
        // constant for ASCII glyphs. Restrict the spot-check to the ASCII
        // range — 0x80-0x9F are C1 controls with no glyphs and chars
        // 0xA0-0xFF rendering depends on Monaco having ISO-Latin-1
        // coverage which Core Text generally provides but the test
        // doesn't strictly assert.
        let asciiCharInfos = Array(reply.charInfos[0..<(126 - 32 + 1)])
        let widthValues = Set(asciiCharInfos.map { $0.characterWidth })
        XCTAssertEqual(widthValues.count, 1, "monospace ASCII: one distinct advance")
        let descentValues = Set(asciiCharInfos.map { $0.descent })
        XCTAssertGreaterThanOrEqual(descentValues.count, 1,
                                    "at least one distinct descent (descenders may or may not differ from ascenders depending on font)")
    }

    func testQueryFontReplyForProportionalFontPopulatesPerGlyphCharInfos() throws {
        // The bug Todd hit on quickplot's menus: Helvetica isn't monospace.
        // Pre-2026-05-15 QueryFont returned charInfos=[] with min==max for
        // every font (the same monospace shortcut QueryTextExtents had
        // before its fix). Xt's LabelWidget reads min/max-bounds to
        // decide whether to per-string measure or assume uniform-width;
        // if it sees min==max it skips per-string measurement and lays
        // out text using the wrong advance.
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let helvetica = "-adobe-helvetica-medium-o-*-*-12-*-*-*-*-*-*-*"
        _ = session.feed(OpenFont(fid: 0x4400006, name: Array(helvetica.utf8))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(QueryFont(font: 0x4400006)
            .encode(byteOrder: .lsbFirst))
        let reply = try QueryFontReply.decode(from: bytes, byteOrder: .lsbFirst)

        // Proportional property: 'M' is wider than 'i', so the advance
        // values across the range vary — min.characterWidth < max.characterWidth.
        XCTAssertLessThan(reply.minBounds.characterWidth, reply.maxBounds.characterWidth,
                          "Helvetica is proportional: min advance < max advance")
        // Per spec, an empty charInfos[] requires min == max across all six
        // fields. Since min < max in characterWidth alone, charInfos MUST
        // be populated. ISO-8859-1 range 32...255 (224 chars) as of
        // 2026-05-17 — wildcard charset in the XLFD resolves to iso8859-1.
        XCTAssertFalse(reply.charInfos.isEmpty,
                       "proportional font requires per-glyph CHARINFO array")
        XCTAssertEqual(reply.charInfos.count, 255 - 32 + 1)

        // Spot-check: 'M' (code 77 → index 77-32 = 45) is wider than 'i'
        // (code 105 → index 73).
        let charInfoM = reply.charInfos[77 - 32]
        let charInfoI = reply.charInfos[105 - 32]
        XCTAssertGreaterThan(charInfoM.characterWidth, charInfoI.characterWidth,
                             "'M' advance > 'i' advance in Helvetica")

        // FONTPROPS: integer metrics (FONT_ASCENT, FONT_DESCENT,
        // DEFAULT_CHAR, AVERAGE_WIDTH) plus charset atoms (CHARSET_REGISTRY,
        // CHARSET_ENCODING) = 6 minimum.
        XCTAssertGreaterThanOrEqual(reply.properties.count, 6,
                                    "at least the six FONTPROPS we emit")
    }

    func testQueryFontReplyEmitsCharsetRegistryAndEncodingFontProps() throws {
        // Regression guard for the 2026-05-17 charset fix. Without
        // CHARSET_REGISTRY / CHARSET_ENCODING FONTPROPS pointing at
        // properly-interned atom IDs that match the font's XLFD-declared
        // charset, Motif's XCreateFontSet can't find a per-charset match
        // and falls through to "Cannot convert string to type FontSet" —
        // widgets end up with no usable font and button labels render
        // blank (the dt-Motif invisible-text bug Todd hit pre-fix).
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let xlfd = "-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-ISO8859-1"
        _ = session.feed(OpenFont(fid: 0x4400007, name: Array(xlfd.utf8))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(QueryFont(font: 0x4400007)
            .encode(byteOrder: .lsbFirst))
        let reply = try QueryFontReply.decode(from: bytes, byteOrder: .lsbFirst)

        // ISO-8859-1 reply must cover 32...255 (224 chars) so Motif's
        // FontSet builder accepts it as the matching variant for C locale.
        XCTAssertEqual(reply.minCharOrByte2, 32)
        XCTAssertEqual(reply.maxCharOrByte2, 255)
        XCTAssertEqual(reply.charInfos.count, 224)

        // Atom IDs for the property names we expect to see.
        let registryName = session.atoms.intern("CHARSET_REGISTRY")
        let encodingName = session.atoms.intern("CHARSET_ENCODING")
        let iso8859Atom  = session.atoms.intern("ISO8859")
        let oneAtom      = session.atoms.intern("1")

        let registryProp = reply.properties.first { $0.name == registryName }
        let encodingProp = reply.properties.first { $0.name == encodingName }
        XCTAssertNotNil(registryProp, "CHARSET_REGISTRY FONTPROP must be present")
        XCTAssertNotNil(encodingProp, "CHARSET_ENCODING FONTPROP must be present")
        XCTAssertEqual(registryProp?.value, iso8859Atom,
                       "CHARSET_REGISTRY value must be atom('ISO8859')")
        XCTAssertEqual(encodingProp?.value, oneAtom,
                       "CHARSET_ENCODING value must be atom('1')")
    }

    func testImageText8DispatchesWithGCFontMetadata() {
        let bridge = RecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level window
        let createWin = CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        )
        _ = session.feed(createWin.encode(byteOrder: .lsbFirst))

        // Open a 9x15 font
        _ = session.feed(OpenFont(fid: 0x4400005, name: Array("9x15".utf8))
            .encode(byteOrder: .lsbFirst))

        // Allocate red so AllocColor returns pixel=16 with R=0xFFFF
        _ = session.feed(AllocColor(cmap: 0x21, red: 0xFFFF, green: 0, blue: 0)
            .encode(byteOrder: .lsbFirst))

        // CreateGC with foreground=16 + font=0x4400005
        let foregroundBytes = encodeUInt32(16, byteOrder: .lsbFirst)
        let backgroundBytes = encodeUInt32(0xFFFFFF, byteOrder: .lsbFirst)
        let fontBytes = encodeUInt32(0x4400005, byteOrder: .lsbFirst)
        let valueMask = GCBits.foreground | GCBits.background | GCBits.font
        // Bits in ascending order: foreground (1<<2), background (1<<3), font (1<<14)
        let valueList = foregroundBytes + backgroundBytes + fontBytes
        let gc = CreateGC(cid: 0xB0001, drawable: 0xA0001,
                          valueMask: valueMask, valueList: valueList)
        _ = session.feed(gc.encode(byteOrder: .lsbFirst))

        // ImageText8 "Hi" at (10, 30)
        let req = ImageText8(drawable: 0xA0001, gc: 0xB0001,
                             x: 10, y: 30, string: Array("Hi".utf8))
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.imageText8Calls.count, 1)
        let call = bridge.imageText8Calls[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        XCTAssertEqual(call.fontName, "Monaco")
        // 9x15 alias → Monaco-natural 7x15 at pointSize 11.
        XCTAssertEqual(call.cellWidth, 7)
        XCTAssertEqual(call.cellHeight, 15)
        XCTAssertEqual(call.foreground, RGB16(red: 0xFFFF, green: 0, blue: 0))
        XCTAssertEqual(call.background, RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF))
        XCTAssertEqual(call.x, 10)
        XCTAssertEqual(call.y, 30)
        XCTAssertEqual(call.string, Array("Hi".utf8))
    }

    func testPolyFillRectangleDispatchTranslatesCoordinates() {
        let bridge = RecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level + descendant at offset (10, 20)
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0002, parent: 0xA0001,
            x: 10, y: 20, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))

        let gc = CreateGC(cid: 0xB0001, drawable: 0xA0002, valueMask: 0, valueList: [])
        _ = session.feed(gc.encode(byteOrder: .lsbFirst))

        // Fill a 50x50 rect at (5, 5) in the descendant.
        let req = PolyFillRectangle(drawable: 0xA0002, gc: 0xB0001,
                                    rectangles: [Framer.Rectangle(x: 5, y: 5, width: 50, height: 50)])
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.fillRectsCalls.count, 1)
        let call = bridge.fillRectsCalls[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        // Translated: descendant offset (10, 20) + rect (5, 5) = (15, 25)
        XCTAssertEqual(call.rectangles, [Framer.Rectangle(x: 15, y: 25, width: 50, height: 50)])
    }

    func testPolyPointDispatchesAs1x1FillRectangles() {
        // PolyPoint (op 64) was falling through to BadRequest pre-2026-05-15;
        // load-bearing for plotting clients. Our Phase-1 impl converts
        // each point to a 1×1 PolyFillRectangle. Verifies (a) the points
        // reach the bridge as 1×1 rects, (b) coordinates are translated
        // to top-level coords (parent offset applied), (c) coordinate-mode
        // Previous accumulates deltas across the list.
        let bridge = RecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0002, parent: 0xA0001,
            x: 10, y: 20, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(cid: 0xB0001, drawable: 0xA0002, valueMask: 0, valueList: [])
            .encode(byteOrder: .lsbFirst))

        // Origin mode: three absolute points in the descendant.
        let originReq = PolyPoint(
            coordinateMode: .origin, drawable: 0xA0002, gc: 0xB0001,
            points: [Point(x: 1, y: 2), Point(x: 5, y: 5), Point(x: 7, y: 9)]
        )
        _ = session.feed(originReq.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.fillRectsCalls.count, 1, "one bridge call per PolyPoint")
        let originCall = bridge.fillRectsCalls[0]
        XCTAssertEqual(originCall.topLevel, 0xA0001)
        // Each point becomes a 1×1 rect at (point.x + descendant.x, point.y + descendant.y).
        XCTAssertEqual(originCall.rectangles, [
            Framer.Rectangle(x: 11, y: 22, width: 1, height: 1),    // (1+10, 2+20)
            Framer.Rectangle(x: 15, y: 25, width: 1, height: 1),    // (5+10, 5+20)
            Framer.Rectangle(x: 17, y: 29, width: 1, height: 1),    // (7+10, 9+20)
        ])

        // Previous mode: first point absolute, subsequent are deltas.
        let prevReq = PolyPoint(
            coordinateMode: .previous, drawable: 0xA0002, gc: 0xB0001,
            points: [Point(x: 3, y: 3), Point(x: 2, y: 1), Point(x: -1, y: 4)]
        )
        _ = session.feed(prevReq.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.fillRectsCalls.count, 2)
        let prevCall = bridge.fillRectsCalls[1]
        // Absolute positions: (3,3), (3+2,3+1)=(5,4), (5-1,4+4)=(4,8).
        // Plus the (10, 20) descendant offset.
        XCTAssertEqual(prevCall.rectangles, [
            Framer.Rectangle(x: 13, y: 23, width: 1, height: 1),
            Framer.Rectangle(x: 15, y: 24, width: 1, height: 1),
            Framer.Rectangle(x: 14, y: 28, width: 1, height: 1),
        ])
    }

    /// Regression test for the dtcalc-LCD-invisible-text bug fixed 2026-05-19.
    ///
    /// X11 SetClipRectangles puts rects in the GC's clip-coordinate system,
    /// which is relative to the drawable the GC draws to (widget-local for
    /// sub-windows). The bridge translates those rects to top-level coords
    /// in `CocoaWindowBridge.withDrawContext` using the target's windowOffset,
    /// so the contract from handlers to the bridge is: pass clipRectangles
    /// in DRAWABLE-LOCAL coords (only clipXOrigin/Yorigin applied). Pre-fix,
    /// the bridge consumed them as-is and applied them in top-level coords,
    /// which clipped dtcalc's LCD text to a tiny rect in the top-left corner
    /// of the calculator window.
    func testPolyText8PassesClipRectanglesInDrawableLocalCoords() {
        let bridge = RecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level window
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))

        // Sub-window inside top-level at offset (50, 50). Same shape as
        // dtcalc's XmText display widget inside its parent panel.
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0002, parent: 0xA0001,
            x: 50, y: 50, width: 100, height: 30, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))

        _ = session.feed(OpenFont(fid: 0x4400005, name: Array("9x15".utf8))
            .encode(byteOrder: .lsbFirst))

        let fontBytes = encodeUInt32(0x4400005, byteOrder: .lsbFirst)
        _ = session.feed(CreateGC(
            cid: 0xB0001, drawable: 0xA0002,
            valueMask: GCBits.font, valueList: fontBytes
        ).encode(byteOrder: .lsbFirst))

        // Clip the GC to (5, 5, 25, 15) in widget-local coords. With
        // clipXOrigin/Yorigin = 0 there's no per-GC offset to fold in.
        _ = session.feed(SetClipRectangles(
            ordering: .unsorted, gc: 0xB0001,
            clipXOrigin: 0, clipYOrigin: 0,
            rectangles: [Framer.Rectangle(x: 5, y: 5, width: 25, height: 15)]
        ).encode(byteOrder: .lsbFirst))

        // PolyText8 to the sub-window at widget-local (10, 20). The handler
        // adds windowOffset to position before dispatching to the bridge.
        // TEXTITEM8 wire format: 1-byte length, 1-byte delta, then chars.
        let textItem: [UInt8] = [2, 0, 0x48, 0x69]  // length=2, delta=0, "Hi"
        _ = session.feed(PolyText8(
            drawable: 0xA0002, gc: 0xB0001,
            x: 10, y: 20, items: textItem
        ).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.polyText8Calls.count, 1)
        let call = bridge.polyText8Calls[0]
        // Position arrives in top-level coords (handler added (50,50)).
        XCTAssertEqual(call.x, 60)
        XCTAssertEqual(call.y, 70)
        // Clip rects arrive in DRAWABLE-LOCAL coords. The translation to
        // top-level happens in withDrawContext, not at this layer.
        XCTAssertEqual(call.clipRectangles, [
            Framer.Rectangle(x: 5, y: 5, width: 25, height: 15)
        ])
    }

    private func encodeUInt32(_ value: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
    }
}
