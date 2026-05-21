import XCTest
import Framer
@testable import SwiftXServerCore

/// Regression for the "quickplot frame disappears after resize" bug.
/// Sequence: SetClipRectangles populates `entry.clipRectangles`; the
/// client later issues `XSetClipMask(gc, None)` (ChangeGC with the
/// clipMask bit set to 0) to reset the clip; we must clear the rect
/// list, not just store 0 in the values dict.
final class GCClipMaskResetTests: XCTestCase {

    func testChangeGCWithClipMaskClearsRectList() {
        let table = GCTable()
        table.insert(id: 0x100, drawable: 0x200, valueMask: 0, valueList: [], byteOrder: .lsbFirst)

        // SetClipRectangles installs a rect list.
        table.setClip(0x100,
                      rectangles: [Rectangle(x: 10, y: 20, width: 30, height: 40)],
                      xOrigin: 0, yOrigin: 0)
        XCTAssertEqual(table.get(0x100)?.clipRectangles?.count, 1,
                       "SetClipRectangles populates the rect list")

        // XSetClipMask(gc, None) → ChangeGC with clipMask bit, value=0.
        // Value list is one CARD32 per set bit.
        table.change(0x100,
                     valueMask: GCBits.clipMask,
                     valueList: [0, 0, 0, 0],
                     byteOrder: .lsbFirst)
        XCTAssertNil(table.get(0x100)?.clipRectangles,
                     "ChangeGC touching clipMask must clear any rect list set by SetClipRectangles")
    }

    func testChangeGCWithoutClipMaskLeavesRectListAlone() {
        let table = GCTable()
        table.insert(id: 0x100, drawable: 0x200, valueMask: 0, valueList: [], byteOrder: .lsbFirst)

        table.setClip(0x100,
                      rectangles: [Rectangle(x: 5, y: 5, width: 50, height: 50)],
                      xOrigin: 0, yOrigin: 0)

        // ChangeGC for foreground only — must not touch the rect list.
        table.change(0x100,
                     valueMask: GCBits.foreground,
                     valueList: [0xAB, 0, 0, 0],
                     byteOrder: .lsbFirst)
        XCTAssertEqual(table.get(0x100)?.clipRectangles?.count, 1,
                       "Unrelated ChangeGC must preserve the rect list")
        XCTAssertEqual(table.get(0x100)?.values[GCBits.foreground], 0xAB)
    }

    func testMaterialiseAfterClipMaskResetHasNoClipRectangles() {
        // End-to-end against GCState.materialise (what the renderer actually
        // reads): after ChangeGC(clipMask=None), the resolved GCState must
        // report nil clipRectangles so the bridge skips the clip step.
        let table = GCTable()
        table.insert(id: 0x100, drawable: 0x200, valueMask: 0, valueList: [], byteOrder: .lsbFirst)
        table.setClip(0x100,
                      rectangles: [Rectangle(x: 0, y: 0, width: 10, height: 10)],
                      xOrigin: 0, yOrigin: 0)
        table.change(0x100,
                     valueMask: GCBits.clipMask,
                     valueList: [0, 0, 0, 0],
                     byteOrder: .lsbFirst)
        let state = GCState.materialise(from: table.get(0x100)!, byteOrder: .lsbFirst)
        XCTAssertNil(state.clipRectangles)
    }
}
