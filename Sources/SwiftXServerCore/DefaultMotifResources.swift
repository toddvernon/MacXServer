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

    /// Raw resources text in legacy single-theme form. Kept module-visible
    /// (not private) so `DefaultThemes` can wrap it in the section format
    /// for the first-run seed of `~/.swiftx-resources` without
    /// duplicating ~500 lines of content. Will be retired once the seed
    /// is hand-tweaked and theme blocks are split out.
    static let text = """
    ! swift-x Tier 1 Motif widget defaults. See MOTIF_TEXT_QUALITY.md.
    !
    ! ---- Color palette ----
    ! Modeled on quickplot's fallback resources (reference/quickplot/app.c
    ! lines 178-239; Todd's Motif app, NASA DFRC 1992). With the CDE
    ! customization daemon retired 2026-05-18 (see DECISIONS), Motif's
    ! compiled-in blue takes over any widget that has no resource. These
    ! restore a coherent classic palette: Gray chrome, DarkSeaGreen text
    ! fields, SlateBlue1 menu bar, Blue dialog accents, Gray70 secondary
    ! surfaces. Motif derives top/bottom shadow shading from *background
    ! automatically, so we don't set shadows here.
    *background:                  Gray
    *foreground:                  Black
    *XmText.background:           DarkSeaGreen
    *XmText.foreground:           Black
    *XmTextField.background:      DarkSeaGreen
    *XmTextField.foreground:      Black
    *XmList.background:           Gray70
    *XmList.foreground:           Black
    ! Menu bars: dt-apps name them differently — dtcalc uses "mainMenu",
    ! dtterm/dticon use "menuBar", quickplot uses "menubar". Cover the
    ! three patterns so the SlateBlue1 accent lands on all of them.
    *menuBar*background:          SlateBlue1
    *menuBar*foreground:          White
    *menubar*background:          SlateBlue1
    *menubar*foreground:          White
    *mainMenu*background:         SlateBlue1
    *mainMenu*foreground:         White
    ! dtterm names its menu bar widget `"menu_pulldown"` even though it's
    ! the menu bar, not a pulldown (XmCreateMenuBar(parent,
    ! "menu_pulldown", ...) in TermViewMenu.c:622). Match it so dtterm's
    ! menu bar gets the SlateBlue1 accent like every other dt-app.
    *menu_pulldown*background:    SlateBlue1
    *menu_pulldown*foreground:    White
    ! Pulldown menus that appear when a menu-bar title is clicked are
    ! XmRowColumn instances parented under an XmMenuShell popup shell.
    ! Scoping by `*XmMenuShell*` is universal across all Motif apps and
    ! reaches both the pane's bg and the item-button bg/fg. Tighter than
    ! `*XmRowColumn*` which would also catch dtcalc's number keypad.
    *XmMenuShell*background:      SlateBlue1
    *XmMenuShell*foreground:      White
    ! Text-insertion caret color across Motif text widgets and the dtterm
    ! terminal area. XmNcursorForeground (resource name `cursorForeground`)
    ! is what Motif's XmText / DtTerm both honor for the caret color.
    ! xterm uses the simpler `cursorColor` resource; cover both.
    *cursorForeground:            cyan
    *cursorColor:                 cyan
    ! Dialog accents: labels and buttons inside popup dialog shells get
    ! Blue text. Main-application labels/buttons stay Black (the
    ! *foreground default above) since they're not under an XmDialogShell.
    ! Most dt-app dialog buttons are Gadgets (XmPushButtonGadget) — the
    ! Help/QuickHelp close/back/print, Print dialog page-size buttons,
    ! dtcalc info-dialog Cancel, etc. — so cover both classes.
    *XmDialogShell*XmLabel.foreground:             Blue
    *XmDialogShell*XmLabelGadget.foreground:       Blue
    *XmDialogShell*XmPushButton.foreground:        Blue
    *XmDialogShell*XmPushButtonGadget.foreground:  Blue
    !
    ! ---- Fonts ----
    ! Motif distinguishes widgets (have an X window each) from gadgets
    ! (lighter — no window, share the parent's). Most menu bars and
    ! labels in dt-apps and quickplot create Gadget instances by default
    ! (XmCascadeButtonGadget, XmLabelGadget, XmPushButtonGadget) because
    ! they're cheaper. Xrm class-name lookup is strict, so we have to
    ! list both forms for resources to reach both kinds of instance.
    *XmText.fontList:               -adobe-helvetica-medium-r-normal--14-*-*-*-p-*-iso8859-1
    *XmTextField.fontList:          -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmLabel.fontList:              -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmLabelGadget.fontList:        -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmList.fontList:               -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    ! Menu items in the quickplot theme are Helvetica 14pt oblique — see
    ! reference/quickplot/app.c `qp.menuFont`. Applies to menu-bar
    ! CascadeButtons across all hosted Motif apps so dtcalc/dtterm/etc.
    ! menus match quickplot's slim-italic menu look. Pulldown menu items
    ! are XmPushButton, but so are dialog action buttons and dtcalc's
    ! number keypad — punting that broader scope until we know which
    ! look the user actually wants.
    *XmCascadeButton.fontList:        -adobe-helvetica-medium-o-normal--14-*-*-*-p-*-iso8859-1
    *XmCascadeButtonGadget.fontList:  -adobe-helvetica-medium-o-normal--14-*-*-*-p-*-iso8859-1
    *XmPushButton.fontList:           -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    *XmPushButtonGadget.fontList:     -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
    ! Pulldown menu items are XmPushButton(Gadget) children of the
    ! XmRowColumn that is the pulldown menu pane. Match quickplot's
    ! convention of menu titles and menu items at the same 14pt oblique.
    ! Audit 2026-05-22 confirmed: dtcalc's number keypad is parented
    ! to XmForm, not XmRowColumn (motif.c:702 `kkeyboard` =
    ! XmCreateForm). The only XmRowColumns that wrap PushButtons in
    ! the dt-apps are XmPulldownMenu / XmPopupMenu instances — exactly
    ! the targets. Safe rule.
    *XmRowColumn*XmPushButton.fontList:        -adobe-helvetica-medium-o-normal--14-*-*-*-p-*-iso8859-1
    *XmRowColumn*XmPushButtonGadget.fontList:  -adobe-helvetica-medium-o-normal--14-*-*-*-p-*-iso8859-1
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
    ! dtpad names its menu bar `"bar"` (XmCreateMenuBar(parent, "bar", ...)
    ! in dtpad.c:947) so the generic *menuBar/*menubar/*mainMenu rules
    ! miss it. App-scoped + name-scoped fix.
    Dtpad*bar*background:       SlateBlue1
    Dtpad*bar*foreground:       White
    ! Text editor bg: override the global DarkSeaGreen XmText bg to White
    ! for dtpad specifically — the editor's main work area benefits from
    ! a paper-white background more than the colored field look used by
    ! quickplot / dt-app XmTextFields.
    Dtpad*XmText.background:        White
    Dtpad*XmText.foreground:        Black
    ! Drop the Motif keyboard-focus highlight ring on the editor — the
    ! caret already indicates focus, and the ring is visually noisy
    ! around a full-window editor area.
    Dtpad*XmText.highlightThickness: 0
    ! dtterm terminal area: classic black background + white foreground.
    ! DtCreateTerm produces an instance with class `DtTerm` and instance
    ! name `dtTerm` (see Term.c:411 + TermView.c:1136). DtTermPrim is a
    ! superclass but Xrm matches on the leaf-class name only, not the
    ! inheritance chain — so we have to spell out DtTerm. Both class
    ! and instance-name forms listed for robustness.
    *DtTerm.background:         Black
    *DtTerm.foreground:         White
    *dtTerm.background:         Black
    *dtTerm.foreground:         White
    ! dthelpview's manBox is a DtHelpQuickDialog instance; its rows/columns
    ! determine the dialog's initial aspect ratio. 32x80 matches u5's
    ! installed app-defaults (Dthelpview source line 43-44).
    Dthelpview*manBox.rows:     32
    Dthelpview*manBox.columns:  80
    Dthelpview*fileBox.rows:    32
    Dthelpview*fileBox.columns: 80
    ! dthelpview uses XtInitialize (creates an ApplicationShell, NOT an
    ! XmDialogShell), so our `*XmDialogShell*` rules don't apply to its
    ! Close/Backtrack/Print action buttons. Buttons are XmPushButtonGadgets
    ! named `closeButton`, `backButton`, `printButton` (HelpQuickD.c:750,
    ! 790, 810). Targeting by instance name beats the class-based rules
    ! since class-name lookup sometimes loses to `*foreground: Black` on
    ! the cascade — instance-name lookup wins more reliably. Also thin the
    ! shadow + highlight rings so the buttons don't sit in the deep
    ! trough Motif draws by default; matches quickplot's lighter look.
    Dthelpview*XmPushButton.foreground:        Blue
    Dthelpview*XmPushButton.fontList:          -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    Dthelpview*XmPushButtonGadget.foreground:  Blue
    Dthelpview*XmPushButtonGadget.fontList:    -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    ! Per-instance .foreground triple still listed — earlier empirical
    ! testing showed the class-based rule didn't beat `*foreground: Black`
    ! reliably for these specific buttons. If we ever sort out why the
    ! class lookup loses the cascade fight, these three can go away.
    Dthelpview*closeButton.foreground:         Blue
    Dthelpview*backButton.foreground:          Blue
    Dthelpview*printButton.foreground:         Blue
    ! Shadow/highlight thinning collapsed to class-based rules. The audit
    ! confirmed the per-instance triple was equivalent and brittle to
    ! button renames. highlightThickness bumped 0 → 1 (2026-05-22) for
    ! parity with the per-app chrome rules below (narrow focus ring, not
    ! zero ring) — matches the reference look.
    Dthelpview*XmPushButtonGadget.shadowThickness:    1
    Dthelpview*XmPushButtonGadget.highlightThickness: 1
    !
    ! ============================================================
    ! Per-app dialog chrome thinning (2026-05-22)
    ! ============================================================
    ! Previous attempt used broad *XmDialogShell* rules; reverted because
    ! they also reached quickplot's dialogs, modifying the reference look
    ! we're trying to match. Re-doing as fully per-app, per-widget rules
    ! prefixed with a dt-app class (Dtcalc*, Dtterm*, Dtpad*, Dthelpview*,
    ! Dtaction*, Dtfile*) so quickplot (class Quickplot) is untouched.
    !
    ! Goal per the reference look:
    !   - 1px shadow on action buttons (thin 3D, not deep trough)
    !   - 1px focus highlight ring (visible but narrow, not zero)
    !   - 1px default-button decoration (visible but not chunky)
    !   - 1px Separator shadow (subtle divider)
    !   - 1px Frame shadow where used
    !
    ! Instance names verified against the CDE source (May 2026); see the
    ! per-section comments for the source file + line.
    !
    ! ---- Dtcalc dialogs ----
    ! Source: reference/cde/cde/programs/dtcalc/motif.c, help.c.
    ! Instance names: rframe (Memory Registers, motif.c:483),
    ! frframe (Financial Registers, motif.c:566), cfframe
    ! (Constant/Function entry, motif.c:1170), aframe (ASCII entry,
    ! motif.c:2545), "continue" (Info dialog — note: NOT "notice"; that's
    ! just the C variable name X->notice; the instance name passed to
    ! XmCreateInformationDialog at motif.c:1423/1457 is "continue"),
    ! ErroNotice (Error dialog, help.c:505), helpDlg (Help dialog,
    ! help.c:85/443/473).
    Dtcalc*rframe*XmPushButton.shadowThickness:                 1
    Dtcalc*rframe*XmPushButton.highlightThickness:              1
    Dtcalc*rframe*XmPushButton.defaultButtonShadowThickness:    1
    Dtcalc*rframe*XmPushButtonGadget.shadowThickness:           1
    Dtcalc*rframe*XmPushButtonGadget.highlightThickness:        1
    Dtcalc*rframe*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*rframe*XmSeparator.shadowThickness:                  1
    Dtcalc*rframe*XmSeparatorGadget.shadowThickness:            1
    Dtcalc*frframe*XmPushButton.shadowThickness:                1
    Dtcalc*frframe*XmPushButton.highlightThickness:             1
    Dtcalc*frframe*XmPushButton.defaultButtonShadowThickness:   1
    Dtcalc*frframe*XmPushButtonGadget.shadowThickness:          1
    Dtcalc*frframe*XmPushButtonGadget.highlightThickness:       1
    Dtcalc*frframe*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*frframe*XmSeparator.shadowThickness:                 1
    Dtcalc*frframe*XmSeparatorGadget.shadowThickness:           1
    Dtcalc*cfframe*XmPushButton.shadowThickness:                1
    Dtcalc*cfframe*XmPushButton.highlightThickness:             1
    Dtcalc*cfframe*XmPushButton.defaultButtonShadowThickness:   1
    Dtcalc*cfframe*XmPushButtonGadget.shadowThickness:          1
    Dtcalc*cfframe*XmPushButtonGadget.highlightThickness:       1
    Dtcalc*cfframe*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*cfframe*XmSeparator.shadowThickness:                 1
    Dtcalc*cfframe*XmSeparatorGadget.shadowThickness:           1
    Dtcalc*aframe*XmPushButton.shadowThickness:                 1
    Dtcalc*aframe*XmPushButton.highlightThickness:              1
    Dtcalc*aframe*XmPushButton.defaultButtonShadowThickness:    1
    Dtcalc*aframe*XmPushButtonGadget.shadowThickness:           1
    Dtcalc*aframe*XmPushButtonGadget.highlightThickness:        1
    Dtcalc*aframe*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*aframe*XmSeparator.shadowThickness:                  1
    Dtcalc*aframe*XmSeparatorGadget.shadowThickness:            1
    Dtcalc*continue*XmPushButton.shadowThickness:               1
    Dtcalc*continue*XmPushButton.highlightThickness:            1
    Dtcalc*continue*XmPushButton.defaultButtonShadowThickness:  1
    Dtcalc*continue*XmPushButtonGadget.shadowThickness:         1
    Dtcalc*continue*XmPushButtonGadget.highlightThickness:      1
    Dtcalc*continue*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*continue*XmSeparator.shadowThickness:                1
    Dtcalc*continue*XmSeparatorGadget.shadowThickness:          1
    Dtcalc*ErroNotice*XmPushButton.shadowThickness:             1
    Dtcalc*ErroNotice*XmPushButton.highlightThickness:          1
    Dtcalc*ErroNotice*XmPushButton.defaultButtonShadowThickness: 1
    Dtcalc*ErroNotice*XmPushButtonGadget.shadowThickness:       1
    Dtcalc*ErroNotice*XmPushButtonGadget.highlightThickness:    1
    Dtcalc*ErroNotice*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*ErroNotice*XmSeparator.shadowThickness:              1
    Dtcalc*ErroNotice*XmSeparatorGadget.shadowThickness:        1
    Dtcalc*helpDlg*XmPushButton.shadowThickness:                1
    Dtcalc*helpDlg*XmPushButton.highlightThickness:             1
    Dtcalc*helpDlg*XmPushButton.defaultButtonShadowThickness:   1
    Dtcalc*helpDlg*XmPushButtonGadget.shadowThickness:          1
    Dtcalc*helpDlg*XmPushButtonGadget.highlightThickness:       1
    Dtcalc*helpDlg*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtcalc*helpDlg*XmSeparator.shadowThickness:                 1
    Dtcalc*helpDlg*XmSeparatorGadget.shadowThickness:           1
    !
    ! ---- Dtterm dialogs ----
    ! Source: reference/cde/cde/lib/DtTerm/TermView/*, programs/dtterm/*.
    ! Instance names: terminal (Terminal Options, TermViewTerminalDialog.c:358),
    ! global (Global Options, TermViewGlobalDialog.c:656), helpDialog
    ! (Help, TermView.c:2016/2050 — used for both quick + full help),
    ! termWarning (TermPrim warning, TermPrim.c:3653), IconEditorError
    ! (sunDtTermServer.c:375).
    ! The Terminal/Global option dialogs heavily use XmFrame to group
    ! settings (KbdControlFrame, ScreenControlFrame, cursorFrame,
    ! backgroundFrame, scrollFrame, bellFrame) and XmToggleButtonGadget
    ! for option toggles.
    Dtterm*terminal*XmPushButton.shadowThickness:               1
    Dtterm*terminal*XmPushButton.highlightThickness:            1
    Dtterm*terminal*XmPushButton.defaultButtonShadowThickness:  1
    Dtterm*terminal*XmPushButtonGadget.shadowThickness:         1
    Dtterm*terminal*XmPushButtonGadget.highlightThickness:      1
    Dtterm*terminal*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtterm*terminal*XmToggleButton.shadowThickness:             1
    Dtterm*terminal*XmToggleButton.highlightThickness:          1
    Dtterm*terminal*XmToggleButtonGadget.shadowThickness:       1
    Dtterm*terminal*XmToggleButtonGadget.highlightThickness:    1
    Dtterm*terminal*XmSeparator.shadowThickness:                1
    Dtterm*terminal*XmSeparatorGadget.shadowThickness:          1
    Dtterm*terminal*XmFrame.shadowThickness:                    1
    Dtterm*global*XmPushButton.shadowThickness:                 1
    Dtterm*global*XmPushButton.highlightThickness:              1
    Dtterm*global*XmPushButton.defaultButtonShadowThickness:    1
    Dtterm*global*XmPushButtonGadget.shadowThickness:           1
    Dtterm*global*XmPushButtonGadget.highlightThickness:        1
    Dtterm*global*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtterm*global*XmToggleButton.shadowThickness:               1
    Dtterm*global*XmToggleButton.highlightThickness:            1
    Dtterm*global*XmToggleButtonGadget.shadowThickness:         1
    Dtterm*global*XmToggleButtonGadget.highlightThickness:      1
    Dtterm*global*XmSeparator.shadowThickness:                  1
    Dtterm*global*XmSeparatorGadget.shadowThickness:            1
    Dtterm*global*XmFrame.shadowThickness:                      1
    Dtterm*helpDialog*XmPushButton.shadowThickness:             1
    Dtterm*helpDialog*XmPushButton.highlightThickness:          1
    Dtterm*helpDialog*XmPushButton.defaultButtonShadowThickness: 1
    Dtterm*helpDialog*XmPushButtonGadget.shadowThickness:       1
    Dtterm*helpDialog*XmPushButtonGadget.highlightThickness:    1
    Dtterm*helpDialog*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtterm*helpDialog*XmSeparator.shadowThickness:              1
    Dtterm*helpDialog*XmSeparatorGadget.shadowThickness:        1
    Dtterm*termWarning*XmPushButton.shadowThickness:            1
    Dtterm*termWarning*XmPushButton.highlightThickness:         1
    Dtterm*termWarning*XmPushButton.defaultButtonShadowThickness: 1
    Dtterm*termWarning*XmPushButtonGadget.shadowThickness:      1
    Dtterm*termWarning*XmPushButtonGadget.highlightThickness:   1
    Dtterm*termWarning*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtterm*termWarning*XmSeparator.shadowThickness:             1
    Dtterm*termWarning*XmSeparatorGadget.shadowThickness:       1
    Dtterm*IconEditorError*XmPushButton.shadowThickness:        1
    Dtterm*IconEditorError*XmPushButton.highlightThickness:     1
    Dtterm*IconEditorError*XmPushButton.defaultButtonShadowThickness: 1
    Dtterm*IconEditorError*XmPushButtonGadget.shadowThickness:  1
    Dtterm*IconEditorError*XmPushButtonGadget.highlightThickness: 1
    Dtterm*IconEditorError*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtterm*IconEditorError*XmSeparator.shadowThickness:         1
    Dtterm*IconEditorError*XmSeparatorGadget.shadowThickness:   1
    !
    ! ---- Dtpad dialogs ----
    ! Source: reference/cde/cde/programs/dtpad/fileDlg.c, helpDlg.c,
    ! printSetup.c; reference/cde/cde/lib/DtWidget/SearchDlg.c, Editor.c.
    ! Instance names: Warn (both alrdy_exist and gen_warning use the
    ! instance name "Warn" — fileDlg.c:117, 781), save_dialog (SaveAs
    ! FileSelectionDialog — NOT "saveAs_form"; that's the C variable.
    ! fileDlg.c:345-346 passes "save_dialog" to XmCreateFileSelectionDialog),
    ! file_sel_dlg (open FileSelectionDialog, fileDlg.c:574-575),
    ! save_warn (PromptDialog, fileDlg.c:648), ad_dial (DtEditor format
    ! settings — NOT "formatDialog"; Editor.c:7220-7221 passes "ad_dial"
    ! to XmCreateFormDialog. "formatDialog" is only a help-topic ID),
    ! findDlg (DtEditor find/replace — NOT "searchDialog"; SearchDlg.c:304-305
    ! passes "findDlg" to XmCreateFormDialog), DtPrintSetup
    ! (printSetup.c:945), helpDlg (helpDlg.c:151).
    Dtpad*Warn*XmPushButton.shadowThickness:                    1
    Dtpad*Warn*XmPushButton.highlightThickness:                 1
    Dtpad*Warn*XmPushButton.defaultButtonShadowThickness:       1
    Dtpad*Warn*XmPushButtonGadget.shadowThickness:              1
    Dtpad*Warn*XmPushButtonGadget.highlightThickness:           1
    Dtpad*Warn*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*Warn*XmSeparator.shadowThickness:                     1
    Dtpad*Warn*XmSeparatorGadget.shadowThickness:               1
    Dtpad*save_dialog*XmPushButton.shadowThickness:             1
    Dtpad*save_dialog*XmPushButton.highlightThickness:          1
    Dtpad*save_dialog*XmPushButton.defaultButtonShadowThickness: 1
    Dtpad*save_dialog*XmPushButtonGadget.shadowThickness:       1
    Dtpad*save_dialog*XmPushButtonGadget.highlightThickness:    1
    Dtpad*save_dialog*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*save_dialog*XmSeparator.shadowThickness:              1
    Dtpad*save_dialog*XmSeparatorGadget.shadowThickness:        1
    Dtpad*file_sel_dlg*XmPushButton.shadowThickness:            1
    Dtpad*file_sel_dlg*XmPushButton.highlightThickness:         1
    Dtpad*file_sel_dlg*XmPushButton.defaultButtonShadowThickness: 1
    Dtpad*file_sel_dlg*XmPushButtonGadget.shadowThickness:      1
    Dtpad*file_sel_dlg*XmPushButtonGadget.highlightThickness:   1
    Dtpad*file_sel_dlg*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*file_sel_dlg*XmSeparator.shadowThickness:             1
    Dtpad*file_sel_dlg*XmSeparatorGadget.shadowThickness:       1
    Dtpad*save_warn*XmPushButton.shadowThickness:               1
    Dtpad*save_warn*XmPushButton.highlightThickness:            1
    Dtpad*save_warn*XmPushButton.defaultButtonShadowThickness:  1
    Dtpad*save_warn*XmPushButtonGadget.shadowThickness:         1
    Dtpad*save_warn*XmPushButtonGadget.highlightThickness:      1
    Dtpad*save_warn*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*save_warn*XmSeparator.shadowThickness:                1
    Dtpad*save_warn*XmSeparatorGadget.shadowThickness:          1
    ! save_warn is a PromptDialog (XmSelectionBox flavor), not an
    ! XmMessageBox — dtpad creates it via XmCreatePromptDialog
    ! (cde/cde/programs/dtpad/fileDlg.c:648). The four logical answers
    ! map onto SelectionBox slots: Yes→OK, No→Apply, Cancel→Cancel,
    ! Help→Help (fileDlg.c:631-643). Button widgets are PushButtonGadgets
    ! literally named "OK"/"Apply"/"Cancel"/"Help" — case-sensitive,
    ! capitalized (SelectioB.c:942/959/978/994 via _XmBB_CreateButtonG →
    ! BBUtil.c:131). Same Blue+italic Helvetica look as the rest of dtpad.
    Dtpad*save_warn*XmPushButton.foreground:         Blue
    Dtpad*save_warn*XmPushButton.fontList:           -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    Dtpad*save_warn*XmPushButtonGadget.foreground:   Blue
    Dtpad*save_warn*XmPushButtonGadget.fontList:     -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    Dtpad*save_warn*OK.foreground:      Blue
    Dtpad*save_warn*Apply.foreground:   Blue
    Dtpad*save_warn*Cancel.foreground:  Blue
    Dtpad*save_warn*Help.foreground:    Blue
    ! Belt-and-suspenders for any other Dtpad SelectionBox / MessageBox
    ! dialogs (covers Warn, which is a real XmMessageBox at fileDlg.c:117).
    Dtpad*XmSelectionBox*XmPushButtonGadget.foreground:  Blue
    Dtpad*XmSelectionBox*XmPushButtonGadget.fontList:    -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    Dtpad*XmMessageBox*XmPushButtonGadget.foreground:    Blue
    Dtpad*XmMessageBox*XmPushButtonGadget.fontList:      -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    Dtpad*ad_dial*XmPushButton.shadowThickness:                 1
    Dtpad*ad_dial*XmPushButton.highlightThickness:              1
    Dtpad*ad_dial*XmPushButton.defaultButtonShadowThickness:    1
    Dtpad*ad_dial*XmPushButtonGadget.shadowThickness:           1
    Dtpad*ad_dial*XmPushButtonGadget.highlightThickness:        1
    Dtpad*ad_dial*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*ad_dial*XmToggleButton.shadowThickness:               1
    Dtpad*ad_dial*XmToggleButton.highlightThickness:            1
    Dtpad*ad_dial*XmToggleButtonGadget.shadowThickness:         1
    Dtpad*ad_dial*XmToggleButtonGadget.highlightThickness:      1
    Dtpad*ad_dial*XmSeparator.shadowThickness:                  1
    Dtpad*ad_dial*XmSeparatorGadget.shadowThickness:            1
    Dtpad*ad_dial*XmFrame.shadowThickness:                      1
    Dtpad*findDlg*XmPushButton.shadowThickness:                 1
    Dtpad*findDlg*XmPushButton.highlightThickness:              1
    Dtpad*findDlg*XmPushButton.defaultButtonShadowThickness:    1
    Dtpad*findDlg*XmPushButtonGadget.shadowThickness:           1
    Dtpad*findDlg*XmPushButtonGadget.highlightThickness:        1
    Dtpad*findDlg*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*findDlg*XmToggleButton.shadowThickness:               1
    Dtpad*findDlg*XmToggleButton.highlightThickness:            1
    Dtpad*findDlg*XmToggleButtonGadget.shadowThickness:         1
    Dtpad*findDlg*XmToggleButtonGadget.highlightThickness:      1
    Dtpad*findDlg*XmSeparator.shadowThickness:                  1
    Dtpad*findDlg*XmSeparatorGadget.shadowThickness:            1
    Dtpad*DtPrintSetup*XmPushButton.shadowThickness:            1
    Dtpad*DtPrintSetup*XmPushButton.highlightThickness:         1
    Dtpad*DtPrintSetup*XmPushButton.defaultButtonShadowThickness: 1
    Dtpad*DtPrintSetup*XmPushButtonGadget.shadowThickness:      1
    Dtpad*DtPrintSetup*XmPushButtonGadget.highlightThickness:   1
    Dtpad*DtPrintSetup*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*DtPrintSetup*XmSeparator.shadowThickness:             1
    Dtpad*DtPrintSetup*XmSeparatorGadget.shadowThickness:       1
    Dtpad*DtPrintSetup*XmFrame.shadowThickness:                 1
    Dtpad*helpDlg*XmPushButton.shadowThickness:                 1
    Dtpad*helpDlg*XmPushButton.highlightThickness:              1
    Dtpad*helpDlg*XmPushButton.defaultButtonShadowThickness:    1
    Dtpad*helpDlg*XmPushButtonGadget.shadowThickness:           1
    Dtpad*helpDlg*XmPushButtonGadget.highlightThickness:        1
    Dtpad*helpDlg*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtpad*helpDlg*XmSeparator.shadowThickness:                  1
    Dtpad*helpDlg*XmSeparatorGadget.shadowThickness:            1
    !
    ! ---- Dthelpview dialogs ----
    ! Source: reference/cde/cde/programs/dthelp/dthelpview/{Util.c, ManPage.c}.
    ! Instance names: manBox (DtHelpQuickDialog, Util.c:595),
    ! fileBox (DtHelpQuickDialog, Util.c:510),
    ! helpWidget (DtHelpDialog, Util.c:350),
    ! manWidget (XmCreateDialogShell wrapping manForm + manBtn + closeBtn,
    ! ManPage.c:165). Note: the existing Dthelpview*XmPushButtonGadget
    ! .shadowThickness:1 / .highlightThickness:1 (above) already covers
    ! the action buttons across these dialogs; the per-dialog rules below
    ! pick up Separators / Frames / widget-class (non-gadget) variants
    ! plus defaultButtonShadowThickness.
    Dthelpview*manBox*XmPushButton.shadowThickness:             1
    Dthelpview*manBox*XmPushButton.highlightThickness:          1
    Dthelpview*manBox*XmPushButton.defaultButtonShadowThickness: 1
    Dthelpview*manBox*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dthelpview*manBox*XmSeparator.shadowThickness:              1
    Dthelpview*manBox*XmSeparatorGadget.shadowThickness:        1
    Dthelpview*fileBox*XmPushButton.shadowThickness:            1
    Dthelpview*fileBox*XmPushButton.highlightThickness:         1
    Dthelpview*fileBox*XmPushButton.defaultButtonShadowThickness: 1
    Dthelpview*fileBox*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dthelpview*fileBox*XmSeparator.shadowThickness:             1
    Dthelpview*fileBox*XmSeparatorGadget.shadowThickness:       1
    Dthelpview*helpWidget*XmPushButton.shadowThickness:         1
    Dthelpview*helpWidget*XmPushButton.highlightThickness:      1
    Dthelpview*helpWidget*XmPushButton.defaultButtonShadowThickness: 1
    Dthelpview*helpWidget*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dthelpview*helpWidget*XmSeparator.shadowThickness:          1
    Dthelpview*helpWidget*XmSeparatorGadget.shadowThickness:    1
    Dthelpview*manWidget*XmPushButton.shadowThickness:          1
    Dthelpview*manWidget*XmPushButton.highlightThickness:       1
    Dthelpview*manWidget*XmPushButton.defaultButtonShadowThickness: 1
    Dthelpview*manWidget*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dthelpview*manWidget*XmSeparator.shadowThickness:           1
    Dthelpview*manWidget*XmSeparatorGadget.shadowThickness:     1
    !
    ! ---- Dtaction dialogs ----
    ! Source: reference/cde/cde/programs/dtaction/Main.c.
    ! Instance names: err (XmCreateErrorDialog, Main.c:796 + Main.c:1199 —
    ! two creation sites, both use the same "err" instance name),
    ! prompt (XmCreatePromptDialog for password prompt, Main.c:916).
    Dtaction*err*XmPushButton.shadowThickness:                  1
    Dtaction*err*XmPushButton.highlightThickness:               1
    Dtaction*err*XmPushButton.defaultButtonShadowThickness:     1
    Dtaction*err*XmPushButtonGadget.shadowThickness:            1
    Dtaction*err*XmPushButtonGadget.highlightThickness:         1
    Dtaction*err*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtaction*err*XmSeparator.shadowThickness:                   1
    Dtaction*err*XmSeparatorGadget.shadowThickness:             1
    Dtaction*prompt*XmPushButton.shadowThickness:               1
    Dtaction*prompt*XmPushButton.highlightThickness:            1
    Dtaction*prompt*XmPushButton.defaultButtonShadowThickness:  1
    Dtaction*prompt*XmPushButtonGadget.shadowThickness:         1
    Dtaction*prompt*XmPushButtonGadget.highlightThickness:      1
    Dtaction*prompt*XmPushButtonGadget.defaultButtonShadowThickness: 1
    Dtaction*prompt*XmSeparator.shadowThickness:                1
    Dtaction*prompt*XmSeparatorGadget.shadowThickness:          1
    !
    ! ---- Dtfile (universal app-scoped rules) ----
    ! dtfile has many dialogs across Help.c, HelpCB.c, Main.c, ModAttr.c,
    ! ChangeDir.c, Prefs.c, FileDialog.c, Filter.c, Find.c, OverWrite.c,
    ! FileMgr.c, MultiView.c, Desktop.c. Per-dialog enumeration would
    ! double the size of this file with diminishing returns. Use
    ! Dtfile-scoped class rules: still per-app (no spillover to
    ! quickplot, class Quickplot), just less granular than the others.
    Dtfile*XmPushButton.shadowThickness:                        1
    Dtfile*XmPushButton.highlightThickness:                     1
    Dtfile*XmPushButton.defaultButtonShadowThickness:           1
    Dtfile*XmPushButtonGadget.shadowThickness:                  1
    Dtfile*XmPushButtonGadget.highlightThickness:               1
    Dtfile*XmPushButtonGadget.defaultButtonShadowThickness:     1
    Dtfile*XmToggleButton.shadowThickness:                      1
    Dtfile*XmToggleButton.highlightThickness:                   1
    Dtfile*XmToggleButtonGadget.shadowThickness:                1
    Dtfile*XmToggleButtonGadget.highlightThickness:             1
    Dtfile*XmSeparator.shadowThickness:                         1
    Dtfile*XmSeparatorGadget.shadowThickness:                   1
    Dtfile*XmFrame.shadowThickness:                             1
    """
}
