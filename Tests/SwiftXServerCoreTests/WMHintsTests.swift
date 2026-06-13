import XCTest
@testable import SwiftXServerCore
import Framer

// Decoder unit tests for WM_NORMAL_HINTS (WMSizeHints) and _MOTIF_WM_HINTS
// (MotifWMHints) plus integration tests proving that ChangeProperty on
// those atoms reaches the bridge with the right values.
final class WMHintsTests: XCTestCase {

    // MARK: - Hint-bytes helpers

    /// Build an 18-CARD32 WM_SIZE_HINTS blob (72 bytes). All trailing
    /// fields zero; caller fills what they need.
    private func makeSizeHintsBytes(
        flags: UInt32,
        minW: Int32 = 0, minH: Int32 = 0,
        maxW: Int32 = 0, maxH: Int32 = 0,
        incW: Int32 = 0, incH: Int32 = 0,
        minAspectX: Int32 = 0, minAspectY: Int32 = 0,
        baseW: Int32 = 0, baseH: Int32 = 0,
        byteOrder: ByteOrder = .lsbFirst
    ) -> [UInt8] {
        var values: [UInt32] = Array(repeating: 0, count: 18)
        values[0] = flags
        // Skip 1..4 (obsolete x/y/w/h).
        values[5] = UInt32(bitPattern: minW); values[6] = UInt32(bitPattern: minH)
        values[7] = UInt32(bitPattern: maxW); values[8] = UInt32(bitPattern: maxH)
        values[9] = UInt32(bitPattern: incW); values[10] = UInt32(bitPattern: incH)
        values[11] = UInt32(bitPattern: minAspectX); values[12] = UInt32(bitPattern: minAspectY)
        // Aspect max (13, 14) and baseW/baseH (15, 16) left zero.
        values[15] = UInt32(bitPattern: baseW); values[16] = UInt32(bitPattern: baseH)
        var bytes: [UInt8] = []
        for v in values {
            if byteOrder == .lsbFirst {
                bytes.append(contentsOf: [UInt8(v & 0xFF),
                                          UInt8((v >> 8) & 0xFF),
                                          UInt8((v >> 16) & 0xFF),
                                          UInt8((v >> 24) & 0xFF)])
            } else {
                bytes.append(contentsOf: [UInt8((v >> 24) & 0xFF),
                                          UInt8((v >> 16) & 0xFF),
                                          UInt8((v >> 8) & 0xFF),
                                          UInt8(v & 0xFF)])
            }
        }
        return bytes
    }

    private func makeMwmHintsBytes(
        flags: UInt32, functions: UInt32 = 0,
        decorations: UInt32 = 0, inputMode: Int32 = 0, status: UInt32 = 0,
        byteOrder: ByteOrder = .lsbFirst
    ) -> [UInt8] {
        let values: [UInt32] = [flags, functions, decorations,
                                UInt32(bitPattern: inputMode), status]
        var bytes: [UInt8] = []
        for v in values {
            if byteOrder == .lsbFirst {
                bytes.append(contentsOf: [UInt8(v & 0xFF),
                                          UInt8((v >> 8) & 0xFF),
                                          UInt8((v >> 16) & 0xFF),
                                          UInt8((v >> 24) & 0xFF)])
            } else {
                bytes.append(contentsOf: [UInt8((v >> 24) & 0xFF),
                                          UInt8((v >> 16) & 0xFF),
                                          UInt8((v >> 8) & 0xFF),
                                          UInt8(v & 0xFF)])
            }
        }
        return bytes
    }

    // MARK: - WMSizeHints decode

    func testSizeHintsDecodeMinMaxBothByteOrders() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = makeSizeHintsBytes(
                flags: WMSizeHints.Flags([.pMinSize, .pMaxSize]).rawValue,
                minW: 80, minH: 24, maxW: 1600, maxH: 1200,
                byteOrder: order
            )
            let hints = WMSizeHints.decode(bytes, byteOrder: order)
            XCTAssertNotNil(hints)
            XCTAssertTrue(hints!.flags.contains(.pMinSize), "order=\(order)")
            XCTAssertTrue(hints!.flags.contains(.pMaxSize), "order=\(order)")
            XCTAssertEqual(hints!.minWidth, 80, "order=\(order)")
            XCTAssertEqual(hints!.minHeight, 24, "order=\(order)")
            XCTAssertEqual(hints!.maxWidth, 1600, "order=\(order)")
            XCTAssertEqual(hints!.maxHeight, 1200, "order=\(order)")
        }
    }

    func testSizeHintsDecodeResizeIncAndAspect() {
        let bytes = makeSizeHintsBytes(
            flags: WMSizeHints.Flags([.pResizeInc, .pAspect]).rawValue,
            incW: 6, incH: 13,
            minAspectX: 4, minAspectY: 3
        )
        let h = WMSizeHints.decode(bytes, byteOrder: .lsbFirst)!
        XCTAssertEqual(h.widthInc, 6)
        XCTAssertEqual(h.heightInc, 13)
        XCTAssertEqual(h.minAspectX, 4)
        XCTAssertEqual(h.minAspectY, 3)
    }

    /// Pre-ICCCM clients ship a 15-element property (60 bytes). Decoder
    /// must accept it and zero the trailing fields rather than rejecting.
    func testSizeHintsDecodeTruncatedPreICCCM() {
        var bytes = makeSizeHintsBytes(
            flags: WMSizeHints.Flags.pMinSize.rawValue,
            minW: 50, minH: 50
        )
        bytes = Array(bytes.prefix(60))   // 15 CARD32s, missing base + winGravity
        let h = WMSizeHints.decode(bytes, byteOrder: .lsbFirst)!
        XCTAssertEqual(h.minWidth, 50)
        XCTAssertEqual(h.minHeight, 50)
        XCTAssertEqual(h.baseWidth, 0)    // trailing field zeroed
    }

    func testSizeHintsDecodeTooShortReturnsNil() {
        XCTAssertNil(WMSizeHints.decode([0x01, 0x02], byteOrder: .lsbFirst))
    }

    // MARK: - MotifWMHints decode

    func testMotifHintsDecorationsBitsParsed() {
        let bytes = makeMwmHintsBytes(
            flags: MotifWMHints.Flags.decorations.rawValue,
            decorations: MotifWMHints.Decorations([.border, .title]).rawValue
        )
        let h = MotifWMHints.decode(bytes, byteOrder: .lsbFirst)!
        XCTAssertTrue(h.flags.contains(.decorations))
        XCTAssertTrue(h.decorations.contains(.border))
        XCTAssertTrue(h.decorations.contains(.title))
        XCTAssertFalse(h.decorations.contains(.menu))
        XCTAssertTrue(h.hasExplicitDecorations,
                      "DECORATIONS flag set + not the ALL bit → explicit")
    }

    /// `decorations = ALL (0x01)` is a sentinel meaning "use the default
    /// everything-on set," NOT "no decorations at all." The bridge should
    /// fall through to static config in that case.
    func testMotifHintsDecorationsAllMeansNoOverride() {
        let bytes = makeMwmHintsBytes(
            flags: MotifWMHints.Flags.decorations.rawValue,
            decorations: MotifWMHints.Decorations.all.rawValue
        )
        let h = MotifWMHints.decode(bytes, byteOrder: .lsbFirst)!
        XCTAssertTrue(h.flags.contains(.decorations))
        XCTAssertFalse(h.hasExplicitDecorations,
                       "ALL bit → not an explicit override; static config wins")
    }

    func testMotifHintsWithoutDecorationsFlagIsNotExplicit() {
        let bytes = makeMwmHintsBytes(
            flags: MotifWMHints.Flags.functions.rawValue,
            decorations: 0xFF   // would matter, but flag bit is OFF
        )
        let h = MotifWMHints.decode(bytes, byteOrder: .lsbFirst)!
        XCTAssertFalse(h.hasExplicitDecorations,
                       "DECORATIONS flag clear → decorations field is undefined")
    }
}
