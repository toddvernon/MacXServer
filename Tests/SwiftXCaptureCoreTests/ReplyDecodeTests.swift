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
