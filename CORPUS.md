# Corpus

`captures/` is a collection of real X11 wire traffic from a 1990s
Sun workstation running real X clients of the era. It is one of the
project's most distinctive assets — a working X11R6 environment with
genuine SunOS / Solaris software is rare to capture today, and the
sessions here are not synthesized.

The corpus exists for three purposes:

1. **Regression fuel for swift-x.** Each `display-on-ss2` capture is a
   gold trace of how a real X server handles the client. Each matching
   `display-on-swiftx` capture is the same client talking to our
   server. `macxcapture diff` between the two surfaces drift.
2. **Replay testbed.** `macxcapture replay <file>.xtap` can re-drive
   the C2S byte stream against any X server, including ours, so a
   capture is a self-contained reproduction of the client's behavior
   without needing the Sun.
3. **Reference traces for the X community.** Vintage Motif / CDE / Athena
   wire traffic at protocol resolution is hard to come by in 2026. The
   per-app entries below note what each capture exercises so anyone
   debugging a vintage X client (on any server) has a starting point.

## What's in the corpus

- **72 capture files** (`.xtap`) plus matching `.xtap.json` sidecars,
  totaling **50 distinct X clients**.
- **22 fully paired**: a gold (ss2 → ss2) and a swiftx-side (ss2 →
  swift-x) capture for the same app. Diff-ready.
- **23 ss2-only golds**: captured on the Sun but not yet exercised
  against our server.
- **5 swiftx-only**: clients that don't have a clean run-and-quit
  pattern on the Sun (xkill, xlsclients, xmaze) or unidentified
  short-lived probes (unidentified-5, unidentified-22).
- **All captures are msb-first** wire byte order — Sun SPARC was a
  big-endian architecture. Tools auto-detect and decode correctly,
  but raw hex dumps show integers in network order (`0x1234` reads
  as `12 34`), which differs from the lsb-first dumps Intel-era
  developers are used to.

## Source environment

All ss2-side traffic was recorded against:

- **Hardware**: Sun SPARCstation 2 (`ss2.example.com`), 1280×1024 8-bit
  PseudoColor frame buffer with 6 visuals per the SetupAccepted reply
  (PseudoColor, DirectColor, GrayScale, StaticColor, TrueColor,
  StaticGray).
- **X server**: X Consortium release 6000 (X11R6), the canonical
  reference X server of the era.
- **Window manager / desktop**: CDE 1.0 with `dtwm` (the Motif-derived
  window manager) for the dt-app and Motif captures. Plain X for the
  Athena demos.

`display-on-ss2` captures: `macxcapture --listen :6000 --forward
ss2.example.com:6000` running on a workstation alongside the Sun, with
the client's `DISPLAY` pointed at the capture port and the capture
forwarding to the Sun's own X server. Both directions of wire traffic
land in the `.xtap`.

`display-on-swiftx` captures: same proxy idea but with the swift-x
server running on the Mac as the upstream — or, more recently,
captured by the server-side tee inside `macxserver` itself (the
captures recorded between 2026-05-27 and now). Server-side tee has
identical fidelity since it's the same `Recorder` in-process.

## Reading the captures

### Filename convention

```
<app>-running-on-<source>-display-on-<destination>.xtap
```

- `app`: the X client's name (typically resolved from `WM_CLASS` /
  `WM_NAME`; six captures kept the fallback `unidentified-N` shape
  because the client never set either).
- `source`: where the client was running. Always `ss2` in this corpus
  (we'd add more sources when we add more vintage workstations).
- `destination`: where the X server was. `ss2` for a gold capture
  (client and server both on the Sun, proxy tees the wire). `swiftx`
  for our server (Sun client, Mac server).

### Tools

```
macxcapture dump    <file.xtap>     # chronological per-message dump
macxcapture summary <file.xtap>     # aggregate analysis
macxcapture diff    <a.xtap> <b.xtap>  # markdown diff aligned per-direction
macxcapture replay  <file.xtap> --target host:port
```

`dump` is the workhorse. It renders the session as decoded protocol
events with timestamps, including inline narrative landmarks
(`# The "dogs" window appears on screen ...`) that flag major
moments. Open any `.xtap` in the macXcapture app (File → Open) for a
syntax-highlighted version with a landmark sidebar.

### File format

`.xtap` is a small binary format: a magic header, the SetupRequest
+ SetupAccepted, then a series of `(direction, byte_count, bytes)`
frames. The format is intentionally tee-shaped: `macxcapture --listen
... --forward ...` writes one frame per packet and Recorder buffers
until the session disconnects. `CaptureFile.swift` and
`CaptureReader.swift` in `Sources/SwiftXCaptureCore/` are the
authoritative reference.

The `.xtap.json` sidecar carries record-time metadata: forward and
listen endpoints, duration, byte counts, recording timestamp.

## Per-app manifest

Entries are alphabetical. The "what's notable" line is what makes the
capture interesting beyond just "this app exists" — what X11 features
it exercises, what edge case it surfaces, or what it documented in
swift-x's history. Entries with `paired` have both a gold and a
swiftx capture; the rest are gold-only or swiftx-only.

### auto-box

`reference/X11R6/contrib/programs/auto_box` — a small Athena demo
that draws and animates a rectangle. **Gold-only.** Lightweight
Athena vbox/Box widget hierarchy + repeated PolyLine + ClearArea
cycles. Useful as a minimum-Athena-app baseline.

### beach-ball

A bouncing-ball animation from the X11R6 demo set. **Gold-only.**
Fixed-size pixmap (the ball image) repeatedly CopyArea'd to new
positions; classic example of "pixmap as sprite" used by many
pre-RENDER X clients.

### bitmap

The X11R6 bitmap editor. **Paired.** Exercises ImageText8 and
ImageText16 for menu text, FillRectangle for the grid, PolySegment
for the highlight overlay. The swiftx capture also exercises SHAPE
(major opcode 128) — bitmap uses SHAPE on its right-click context
menu.

### dogs

`reference/motif/demos/unsupported/dogs` — multi-window dog images,
the Motif demo (not the Athena `xdogs`).
**Paired.** First-window-appears landmark fires on this one
specifically because of its memorable name. Exercises CreateWindow
with `bg-pix` from a CreatePixmap'd source — a classic vintage
"window IS a sprite" pattern.

### editres

Athena widget-tree introspection tool. **Paired but unresolvable.**
editres' core function (display another running client's widget tree
via `_XEDITRES_PROTOCOL` ClientMessages) is multi-client and not
captured here — the swiftx capture ends cleanly after the normal
sync-grab pointer tracking, before any target-client interaction.
The lockup that surfaces with two real clients is one of the open
items in STATUS.

### fileview

CDE's file-content viewer (`dtfileview`-ish). **Paired.** Mid-sized
Motif app: ScrolledText widget for content, menu bar, status line.
Exercises XmText programmatic content updates.

### ico

`reference/X11R6/contrib/programs/ico` — the icosahedron animation, the
quintessential "X works" demo. **Paired.** 2865 cycles of
`ClearArea(151×151) + PolySegment(20 segments)` — a tight redraw
loop with no double buffering, illustrating why ClearArea
performance mattered on the era's hardware. Only sets WM_NAME, not
WM_CLASS — was one of the four captures the 2026-06-01 WM_NAME
fallback work was motivated by.

### maze / xmaze

`reference/X11R6/contrib/programs/maze` (Athena) and `xmaze` (Motif
variant). **maze: gold-only. xmaze: swiftx-only.** Both build a
random maze with PolyFillRectangle and walk a solution path with
small CopyPlane'd 64×64 pawns at depth=1. xmaze's swiftx capture
(11889 PolyFillRectangle requests, 54 synthesized ConfigureNotify
events) was a primary motivator for closing the ZPixmap PutImage gap
on 2026-05-31 — see commits `9a154f1` and `afdd26b`.

### motifanim

A Motif animation demo. **Paired.** Bitmap-driven sprite animation
with ZPixmap PutImage at depth=8 — the path that was silently
dropped before `9a154f1` (2026-05-31). The swiftx capture predates
the fix and should re-render correctly post-fix; awaiting Sun
re-verification.

### motifbur

Motif burgundy demo with icon-button bar. **Paired.** Uses ZPixmap
PutImage to paint its toolbar icons. One of the four captures the
2026-05-31 audit caught silently dropping ZPixmap data.

### motifgif

A Motif GIF viewer. **Gold-only.** Heavy PutImage traffic in the
GIF-decoded path; XmDrawingArea recipient. Useful for testing
PutImage at large image sizes.

### motifshell

`xmsh` / Motif command-shell wrapper. **Paired.** Combines XmText
for the terminal area with a Motif menu bar. Stretches the Motif
text rendering code path (the `MOTIF_TEXT_QUALITY` design
constraints).

### oclock

Round analog clock from the X11R6 demos. **Gold-only.** Lives or
dies by the SHAPE extension — without SHAPE the window renders
square. swift-x's SHAPE implementation (2026-05-28, `5be5334` +
follow-ups) was demo'd against oclock; the SHAPE work itself was
exercised against this capture's wire trace.

### periodic

Athena periodic-table viewer. **Paired.** Grid of small windows for
each element. Stress-tests the WindowTable + per-window clip-list
machinery on a large flat hierarchy.

### puzzle

`reference/X11R6/contrib/programs/puzzle` — the 15-tile sliding puzzle.
**Paired.** Sets WM_NAME but not WM_CLASS (covered by the 2026-06-01
fallback). Uses CopyGC (opcode 57) at startup to clone its base GC
into per-tile variants — was the motivating bug for opcode 57
implementation on 2026-05-31 (`afdd26b`).

### textedit

OpenWindows text editor — the canonical Solaris text widget showing
what NeWS-era TextSubwindow looked like. **Gold-only.** Heavy
RasterText extension usage; the gold capture is one of our few
"non-X-Consortium-toolkit" reference traces.

### unidentified-5

A short probe session, 5 requests total, ends after querying for the
X3D-PEX extension. **Swiftx-only.** Kept around as a "what an
extension probe looks like" sample.

### unidentified-22

Aborted xkill-style startup — 9 requests including GrabPointer and
CreateGlyphCursor, but no ButtonPress/UngrabPointer pair. **Swiftx
only.** Pair with `xkill-running-on-ss2-display-on-swiftx.xtap` to
see the same client both completed and aborted.

### viewres

Athena widget-tree visualizer. **Paired.** Reads `app-defaults` for
its hierarchy and renders it as a tree. Exercises List widget,
Scrollbar, and a fairly deep Box/Form nesting.

### xbiff

The mailbox-flag indicator. **Gold-only.** Tiny — a single window
that flips between two pixmaps (flag up / flag down) based on
mailbox state. Wire is mostly idle: SelectInput on file-descriptor
events, no draw traffic until the bitmap swap.

### xcalc

`reference/X11R6/contrib/programs/xcalc` — the Athena calculator.
**Gold-only.** Exercises Athena Command widget grid for buttons,
Label widget for the display. One of the canonical "Athena app
works" demos; live xcalc works against swift-x as of 2026-05-07.

### xclipboard

The X clipboard manager. **Gold-only.** Exercises PRIMARY and
CLIPBOARD selection protocols; reads selection notifications from
other clients. Useful for understanding the selection-roundtrip flow
that swift-x's `selectionSinkWindow` machinery models.

### xclock

The classic analog/digital clock. **Gold-only.** Pure Xt + Xmu, no
SHAPE. The reference capture for "what does a long-running X client
that does almost nothing look like on the wire" — useful for
verifying idle behavior.

### xconsole

Athena terminal that captures system console messages. **Gold-only.**
Long-running text-streaming app; exercises XmText / Xaw Text widget
incremental rendering.

### xedit

Athena's text editor. **Gold-only.** Exercises Xaw Text, Scrollbar,
Command widgets. Notable for stressing GetProperty replies (read
file path), and ChangeProperty (clipboard) on save.

### xev

Event tester. **Paired.** Sets only `WM_NAME="Event Tester"` —
another WM_NAME-fallback motivator. Sends 219 MotionNotify events in
the swiftx capture as the user hovered over the test window — useful
for testing motion delivery and event compression.

### xeyes

`reference/X11R6/contrib/programs/xeyes` — the pair of eyeballs that
track the cursor. **Gold-only.** Uses SHAPE via Xmu's
`XShapeCombineMask` to make the window an oval; without SHAPE it
renders as a rectangle. Pairs conceptually with oclock for SHAPE
testing.

### xfontsel

Font browser. **Gold-only.** Heavy ListFonts traffic to enumerate
the font catalog; QueryFont per selection to render the preview.
Useful for stressing the font path on any server implementation.

### xgas

Motif demo of the kinetic gas model. **Paired.** Continuous
PolyFillRectangle redraw of particles. The swiftx capture was one of
the four caught by the 2026-05-31 audit using ZPixmap PutImage on a
path that was silently dropped.

### xgc

Athena GC-test demo. **Paired.** Exhaustively walks GC attribute
combinations (line styles, fill styles, dashing, function operators)
and renders test patterns. Stress test for graphics-state state
machine.

### xkill

The "click a window to kill its client" tool. **Swiftx-only.**
Distinctive fingerprint: GrabPointer → ButtonPress → AllowEvents →
UngrabPointer cycle with skull/pirate cursor glyphs (144/148/78/76)
loaded from the `cursor` font. No window of its own.

### xlclients / xlsclients

List clients connected to the X server. **xlclients: gold-only.
xlsclients: swiftx-only.** Walks QueryTree + GetProperty(WM_STATE)
across the root's children. xlclients is the older Sun name;
xlsclients is the X Consortium name.

### xlfonts / xlsatoms

List fonts / atoms. **xlfonts: gold-only. xlsatoms: paired.**
xlfonts hammers ListFonts; xlsatoms hammers GetAtomName in a tight
loop until the first BadAtom (their probe-until-fail pattern). The
xlsatoms capture pair was one of the audit successes on 2026-05-31.

### xlogo

The X logo. **Gold-only.** Smallest non-trivial X client: one
window, one Xmu-drawn logo via FillPoly + PolyLine. Useful as a
fixed point for rendering correctness.

### xmag

Screen magnifier. **Paired.** GrabServer + PolyRectangle on the
root + UngrabServer drumbeat (rubber-band selection rectangle), then
a GetImage of the chosen region. Exercises the GetImage path on the
root window — the only common client that does.

### xmeditor

Motif editor demo. **Paired.** XmText widget with menu bar, dialogs
(File Open / Save). One of the bigger Motif captures by request
count.

### xmforc / xmform / xmfonts / xmgetres

Motif demo apps from the `Xm/demo` directory. **xmform/xmfonts/
xmgetres: gold-only. xmforc: paired.** Various ways of exercising
XmForm, font enumeration, and XmGetResources. Together they cover a
good spread of XmManager / XmRowColumn / XmGetColors behavior.

### xmlist / xmmap

Motif list / map demos. **xmlist: gold-only. xmmap: paired.** The
xmmap swiftx capture is the source of the open "Expose verbosity"
investigation (1558 Expose events vs gold's 140) — see STATUS for
the unresolved render-pipeline thread.

### xmpiano

Motif piano demo with keyboard widget. **Paired.** Was one of the
two BROKEN-on-swiftx apps closed on 2026-05-31 (the missing opcode
103 GetKeyboardControl handler — `afdd26b`).

### xmter / xmtravel

Motif terminal-emulator demo / Motif travel-form demo. **xmter:
paired. xmtravel: gold-only.** xmter exercises the Motif text
widget's terminal-mode rendering — a separate code path from XmText
in document mode.

### xprop

Property inspector. **Gold-only.** Queries WM_* and other ICCCM
properties on a target window via GetProperty.

### xterm

The terminal. **Paired.** The reference capture for any X server.
Exercises ChangeKeyboardMapping, ChangeProperty (window title
updates), CopyArea (scrollback), font rendering via PolyText8 +
ImageText8. Two-way clipboard via PRIMARY and CLIPBOARD selections.

## Indices

### By distinctive X11 protocol feature

These indices point at the captures that most heavily exercise a
specific protocol feature. Useful for "I'm implementing X, where's a
realistic test trace for Y?"

- **SHAPE extension** → oclock, xeyes, bitmap (right-click menu)
- **CopyPlane (depth-1 to depth-8 transfer)** → xmaze, maze, motifbur
- **ZPixmap PutImage** → motifanim, motifbur, viewres, xgas
- **GetImage on root** → xmag
- **GrabServer / UngrabServer** → xmag (446 cycles in the swiftx capture)
- **GrabPointer + glyph cursor** → xkill
- **Atom-walk (GetAtomName loop)** → xlsatoms
- **QueryTree + WM_STATE walk** → xlsclients
- **Selection PRIMARY/CLIPBOARD** → xterm, xclipboard
- **ListFonts / QueryFont** → xfontsel, xlfonts
- **XmText rendering** → motifshell, xmeditor, xmter (terminal mode),
  fileview
- **MotionNotify stream** → xev (219 events)
- **CopyGC** → puzzle (motivated opcode 57 implementation)
- **GetKeyboardControl** → xmpiano (motivated opcode 103
  implementation)
- **PolySegment + ClearArea redraw loop** → ico

### By identification path

Documents how each client made itself identifiable to the capture
machinery. Relevant to anyone writing capture / debugging tooling:
some "minimalist" X clients still never set either property.

- **WM_CLASS-identified (canonical path)**: most apps. xterm, xclock,
  motifbur, viewres, …
- **WM_NAME-fallback only** (no WM_CLASS published — the 2026-06-01
  fallback motivators): ico, xmaze, puzzle, xev.
- **No identifying property at all** (no top-level window): xkill,
  xmag, xlsatoms, xlsclients, unidentified-5, unidentified-22.

## Adding to the corpus

New captures should follow the existing filename convention. If you
add a new source workstation (e.g., a DECstation, an SGI Indy),
extend `<source>` and `<destination>` accordingly and add a short
"Source environment" subsection above noting that workstation's
configuration.

Captures that document a specific bug should also note that in the
manifest entry — the goal is for any future maintainer to be able to
ask "do we have a wire trace of behavior X?" and find it.
