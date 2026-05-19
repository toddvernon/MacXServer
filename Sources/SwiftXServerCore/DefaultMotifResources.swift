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
    *XmText.fontList:           -adobe-helvetica-medium-r-normal--14-*-*-*-p-*-iso8859-1
    *XmTextField.fontList:      -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmLabel.fontList:          -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmList.fontList:           -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmCascadeButton.fontList:  -adobe-helvetica-bold-r-normal--12-*-*-*-p-*-iso8859-1
    *XmPushButton.fontList:     -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    ! DtEditor (the compound widget dtpad/dtmail use) exposes its text
    ! font via a separate resource name: textFontList, not fontList.
    ! When unset, DtEditor leaves XmNfontList alone on its inner XmText,
    ! but in practice the inner XmText still falls back to "fixed" —
    ! so we have to set the wrapper resource explicitly.
    *DtEditor.textFontList:     -adobe-courier-medium-r-normal--14-*-*-*-m-*-iso8859-1
    ! DtHelp's DisplayArea inherits its parent's background by default,
    ! which under Motif fallback is the panel-blue color — illegible for
    ! man-page body text. The pattern below is verbatim from CDE's shared
    ! `Dt.ad` file (lib/DtSvc/DtUtil2/Dt.ad lines 54-63). The comment
    ! there explains the duplication: "The resources are complex because
    ! they have to override the standard color resources in all cases."
    ! Generic `*DisplayArea.background` doesn't win the Xrm specificity
    ! contest against parent-bg propagation.
    *XmDialogShell.DtHelpDialog*DisplayArea.background:                White
    *XmDialogShell*XmDialogShell.DtHelpDialog*DisplayArea.background:  White
    *XmDialogShell.DtHelpDialog*DisplayArea.foreground:                Black
    *XmDialogShell*XmDialogShell.DtHelpDialog*DisplayArea.foreground:  Black
    *XmDialogShell.DtHelpQuickDialog*DisplayArea.background:           White
    *XmDialogShell*XmDialogShell.DtHelpQuickDialog*DisplayArea.background: White
    *XmDialogShell.DtHelpQuickDialog*DisplayArea.foreground:           Black
    *XmDialogShell*XmDialogShell.DtHelpQuickDialog*DisplayArea.foreground: Black
    ! Per-app overrides
    Dtpad*XmText.fontList:      -adobe-courier-medium-r-normal--14-*-*-*-m-*-iso8859-1
    Dtpad*textFontList:         -adobe-courier-medium-r-normal--14-*-*-*-m-*-iso8859-1
    ! dthelpview's manBox is a DtHelpQuickDialog instance; its rows/columns
    ! determine the dialog's initial aspect ratio. 32x80 matches u5's
    ! installed app-defaults (Dthelpview source line 43-44).
    Dthelpview*manBox.rows:     32
    Dthelpview*manBox.columns:  80
    Dthelpview*fileBox.rows:    32
    Dthelpview*fileBox.columns: 80
    """
}
