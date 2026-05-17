// Captured RESOURCE_MANAGER property bytes from u5's real CDE session.
//
// Source: dtcalc-sun.xtap seq=3 GetProperty reply, recorded 2026-05-09.
// Verified byte-identical against live u5 `xrdb -query` on 2026-05-17.
// Raw bytes are also stashed at captures/fixtures/sun_resource_manager.bin.
//
// On a real CDE session, dtsession + xrdb populate RESOURCE_MANAGER with
// this database at login. Without it, Xt-based clients (Motif, Athena)
// fall back to compiled-in defaults: Motif loads `Fixed` instead of the
// `-dt-interface ...` XLFDs the resource db specifies, widget geometry
// computes from default metrics (so dt-app dialogs end up the wrong
// size), and the client manually interns ~50 CDE atoms upfront that
// would otherwise have been inherited from CDE init.
//
// See FOLLOWUPS_FROM_DTCALC_DIFF_2026-05-17.md for the discovery trail.
//
// The trailing 0x00 byte is part of the captured property — Solaris
// terminates the STRING-typed value with NUL. Raw string `#"""..."""#`
// preserves backslashes literally (Motif Translations entries use them
// for line continuation and embed the literal two-character sequence
// `\n`). Content has no `"""#` terminator collisions.

enum CDEResourceManagerFixture {

    static let bytes: [UInt8] = {
        // Editors / formatters strip trailing whitespace. The captured
        // property has 4 bytes of trailing-or-on-blank-line whitespace that
        // get stripped from the literal below. Restore them so the bytes
        // are byte-identical to captures/fixtures/sun_resource_manager.bin
        // (matters only for clean diff output; not load-bearing for any
        // client behavior since these are dtsession + dtwm config keys).
        let restored = text
            .replacingOccurrences(of: "helpResources:\t\\n\\\n\n",
                                  with: "helpResources:\t\\n\\\n  \n")
            .replacingOccurrences(of: "cycleTimeout:\t3\n",
                                  with: "cycleTimeout:\t3 \n")
            .replacingOccurrences(of: "saverTimeout:\t15\n",
                                  with: "saverTimeout:\t15 \n")
        return Array(restored.utf8) + [0x0a, 0x00]
    }()

    private static let text = #"""
*0*ColorPalette:	Delphinium.dp
*DtEditor*textFontList:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*DtTerm*shadowThickness:	1
*Font:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*
*FontList:	-dt-interface system-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*FontSet:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*
*XmText*FontList:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*XmText*Translations:	#override\n\
        Ctrl<Key>u:delete-to-start-of-line()\n\
        Ctrl<Key>k:delete-to-end-of-line()\n\
        Ctrl<Key>a:beginning-of-line()\n\
        Ctrl<Key>e:end-of-line()\n\
        Ctrl<Key>p:process-up()\n\
        Ctrl<Key>b:backward-character()\n\
        Ctrl<Key>n:process-down()\n\
        Ctrl<Key>f:forward-character()
*XmTextField*FontList:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*XmTextField*Translations:	#override\n\
        Ctrl<Key>u:delete-to-start-of-line()\n\
        Ctrl<Key>k:delete-to-end-of-line()\n\
        Ctrl<Key>a:beginning-of-line()\n\
        Ctrl<Key>e:end-of-line()\n\
        Ctrl<Key>b:backward-character()\n\
        Ctrl<Key>f:forward-character()
*background:	#C800C800C800
*buttonFontList:	-dt-interface system-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*dtEnvMapForRemote:	DTAPPSEARCHPATH:DTHELPSEARCHPATH:DTDATABASESEARCHPATH:XMICONSEARCHPATH:XMICONBMSEARCHPATH
*enableBtn1Transfer:	button2_transfer
*enableButtonTab:	True
*enableCDEColorFactors:	True
*enableDefaultButton:	True
*enableDragIcon:	True
*enableEtchedInMenu:	True
*enableMenuInCascade:	True
*enableMultiKeyBindings:	True
*enableThinThickness:	True
*enableToggleColor:	True
*enableToggleVisual:	True
*enableUrlAwareness:	True
*fontGroup:	Default
*foreground:	#000000000000
*labelFontList:	-dt-interface system-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*multiClickTime:	500
*promptDialog.bboard.frame.form.text.columns:	45
*sessionVersion:	3.0
*systemFont:	-dt-interface system-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*textFontList:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*:
*ttyModes:	intr ^c quit ^\ erase ^h kill ^u eof ^d start ^q stop ^s susp ^z dsusp ^y rprnt ^r flush ^o weras ^w lnext ^v
*userFont:	-dt-interface user-medium-r-normal-s*-*-*-*-*-*-*-*-*:
Dtwm*0*FrontPanel*geometry:	-125-0
Dtwm*0*helpResources:	\n\

Dtwm*0*initialWorkspace:	ws0
Dtwm*0*workspaceCount:	4
Dtwm*0*ws0*backdrop*image:	Background
Dtwm*useFrontPanel:	false
OpenWindows.BasicLocale:	C
OpenWindows.Beep:	always
OpenWindows.BeepDuration:	100
OpenWindows.DataBackground:	#FF00FF00E600
OpenWindows.DataForeground:	#000000000000
OpenWindows.DisplayLang:	C
OpenWindows.DragRightDistance:	100
OpenWindows.IconLocation:	bottom
OpenWindows.InputLang:	C
OpenWindows.KeyClick:	False
OpenWindows.KeyRepeat:	True
OpenWindows.KeyboardCommands:	Basic
OpenWindows.MenuAccelerators:	True
OpenWindows.MouseAcceleration:	2
OpenWindows.MouseThreshold:	15
OpenWindows.MultiClickTimeout:	4
OpenWindows.NumericFormat:	C
OpenWindows.PaintWorkspace:	True
OpenWindows.PointerMapping:	right
OpenWindows.PopupJumpCursor:	True
OpenWindows.Scale:	medium
OpenWindows.ScreenSaver.IdleTime:	10
OpenWindows.ScreenSaver.OnOff:	off
OpenWindows.ScrollbarJumpCursor:	True
OpenWindows.ScrollbarPlacement:	right
OpenWindows.SelectDisplaysMenu:	True
OpenWindows.SetInput:	select
OpenWindows.TimeFormat:	C
OpenWindows.WindowColor:	#C800C800C800
OpenWindows.WindowForeground:	#000000000000
OpenWindows.WindowMenuAccelerators:	True
OpenWindows.WorkspaceBitmapBg:	#ffffff
OpenWindows.WorkspaceBitmapFg:	#000000
OpenWindows.WorkspaceBitmapFile:	gray
OpenWindows.WorkspaceColor:	#C800C800C800
OpenWindows.WorkspaceStyle:	paintcolor
Scrollbar.JumpCursor:	True
Window.Color.Background:	#FF00FF00E600
Window.Color.Foreground:	#000000000000
dtsession*cycleTimeout:	3
dtsession*displayResolution:	3543
dtsession*lockTimeout:	30
dtsession*saverList:	StartDtscreenBlank
dtsession*saverTimeout:	15
dtsession*sessionLanguage:	C
"""#
}
