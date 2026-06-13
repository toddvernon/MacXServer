import XCTest
import AppKit
@testable import SwiftXServerCore

// Pins the title-bar geometry across the four decoration-bit cases.
// Background: pre-2026-06-13 our titleBarRect() bracketed itself by
// menuButton.maxX and restoreButton.minX unconditionally, so dialogs
// using _MOTIF_WM_HINTS to hide corner buttons (quickplot About/Quit,
// XmMessageBox templates that ask for BORDER|RESIZEH|TITLE only) left
// empty chrome carve-outs where the buttons would have been. Real Sun
// mwm extends the title bar to the frame edge in those corners; we now
// match. Verified visually against u5 2026-06-13.
final class MotifFrameViewGeometryTests: XCTestCase {

    // Restore MotifTheme.current after every test so we don't leak state
    // into other suites (some tests read the current theme to compute
    // pixmap layouts, etc.).
    private var savedTheme: MotifTheme!

    override func setUp() {
        super.setUp()
        savedTheme = MotifTheme.current
        // Known fixture: 32-pt title, 2-pt bevel + frame.
        // Derived: band = 2 + 2*2 = 6, buttonSize = 32, buttonInset = 2,
        // titleRowY = 6 + 2 = 8.
        var theme = MotifTheme.default
        theme.titleBarHeight = 32
        theme.bevelWidth = 2
        theme.frameWidth = 2
        MotifTheme.install(theme)
    }
    override func tearDown() {
        MotifTheme.install(savedTheme)
        super.tearDown()
    }

    /// Build a MotifFrameView with a fixed bounds and an optional set of
    /// decoration bits. Bounds are 400×300 so the math is easy to verify.
    @MainActor
    private func makeView(decorations: MotifWMHints.Decorations?) -> MotifFrameView {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let client = NSView(frame: NSRect.zero)
        let v = MotifFrameView(frame: bounds, clientView: client)
        if let d = decorations {
            v.motifHints = MotifWMHints(
                flags: .decorations,
                functions: 0,
                decorations: d,
                inputMode: 0,
                status: 0
            )
        }
        return v
    }

    /// Expected geometry constants, derived once from the fixture theme.
    /// band = 6, bi = 2, bs = 32, titleRowY = 8.
    private let bandPlusBi: CGFloat = 8       // band(6) + bi(2)
    private let buttonSize: CGFloat = 32
    private let titleRowY: CGFloat  = 8

    // MARK: - Cases

    /// No `_MOTIF_WM_HINTS` at all: all decorations show, title sits
    /// between the two visible button groups. Matches today's default
    /// behavior for any window that doesn't override decorations.
    @MainActor
    func testTitleBarBetweenButtonsWhenNoHints() {
        let v = makeView(decorations: nil)
        let rect = v.titleBarRect()
        // left = menuButtonRect().maxX = (band+bi)(8) + bs(32) = 40
        // right = restoreButtonRect().minX = maximize.minX(360) - bs(32) = 328
        XCTAssertEqual(rect.minX, 40)
        XCTAssertEqual(rect.maxX, 328)
        XCTAssertEqual(rect.minY, titleRowY)
        XCTAssertEqual(rect.height, buttonSize)
    }

    /// `_MOTIF_WM_HINTS` with decorations = BORDER|RESIZEH|TITLE (=0x0E):
    /// menu, minimize, maximize all hidden. Title bar extends from the
    /// left frame edge to the right frame edge. This is what quickplot
    /// About/Quit dialogs request.
    @MainActor
    func testTitleBarSpansFullWidthWhenAllButtonsHidden() {
        let v = makeView(decorations: [.border, .resizeH, .title])
        let rect = v.titleBarRect()
        // left = band+bi = 8 (no menu button)
        // right = bounds.width - band - bi = 400 - 8 = 392
        XCTAssertEqual(rect.minX, 8)
        XCTAssertEqual(rect.maxX, 392)
        XCTAssertEqual(rect.width, 384)
    }

    /// Menu hidden, minimize+maximize shown. Title bar starts at the
    /// frame's left edge, ends at the inner-right (minimize) button.
    @MainActor
    func testTitleBarExtendsLeftWhenMenuHidden() {
        let v = makeView(decorations: [.title, .minimize, .maximize])
        let rect = v.titleBarRect()
        // left = band+bi = 8
        // right = restoreButtonRect().minX = 360 - 32 = 328
        XCTAssertEqual(rect.minX, 8)
        XCTAssertEqual(rect.maxX, 328)
    }

    /// Menu shown, both right buttons hidden. Title bar starts at the
    /// menu button's right edge and runs to the right frame.
    @MainActor
    func testTitleBarExtendsRightWhenBothRightButtonsHidden() {
        let v = makeView(decorations: [.title, .menu])
        let rect = v.titleBarRect()
        // left = menuButtonRect().maxX = (8) + 32 = 40
        // right = bounds.width - band - bi = 392
        XCTAssertEqual(rect.minX, 40)
        XCTAssertEqual(rect.maxX, 392)
    }

    /// Maximize hidden but minimize shown — unusual but theoretically
    /// possible. Title ends at minimize's left edge as before; the
    /// freed-up rightmost slot stays empty for now (would need an extra
    /// "extend title past minimize into the maximize slot" path that
    /// no client we host actually exercises).
    @MainActor
    func testTitleBarRespectsMinimizeWhenMaximizeAloneHiddenIsNotRebalanced() {
        let v = makeView(decorations: [.title, .menu, .minimize])
        let rect = v.titleBarRect()
        // left = 40 (menu shown)
        // right = restoreButtonRect().minX = 328 (minimize shown)
        XCTAssertEqual(rect.minX, 40)
        XCTAssertEqual(rect.maxX, 328)
    }
}
