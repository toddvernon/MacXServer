import XCTest
@testable import SwiftXCaptureCore
import Framer

// Decoder coverage for the three vintage-era extensions added 2026-05-31:
// XC-MISC, XTEST, RECORD. None of the corpus captures exercise them; this
// is the verification surface. Wire layouts mirror what
// reference/X11R6/xc/include/extensions/xcmiscstr.h,
// reference/xproto/include/X11/extensions/xtestproto.h, and
// /opt/X11/include/X11/extensions/recordproto.h declare.

final class Tier4ExtensionTests: XCTestCase {

    // The extension's runtime-assigned major opcode; arbitrary in tests.
    private let extMajor: UInt8 = 130

    private func u16(_ v: UInt16, _ bo: ByteOrder) -> [UInt8] {
        switch bo {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8(v >> 8)]
        case .msbFirst: return [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
    }
    private func u32(_ v: UInt32, _ bo: ByteOrder) -> [UInt8] {
        switch bo {
        case .lsbFirst:
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        case .msbFirst:
            return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }

    // MARK: - XC-MISC

    func testXcMiscGetVersion() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 0]      // major, minor=0 (GetVersion)
        b += u16(2, bo)                      // length in 4-byte units
        b += u16(1, bo) + u16(1, bo)         // requested major.minor
        XCTAssertEqual(XcMiscDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XCMiscGetVersion         requested=1.1")
    }

    func testXcMiscGetXIDRange() {
        let bo: ByteOrder = .msbFirst
        let b: [UInt8] = [extMajor, 1] + u16(1, bo)
        XCTAssertEqual(XcMiscDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XCMiscGetXIDRange")
    }

    func testXcMiscGetXIDList() {
        let bo: ByteOrder = .lsbFirst
        var b: [UInt8] = [extMajor, 2] + u16(2, bo)
        b += u32(64, bo)                     // count
        XCTAssertEqual(XcMiscDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XCMiscGetXIDList         count=64")
    }

    func testXcMiscRejectsUnknownMinor() {
        XCTAssertNil(XcMiscDumper.formatRequest(bytes: [extMajor, 99, 0, 1], byteOrder: .msbFirst))
    }

    // MARK: - XTEST

    func testXTestGetVersion() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 0] + u16(2, bo)
        b += [2, 0] + u16(2, bo)            // majorVersion=2 pad minorVersion=2
        XCTAssertEqual(XTestDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XTestGetVersion          requested=2.2")
    }

    func testXTestCompareCursor() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 1] + u16(3, bo)
        b += u32(0x2800001, bo)              // window
        b += u32(0x500, bo)                  // cursor
        XCTAssertEqual(XTestDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XTestCompareCursor       window=0x2800001 cursor=0x500")
    }

    func testXTestCompareCursorNoneCursor() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 1] + u16(3, bo)
        b += u32(0x2800001, bo) + u32(0, bo)
        XCTAssertEqual(XTestDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XTestCompareCursor       window=0x2800001 cursor=None")
    }

    func testXTestFakeInputKeyPress() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 2] + u16(9, bo)
        b += [2, 92]                         // type=KeyPress detail=keycode 92
        b += u16(0, bo)                      // pad
        b += u32(0, bo)                      // time = CurrentTime
        b += u32(0x2B, bo)                   // root
        b += u32(0, bo) + u32(0, bo)         // pad1, pad2
        b += u16(UInt16(bitPattern: 100), bo) + u16(UInt16(bitPattern: 200), bo)
        b += u32(0, bo) + u16(0, bo) + [0, 0]  // pad3, pad4, pad5, deviceId=0
        XCTAssertEqual(XTestDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XTestFakeInput           KeyPress detail=keycode=92 time=CurrentTime root=0x2B at (100,200) device=0")
    }

    func testXTestFakeInputMotionRelative() {
        let bo: ByteOrder = .lsbFirst
        var b: [UInt8] = [extMajor, 2] + u16(9, bo)
        b += [6, 1]                          // type=MotionNotify detail=relative
        b += u16(0, bo)
        b += u32(12345, bo) + u32(0x2B, bo)
        b += u32(0, bo) + u32(0, bo)
        b += u16(UInt16(bitPattern: Int16(-5)), bo) + u16(UInt16(bitPattern: Int16(10)), bo)
        b += u32(0, bo) + u16(0, bo) + [0, 3]
        XCTAssertEqual(XTestDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XTestFakeInput           MotionNotify detail=relative time=12345 root=0x2B at (-5,10) device=3")
    }

    func testXTestGrabControl() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 3] + u16(2, bo)
        b += [1, 0, 0, 0]                    // impervious=true + pad
        XCTAssertEqual(XTestDumper.formatRequest(bytes: b, byteOrder: bo),
                       "XTestGrabControl         impervious=true")
    }

    // MARK: - RECORD

    func testRecordQueryVersion() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 0] + u16(2, bo)
        b += u16(1, bo) + u16(13, bo)
        XCTAssertEqual(RecordDumper.formatRequest(bytes: b, byteOrder: bo),
                       "RecordQueryVersion       requested=1.13")
    }

    func testRecordCreateContext() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 1] + u16(5, bo)
        b += u32(0x300001, bo)               // context resource id
        b += [0, 0] + u16(0, bo)             // elementHeader=0, pads
        b += u32(2, bo) + u32(3, bo)         // nClients=2 nRanges=3
        XCTAssertEqual(RecordDumper.formatRequest(bytes: b, byteOrder: bo),
                       "RecordCreateContext      context=0x300001 elementHeader=0x0 clients=2 ranges=3")
    }

    func testRecordEnableContext() {
        let bo: ByteOrder = .lsbFirst
        var b: [UInt8] = [extMajor, 5] + u16(2, bo)
        b += u32(0x300001, bo)
        XCTAssertEqual(RecordDumper.formatRequest(bytes: b, byteOrder: bo),
                       "RecordEnableContext      context=0x300001")
    }

    func testRecordFreeContext() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = [extMajor, 7] + u16(2, bo)
        b += u32(0x300001, bo)
        XCTAssertEqual(RecordDumper.formatRequest(bytes: b, byteOrder: bo),
                       "RecordFreeContext        context=0x300001")
    }

    // MARK: - Registry

    func testAllThreeRegistered() {
        XCTAssertNotNil(ExtensionDumperRegistry.decoder(forName: "XC-MISC"))
        XCTAssertNotNil(ExtensionDumperRegistry.decoder(forName: "XTEST"))
        XCTAssertNotNil(ExtensionDumperRegistry.decoder(forName: "RECORD"))
        XCTAssertEqual(ExtensionDumperRegistry.eventCount(forName: "XC-MISC"), 0)
        XCTAssertEqual(ExtensionDumperRegistry.eventCount(forName: "XTEST"), 0)
        XCTAssertEqual(ExtensionDumperRegistry.eventCount(forName: "RECORD"), 0)
    }
}
