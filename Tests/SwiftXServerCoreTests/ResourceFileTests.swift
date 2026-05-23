import XCTest
@testable import SwiftXServerCore

final class ResourceFileTests: XCTestCase {

    // MARK: - Parsing

    func testEmptyTextParsesAsEmpty() {
        let file = ResourceFile.parse("")
        XCTAssertTrue(file.sections.isEmpty)
        XCTAssertEqual(file.activeTheme, "quickplot")
        XCTAssertEqual(file.themeNames, [])
        XCTAssertEqual(String(decoding: file.resourceManagerBytes(), as: UTF8.self),
                       "\n\0",
                       "empty file still emits the LF+NUL terminator")
    }

    func testConfigGlobalAndThemeSectionsParseInOrder() {
        let text = """
        [swiftx-config]
        theme: quickplot

        [global]
        *cursorForeground: cyan

        [theme:quickplot]
        *background: Gray
        *foreground: Black
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.sections.count, 3)
        XCTAssertEqual(file.sections[0].kind, .config)
        XCTAssertEqual(file.sections[1].kind, .global)
        XCTAssertEqual(file.sections[2].kind, .theme("quickplot"))
        XCTAssertEqual(file.activeTheme, "quickplot")
        XCTAssertEqual(file.themeNames, ["quickplot"])
    }

    func testThemeWithSpacesInHeaderTrims() {
        let text = """
        [ theme: dark ]
        *background: black
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.sections.count, 1)
        XCTAssertEqual(file.sections[0].kind, .theme("dark"))
    }

    func testUnknownSectionPreserved() {
        let text = """
        [some-future-section]
        key: value

        [theme:quickplot]
        *background: Gray
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertEqual(file.sections[0].kind, .unknown("some-future-section"))
        XCTAssertEqual(file.sections[1].kind, .theme("quickplot"))
    }

    func testCommentsAndBlankLinesPreserved() {
        let text = """
        [theme:quickplot]
        ! this is a comment

        *background: Gray
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.sections[0].bodyLines, [
            "! this is a comment",
            "",
            "*background: Gray"
        ])
    }

    func testLinesBeforeFirstHeaderGoToSyntheticUnknown() {
        let text = """
        ! preamble comment
        random text

        [theme:quickplot]
        *background: Gray
        """
        let file = ResourceFile.parse(text)
        // Synthetic .unknown("") section holds the preamble.
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertEqual(file.sections[0].kind, .unknown(""))
        XCTAssertEqual(file.sections[0].bodyLines, [
            "! preamble comment",
            "random text",
            ""
        ])
        XCTAssertEqual(file.sections[1].kind, .theme("quickplot"))
    }

    func testMissingConfigDefaultsToQuickplotTheme() {
        let text = """
        [theme:dark]
        *background: black
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.activeTheme, "quickplot",
            "no [swiftx-config] section → defaults to 'quickplot' even if absent from the file")
    }

    func testThemeKeyWithoutColonIgnored() {
        let text = """
        [swiftx-config]
        theme dark

        [theme:dark]
        *bg: black
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.activeTheme, "quickplot",
            "malformed `theme dark` (no colon) → default kicks in")
    }

    func testWhitespaceAroundThemeColonHandled() {
        let text = """
        [swiftx-config]
            theme   :   dark
        """
        let file = ResourceFile.parse(text)
        XCTAssertEqual(file.activeTheme, "dark")
    }

    // MARK: - resourceManagerBytes

    func testResourceManagerBytesConcatGlobalAndActiveTheme() {
        let text = """
        [swiftx-config]
        theme: dark

        [global]
        *cursorForeground: cyan

        [theme:quickplot]
        *background: Gray

        [theme:dark]
        *background: black
        *foreground: white
        """
        let file = ResourceFile.parse(text)
        let bytes = file.resourceManagerBytes()
        let str = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(str.contains("*cursorForeground: cyan"), "global rule included")
        XCTAssertTrue(str.contains("*background: black"), "dark theme rule included")
        XCTAssertTrue(str.contains("*foreground: white"), "dark theme rule included")
        XCTAssertFalse(str.contains("*background: Gray"),
            "quickplot rule NOT included because dark is active")
        XCTAssertTrue(str.hasSuffix("\0"), "LF+NUL terminator preserved")
    }

    func testResourceManagerBytesIgnoresConfigSection() {
        let text = """
        [swiftx-config]
        theme: quickplot
        other-future-setting: 42

        [theme:quickplot]
        *bg: Gray
        """
        let file = ResourceFile.parse(text)
        let str = String(decoding: file.resourceManagerBytes(), as: UTF8.self)
        XCTAssertFalse(str.contains("theme: quickplot"),
            "config section content NOT published")
        XCTAssertFalse(str.contains("other-future-setting"),
            "unknown config keys NOT published")
        XCTAssertTrue(str.contains("*bg: Gray"))
    }

    func testActiveThemeMissingFromFileEmitsEmpty() {
        let text = """
        [swiftx-config]
        theme: nonexistent

        [global]
        *cursor: red

        [theme:quickplot]
        *bg: Gray
        """
        let file = ResourceFile.parse(text)
        let str = String(decoding: file.resourceManagerBytes(), as: UTF8.self)
        XCTAssertTrue(str.contains("*cursor: red"), "global still applied")
        XCTAssertFalse(str.contains("*bg: Gray"),
            "quickplot theme rules NOT included; user picked 'nonexistent'")
    }

    // MARK: - Seed (round-trip)

    func testSeedContentParsesAndYieldsExpectedTheme() {
        let file = ResourceFile.parse(DefaultThemes.seedContent)
        XCTAssertEqual(file.activeTheme, "quickplot")
        XCTAssertTrue(file.themeNames.contains("quickplot"),
            "seed has at least one [theme:quickplot] section")
        // Quick smoke check that the published bytes contain the
        // anchor resource from our pre-themes setup.
        let str = String(decoding: file.resourceManagerBytes(), as: UTF8.self)
        XCTAssertTrue(str.contains("*background:"),
            "seed publish includes the canonical *background rule")
    }
}
