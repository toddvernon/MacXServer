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

    func testPrimaryTagOnFirstTopLevelMap() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B, w: 500, h: 600)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400001)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertTrue(lms.first?.text.contains("primary") ?? false)
        XCTAssertTrue(lms.first?.text.contains("500×600") ?? false)
    }

    func testAuxiliaryTagOnSecondTopLevelMap() {
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
        XCTAssertTrue(lms.first?.text.contains("auxiliary") ?? false)
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

    func testWMNameSetsIdentityLandmark() {
        var d = LandmarkDetector()
        let roots: Set<UInt32> = [0x2B]
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400001, parent: 0x2B)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.changeProperty(setWMName(0x4400001, "editres")),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        XCTAssertEqual(lms.count, 1)
        XCTAssertTrue(lms.first?.text.contains("\"editres\"") ?? false)
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
        _ = d.afterRequest(.mapWindow(mw(0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // Dialog window created with parent == root
        _ = d.afterRequest(.createWindow(cw(wid: 0x4400029, parent: 0x2B, w: 200, h: 100)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        _ = d.afterRequest(.changeProperty(setTransientFor(0x4400029, parent: 0x4400001)),
                           byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        let lms = d.afterRequest(.mapWindow(mw(0x4400029)),
                                  byteOrder: .lsbFirst, screenRoots: roots, atomToName: [:])
        // Two landmarks now expected: auxiliary top-level + dialog tag
        XCTAssertEqual(lms.count, 2)
        XCTAssertTrue(lms.contains { $0.text.contains("auxiliary") })
        XCTAssertTrue(lms.contains { $0.text.contains("dialog") })
    }

    func testClickLandmarkOnMatchedPress() {
        var d = LandmarkDetector()
        // Press at t=1000, release at t=1100 — within threshold
        _ = d.afterServerMessage(buttonEvent(code: 4, window: 0x4400023, button: 1, time: 1000),
                                  byteOrder: .lsbFirst)
        let lms = d.afterServerMessage(buttonEvent(code: 5, window: 0x4400023, button: 1, time: 1100),
                                        byteOrder: .lsbFirst)
        XCTAssertEqual(lms.count, 1)
        XCTAssertTrue(lms.first?.text.contains("click on window 0x4400023") ?? false)
        XCTAssertTrue(lms.first?.text.contains("button=1") ?? false)
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
