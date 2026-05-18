import XCTest
@testable import SwiftXServerCore

final class DefaultMotifResourcesTests: XCTestCase {

    // The shape this fixture has to keep, per MOTIF_TEXT_QUALITY.md's
    // Tier 1 curated set. If a future editor strips trailing whitespace
    // or someone refactors the resource list, these still hold.

    func testBytesEndWithNewlineAndNul() {
        let bytes = DefaultMotifResources.bytes
        XCTAssertEqual(bytes[bytes.count - 2], 0x0A)
        XCTAssertEqual(bytes[bytes.count - 1], 0x00)
    }

    func testContainsAllSixWidgetClassFontList() {
        let s = String(decoding: DefaultMotifResources.bytes, as: UTF8.self)
        for cls in ["XmText", "XmTextField", "XmLabel",
                    "XmList", "XmCascadeButton", "XmPushButton"] {
            XCTAssertTrue(s.contains("*\(cls).fontList:"),
                          "Tier 1 must publish *\(cls).fontList")
        }
    }

    func testReferencesAdobeHelveticaXLFD() {
        let s = String(decoding: DefaultMotifResources.bytes, as: UTF8.self)
        XCTAssertTrue(s.contains("-adobe-helvetica-"),
                      "Tier 1 set steers Motif at Helvetica XLFDs")
    }

    func testDtpadOverrideUsesCourier() {
        let s = String(decoding: DefaultMotifResources.bytes, as: UTF8.self)
        XCTAssertTrue(s.contains("Dtpad*XmText.fontList:"),
                      "dtpad needs a monospace override for its editor pane")
        XCTAssertTrue(s.contains("-adobe-courier-"))
    }
}
