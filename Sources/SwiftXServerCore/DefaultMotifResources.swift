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
    /// duplicating content.
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
    ! Dialog labels (labels and label gadgets inside popup dialog shells)
    ! get Blue text. Main-application labels stay Black (the *foreground
    ! default above) since they're not under an XmDialogShell. Button
    ! foreground rules removed 2026-05-26: Motif sets dialog-button fg/bg
    ! programmatically via XmGetColors at widget-create (XtSetArg beats
    ! Xrm), so *XmDialogShell*XmPushButton(Gadget).foreground rules
    ! never fired. Labels may or may not honor Xrm fg depending on the
    ! widget class; left in until shown otherwise.
    *XmDialogShell*XmLabel.foreground:             Blue
    *XmDialogShell*XmLabelGadget.foreground:       Blue
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
    !
    ! ---- Per-app overrides ----
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
    ! Close/Backtrack/Print action buttons. Use the smaller oblique
    ! Helvetica 12pt for these to match the reference look.
    Dthelpview*XmPushButton.fontList:          -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    Dthelpview*XmPushButtonGadget.fontList:    -adobe-helvetica-medium-o-normal--12-*-*-*-p-*-iso8859-1
    !
    ! ============================================================
    ! Composite chrome thinning
    ! ============================================================
    ! Single set of global Xrm rules that thin Motif's default 2px shadows
    ! down to 1px across every dt-app and quickplot. Goal:
    !
    !   - 1px shadow on action buttons (thin 3D, not deep trough)
    !   - 1px focus highlight ring (visible but narrow, not zero)
    !   - 1px Separator shadow (subtle divider)
    !   - 1px Frame shadow where used
    !
    ! Safety: this DOES reach quickplot, but Xt's XtSetArg(XmNshadow-
    ! Thickness, N) calls in quickplot's own source (about_dialog.c:178,
    ! legend_dialog.c:483, etc.) win over Xrm regardless of how specific
    ! the Xrm rule is. So quickplot's intentional 2/4 px shadows survive
    ! verbatim; the global rules only fill in widgets where the app left
    ! the value at Motif's compile-time default.
    !
    ! We also mirror what quickplot does per-button via XtSetArg
    ! (dialog.c:738-755):
    !   XmNhighlightThickness, 1   — covered below
    !   XmNborderWidth,        1   — covered below (only meaningful on the
    !                                widget-class XmPushButton; gadgets
    !                                have no X window so it's a no-op there)
    !
    ! Quickplot itself never sets shadowThickness or
    ! defaultButtonShadowThickness, so it takes Motif's compile-time
    ! defaults (shadowThickness=2, dbst=0). We override shadowThickness=1
    ! globally for the "thin 3D" look, but DELIBERATELY leave
    ! defaultButtonShadowThickness UNSET so it stays at Motif's default
    ! of 0:
    !
    !  - For quickplot (Form-based dialogs, no BulletinBoard machinery):
    !    dbst=0 → ShowAsDefault(DEFAULT_READY) never fires → no auto-
    !    inflation of highlight_thickness → the default button has NO
    !    separate ring; the 3D bevel signals "this is the default." Tight
    !    hugged look, which is what quickplot intends.
    !
    !  - For dt-apps (XmTemplateDialog / XmMessageBox / XmDialog, all
    !    BulletinBoard-derived): BulletinBoard calls ShowAsDefault on the
    !    OK button, which sets dbst > 0 and triggers
    !    AdjustHighLightThickness (PushBG.c:2857). That silently inflates
    !    highlight_thickness by Xm3D_ENHANCE_PIXEL (= 2, hardcoded
    !    #define in XmP.h:161). The resulting 2-pixel "trough" between
    !    the button bevel and the default-button ring is hardcoded in
    !    Motif's source and not removable via Xrm — confirmed by setting
    !    dbst=1 in Xrm directly (2026-06-03), which did not bypass the
    !    inflation as the source code suggested it would. We accept the
    !    trough on dt-app default buttons as a Motif-level artifact.
    *XmPushButton.shadowThickness:                    1
    *XmPushButton.highlightThickness:                 1
    *XmPushButton.borderWidth:                        1
    *XmPushButtonGadget.shadowThickness:              1
    *XmPushButtonGadget.highlightThickness:           1
    *XmToggleButton.shadowThickness:                  1
    *XmToggleButton.highlightThickness:               1
    *XmToggleButtonGadget.shadowThickness:            1
    *XmToggleButtonGadget.highlightThickness:         1
    *XmSeparator.shadowThickness:                     1
    *XmSeparatorGadget.shadowThickness:               1
    *XmFrame.shadowThickness:                         1
    """
}
