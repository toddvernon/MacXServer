# Post 8: Live xcalc, Athena widgets, multi-client

**Date range**: May 8, 2026
**One-line elevator**: xcalc renders from a real Sun. Athena widget toolkit, PolyText8 for button labels, AllocNamedColor with X11R6 rgb.txt embedded, mouse clicks updating the LCD. Multi-client server. Per-session log files. The same day Mac-side gains a proper app shell with menu bar and Preferences.

## What this post covers

The shift from "xterm works" to "real GUI apps with widgets work." xcalc's Athena toolkit. The X color database. Mouse input. Enter/Leave for hover. The multi-client protocol coordinator. The Mac-side app shell.

## Setting

xterm works. Color, scrollback, resize, keyboard, copy-to-Mac. xclock works. xterm and xclock are toolkit-free (raw Xlib). The next obvious step is something that uses a widget toolkit.

xcalc is the canonical Athena app. Buttons, labels, a small LCD readout. Old enough to be pure X11R6 with no extensions. Tests our handling of PolyText8 (text drawing on a non-bg-fill GC), AllocNamedColor (named colors like "gray70"), CWBackPixel for window backgrounds, Expose-on-ClearArea for the LCD redraw pattern.

## Live xcalc shipped

Commit `947296b` 2026-05-08: "Live xcalc from u5: window bg/borders, PolyText8, AllocNamedColor, mouse." The first GUI app with proper widgets running through swift-x.

What this required:
- Window background/border painting from CreateWindow's CWBackPixel and CWBorderPixel
- PolyText8 with CTFont actual-advance positioning (to avoid metrics-drift gaps between glyphs)
- AllocNamedColor with the full X11R6 rgb.txt database embedded as data
- ButtonPress/ButtonRelease event plumbing from FlippedXView to the X protocol
- Expose-on-ClearArea(exposures=1): xcalc's LCD redraw pattern is "ClearArea → wait for Expose → PolyText8 the new value." Without emitting Expose on ClearArea, the LCD never repaints.
- Expose-on-mapDescendant: when xcalc maps its inner LCD window after the top-level is already mapped, we have to emit Expose on the descendant.

## The X11R6 rgb.txt

`AllocNamedColor` takes a name like "gray70" or "papaya whip" and returns a pixel value plus the RGB triplet that name resolves to. The mapping lives in `/usr/X11R6/lib/rgb.txt` on a real X server, with about 750 named colors.

We don't have `/usr/X11R6` on macOS, so the database is embedded as static data in `XColorDatabase.swift`. Compiled in at build time from the canonical X11R6 rgb.txt. ~30KB.

Unknown names fall back to black with a logged warning. Real X servers emit `BadName` errors; we don't emit XErrors yet (a known gap in SHORTCUTS.md since M3) so we substitute black to keep clients moving.

## Athena widget click handling

Athena's Command (button) widget responds to ButtonPress/ButtonRelease for the click and to EnterNotify/LeaveNotify for hover highlight. Both event chains had to be wired.

Commit `bee1010` 2026-05-09: "EnterNotify / LeaveNotify + PolyRectangle for Athena hover highlight." xcalc buttons now highlight on hover with a 2-pixel border, and depress on click. The PolyRectangle implementation was a small detour. xcalc uses it to stroke the hover-highlight outline, and we hadn't implemented stroked-rect drawing yet.

## Cut and paste both directions

Commit `b60ae9b` 2026-05-08 (color xterm + Cmd-V paste) and `1c31714` 2026-05-08 ("Cut to clipboard: copy roundtrip, Preferences window, MotionNotify drag"). PRIMARY selection roundtrips between X and NSPasteboard.

Outbound (X to Mac): xterm SetSelectionOwner on PRIMARY when text is selected. On Cmd-C, the session SelectionRequests STRING into a server pseudo-window, intercepts the ChangeProperty, pushes the bytes to NSPasteboard.

Inbound (Mac to X): on Cmd-V, the server fakes a Paste-on-X-side by reading NSPasteboard and synthesizing the SelectionRequest/SelectionNotify chain.

Limits: PRIMARY only (no CLIPBOARD), STRING only (no UTF8_STRING or COMPOUND_TEXT), no INCR (large selections don't transfer). Two trigger modes in Preferences: Mac behavior (autocopy on selection) vs Xterm behavior (Cmd-C explicit).

## Real Mac app shell

Commit `3f4d984` 2026-05-08: "Multi-client server with per-session logs identified by WM_CLASS." The same day, the server gained a proper Mac app structure:

- `setActivationPolicy(.regular)` for the top menu bar (with the cost of a Dock icon. Info.plist LSUIElement would suppress that, deferred per SHORTCUTS.md)
- Status item shows the resolved IP (so you know what `xterm -display` argument to use)
- Tabbed Preferences window persisting via UserDefaults

## Multi-client server

`Listener.runAccepting` handles multiple concurrent connections. `ServerCoordinator` owns cross-session state (atoms global per server, selection ownership). Per-session state (windows, GCs, properties on those windows, fonts, pixmaps, colors) stays per-session.

Each session gets a `FileLogSink` writing to `~/Library/Logs/swiftx-server/`. Once `WM_CLASS` arrives from the client (the instance, like "xterm" or "xcalc"), the log file gets renamed to `<instance>-<timestamp>.log`. The NSWindow title also gets prefixed with the instance: `[xterm] My Terminal` instead of just `My Terminal`.

## Pivotal moment

The first xcalc session: type a digit, press +, type another digit, press =, see the result on the LCD. Click hover-highlights working. A working Athena widget app on the Mac, looking like a Mac app, but running a 1996-era widget toolkit unmodified.

## What Todd should add

- The "this is a real GUI app now" moment.
- The X11R6 rgb.txt detour. Why embed instead of link to a file? How big is the data? Was the lookup pleasant or annoying to write?
- The cut/paste UX. Mac users have a different expectation than Xterm users (Cmd-C vs middle-click-paste). The Preferences toggle came out of that.
- The multi-client decision. When did you realize multi-client mattered? What does "two xterms at once" feel like vs "one at a time"?
- The status-item IP-resolution choice. Small UX win.

## Anchors for fact-check pass

- Files: `Sources/SwiftXServerCore/XColorDatabase.swift` (the rgb.txt embed), `Sources/SwiftXServerCore/ServerCoordinator.swift`, `Sources/SwiftXServerCore/Listener.swift`, `Sources/SwiftXServerCore/FileLogSink.swift`, `Sources/SwiftXServerCore/ClipboardPreferencesProvider.swift` (or similar)
- Commits: `947296b` 2026-05-08 live xcalc, `bee1010` 2026-05-09 EnterNotify/LeaveNotify + PolyRectangle, `b60ae9b` 2026-05-08 color xterm + Cmd-V, `1c31714` 2026-05-08 Cut to clipboard + Preferences, `3f4d984` 2026-05-08 multi-client + per-session logs
- The Preferences window: tabs, UserDefaults persistence, two trigger modes for clipboard
- PRIMARY selection wire path: SetSelectionOwner → ConvertSelection → SelectionRequest → ChangeProperty → SelectionNotify
- SHORTCUTS open: Dock icon, no LSUIElement; CLIPBOARD atom not wired; UTF8_STRING not handled; INCR not implemented

## Working title alternatives

- "xcalc on a Mac"
- "Athena widgets, native chrome"
- "Day three: a real GUI"
