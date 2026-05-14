# Post 8: Papaya whip, cornflower blue, gainsboro

**Date range**: May 8, 2026 **One-line elevator**: An X11 client from 1995 asks the 2026 Swift X server
for "papaya whip" and gets back a 16-bit RGB triplet that has not changed since 1989. Plus xcalc works,
multi-client lands, and the development loop gets noticeably faster.

## What this post covers

The X11 named-color database, embedded inside the swift-x binary in 2026, answering color queries from
clients built thirty years earlier. xcalc on Athena widgets as the test case that needed it. Multi-client
support as the development-velocity unlock that came the same day.

## Setting

xterm works. xclock works. Both are toolkit-free, written directly against Xlib. The next obvious step
was something with widgets. xcalc is the canonical Athena demo: buttons in a form layout, an LCD readout
at the top, click a digit and a math operator and equals. Old enough to predate every extension we don't
support.

When I pointed xcalc at the swift-x server, it sent two requests near the start of init that I hadn't
seen before. One asked for the color "gray70." The other asked for "MediumAquamarine."

## The X11R6 rgb.txt

X11 has had a database of named colors since basically the beginning. On a real X server it lives at
`/usr/X11R6/lib/rgb.txt` (or `/usr/openwin/lib/X11/rgb.txt` on a Sun). It's a flat text file with one
color per line: three 8-bit RGB integers, a tab, and a name. About 750 entries. The format hasn't
meaningfully changed since X11R3 in 1989.

```
220 220 220	gainsboro
255 239 213	papaya whip
100 149 237	cornflower blue
179 179 179	gray70
255 222 173	navajowhite
```

The reason it exists is the same reason most of X11 exists: network transparency. A client written in
1989 against Xlib can call `XAllocNamedColor(display, cmap, "navajowhite")` and get back a usable pixel
on whatever the server's color table looks like. Reds are computed server-side at allocation time. The
file lived next to the X server because the lookup had to happen on the server's machine, not the
client's. A different vendor's server might have a slightly different rgb.txt with extra entries, but
the canonical names were universal.

When xcalc on a Sun calls `AllocNamedColor("gray70")`, what goes over the wire is the literal byte
string "gray70" in the request payload. The server has to look it up. We don't have
`/usr/X11R6/lib/rgb.txt` on macOS, and I didn't want to ship a separate data file alongside the binary.
So the database is embedded as static Swift data in `XColorDatabase.swift`, generated at build time from
`reference/X11R6/xc/programs/rgb/rgb.txt`. 752 entries, about 30KB of source, compiled in.

The lookup matches the historical X11 behavior, which is more forgiving than you'd guess. Case-
insensitive: "Gray70", "gray70", "GRAY70" all resolve. Whitespace-insensitive: "papaya whip",
"PapayaWhip", and "papayawhip" all hit the same entry. The 8-bit RGB values from the file get
replicated to 16-bit per X11 convention (`0xDC` becomes `0xDCDC`), matching what real X servers have
always done for `AllocNamedColor`.

There's also the hex-spec form, which I'd forgotten about until xcalc tripped it. Clients can pass
`"#F00"`, `"#FF0000"`, `"#FFF000000"`, or `"#FFFF00000000"` and the server is supposed to parse them
to RGB triplets with the right bit-shift rules: each digit shifted to the high-order 16 bits for `#RGB`,
each pair for `#RRGGBB`, each triple shifted left by 4 for `#RRRGGGBBB`, and the 4-digit form already
16-bit. These rules are in `libX11/src/ParseCol.c` and they are not in the X protocol spec because
they're a client-side convention that the server happens to honor. Cargo-culted onto every X server
since forever. We do them too.

## The surreal moment

A few days into this work I was setting xterm's foreground and background by passing color arguments on
the command line. The Xlib clients on the Sun have a parser for those arguments, and I'd assumed I
needed to pass standard X color names. I tried something like `-fg "papaya whip"` and got back an
unhappy xterm.

Claude suggested I try `-fg "#FFEFD5"` (the RGB triplet for papaya whip) instead. I knew the xterm
build on the SS2 had no support for hex specs in command-line arguments. The argument parser would just
pass the literal string `#FFEFD5` through to `AllocNamedColor` as a name. I tried it anyway. It worked.

The client did exactly what I expected — it passed the bytes through naively, thinking they were a
color name. The server recognized `#` as the hex-spec prefix per the 1989 convention, parsed the six
hex digits, and answered with the right RGB. xterm displayed the right color. The whole chain worked
because the protocol-level fallback that nobody on the Sun cared about for thirty years happened to be
exactly the right behavior for this case.

That's the kind of moment that keeps you going on a project like this. A 1995 binary, a 2026 server,
a hex spec from a 1989 client-side library that neither side knew the other side knew about, and it
all just resolved correctly because the X protocol has been holding still long enough.

Unknown names fall back to black with a logged warning. Real X servers emit `BadName` errors for that
case. We don't emit X errors yet (a SHORTCUTS.md gap from M3 onward) so we substitute black and keep
the client moving. That's a real shortcut and it will bite us eventually.

## What xcalc actually needed

The rgb.txt embed was the part that delighted me. The rest of getting xcalc working was workmanlike.
Commit `947296b` 2026-05-08: window background and border painting from `CreateWindow`'s `CWBackPixel`
and `CWBorderPixel` value-mask bits, `PolyText8` for the button labels with CTFont actual-advance
positioning to avoid metrics-drift gaps between glyphs, button event plumbing from `FlippedXView` to the
X protocol, Expose-on-ClearArea for the LCD's redraw cycle, and Expose on newly-mapped descendants for
inner LCD windows that mapped after their parent.

The Athena Command widget's hover highlight came the next day (commit `bee1010` 2026-05-09):
EnterNotify and LeaveNotify events for hover, plus `PolyRectangle` for the 2-pixel highlight border
that Athena strokes around the focused button. PolyRectangle was a small detour. We hadn't done
stroked rectangles yet because xterm and xclock didn't need them; xcalc did.

The first xcalc session: digit, plus, digit, equals, the LCD shows the right answer. Hover highlights
work. The buttons depress on click. It looks like xcalc. A 1996-era Athena widget app running
unmodified on a Mac in 2026.

## Multi-client: the velocity unlock

Same day, the server became multi-client. Commit `3f4d984` 2026-05-08: "Multi-client server with
per-session logs identified by WM_CLASS."

`Listener.runAccepting` now handles concurrent connections instead of one at a time. `ServerCoordinator`
owns the cross-session state (atoms are global per server, selection ownership is global). Per-session
state stays per-session: windows, GCs, properties on those windows, fonts, pixmaps, colors. Two xterms
running side by side are now genuinely two clients with two private resource tables.

The development-velocity story is more interesting than the code change. Before this commit, testing
the server meant: kill any existing session, restart `swiftx-server`, launch one client from the Sun,
trip whatever was being debugged, kill the client, repeat. Iteration cycle measured in tens of seconds
per loop, with the cognitive overhead of knowing which run produced which log.

After the commit, I could leave swiftx-server running, boot xterm and xcalc and xclock and xeyes all
at once, see them as separate NSWindows on the Mac, and find the relevant log file by name. Each
session writes to `~/Library/Logs/swiftx-server/`. The instant `WM_CLASS` arrives from the client
(xcalc identifies as `XCalc`, xterm as `XTerm`, and so on), the log file gets renamed from a generic
timestamp name to `<instance>-<timestamp>.log`. The NSWindow title gets prefixed the same way:
`[XCalc] Calculator` in the title bar instead of just `Calculator`.

The unlock is operational. You can leave a session up, try the same client against the same server
five different ways, compare logs by app name, and not have to remember which run was which.

## App shell, IP discoverability, Preferences

Same commit cluster brought a real Mac app structure. `setActivationPolicy(.regular)` for the top menu
bar (which costs a Dock icon, since we don't ship an `LSUIElement` Info.plist key yet; that's logged
in SHORTCUTS.md). A status item in the menu bar shows the resolved IP address of the Mac, since
between DHCP, multiple Macs, and not always remembering which one I'm on, knowing what
`DISPLAY=<this-mac>:0` should say is a real workflow win. A tabbed Preferences window persisting via
UserDefaults, with the trigger-mode toggle for clipboard behavior (the Mac-vs-xterm copy/paste
preference covered in Post 7).

Small things, but the kind of small things that make a Mac app feel like a Mac app instead of a CLI
with a Cocoa runloop bolted on.

## Pivotal moment

Not the xcalc session. The papaya-whip moment. A 30-year-old binary asking a brand-new Swift server
for a color named in 1989, and the server answering correctly because that file is still right and
still load-bearing and still inside the build.

## What Todd should add

- The hex-spec surreal moment in your voice. The "I knew the client had no support for hex specs but
  it worked anyway" beat is the post's emotional center. Lean into it.
- The "everything just kept working" feeling about embedding rgb.txt. The protocol is stable, the file
  is stable, the names haven't changed, and the work of carrying a 1989 file forward into 2026 is one
  copy operation. That stability is the gift X11 keeps giving this project.
- The multi-client moment in your voice. You called it a "huge human unlock" in the prior draft.
  That's the right tone: not a feature, a working-pace shift.
- Any color-name memories. The X11 named colors have a personality (cornflower blue, papaya whip,
  navajowhite, mistyrose) that the modern color-picker UI has scrubbed away. If you have a memory of
  using these in actual X programming, it lands.

## Anchors for fact-check pass

- Files: `Sources/SwiftXServerCore/XColorDatabase.swift` (the rgb.txt embed; 752 entries from
  `reference/X11R6/xc/programs/rgb/rgb.txt`, case- and whitespace-insensitive lookup, hex spec
  parsing per `libX11/src/ParseCol.c`), `Sources/SwiftXServerCore/ServerCoordinator.swift`,
  `Sources/SwiftXServerCore/Listener.swift`, `Sources/SwiftXServerCore/FileLogSink.swift`
- Commits: `947296b` 2026-05-08 live xcalc, `bee1010` 2026-05-09 EnterNotify/LeaveNotify +
  PolyRectangle, `3f4d984` 2026-05-08 multi-client + per-session logs
- The hex-spec parse rules: `#RGB` (each digit shifted to high-order 16-bit), `#RRGGBB` (each pair
  shifted), `#RRRGGGBBB` (each triple shifted left by 4), `#RRRRGGGGBBBB` (no shift). 8-bit named
  values are replicated to 16-bit per historical X server behavior.
- SHORTCUTS open: Dock icon, no LSUIElement; X errors not emitted (unknown color names fall back to
  black instead of `BadName`).

(Cut and paste, the PRIMARY selection wire path, and the Preferences trigger modes are covered in
Post 7 where xterm makes them concrete. Not duplicated here.)

## Working title alternatives

- "Papaya whip, cornflower blue, gainsboro"
- "The 1989 file inside the 2026 binary"
- "Named colors and a faster development loop"
