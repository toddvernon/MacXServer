import XCTest
import Framer
@testable import SwiftXCaptureCore

final class LandmarkDetectorTests: XCTestCase {

    // Build a minimal CreateWindow for landmark testing. Only the fields
    // the detector reads matter; defaults are filler.
    private func cw(wid: UInt32, parent: UInt32, w: UInt16 = 100, h: UInt16 = 50) -> CreateWindow {
        return CreateWindow(
            depth: 24, wid: wid, parent: parent,
            x: 0, y: 0, width: w, height: h, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        )
    }

    private func mw(_ window: UInt32) -> MapWindow {
        MapWindow(window: window)
    }

    // ChangeProperty WM_NAME shaped as Athena/Motif would write it.
    private func setWMName(_ window: UInt32, _ name: String) -> ChangeProperty {
        ChangeProperty(
            mode: .replace, window: window,
            property: 39 /* WM_NAME */, type: 31 /* STRING */,
            format: .format8, data: Array(name.utf8)
        )
    }

    private func setTransientFor(_ window: UInt32, parent: UInt32, byteOrder: ByteOrder = .lsbFirst) -> ChangeProperty {
        // 32-bit WINDOW id encoded LE
        var data = [UInt8](repeating: 0, count: 4)
        switch byteOrder {
        case .lsbFirst:
            data[0] = UInt8(parent & 0xFF)
            data[1] = UInt8((parent >> 8) & 0xFF)
            data[2] = UInt8((parent >> 16) & 0xFF)
            data[3] = UInt8((parent >> 24) & 0xFF)
        case .msbFirst:
            data[3] = UInt8(parent & 0xFF)
            data[2] = UInt8((parent >> 8) & 0xFF)
            data[1] = UInt8((parent >> 16) & 0xFF)
            data[0] = UInt8((parent >> 24) & 0xFF)
        }
        return ChangeProperty(
            mode: .replace, window: window,
            property: 68 /* WM_TRANSIENT_FOR */, type: 33 /* WINDOW */,
            format: .format32, data: data
        )
    }

    // Build a ButtonPress / ButtonRelease event for landmark testing.
    private func buttonEvent(code: UInt8, window: UInt32, button: UInt8, time: UInt32,
                             x: Int16 = 10, y: Int16 = 20) -> ServerMessage {
        let ie = InputEvent(
            detail: button, sequenceNumber: 1, time: time,
            root: 0x2B, event: window, child: 0,
            rootX: x, rootY: y, eventX: x, eventY: y,
            state: 0, sameScreen: true
        )
        return .event(Event(bytes: ie.encode(code: code, byteOrder: .lsbFirst)))
    }

    func testFirstUnnamedTopLevelReadsAsTopLevelAppearing() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B, w: 500, h: 600)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# A top-level window appears on screen (0x4400001, 500×600)")
    }

    func testNamedFirstTopLevelReadsAsTheNamedWindowAppearing() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B, w: 500, h: 600)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# The \"editres\" window appears on screen (0x4400001, 500×600)")
    }

    func testSecondTopLevelReadsAsAnotherTopLevel() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B, w: 500, h: 600)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400029, parent: 0x2B, w: 200, h: 100)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.mapWindow(mw(0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400029)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# Another top-level window appears on screen (0x4400029, 200×100)")
    }

    func testNonTopLevelMapEmitsNoLandmark() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        // parent != root
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400002, parent: 0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400002)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 0)
    }

    func testRepeatedMapDoesNotDoubleEmit() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let first = d.afterRequest(.mapWindow(mw(0x4400001)),
                                    byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let second = d.afterRequest(.mapWindow(mw(0x4400001)),
                                     byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0)
    }

    func testWMNameOnFirstTopLevelReadsAsFirstWindowIdentifies() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# The first top-level window identifies as \"editres\"")
    }

    func testWMNameOnLaterTopLevelReadsAsNamedWindowIdentifies() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        // Identify a primary first so subsequent identifies don't say "first."
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // Now identify a second top-level
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400029, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400029, "Help")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# Window 0x4400029 identifies as \"Help\"")
    }

    // Regression: Motif apps like xmeditor commonly set WM_NAME on every
    // top-level popup/dialog window at startup, BEFORE mapping any of
    // them. Earlier the "first top-level" gate was tied to MapWindow, so
    // every WM_NAME landmark before the first map said "first." Each
    // identify after the first should say "Window 0x... identifies as ..."
    // regardless of whether any window has been mapped yet.
    func testMultipleIdentifiesBeforeAnyMapOnlyFirstSaysFirst() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400002, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400003, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let l1 = d.afterRequest(.changeProperty(setWMName(0x4400001, "xmeditor")),
                                 byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let l2 = d.afterRequest(.changeProperty(setWMName(0x4400002, "Open File")),
                                 byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let l3 = d.afterRequest(.changeProperty(setWMName(0x4400003, "Save Warning")),
                                 byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(l1.first?.text, "# The first top-level window identifies as \"xmeditor\"")
        XCTAssertEqual(l2.first?.text, "# Window 0x4400002 identifies as \"Open File\"")
        XCTAssertEqual(l3.first?.text, "# Window 0x4400003 identifies as \"Save Warning\"")
    }

    func testWMNameOnNonTopLevelEmitsNothing() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        // window never registered as top-level
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400002, "child")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 0)
    }

    func testTransientForTriggersDialogLandmarkOnMap() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.mapWindow(mw(0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // Dialog window created with parent == root
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400029, parent: 0x2B, w: 200, h: 100)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setTransientFor(0x4400029, parent: 0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400029)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // Two landmarks now expected: another-top-level appearance + dialog
        XCTAssertEqual(lms.count, 2)
        XCTAssertTrue(lms.contains { $0.text.contains("Another top-level window appears") })
        XCTAssertTrue(lms.contains {
            $0.text == "# A dialog opens above \"editres\" (0x4400029, 200×100)"
        })
    }

    func testClickLandmarkOnMatchedPressReadsAsUserClicks() {
        var d = LandmarkDetector()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400023, button: 1, time: 1000, x: 55, y: 8),
                                  byteOrder: .lsbFirst)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400023, button: 1, time: 1100, x: 55, y: 8),
                                        byteOrder: .lsbFirst)
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks at (55,8) on window 0x4400023")
    }

    func testClickLandmarkButtonThreeReadsAsButton3() {
        var d = LandmarkDetector()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400023, button: 3, time: 1000),
                                  byteOrder: .lsbFirst)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400023, button: 3, time: 1100),
                                        byteOrder: .lsbFirst)
        XCTAssertEqual(lms.count, 1)
        XCTAssertTrue(lms.first?.text.contains("clicks button 3") ?? false)
    }

    func testClickThresholdRejectsLatePairs() {
        var d = LandmarkDetector()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400023, button: 1, time: 1000),
                                  byteOrder: .lsbFirst)
        // Release at t=2000 — 1000ms gap, beyond 500ms threshold
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400023, button: 1, time: 2000),
                                        byteOrder: .lsbFirst)
        XCTAssertEqual(lms.count, 0)
    }

    func testMismatchedButtonNumbersDontCount() {
        var d = LandmarkDetector()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400023, button: 1, time: 1000),
                                  byteOrder: .lsbFirst)
        // Release with a different button — no match
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400023, button: 2, time: 1100),
                                        byteOrder: .lsbFirst)
        XCTAssertEqual(lms.count, 0)
    }
}
