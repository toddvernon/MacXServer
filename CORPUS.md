# Corpus

`captures/` is a collection of real X11 wire traffic from a 1990s
Sun workstation running real X clients of the era. It is one of the
project's most distinctive assets — a working X11R6 environment with
genuine SunOS-era Motif / OpenWindows / Athena software is rare to
capture today, and the sessions here are not synthesized.

The corpus exists for three purposes:

1. **Regression fuel for swift-x.** Each `display-on-ss2` capture is a
   gold trace of how a real X server handles the client. Each matching
   `display-on-swiftx` capture is the same client talking to our
   server. `macxcapture diff` between the two surfaces drift.
2. **Replay testbed.** `macxcapture replay <file>.xtap` can re-drive
   the C2S byte stream against any X server, including ours, so a
   capture is a self-contained reproduction of the client's behavior
   without needing the Sun.
3. **Reference traces for the X community.** Vintage Motif / Athena /
   OpenWindows wire traffic at protocol resolution is hard to come by
   in 2026. The
   per-app entries below note what each capture exercises so anyone
   debugging a vintage X client (on any server) has a starting point.

## What's in the corpus

- **71 capture files** (`.xtap`) plus matching `.xtap.json` sidecars,
  totaling **49 distinct X clients**.
- **22 fully paired**: a gold (ss2 → ss2) and a swiftx-side (ss2 →
  swift-x) capture for the same app. Diff-ready.
- **22 ss2-only golds**: captured on the Sun but not yet exercised
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
- **OS**: SunOS 4.1.4.
- **X server**: X Consortium release 6000 (X11R6), the canonical
  reference X server of the era.
- **Window manager**: standalone Motif `mwm` (not CDE / `dtwm`).
  Motif on SunOS 4.1.4 came as a commercial binary-only product back
  in the day — Motif libraries plus the `mwm` window manager,
  shipped as Sun-format binaries with no source. This machine has
  the exact binaries the project author bought originally for the
  quickplot work, recovered recently from someone who'd held onto
  them. The libraries came without headers; CDE-Motif headers from
  Solaris 2.6 turned out to work as a build-time stand-in (different
  era, same ABI), which is why quickplot rebuilt cleanly when the
  environment came back online. No CDE / dtwm captures in this
  corpus — all Motif clients (`xm*`, `motif*`) ran under standalone
  `mwm`.

This is what makes the corpus rare: SunOS 4.1.4 + commercial-binary
Motif + a real ss2 was a common 1990s industrial workstation
configuration, but the Motif binaries are essentially unobtainable
in 2026. Captures of how that toolkit actually behaves on the wire
are not reproducible by re-installing modern software.

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

`reference/X11R6/contrib/programs/auto_box` — a 3D graphics demo
using the X3D-PEX extension. **Gold-only.** 152 of the 181 requests
are X3D-PEX extension calls (opcode 130). Notable as one of the
few PEX-exercising captures in the corpus; PEX (the X 3D
extension) is mostly extinct in 2026 and traces of real PEX traffic
are hard to find.

### bitmap

The X11R6 bitmap editor. **Paired.** Heavy PolyFillRectangle (the
edit grid), PolyText8 (menu and label text), PolySegment (highlight
overlay), and SetClipRectangles. Exercises SHAPE (64 calls in the
gold) — bitmap uses SHAPE on its right-click context menu.

### dogs

`reference/motif/demos/unsupported/dogs` — multi-window dog images,
the Motif demo (not the Athena `xdogs`). **Paired.** Creates 26
pixmaps + 12 PutImages the dog bitmaps into them, then redraws via
151 PolySegment + 65 PolyFillRectangle + 31 CopyArea. Window
backgrounds are plain CWBackPixel (just a color), not bg-pixmap.

### editres

Athena widget-tree introspection tool. **Paired but unresolvable.**
editres' core function (display another running client's widget tree
via `_XEDITRES_PROTOCOL` ClientMessages) is multi-client and not
captured here — the swiftx capture ends cleanly after the normal
sync-grab pointer tracking, before any target-client interaction.
The lockup that surfaces with two real clients is one of the open
items in STATUS.

### fileview

OpenWindows / SunView file manager (Sun's pre-CDE bundled file
viewer, `WM_CLASS=fileview/Fileview`). **Paired.** Mid-sized Xt app
with menu bar and content pane. Exercises Xt save-under/override
patterns at startup. Distinct from CDE's `dtfile`.

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
variant). **maze: gold-only. xmaze: swiftx-only.** Build a random
maze with heavy PolyFillRectangle: 3755 of them in maze, 11889 in
xmaze's swiftx capture (the latter also has 54 synthesized
ConfigureNotify events). CopyPlane is only used incidentally
(2 / 8 calls), not as the primary mechanism. xmaze's swiftx capture
was a primary motivator for closing the ZPixmap PutImage gap on
2026-05-31 — see commits `9a154f1` and `afdd26b`.

### motifanim

A Motif animation demo. **Paired.** Animation runs through CopyArea
(277 in the gold) from pre-rendered offscreen pixmaps, with a
small number of PutImage calls in the mix — including at least one
ZPixmap depth=8 PutImage (81×47, 3948 bytes) that was silently
dropped pre-`9a154f1` (2026-05-31). The swiftx capture predates the
fix and should re-render correctly post-fix; awaiting Sun
re-verification.

### motifbur

Motif burgundy demo with icon-button bar. **Paired.** Exercises
ZPixmap PutImage on its toolbar icons (6 PutImage calls in the
gold) — was one of the four captures the 2026-05-31 audit caught
silently dropping ZPixmap data.

### motifgif

A Motif GIF picker (`WM_CLASS=motifgif/XMclient`, top-level "Picture
Selection Window"). **Gold-only.** Mostly the file-picker chrome
on the wire — PolySegment / PolyFillRectangle / ClearArea
dominate. Only 3 PutImage calls (rendered when a GIF is actually
selected), so this is not the heavy image-decode workload the name
suggests.

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

OpenWindows text editor — the canonical SunOS-era text widget,
predating CDE's `dtpad`. **Gold-only.** One of the corpus's few
"non-X-Consortium-toolkit" reference traces, since OpenWindows used
Sun's own XView / OPEN LOOK toolkit rather than Motif or Athena.

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

The X clipboard manager. **Gold-only.** The capture is mostly Xaw
chrome on the wire — ChangeGC / CreateGC / PolyFillRectangle /
PolySegment / ClearArea. Notable: 20 CopyPlane calls (text glyph
rendering from depth-1 sources) and **18 SHAPE-extension calls**
(the clipboard window uses SHAPE). Selection ops (SetSelectionOwner,
ConvertSelection, etc.) are present at lower counts than the chrome
opcodes — this capture happens to catch xclipboard at startup and
through a few paste operations, not in a heavy selection-traffic
loop.

### xclock

The classic analog/digital clock. **Gold-only.** Pure Xt + Xmu, no
SHAPE. The reference capture for "what does a long-running X client
that does almost nothing look like on the wire" — useful for
verifying idle behavior.

### xconsole

Athena terminal that captures system console messages. **Gold-only.**
Long-running text-streaming app — though this capture is short
(~35 requests total, caught at startup before any console messages
arrived). Uses Xaw Text widget for the display area.

### xedit

Athena's text editor. **Gold-only.** 56 CopyPlane calls (text glyph
rendering from depth-1 font pixmaps), 14 ImageText8, 8 PolyText8 —
mixed text-rendering modes. 8 CreateGlyphCursor (the I-beam + other
cursors), 20 ConfigureWindow as the user resized panes. Uses the
Xaw Text widget; the capture is short and doesn't reach
property-based file-load / clipboard interaction.

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

Font browser. **Gold-only.** Short interactive session: 1 ListFonts
call to populate the dropdowns, 5 QueryFont calls as the user picked
fonts to preview. Mostly Xaw chrome on the wire (PolyText8 for menu
text). The actual heavy "enumerate the catalog" workload is a single
big ListFonts reply, not a sustained burst.

### xgas

Motif demo of the kinetic gas model. **Paired.** Particles are
drawn as text glyphs, not rectangles — 290 PolyText8 + 281 ClearArea
form the simulation loop (label, erase, redraw). Only 9
PolyFillRectangle and 4 PutImage. The swiftx capture was one of the
four caught by the 2026-05-31 audit using ZPixmap PutImage on a
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
xlfonts is tiny — 3 requests, one big ListFonts that returns the
full catalog as a single (large) reply. xlsatoms hammers GetAtomName
in a tight loop until the first BadAtom (their probe-until-fail
pattern; 341 calls in the gold, 132 in the swiftx capture, both
ending in the legitimate BadAtom that signals "you ran off the end
of the atom table"). The xlsatoms capture pair was one of the audit
successes on 2026-05-31.

### xlogo

The X logo. **Gold-only.** Smallest non-trivial X client: 41
requests total, the X-letter shape drawn via 10 FillPoly calls
(4-point convex polygons forming the two crossing strokes). No
PolyLine. Useful as a fixed point for rendering correctness.

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

Motif demo apps from `reference/motif/demos/unsupported/`.
**xmform/xmfonts/xmgetres: gold-only. xmforc: paired.** Various
ways of exercising XmForm, font enumeration, and XmGetResources.
Together they cover a good spread of XmManager / XmRowColumn /
XmGetColors behavior.

### xmlist / xmmap

Motif list / map demos. **xmlist: gold-only. xmmap: paired.** The
xmmap swiftx capture is the source of the open "Expose verbosity"
investigation (1558 Expose events vs gold's 140) — see STATUS for
the unresolved render-pipeline thread.

### xmpiano

Motif piano demo with keyboard widget. **Paired.** Gold has 121
PolySegment + 75 PolyFillRectangle + 28 CreatePixmap + 23 PutImage
(the key bitmaps). The swiftx capture shows the bug that motivated
`afdd26b` on 2026-05-31: 1 `GetKeyboardControl` request (opcode
103) + 1 BadRequest error in reply, before the fix landed.

### xmter / xmtravel

Motif demo apps (WM_CLASS `XMdemos` / `XMtravel`). **xmter: paired.
xmtravel: gold-only.** xmter is the corpus's heaviest CopyPlane
user by a wide margin — 299 calls in the gold, drawing 64×64
regions out of a 64×1920 depth-1 source pixmap (looks like a
30-frame sprite-strip animation). A useful capture for stressing
CopyPlane code paths. xmtravel is a Motif form / travel-agent
demo: 86 CreateWindows, heavy PolySegment + SetClipRectangles +
ClearArea redraw.

### xprop

Property inspector. **Gold-only.** Queries WM_* and other ICCCM
properties on a target window via GetProperty.

### xterm

The terminal. **Paired.** The reference capture for any X server.
Dominated by ImageText8 (196 calls in the gold — character cells
rendered with foreground glyph + background block in one round
trip). Also exercises 8 CreateGlyphCursor calls (the I-beam plus
resize-edge cursors and a pirate cursor for kill targeting), 12
GrabButton (selection), 3 GetKeyboardMapping + 3 GetModifierMapping
(keymap probe on startup), and ChangeProperty (window title updates
as the shell prompt changes). The gold capture is from a short
session; longer sessions would show much more CopyArea (for
scrollback redraw) and selection traffic.

## Indices

### By distinctive X11 protocol feature

These indices point at the captures that most heavily exercise a
specific protocol feature. Useful for "I'm implementing X, where's a
realistic test trace for Y?"

- **SHAPE extension** → SHAPE is more pervasive in the corpus than
  the obvious "shaped-window" demos suggest. Counts (gold):
  - xcalc (80) — rounded calculator buttons
  - bitmap (64) — right-click menu
  - xclipboard (18)
  - viewres (6) — Athena widget chrome
  - editres (4) — Athena widget chrome
  - oclock (2) — the round clock window itself
  - xmter (2)
  - xeyes (1) — the oval-shaped window
- **CopyPlane (depth-1 to depth-N glyph or sprite transfer)** →
  xmter (**299 calls — corpus champion**, sprite-strip animation),
  xedit (56), xclipboard (20), bitmap (19), xgc (16), editres (14)
- **PutImage (any format)** → almost every Athena/Motif app uses
  some PutImage. Heavy users: xmpiano (23 — key bitmaps), bitmap
  (19), viewres (13), dogs (12), xgc (9), periodic (9). Most are
  `format=bitmap` depth=1, not ZPixmap.
- **ZPixmap PutImage at depth=8** specifically (the path closed by
  `9a154f1` on 2026-05-31) → motifanim, motifbur, viewres, xgas —
  the four caught by the audit. Modest counts each.
- **GetImage on root** → xmag
- **GrabServer / UngrabServer** → xmag (446 cycles in the swiftx capture)
- **GrabPointer + glyph cursor** → xkill, xterm, xmag
- **Atom-walk (GetAtomName loop)** → xlsatoms (341 / 132)
- **QueryTree + WM_STATE walk** → xlsclients
- **PRIMARY/CLIPBOARD selections** → xterm, xclipboard
- **ListFonts / QueryFont** → xlfonts (1 big ListFonts), xfontsel
  (1 ListFonts + 5 QueryFont in a short session)
- **Heavy ImageText8** → xterm (196 calls)
- **MotionNotify stream** → xev (219 events)
- **CopyGC** → puzzle (motivated opcode 57 implementation)
- **GetKeyboardControl** → xmpiano (motivated opcode 103
  implementation)
- **PolySegment + ClearArea redraw loop** → ico (2865 / 2865)
- **PolyFillRectangle stress** → xmaze (11889), maze (3755)
- **X3D-PEX (3D graphics)** → auto-box (152 calls — the only PEX
  capture in the corpus)

### By identification path

How each capture got its filename — which signal the capture
machinery used. Relevant to anyone writing capture / debugging
tooling: some "minimalist" X clients never set either property
during certain usage patterns, even if the app's normal flow would.

- **WM_CLASS-identified (canonical path)**: most apps. xterm,
  xclock, motifbur, viewres, …
- **WM_NAME-fallback only** (no WM_CLASS in this session — the
  2026-06-01 fallback motivators): ico, xmaze, puzzle, xev.
- **Neither property in this session** (so the capture lands as
  `unidentified-N` until manually identified by wire fingerprint):
  xkill, xmag (swiftx-side only — the user did a rubber-band
  selection without creating a result window; the gold has full
  WM_CLASS), xlsatoms (no top-level window at all), xlsclients
  (no top-level), unidentified-5, unidentified-22.

## Adding to the corpus

New captures should follow the existing filename convention. If you
add a new source workstation (e.g., a DECstation, an SGI Indy),
extend `<source>` and `<destination>` accordingly and add a short
"Source environment" subsection above noting that workstation's
configuration.

Captures that document a specific bug should also note that in the
manifest entry — the goal is for any future maintainer to be able to
ask "do we have a wire trace of behavior X?" and find it.
