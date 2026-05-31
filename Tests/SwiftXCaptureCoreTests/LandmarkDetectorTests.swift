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
                             x: Int16 = 10, y: Int16 = 20, state: UInt16 = 0) -> ServerMessage {
        let ie = InputEvent(
            detail: button, sequenceNumber: 1, time: time,
            root: 0x2B, event: window, child: 0,
            rootX: x, rootY: y, eventX: x, eventY: y,
            state: state, sameScreen: true
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

    // MARK: - Error correlation

    private func errorMsg(code: XErrorCode, seq: UInt16, badId: UInt32 = 0,
                          majorOpcode: UInt8, minorOpcode: UInt16 = 0) -> ServerMessage {
        .xError(XError(bytes: XError.encode(
            code: code, sequenceNumber: seq,
            badResourceId: badId, minorOpcode: minorOpcode,
            majorOpcode: majorOpcode, byteOrder: .lsbFirst
        )))
    }

    func testBadWindowErrorIncludesNamedWindow() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        mapped(&d, wid: 0x4400001, name: "Coordinates", roots: roots)
        let lms = d.afterServerMessage(
            errorMsg(code: .window, seq: 42, badId: 0x4400001, majorOpcode: 8 /* MapWindow */),
            byteOrder: .lsbFirst, screenRoots: roots
        )
        XCTAssertEqual(lms.first?.text,
                       "# BadWindow at seq=42 from MapWindow on \"Coordinates\"")
    }

    func testBadWindowErrorOnUnknownResourceQuotesId() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        let lms = d.afterServerMessage(
            errorMsg(code: .window, seq: 100, badId: 0xFFFE0001, majorOpcode: 2 /* ChangeWindowAttributes */),
            byteOrder: .lsbFirst, screenRoots: roots
        )
        XCTAssertEqual(lms.first?.text,
                       "# BadWindow at seq=100 from ChangeWindowAttributes (bad resource 0xFFFE0001)")
    }

    func testBadValueErrorRendersBadValue() {
        var d = LandmarkDetector()
        let lms = d.afterServerMessage(
            errorMsg(code: .value, seq: 17, badId: 0x99, majorOpcode: 55 /* CreateGC */),
            byteOrder: .lsbFirst
        )
        XCTAssertEqual(lms.first?.text,
                       "# BadValue at seq=17 from CreateGC (bad value=153)")
    }

    func testBadMatchErrorOmitsResourcePhrase() {
        var d = LandmarkDetector()
        let lms = d.afterServerMessage(
            errorMsg(code: .match, seq: 5, badId: 0, majorOpcode: 1 /* CreateWindow */),
            byteOrder: .lsbFirst
        )
        // No resource phrase for BadMatch (and no badId either)
        XCTAssertEqual(lms.first?.text, "# BadMatch at seq=5 from CreateWindow")
    }

    func testErrorOnExtensionRequestUsesExtensionName() {
        var d = LandmarkDetector()
        let lms = d.afterServerMessage(
            errorMsg(code: .value, seq: 88, badId: 0xFF, majorOpcode: 128, minorOpcode: 3),
            byteOrder: .lsbFirst,
            extensionMajorToName: [128: "SHAPE"]
        )
        XCTAssertEqual(lms.first?.text,
                       "# BadValue at seq=88 from SHAPE request (minor=3) (bad value=255)")
    }

    func testErrorOnUnknownExtensionUsesNumericMajor() {
        var d = LandmarkDetector()
        let lms = d.afterServerMessage(
            errorMsg(code: .value, seq: 88, badId: 0xFF, majorOpcode: 129, minorOpcode: 7),
            byteOrder: .lsbFirst
            // no extensionMajorToName lookup available
        )
        XCTAssertEqual(lms.first?.text,
                       "# BadValue at seq=88 from extension request major=129 minor=7 (bad value=255)")
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

    // MARK: - A: provenance suffix on map landmark

    /// Drive the toolkit's typical realize sequence: CreateWindow,
    /// WM_NAME (identify fires), then WM_CLASS / WM_CLIENT_MACHINE /
    /// WM_COMMAND, then MapWindow (map landmark fires with provenance).
    func testMapLandmarkPicksUpClassHostAndArgv() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x100, parent: 0x2B, w: 484, h: 316)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x100, "xterm")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMClientMachine(0x100, "u5")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMClass(0x100, instance: "xterm", cls: "XTerm")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMCommand(0x100, argv: ["xterm", "-bg", "black"])),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x100)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let mapLm = lms.first { $0.text.contains("appears on screen") }
        XCTAssertNotNil(mapLm)
        let text = mapLm?.text ?? ""
        XCTAssertTrue(text.contains("XTerm class"), text)
        XCTAssertTrue(text.contains("host \"u5\""), text)
        XCTAssertTrue(text.contains("launched as `xterm -bg black`"), text)
    }

    func testMapLandmarkProvenanceOmittedWhenAbsent() {
        // A toolkit that sets only WM_NAME (no class/host/argv) should
        // get the original landmark text — provenance suffix is purely
        // additive.
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x100, parent: 0x2B, w: 484, h: 316)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setWMName(0x100, "X")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x100)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.first?.text,
                       "# The \"X\" window appears on screen (0x100, 484×316)")
    }

    // MARK: - B: modifier prefix on click landmark

    func testClickWithShiftReadsAsShiftClick() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 1, time: 1000,
                                              x: 50, y: 50, state: 0x0001 /* Shift */),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 1, time: 1100,
                                                    x: 50, y: 50, state: 0x0001),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user Shift-clicks on \"Command Window\" at (50,50)")
    }

    func testClickWithCtrlPlusShiftCombines() {
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 1, time: 1000,
                                              x: 50, y: 50, state: 0x0005 /* Shift|Ctrl */),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 1, time: 1100,
                                                    x: 50, y: 50, state: 0x0005),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user Shift+Ctrl-clicks on \"Command Window\" at (50,50)")
    }

    func testClickWithButtonStateBitsIgnoresPointerButtons() {
        // Pointer-button bits in `state` (Button1..5 at 0x100..0x1000) are
        // the originating button's own bit — don't render those as
        // modifiers. Bare click should still read as bare.
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400001, button: 1, time: 1000,
                                              x: 50, y: 50, state: 0x0100 /* Button1 */),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400001, button: 1, time: 1100,
                                                    x: 50, y: 50, state: 0x0100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks on \"Command Window\" at (50,50)")
    }

    // MARK: - C: modal dialog distinction

    func testDialogWithMotifModalHintReadsAsModal() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        // _MOTIF_WM_HINTS is a runtime-interned atom; supply the lookup.
        let atoms: [UInt32: String] = [0xFE: "_MOTIF_WM_HINTS"]
        _ = d.afterRequest(.createWindow(cw(wid: 0x100, parent: 0x2B, w: 400, h: 200)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.createWindow(cw(wid: 0x200, parent: 0x2B, w: 300, h: 120)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.changeProperty(setWMName(0x100, "dtpad")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.changeProperty(setTransientFor(0x200, parent: 0x100)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.changeProperty(setMotifWMHints(0x200, inputMode: 1)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        let lms = d.afterRequest(.mapWindow(mw(0x200)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        let dialogLm = lms.first { $0.text.contains("dialog opens") }
        XCTAssertNotNil(dialogLm)
        XCTAssertTrue(dialogLm?.text.contains("# A modal dialog opens above \"dtpad\"") ?? false,
                      dialogLm?.text ?? "")
    }

    func testDialogWithoutModalHintReadsAsBareDialog() {
        // Either no _MOTIF_WM_HINTS, or inputMode=MODELESS. Either way no
        // "modal" prefix.
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        let atoms: [UInt32: String] = [0xFE: "_MOTIF_WM_HINTS"]
        _ = d.afterRequest(.createWindow(cw(wid: 0x100, parent: 0x2B, w: 400, h: 200)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.createWindow(cw(wid: 0x200, parent: 0x2B, w: 300, h: 120)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.changeProperty(setWMName(0x100, "dtpad")),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.changeProperty(setTransientFor(0x200, parent: 0x100)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        _ = d.afterRequest(.changeProperty(setMotifWMHints(0x200, inputMode: 0)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        let lms = d.afterRequest(.mapWindow(mw(0x200)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: atoms)
        let dialogLm = lms.first { $0.text.contains("dialog opens") }
        XCTAssertTrue(dialogLm?.text.contains("# A dialog opens above") ?? false,
                      dialogLm?.text ?? "")
        XCTAssertFalse(dialogLm?.text.contains("modal") ?? true, dialogLm?.text ?? "")
    }

    // MARK: - D: window-text cache → button label on click landmark

    func testClickOnButtonWithImageText8LabelReadsTheLabel() {
        var (d, roots) = clickOnNamedSetup()
        // A button widget gets its own child window; toolkit draws the
        // label into that window via ImageText8.
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400099, parent: 0x4400001, w: 60, h: 26)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.imageText8(ImageText8(
            drawable: 0x4400099, gc: 1, x: 5, y: 18,
            string: Array("OK".utf8))),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400099, button: 1, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400099, button: 1, time: 1100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks on \"OK\" in \"Command Window\" at (10,20)")
    }

    func testClickWithLongTextDoesNotUseItAsLabel() {
        // A 50-char string is past the labelLengthCap — falls back to the
        // existing geometry-based phrasing.
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400099, parent: 0x4400001, w: 600, h: 26)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let longText = String(repeating: "x", count: 50)
        _ = d.afterRequest(.imageText8(ImageText8(
            drawable: 0x4400099, gc: 1, x: 5, y: 18,
            string: Array(longText.utf8))),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400099, button: 1, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400099, button: 1, time: 1100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertTrue(lms.first?.text.contains("on a 600×26 child") ?? false,
                      lms.first?.text ?? "")
    }

    func testClickOnButtonWithPolyText8Label() {
        // CDE/Motif clients draw via PolyText8 — the items buffer holds
        // glyph runs prefixed by length+delta. Decoder walks them.
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400099, parent: 0x4400001, w: 60, h: 26)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // Single glyph run: length=6, delta=0, then "Cancel".
        var items: [UInt8] = [6, 0]
        items += Array("Cancel".utf8)
        _ = d.afterRequest(.polyText8(PolyText8(
            drawable: 0x4400099, gc: 1, x: 5, y: 18, items: items)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400099, button: 1, time: 1000),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400099, button: 1, time: 1100),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user clicks on \"Cancel\" in \"Command Window\" at (10,20)")
    }

    func testClickComboShiftAndButtonLabel() {
        // Shift-click on a labeled button: both enrichments compose.
        var (d, roots) = clickOnNamedSetup()
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400099, parent: 0x4400001, w: 60, h: 26)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.imageText8(ImageText8(
            drawable: 0x4400099, gc: 1, x: 5, y: 18,
            string: Array("Delete".utf8))),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400099, button: 1, time: 1000,
                                              x: 30, y: 13, state: 0x0001),
                                  byteOrder: .lsbFirst, screenRoots: roots)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400099, button: 1, time: 1100,
                                                    x: 30, y: 13, state: 0x0001),
                                        byteOrder: .lsbFirst, screenRoots: roots)
        XCTAssertEqual(lms.first?.text,
                       "# The user Shift-clicks on \"Delete\" in \"Command Window\" at (30,13)")
    }

    // MARK: - Helpers for the A/C tests

    private func setWMClass(_ window: UInt32, instance: String, cls: String) -> ChangeProperty {
        var data = Array(instance.utf8)
        data.append(0)
        data.append(contentsOf: cls.utf8)
        data.append(0)
        return ChangeProperty(
            mode: .replace, window: window,
            property: 67 /* WM_CLASS */, type: 31 /* STRING */,
            format: .format8, data: data
        )
    }

    private func setWMClientMachine(_ window: UInt32, _ host: String) -> ChangeProperty {
        return ChangeProperty(
            mode: .replace, window: window,
            property: 36 /* WM_CLIENT_MACHINE */, type: 31 /* STRING */,
            format: .format8, data: Array(host.utf8)
        )
    }

    private func setWMCommand(_ window: UInt32, argv: [String]) -> ChangeProperty {
        var data: [UInt8] = []
        for arg in argv {
            data.append(contentsOf: arg.utf8)
            data.append(0)
        }
        return ChangeProperty(
            mode: .replace, window: window,
            property: 34 /* WM_COMMAND */, type: 31 /* STRING */,
            format: .format8, data: data
        )
    }

    private func setMotifWMHints(_ window: UInt32, inputMode: UInt32) -> ChangeProperty {
        // 5 CARD32s LE: flags=0x4 (INPUT_MODE), functions=0, decorations=0,
        // inputMode, status=0.
        func u32le(_ v: UInt32) -> [UInt8] {
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                    UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        var data: [UInt8] = u32le(0x4) + u32le(0) + u32le(0) + u32le(inputMode) + u32le(0)
        // _MOTIF_WM_HINTS is a runtime atom; use a plausible-looking id.
        // Detector uses `atomToName[property]` which we pass empty, but
        // since the inputMode logic uses propName lookup, we need to plumb
        // a known atom-name resolution. Use atom 0x95 and route via the
        // atomToName argument from the call site... actually simpler: this
        // helper is only used in tests that go through afterRequest where
        // we pass atomToName. So we need the caller to supply atomToName
        // with that atom mapped. To keep helpers self-contained, we use
        // atom 0xFE for _MOTIF_WM_HINTS and the calling tests pass
        // atomToName=[0xFE: "_MOTIF_WM_HINTS"]. See dialog tests above.
        return ChangeProperty(
            mode: .replace, window: window,
            property: 0xFE, type: 0xFE /* _MOTIF_WM_HINTS atom */,
            format: .format32, data: data
        )
    }
}
