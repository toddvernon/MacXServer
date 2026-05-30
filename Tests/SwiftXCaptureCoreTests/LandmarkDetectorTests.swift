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

    private func uw(_ window: UInt32) -> UnmapWindow {
        UnmapWindow(window: window)
    }

    private func dw(_ window: UInt32) -> DestroyWindow {
        DestroyWindow(window: window)
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

    func testWMNameOnFirstTopLevelReadsAsClientCreatesFirstWindow() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# The client creates its first top-level window " +
                       "(\"editres\", 100×50, 0x4400001). Not yet visible on screen.")
    }

    func testWMNameOnLaterTopLevelReadsAsAnotherWindowCreated() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400029, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400029, "Help")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# Another top-level window is created " +
                       "(\"Help\", 100×50, 0x4400029). Not yet visible on screen.")
    }

    func testEmptyWMNameSurfacedAsNoNameSet() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4600001, parent: 0x2B, w: 1, h: 1)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4600001, "")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# The client creates its first top-level window " +
                       "(no name set, 1×1, 0x4600001). Not yet visible on screen.")
    }

    func testWMNameAfterMapReadsAsRename() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.mapWindow(mw(0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertEqual(lms.first?.text,
                       "# Window 0x4400001 is renamed to \"editres\"")
    }

    // Regression: Motif apps like xmeditor commonly set WM_NAME on every
    // top-level popup/dialog window at startup, BEFORE mapping any of
    // them. Earlier the "first top-level" gate was tied to MapWindow, so
    // every WM_NAME landmark before the first map said "first." Each
    // identify after the first should narrate as "Another top-level
    // window is created ..." regardless of whether any has been mapped.
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
        XCTAssertTrue(l1.first?.text.hasPrefix("# The client creates its first top-level window") ?? false)
        XCTAssertTrue(l1.first?.text.contains("\"xmeditor\"") ?? false)
        XCTAssertTrue(l2.first?.text.hasPrefix("# Another top-level window is created") ?? false)
        XCTAssertTrue(l2.first?.text.contains("\"Open File\"") ?? false)
        XCTAssertTrue(l3.first?.text.hasPrefix("# Another top-level window is created") ?? false)
        XCTAssertTrue(l3.first?.text.contains("\"Save Warning\"") ?? false)
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

    // MARK: - Click landmarks (hierarchy + naming)

    private func clickOnNamedSetup() -> (LandmarkDetector, Set<UInt32>) {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B, w: 500, h: 600)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400001, "Command Window")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        return (d, roots)
    }

    func testClickDirectlyOnNamedTopLevel() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 1, time: 1000, x: 50, y: 50),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 1, time: 1100, x: 50, y: 50),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks on \"Command Window\" at (50,50)")
    }

    func testClickOnChildOfNamedTopLevel() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400074, parent: 0x4400001, w: 60, h: 26)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400074, button: 1, time: 1000, x: 26, y: 21),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400074, button: 1, time: 1100, x: 26, y: 21),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks inside \"Command Window\" on a 60×26 child 0x4400074 at (26,21)")
    }

    func testClickOnDeeplyNestedChildWalksToTopLevel() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400010, parent: 0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400020, parent: 0x4400010, w: 46, h: 18)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400020, button: 1, time: 1000, x: 13, y: 12),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400020, button: 1, time: 1100, x: 13, y: 12),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks inside \"Command Window\" on a 46×18 child 0x4400020 at (13,12)")
    }

    func testClickOnRootReadsAsClickOnDesktop() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x2B, button: 1, time: 1000, x: 100, y: 100),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x2B, button: 1, time: 1100, x: 100, y: 100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text, "# The user clicks on the desktop at (100,100)")
    }

    func testClickOnUnknownWindowEmitsNothing() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        // Click on a window we never saw a CreateWindow for — namability
        // rule says skip rather than emit a bare hex id.
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x99999, button: 1, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x99999, button: 1, time: 1100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.count, 0)
    }

    func testClickInsideUnnamedTopLevelStillEmits() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        // Top-level created but WM_NAME never set
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B, w: 16, h: 16)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400025, parent: 0x4400001, w: 16, h: 16)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400025, button: 1, time: 1000, x: 5, y: 5),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400025, button: 1, time: 1100, x: 5, y: 5),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks inside an unnamed top-level on a 16×16 child 0x4400025 at (5,5)")
    }

    func testClickButtonThreeReadsAsButton3() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 3, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 3, time: 1100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertTrue(lms.first?.text.contains("clicks button 3") ?? false)
    }

    func testClickThresholdRejectsLatePairs() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 1, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 1, time: 2000),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.count, 0)
    }

    func testMismatchedButtonNumbersDontCount() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 1, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 2, time: 1100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.count, 0)
    }

    // MARK: - Hide / close / dialog-dismissed landmarks

    private func mapped(_ d: inout LandmarkDetector, wid: UInt32, name: String?,
                        roots: Set<UInt32>) {
        _ = d.afterRequest(.createWindow(cw(wid: wid, parent: 0x2B, w: 500, h: 600)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        if let n = name {
            _ = d.afterRequest(.changeProperty(setWMName(wid, n)),
                               byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        }
        _ = d.afterRequest(.mapWindow(mw(wid)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
    }

    func testUnmapNamedTopLevelReadsAsHidden() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Coordinates", roots: roots)
        let lms = d.afterRequest(.unmapWindow(uw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.first?.text, "# The \"Coordinates\" window was hidden")
    }

    func testUnmapUnnamedTopLevelReadsAsUnnamed() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: nil, roots: roots)
        let lms = d.afterRequest(.unmapWindow(uw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.first?.text,
                       "# An unnamed top-level was hidden (0x4400001, 500×600)")
    }

    func testUnmapEmptyNamedTopLevelReadsAsUnnamed() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "", roots: roots)
        let lms = d.afterRequest(.unmapWindow(uw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.first?.text,
                       "# An unnamed top-level was hidden (0x4400001, 500×600)")
    }

    func testUnmapTransientReadsAsDialogDismissed() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Command Window", roots: roots)
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400029, parent: 0x2B, w: 200, h: 100)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400029, "Save Confirm")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setTransientFor(0x4400029, parent: 0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.mapWindow(mw(0x4400029)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.unmapWindow(uw(0x4400029)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.first?.text,
                       "# The \"Save Confirm\" dialog above \"Command Window\" was dismissed")
    }

    func testDestroyTopLevelReadsAsClosed() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Help Window", roots: roots)
        let lms = d.afterRequest(.destroyWindow(dw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.first?.text, "# The \"Help Window\" window was closed")
    }

    func testDestroyAfterUnmapDoesNotRepeatLandmark() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Find Dialog", roots: roots)
        let hide = d.afterRequest(.unmapWindow(uw(0x4400001)),
                                   byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let close = d.afterRequest(.destroyWindow(dw(0x4400001)),
                                    byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(hide.count, 1)
        XCTAssertEqual(close.count, 0)
    }

    func testUnmapNonTopLevelEmitsNothing() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Parent", roots: roots)
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400002, parent: 0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.mapWindow(mw(0x4400002)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.unmapWindow(uw(0x4400002)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 0)
    }

    func testUnmapNeverMappedWindowEmitsNothing() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x4400001, "Never Shown")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.unmapWindow(uw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 0)
    }

    func testRemapAfterHideEmitsFreshAppearance() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Coordinates", roots: roots)
        _ = d.afterRequest(.unmapWindow(uw(0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // After hide, a re-map produces a fresh appearance landmark so
        // the reader can follow hide/reshow as a sequence.
        XCTAssertTrue(lms.contains { $0.text.contains("appears on screen") })
    }
}
