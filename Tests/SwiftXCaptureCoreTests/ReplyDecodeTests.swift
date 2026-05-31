import XCTest
@testable import SwiftXCaptureCore
import Framer

// Reply-body decode coverage. The ChronoDumper formats every reply through
// the seq-keyed `formatServerMessage` path; this suite builds raw reply
// bytes via the Framer reply structs' encoders, runs them through that path,
// and asserts on the rendered detail field. Covers the 10 reply decoders
// added 2026-05-31 alongside the 7 that were already in place.

final class ReplyDecodeTests: XCTestCase {

    /// Render a reply via the same path the dumper uses end-to-end. We
    /// install `op` into ctx.seqToOpcode for the requested sequence, then
    /// call formatServerMessage. The returned string is the formatted line;
    /// we slice off the leading `[seq=NNN] Reply (NAME)` prefix and return
    /// the trailing detail for easier assertions.
    private func render(_ bytes: [UInt8], opcode: UInt8,
                         byteOrder: ByteOrder = .msbFirst,
                         ctxBuilder: (inout ChronoContext) -> Void = { _ in })
                         -> String {
        var ctx = ChronoContext()
        let seq: UInt16 = 7
        ctx.seqToOpcode[seq] = opcode
        ctxBuilder(&ctx)
        let reply = Reply(bytes: bytes)
        let line = formatServerMessage(.reply(reply), byteOrder: byteOrder, ctx: &ctx)
        return line
    }

    // MARK: - GetInputFocus (op 43)

    func testGetInputFocusFocusedWindow() {
        let bytes = GetInputFocusReply(sequenceNumber: 7, revertTo: .parent, focus: 0x140000E)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetInputFocus.opcode)
        XCTAssertTrue(s.contains("focus=0x140000E revertTo=parent"), s)
    }

    func testGetInputFocusPointerRootAndNone() {
        let pr = GetInputFocusReply(sequenceNumber: 7, revertTo: .none, focus: 1)
            .encode(byteOrder: .msbFirst)
        XCTAssertTrue(render(pr, opcode: GetInputFocus.opcode).contains("focus=PointerRoot"))
        let nf = GetInputFocusReply(sequenceNumber: 7, revertTo: .none, focus: 0)
            .encode(byteOrder: .msbFirst)
        XCTAssertTrue(render(nf, opcode: GetInputFocus.opcode).contains("focus=None"))
    }

    // MARK: - GetAtomName (op 17)

    func testGetAtomNameResolvesAndPopulatesContext() {
        let bytes = GetAtomNameReply(sequenceNumber: 7, name: Array("WM_DELETE_WINDOW".utf8))
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetAtomName.opcode) { ctx in
            ctx.seqToGetAtomName[7] = 0x199
        }
        XCTAssertTrue(s.contains("atom=0x199 → name=\"WM_DELETE_WINDOW\""), s)
    }

    // MARK: - GetGeometry (op 14)

    func testGetGeometryAllFields() {
        let bytes = GetGeometryReply(sequenceNumber: 7, depth: 8, root: 0x2B,
                                      x: 10, y: 20, width: 484, height: 316,
                                      borderWidth: 2).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetGeometry.opcode)
        XCTAssertTrue(s.contains("root=0x2B at (10,20) 484x316 border=2 depth=8"), s)
    }

    // MARK: - QueryTree (op 15)

    func testQueryTreeWithChildren() {
        let bytes = QueryTreeReply(sequenceNumber: 7, root: 0x2B, parent: 0x100,
                                    children: [0x200, 0x201, 0x202])
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryTree.opcode)
        XCTAssertTrue(s.contains("root=0x2B parent=0x100 children=[0x200,0x201,0x202]"), s)
    }

    func testQueryTreeRootHasNoneParent() {
        let bytes = QueryTreeReply(sequenceNumber: 7, root: 0x2B, parent: 0,
                                    children: []).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryTree.opcode)
        XCTAssertTrue(s.contains("parent=None"), s)
        XCTAssertTrue(s.contains("children=[]"), s)
    }

    func testQueryTreeTruncatesLargeChildList() {
        let bytes = QueryTreeReply(sequenceNumber: 7, root: 0x2B, parent: 0x100,
                                    children: (1...12).map(UInt32.init))
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryTree.opcode)
        XCTAssertTrue(s.contains("…(+4)"), s)
    }

    // MARK: - GetWindowAttributes (op 3)

    func testGetWindowAttributesInputOutput() {
        let bytes = makeGetWindowAttributesReply(visualId: 0x22, classCode: 1,
                                                  mapState: 2, overrideRedirect: true)
        let s = render(bytes, opcode: GetWindowAttributes.opcode) { ctx in
            ctx.visualCatalog[0x22] = VisualCatalogEntry(
                depth: 8, visualClass: .pseudoColor, bitsPerRgbValue: 8, screenIndex: 0)
        }
        XCTAssertTrue(s.contains("InputOutput visual=0x22(PseudoColor d8) mapState=Viewable override=true"), s)
    }

    // MARK: - QueryColors (op 91)

    func testQueryColorsTriples() {
        let bytes = QueryColorsReply(sequenceNumber: 7, colors: [
            QueryColorsRGB(red: 0x0000, green: 0x0000, blue: 0x0000),
            QueryColorsRGB(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF),
        ]).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryColors.opcode)
        XCTAssertTrue(s.contains("rgb=[(0,0,0),(255,255,255)]"), s)
    }

    // MARK: - GetModifierMapping (op 119)

    func testGetModifierMapping() {
        // 2 keycodes per modifier, only Shift + Ctrl mapped.
        let kpm: UInt8 = 2
        var keycodes: [UInt8] = [50, 62]      // Shift
        keycodes += [0, 0]                    // Lock (empty)
        keycodes += [37, 0]                   // Ctrl (one keycode)
        keycodes += [0, 0]                    // Mod1
        keycodes += [0, 0]                    // Mod2
        keycodes += [0, 0]                    // Mod3
        keycodes += [0, 0]                    // Mod4
        keycodes += [0, 0]                    // Mod5
        let bytes = GetModifierMappingReply(sequenceNumber: 7,
                                             keycodesPerModifier: kpm,
                                             keycodes: keycodes).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetModifierMapping.opcode)
        XCTAssertTrue(s.contains("Shift=[50,62] Ctrl=[37]"), s)
        XCTAssertFalse(s.contains("Lock="), s) // empty slot suppressed
    }

    // MARK: - GrabPointer / GrabKeyboard (ops 26 / 31)

    func testGrabPointerStatus() {
        let bytes = GrabReply(sequenceNumber: 7, status: .success).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GrabPointer.opcode)
        XCTAssertTrue(s.contains("status=success"), s)
    }

    func testGrabKeyboardFrozen() {
        let bytes = GrabReply(sequenceNumber: 7, status: .frozen).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GrabKeyboard.opcode)
        XCTAssertTrue(s.contains("status=frozen"), s)
    }

    // MARK: - GetSelectionOwner (op 23)

    func testGetSelectionOwnerOwner() {
        let bytes = GetSelectionOwnerReply(sequenceNumber: 7, owner: 0x2800029)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetSelectionOwner.opcode)
        XCTAssertTrue(s.contains("owner=0x2800029"), s)
    }

    func testGetSelectionOwnerNone() {
        let bytes = GetSelectionOwnerReply(sequenceNumber: 7, owner: 0)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetSelectionOwner.opcode)
        XCTAssertTrue(s.contains("owner=None"), s)
    }

    // MARK: - QueryPointer (op 38)

    func testQueryPointerFull() {
        let bytes = QueryPointerReply(sequenceNumber: 7, sameScreen: true,
                                       root: 0x2B, child: 0x100,
                                       rootX: 200, rootY: 150,
                                       winX: 50, winY: 25,
                                       mask: 0x0104).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryPointer.opcode)
        XCTAssertTrue(s.contains("root=0x2B rootAt=(200,150) winAt=(50,25) child=0x100 buttons=Ctrl|Button1 sameScreen=true"), s)
    }

    // MARK: - TranslateCoordinates (op 40)

    func testTranslateCoordinates() {
        let bytes = TranslateCoordinatesReply(sequenceNumber: 7, sameScreen: true,
                                               child: 0x100051F,
                                               dstX: 621, dstY: 299).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: TranslateCoordinates.opcode)
        XCTAssertTrue(s.contains("dst=(621,299) child=0x100051F sameScreen=true"), s)
    }

    // MARK: - QueryBestSize (op 97)

    func testQueryBestSize() {
        let bytes = QueryBestSizeReply(sequenceNumber: 7, width: 32, height: 32)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryBestSize.opcode)
        XCTAssertTrue(s.contains("best=32x32"), s)
    }

    // MARK: - ListProperties (op 21)

    func testListProperties() {
        let bytes = ListPropertiesReply(sequenceNumber: 7, atoms: [39, 35, 0x84]).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListProperties.opcode) { ctx in
            ctx.atomToName[0x84] = "_NET_WM_STATE"
        }
        // 39 = WM_NAME (predefined), 35 = WM_HINTS (predefined), 0x84 = interned.
        XCTAssertTrue(s.contains("atoms=[WM_NAME,WM_HINTS,_NET_WM_STATE]"), s)
    }

    // MARK: - ListFonts (op 49)

    func testListFontsTruncation() {
        let names = (0..<10).map { Array("font\($0)".utf8) }
        let bytes = ListFontsReply(sequenceNumber: 7, names: names).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListFonts.opcode)
        XCTAssertTrue(s.contains("count=10 names=[\"font0\",\"font1\",\"font2\",\"font3\",…(+6)]"), s)
    }

    // MARK: - ListFontsWithInfo (op 50)

    func testListFontsWithInfoEntry() {
        let zeroCI = CharInfo(leftSideBearing: 0, rightSideBearing: 0,
                              characterWidth: 0, ascent: 0, descent: 0, attributes: 0)
        let entry = ListFontsWithInfoReply(
            sequenceNumber: 7,
            name: Array("fixed".utf8),
            minBounds: zeroCI, maxBounds: zeroCI,
            minCharOrByte2: 0, maxCharOrByte2: 0, defaultChar: 0,
            drawDirection: .leftToRight, minByte1: 0, maxByte1: 0,
            allCharsExist: false, fontAscent: 10, fontDescent: 3,
            repliesHint: 1, properties: [])
        let bytes = entry.encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListFontsWithInfo.opcode)
        XCTAssertTrue(s.contains("name=\"fixed\" ascent/descent=10/3"), s)
    }

    func testListFontsWithInfoTerminator() {
        let zeroCI = CharInfo(leftSideBearing: 0, rightSideBearing: 0,
                              characterWidth: 0, ascent: 0, descent: 0, attributes: 0)
        let term = ListFontsWithInfoReply(
            sequenceNumber: 7, name: [],
            minBounds: zeroCI, maxBounds: zeroCI,
            minCharOrByte2: 0, maxCharOrByte2: 0, defaultChar: 0,
            drawDirection: .leftToRight, minByte1: 0, maxByte1: 0,
            allCharsExist: false, fontAscent: 0, fontDescent: 0,
            repliesHint: 0, properties: [])
        let bytes = term.encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListFontsWithInfo.opcode)
        XCTAssertTrue(s.contains("(end of list)"), s)
    }

    // MARK: - GetFontPath (op 52)

    func testGetFontPath() {
        let bytes = GetFontPathReply(sequenceNumber: 7, path: ["/usr/X11/fonts/75dpi", "/usr/X11/fonts/100dpi"])
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetFontPath.opcode)
        XCTAssertTrue(s.contains("path=[\"/usr/X11/fonts/75dpi\",\"/usr/X11/fonts/100dpi\"]"), s)
    }

    // MARK: - ListExtensions (op 99)

    func testListExtensions() {
        let names = [Array("SHAPE".utf8), Array("RENDER".utf8), Array("MIT-SHM".utf8)]
        let bytes = ListExtensionsReply(sequenceNumber: 7, names: names).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListExtensions.opcode)
        XCTAssertTrue(s.contains("count=3 names=[SHAPE,RENDER,MIT-SHM]"), s)
    }

    // MARK: - ListInstalledColormaps (op 83)

    func testListInstalledColormaps() {
        let bytes = ListInstalledColormapsReply(sequenceNumber: 7, colormaps: [0x20, 0x21])
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListInstalledColormaps.opcode)
        XCTAssertTrue(s.contains("colormaps=[0x20,0x21]"), s)
    }

    // MARK: - ListHosts (op 110)

    func testListHostsEmptyAndDisabled() {
        let bytes = ListHostsReply(sequenceNumber: 7, enabled: false, hosts: [])
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: ListHosts.opcode)
        XCTAssertTrue(s.contains("enabled=false hosts=0"), s)
    }

    // MARK: - GetImage (op 73)

    func testGetImage() {
        let bytes = GetImageReply(sequenceNumber: 7, depth: 8, visual: 0x22,
                                   imageData: Array(repeating: 0, count: 4096))
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetImage.opcode) { ctx in
            ctx.visualCatalog[0x22] = VisualCatalogEntry(
                depth: 8, visualClass: .pseudoColor, bitsPerRgbValue: 8, screenIndex: 0)
        }
        XCTAssertTrue(s.contains("depth=8 visual=0x22(PseudoColor d8) bytes=4096"), s)
    }

    // MARK: - GetKeyboardControl (op 103)

    func testGetKeyboardControl() {
        let bytes = GetKeyboardControlReply(
            sequenceNumber: 7, globalAutoRepeat: true, ledMask: 0,
            keyClickPercent: 0, bellPercent: 50, bellPitch: 400, bellDuration: 100,
            autoRepeats: Array(repeating: 0, count: 32)).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetKeyboardControl.opcode)
        XCTAssertTrue(s.contains("autoRepeat=true ledMask=0x0 keyClick=0% bell=50%@400Hz/100ms"), s)
    }

    // MARK: - GetPointerControl (op 105)

    func testGetPointerControl() {
        let bytes = GetPointerControlReply(sequenceNumber: 7, accelerationNumerator: 2,
                                            accelerationDenominator: 1, threshold: 4)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetPointerControl.opcode)
        XCTAssertTrue(s.contains("accel=2/1 threshold=4"), s)
    }

    // MARK: - GetPointerMapping (op 116)

    func testGetPointerMapping() {
        let bytes = GetPointerMappingReply(sequenceNumber: 7, map: [1, 2, 3])
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetPointerMapping.opcode)
        XCTAssertTrue(s.contains("map=[1,2,3]"), s)
    }

    // MARK: - GetScreenSaver (op 108)

    func testGetScreenSaver() {
        let bytes = GetScreenSaverReply(sequenceNumber: 7, timeout: 600, interval: 600,
                                         preferBlanking: 1, allowExposures: 0)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: GetScreenSaver.opcode)
        XCTAssertTrue(s.contains("timeout=600s interval=600s preferBlanking=1 allowExposures=0"), s)
    }

    // MARK: - QueryKeymap (op 44)

    func testQueryKeymap() {
        // 32-byte bitmap: 0xFF in slots 5 and 6 = 16 bits set.
        var keys = Array<UInt8>(repeating: 0, count: 32)
        keys[5] = 0xFF
        keys[6] = 0xFF
        let bytes = QueryKeymapReply(sequenceNumber: 7, keys: keys).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryKeymap.opcode)
        XCTAssertTrue(s.contains("keysDown=16"), s)
    }

    // MARK: - QueryTextExtents (op 48)

    func testQueryTextExtents() {
        let bytes = QueryTextExtentsReply(sequenceNumber: 7, drawDirection: 0,
                                           fontAscent: 12, fontDescent: 3,
                                           overallAscent: 12, overallDescent: 3,
                                           overallWidth: 84, overallLeft: 0, overallRight: 84)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: QueryTextExtents.opcode)
        XCTAssertTrue(s.contains("width=84 ascent/descent=12/3 dir=LtoR"), s)
    }

    // MARK: - LookupColor (op 92)

    func testLookupColor() {
        let bytes = LookupColorReply(sequenceNumber: 7,
                                      exactRed: 0x0000, exactGreen: 0xFFFF, exactBlue: 0xFFFF,
                                      visualRed: 0x0000, visualGreen: 0xFFFF, visualBlue: 0xFFFF)
            .encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: LookupColor.opcode)
        XCTAssertTrue(s.contains("exact=(0,255,255) visual=(0,255,255)"), s)
    }

    // MARK: - SetModifierMapping / SetPointerMapping (ops 118 / 117)

    func testSetMappingSuccess() {
        let bytes = SetMappingReply(sequenceNumber: 7, status: 0).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: SetModifierMapping.opcode)
        XCTAssertTrue(s.contains("status=Success"), s)
    }

    func testSetMappingBusy() {
        let bytes = SetMappingReply(sequenceNumber: 7, status: 1).encode(byteOrder: .msbFirst)
        let s = render(bytes, opcode: SetPointerMapping.opcode)
        XCTAssertTrue(s.contains("status=Busy"), s)
    }

    // MARK: - Helpers

    /// Hand-rolled encoder for GetWindowAttributesReply because the existing
    /// init takes ~14 parameters and most don't matter for the dumper's
    /// rendering. Build the 44-byte wire form directly.
    private func makeGetWindowAttributesReply(visualId: UInt32, classCode: UInt16,
                                                mapState: UInt8, overrideRedirect: Bool) -> [UInt8] {
        // Use the framer's encoder via a fully-specified init.
        return GetWindowAttributesReply(
            sequenceNumber: 7, backingStore: 0, visualId: visualId,
            windowClass: classCode, bitGravity: 1, winGravity: 1,
            backingBitPlanes: 0, backingPixel: 0, saveUnder: false,
            mapInstalled: true, mapState: mapState, overrideRedirect: overrideRedirect,
            colormap: 0x20, allEventMasks: 0x42850D, yourEventMask: 0,
            doNotPropagateMask: 0).encode(byteOrder: .msbFirst)
    }
}
