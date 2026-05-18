// Tier 1 RESOURCE_MANAGER content. Per MOTIF_TEXT_QUALITY.md's "control
// surface" section: what Motif's resource cascade reads on the X server's
// root window decides which fonts XmText / XmLabel / XmPushButton /
// XmList / XmCascadeButton widgets request via OpenFont. We curate that.
//
// This replaces the 2026-05-18-retired CDE-flavored fixture
// (CDEResourceManagerFixture). That fixture's purpose was to impersonate
// Solaris CDE; cut once we settled on "be SS2 with mwm, not SS2 with
// CDE." Our purpose now is different — drive Motif's widget-class
// defaults toward Helvetica/Courier XLFDs that map cleanly through
// FontResolver's substitution table to Mac fonts that render nicely
// at retina scaling.
//
// Tiering (see MOTIF_TEXT_QUALITY.md → "Staged delivery"):
//   - Tier 1 (this file): hardcoded in Swift, identical per session.
//   - Tier 2: user-editable Xresources file in app support.
//   - Tier 3: macOS settings panel.
// Each tier compounds on the last. Tier 1 is enough to fix "dtpad uses
// `fixed`" — and is what's shipped today.
//
// Format: Xresources, one resource per line, `*Class.resource: value`,
// `!` for comments. Trailing 0x0A (LF) + 0x00 (NUL) matches the STRING
// convention u5 used; safe even though X11 specifies no NUL termination,
// because every Xrm parser stops at LF anyway and the NUL gets ignored.

enum DefaultMotifResources {

    static let bytes: [UInt8] = {
        return Array(text.utf8) + [0x0A, 0x00]
    }()

    private static let text = """
    ! swift-x Tier 1 Motif widget defaults. See MOTIF_TEXT_QUALITY.md.
    *XmText.fontList:           -adobe-helvetica-medium-r-normal--14-*-*-*-*-p-*-iso8859-1
    *XmTextField.fontList:      -adobe-helvetica-medium-r-normal--12-*-*-*-*-p-*-iso8859-1
    *XmLabel.fontList:          -adobe-helvetica-medium-r-normal--12-*-*-*-*-p-*-iso8859-1
    *XmList.fontList:           -adobe-helvetica-medium-r-normal--12-*-*-*-*-p-*-iso8859-1
    *XmCascadeButton.fontList:  -adobe-helvetica-bold-r-normal--12-*-*-*-*-p-*-iso8859-1
    *XmPushButton.fontList:     -adobe-helvetica-medium-r-normal--12-*-*-*-*-p-*-iso8859-1
    ! Per-app overrides
    Dtpad*XmText.fontList:      -adobe-courier-medium-r-normal--14-*-*-*-*-m-*-iso8859-1
    """
}
