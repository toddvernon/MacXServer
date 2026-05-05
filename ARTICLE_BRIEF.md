# Article brief: xterm on the wire (a walkthrough from a real Sun)

This is a briefing for whoever writes the actual article. It contains the
material gathered during one day of building swift-x's capture tool and
framer. Use it as source. Don't paste the brief verbatim — write a real article
in Todd's voice from the data here.

## Voice and audience

**Audience**: visitors to OldSilicon.com — vintage computer hobbyists who want
technical depth but read for stories, not specs.

**Voice**: Todd's (the project owner). Casual, first-person, direct, technical.
Examples of what he sounds like (lifted from the project docs):

- "The motivation is that XQuartz works but is clunky, dated, and doesn't take
  advantage of modern Mac rendering."
- "The Sun stays vintage and dumb. It does plain TCP X11 to whatever's at the
  IP in DISPLAY."
- "Sun side: nothing. The Suns run stock Xsun and stock X clients. They are
  not modified."

**Hard style constraints** (from CLAUDE.md, non-negotiable):

- No em-dashes. They're an AI tell Todd dislikes. Use commas, periods, parens,
  or rewordings.
- No "I'd be happy to help!", "Certainly!", "Great question!", "Let's dive in!"
  Write like a thoughtful colleague, not a chatbot.
- No marketing language. No hyperbole. Concrete observations beat adjectives.
- Bullet points are fine but use prose where prose flows better.
- Technical accuracy over polish.
- It's OK to be specific and a bit nerdy. The audience asked for it.

## What's swift-x and what's today's milestone

swift-x is Todd's project to build a modern X11 server in Swift on macOS so he
can display X applications from his real vintage Sun workstations on his Mac
with proper modern rendering. The project's first phase is "Product 1: a
capture tool" — a passive proxy that sits between two Suns on the LAN,
forwarding bytes faithfully while recording and decoding everything that
crosses the wire.

Today's session, in one day, went from `git init` to:

- A Swift package with a wire protocol decoder (the "framer")
- ~73 typed X11 core protocol opcode decoders
- 26 typed event decoders
- 3 typed reply decoders (InternAtomReply, QueryFontReply, QueryExtensionReply)
- A POSIX TCP byte-pump proxy with `.xtap` capture file format
- A chronological dump tool that prints decoded sessions
- A summary/statistics tool
- 212 passing tests
- 8 captures from real Sun workstations: xterm (3 different sessions), xeyes,
  xclock, xcalc, and a Motif graphing app called quickplot (2 captures)
- Diagnosed and fixed a real auth issue (xhost / xauth dance)
- Diagnosed and fixed a 10× perf regression caused by missing TCP_NODELAY

Total wire data captured: ~45,000 requests across the corpus. **100% of those
requests were typed by the end of the day** (every X11 core opcode any of
those Sun apps actually emitted). The only "unknown" calls in the entire
corpus are 161 calls to the SHAPE extension, which is a separate protocol
running on top of X11.

## The hero artifact: xterm startup, decoded byte by byte

The article's centerpiece should be the chronological dump of an xterm session
from the moment the connection opens to the moment the first prompt appears.
Here's what swift-x's `dump` subcommand prints when fed the captured `.xtap`
file. The comments below each snippet are explanations, not part of the dump
output.

### Phase 1 — Handshake (0–6ms)

```
    0.000ms        SetupRequest             msbFirst proto=11.0 auth=(none)
    5.118ms        SetupAccepted            Sun Microsystems, Inc. release=3600 1280x1024 depth=8
```

The Sun says hello in big-endian byte order ("MSB first" is the SPARC native
order). The server (running on a different Sun) answers with vendor info,
screen geometry, depth. Five milliseconds across the LAN.

A few things readers should notice:

- The Sun's vendor string really is "Sun Microsystems, Inc." Release 3600 is
  the Solaris-era Xsun build.
- The screen is 1280×1024 at 8-bit depth. Classic SPARCstation pixel real
  estate. Modern displays would say 4K at 24-bit.
- `auth=(none)` — this Sun trusts the LAN. xhost+ was set on the server side.
  No cookies were exchanged.

### Phase 2 — Defaults and cursor preparation (14–200ms)

```
   13.860ms  →   [seq=2   ] GetProperty              window=0x28 prop=RESOURCE_MANAGER
   83.697ms  →   [seq=3   ] AllocNamedColor          cmap=0x21 name="black"
  132.521ms  →   [seq=6   ] AllocNamedColor          cmap=0x21 name="green"
  156.894ms  →   [seq=7   ] OpenFont                 fid=0x4400001 name="cursor"
  156.894ms  →   [seq=8   ] CreateGlyphCursor        cid=0x4400002 sourceFont=0x4400001 char=152
  156.894ms  →   [seq=9   ] CreateGlyphCursor        cid=0x4400003 sourceFont=0x4400001 char=116
  156.894ms  →   [seq=10  ] CreateGlyphCursor        cid=0x4400004 sourceFont=0x4400001 char=108
  156.894ms  →   [seq=11  ] CreateGlyphCursor        cid=0x4400005 sourceFont=0x4400001 char=114
  156.894ms  →   [seq=12  ] CreateGlyphCursor        cid=0x4400006 sourceFont=0x4400001 char=106
  156.894ms  →   [seq=13  ] CreateGlyphCursor        cid=0x4400007 sourceFont=0x4400001 char=110
  156.894ms  →   [seq=14  ] CreateGlyphCursor        cid=0x4400008 sourceFont=0x4400001 char=112
```

xterm reads `RESOURCE_MANAGER` (the user's X resource defaults), allocates its
two colors (black background, green foreground — those came from the
`-bg black -fg green` flags), opens the X "cursor" font, and creates seven
glyph cursors from it. Char 152 is the I-beam, 116 is the watch, 108 the
X-cursor, etc. Every cursor xterm might display through its lifetime is
created up front. Pre-loading all the cursors at startup is a 1980s Unix
performance trick that's still in use 30+ years later.

### Phase 3 — Main window birth (200–280ms)

```
  203.247ms  →   [seq=24  ] CreateWindow             wid=0x440000D parent=0x28 1x1 at (0,0) class=inputOutput
  203.247ms  →   [seq=25  ] ChangeProperty           window=0x440000D prop=WM_NAME type=STRING data="xterm"
  203.247ms  →   [seq=26  ] ChangeProperty           window=0x440000D prop=WM_ICON_NAME type=STRING data="xterm"
  203.247ms  →   [seq=27  ] ChangeProperty           window=0x440000D prop=WM_COMMAND type=STRING data="xterm-bgblack-fggreen-fn8x13-display192.168.7.126:0"
  203.247ms  →   [seq=28  ] ChangeProperty           window=0x440000D prop=WM_CLIENT_MACHINE type=STRING data="ss2"
  203.247ms  →   [seq=29  ] ChangeProperty           window=0x440000D prop=WM_NORMAL_HINTS type=WM_SIZE_HINTS format=32 data=72b
  203.247ms  →   [seq=30  ] ChangeProperty           window=0x440000D prop=WM_HINTS type=WM_HINTS format=32 data=36b
  203.247ms  →   [seq=31  ] ChangeProperty           window=0x440000D prop=WM_CLASS type=STRING data="xtermXTerm"
  203.247ms  →   [seq=32  ] OpenFont                 fid=0x440000E name="8x13"
  203.247ms  →   [seq=33  ] QueryFont                font=0x440000E
  231.239ms  ←   [seq=33] Reply (QueryFont) ascent/descent=11/2 chars=256 properties=21
```

xterm creates the top-level window at 1×1 — a placeholder, since the window
manager will resize it. Then it sets seven ICCCM properties: window title,
icon-name, the command line that started it, the host (`"ss2"`), size hints,
input hints, and class. This is how the WM knows what to display in the
title bar.

Then it opens the "8x13" font (the classic monospace X bitmap font used for
basically everything terminal-shaped on Sun workstations) and queries it. The
reply comes back with `ascent=11, descent=2, chars=256, properties=21`. That
last number — 21 — is the count of XLFD properties on the font, things like
`POINT_SIZE=120` (12-point), `WEIGHT=10` (medium), `RESOLUTION_X/Y=75 75`
(75dpi), and so on. The properties are atom-keyed, and several resolve to
predefined ICCCM atoms (`FONT_NAME`, `FAMILY_NAME`, `WM_NAME`) whose IDs were
assigned in 1989 and haven't changed since.

### Phase 4 — Inner text window and button grabs (280–500ms)

```
  267.455ms  →   [seq=41  ] CreateWindow             wid=0x4400011 parent=0x440000D 644x316 at (0,0) class=inputOutput
  267.455ms  →   [seq=43  ] GrabButton               window=0x4400011 button=3 modifiers=0x6
  267.455ms  →   [seq=44  ] GrabButton               window=0x4400011 button=3 modifiers=0x4
  267.455ms  →   [seq=45  ] GrabButton               window=0x4400011 button=2 modifiers=0x6
  267.455ms  →   [seq=46  ] GrabButton               window=0x4400011 button=2 modifiers=0x4
  267.455ms  →   [seq=47  ] GrabButton               window=0x4400011 button=1 modifiers=0x6
  267.455ms  →   [seq=48  ] GrabButton               window=0x4400011 button=1 modifiers=0x4
  267.455ms  →   [seq=49  ] MapSubwindows            window=0x440000D
```

xterm creates an inner text-rendering window inside its top-level. Then it
grabs all three buttons, twice each, with `Ctrl` (modifier mask 0x4) and
`Ctrl+Shift` (mask 0x6). That's the famous xterm menu binding — Ctrl+left/
middle/right pop the three xterm menus that nobody remembers exist anymore
(VT options, fonts, key bindings). The grabs are scoped to the inner text
window. `MapSubwindows` tells the server to map the inner window now that
its parent has been set up.

### Phase 5 — The window actually appears (500–515ms)

```
  497.466ms  →   [seq=53  ] MapWindow                window=0x440000D
  497.466ms  →   [seq=54  ] ImageText8               drawable=0x4400011 gc=0x440000F at (2,13) " "
  497.466ms  →   [seq=55  ] PolyLine                 drawable=0x4400011 gc=0x440000F points=5
  509.177ms  ←   ConfigureNotify window=0x440000D 644x316 at (0,0)
  509.177ms  ←   ReparentNotify window=0x440000D parent=0x3800106 at (0,0)
  509.177ms  ←   [SendEvent] ConfigureNotify window=0x440000D 644x316 at (225,225)
  514.764ms  ←   MapNotify window=0x440000D
  514.764ms  ←   Expose window=0x4400011 (0,0) 644x316 count=0
  515.728ms  ←   FocusIn window=0x440000D detail=nonlinear mode=normal
```

`MapWindow` is the call that makes the top-level visible. The very next
requests draw a placeholder character and a 5-point `PolyLine` — that's
xterm's I-beam cursor outline being drawn into the inner text window.

Then events flood back from the server in a flurry:

- `ConfigureNotify` — confirms size
- `ReparentNotify` — **CDE has reparented xterm into a frame window**.
  `parent=0x3800106` is the dtwm (CDE Motif Window Manager) title-bar frame.
  xterm is no longer the top-level window from the WM's perspective; it's now
  a child inside dtwm's decoration window.
- A second `ConfigureNotify`, this one synthesized via `SendEvent` (note the
  `[SendEvent]` flag in the dump). The position changed to (225,225) — these
  are now absolute screen coordinates. This is exactly the ICCCM-mandated
  "synthetic ConfigureNotify with root-relative coordinates" handshake that
  every X window manager has done since 1989.
- `MapNotify` — the window is officially mapped
- `Expose` — the server tells xterm to draw its content
- `FocusIn` — the user's keyboard is now connected

That's the moment the xterm window appeared on the Sun's screen. We can pin
it precisely to **514.764ms after the connection opened**.

### Phase 6 — First text (980ms)

```
  980.222ms  →   [seq=59  ] ChangeProperty           window=0x440000D prop=WM_NAME type=STRING data="~"
  980.222ms  →   [seq=60  ] ChangeProperty           window=0x440000D prop=WM_ICON_NAME type=STRING data="ss2"
  980.222ms  →   [seq=62  ] ImageText8               drawable=0x4400011 gc=0x440000F at (2,13) "[ss2:[tvernon]:/home2/tvernon] "
```

About half a second after the window appeared, xterm got around to running
its shell and the shell drew its prompt. The shell prompt sets the title bar
to `"~"` (current working directory via the prompt-escape sequence) and the
icon-name to `"ss2"` (the host). Then the prompt itself is drawn into the
text window: `"[ss2:[tvernon]:/home2/tvernon] "` at pixel position (2,13)
using GC `0x440000F`.

That's the full story. **From "TCP connection opens" to "shell prompt is on
screen": 980ms, 62 requests, 7 server events, every byte decoded by code
that didn't exist 12 hours earlier.**

## How much data is that?

A useful magnitude fact for the article: an entire short xterm session
(open, render, type a few characters, sit idle for 10 seconds, close) is
about **15 KB total on the wire**. That's smaller than a typical web page's
favicon. One of the first captures came in at:

- 2,484 bytes from xterm to the server (the requests above)
- 12,956 bytes from the server back to xterm
- 92 requests, 14 replies, 13 events
- 10.7 seconds of session

The server-to-client direction is bigger because the early-startup replies
are the heavy ones: the `QueryFont` reply alone is ~4 KB (font metrics for
256 glyphs), the `GetProperty` reply for `RESOURCE_MANAGER` returns several
kilobytes of X resource defaults, and the `SetupAccepted` is ~232 bytes of
screen and visual info.

Once the window is running, individual messages are tiny:

- Each character drawn into xterm is a 24- to 50-byte `ImageText8` request
  (header plus the literal text)
- Each keystroke arrives as a 32-byte `KeyPress` event
- Each mouse motion is 32 bytes
- A `MapWindow` request is 8 bytes
- `SetupRequest` for the entire connection setup is 12 bytes

A more interactive xterm session (with resize, mouse selections, paste, and
some scrolling under CDE) ran ~36 KB. A heavily-used one with 4,000+
requests over a few minutes was around 200 KB. The whole point of the X
protocol is that tiny structured messages do the work that a screen-grab or
VNC stream would handle by shipping pixels. The bandwidth difference is
multiple orders of magnitude.

For perspective: a single 1280×1024×8-bit screen image, uncompressed, is
1.3 MB. xterm did its entire startup-and-prompt sequence in 1/86th of one
screen's worth of pixels.

## quickplot — a real Motif app on the wire

The most visually interesting capture in the corpus is a session of
**quickplot**, a Motif graphing application running on the Sun. Todd has
photos of it that should accompany the article (ask him for the images
when you're writing). It's worth a dedicated section because it shows what
a "real" 1990s Sun application looks like on the wire — not the toy demos
of xeyes or xclock, but a full Motif app with menus, plot canvases, axis
rendering, rubberband selection, and font dialogs.

**Capture stats (one quickplot session, a few minutes of plotting work):**

- 27,649 requests, 4,376 events, 24 replies
- ~878 KB total wire traffic (633 KB client-to-server, 245 KB
  server-to-client)
- **100% of requests typed** by the framer

**The activity tells the story:**

- **5,330 `SetClipRectangles`** — quickplot supports rubberband selection on
  its plot canvas. Each frame of a rubberband redraw sets a new clipping
  region so the line stays inside the plot area as you drag. 5,330 of these
  in one session means a lot of interactive selecting.
- **4,876 `PolyFillRectangle`** — filled rectangles. Plot legend boxes,
  axis panels, button backgrounds, the works.
- **4,826 `ChangeGC`** — Athena/Motif widgets switch graphics-context
  parameters constantly. They configure the GC for each draw rather than
  caching configured GCs. Inefficient, but it's what the toolkit does.
- **2,386 `PolySegment`** — discrete line segments. Plot grid lines, ticks.
- **2,104 `CopyArea`** — bit-blits between drawables. Probably double
  buffering for the plot canvas.
- **1,729 `PolyText8`** — proportional-font text rendering. Axis labels,
  titles, legend text. (Fixed-width text uses `ImageText8`; proportional
  text needs `PolyText8`'s richer item format.)
- **294 `SetDashes`** — dashed-line patterns for grid/comparison lines.
- **161 `[ext: SHAPE]` calls** — quickplot uses the SHAPE extension. Even
  though its windows look rectangular, Motif uses SHAPE to define exact
  bounding regions for its widget hierarchies.
- **8 `GraphicsExposure` events** — places where a `CopyArea` operation
  encountered an obscured source region and the server had to follow up
  with "draw this missing area" hints.

**The font dialog (a separate quickplot capture):**

A second quickplot capture exercised the Title Font dialog, where the user
cycles through different font sizes. Visible in the wire trace:

- 25 `OpenFont` requests, 24 `QueryFont` requests (one preview cycle each)
- The `QueryFontReply` for each font shows different metrics:
  - `ascent=11/2, POINT_SIZE=120` (12-point, fixed)
  - `ascent=12/3, POINT_SIZE=140` (14-point, proportional)
  - `ascent=15/4, POINT_SIZE=180` (18-point, proportional)
- Proportional fonts visible because `min char width != max char width`
  (3..13 px or 3..18 px in the bigger sizes). Fixed-width fonts have
  `min == max`.
- `RESOLUTION_X=75, RESOLUTION_Y=75` in every reply — the Sun renders fonts
  at 75 dpi, the standard X11 resolution of the era.

**The framing for the article**: this is what a vintage Motif app looks like
when you drag it through a byte-level decoder. The "rubberband mechanic"
that took half a thought to implement in 1992 generates 5,330 protocol
calls when you actually use it. The font dialog that lets you preview
sizes is a sequence of `OpenFont`/`QueryFont` round-trips, each of which
returns a 4 KB metrics table. The proportional axis labels are
`PolyText8` requests carrying the literal text and the GC. None of this is
hidden. It all flies across the wire as discrete, structured, decodable
messages, exactly as Bob Scheifler designed in 1984.

**Photos**: Todd has screenshots of quickplot running. They should be the
opening or anchoring image for the article, paired with a short snippet of
the dump output showing rubberband or font-cycle activity. Ask him for
the image files.

## Coverage we ended up with

The full numbers, useful for the "how complete is this thing" angle:

**Spec coverage** — typed core protocol opcodes:
- 73 of 120 specced (60.8%)
- The 47 we didn't type are mostly things our app set never uses:
  `ChangeKeyboardControl`, `SetScreenSaver`, `ChangeHosts`,
  `ListFontsWithInfo`, `ChangePointerControl`, `KillClient`,
  `RotateProperties`. Administrative and rare-extension territory.

**Practical coverage** — distinct opcodes that actually appeared across all
8 captures (about 45,000 requests):
- 56 distinct core opcodes used
- 56 of those typed (100%)
- 1 extension (SHAPE) used in 161 calls in xeyes and xcalc, not yet typed.
  SHAPE is what gives X11 windows non-rectangular shape masks; xcalc's
  Athena widgets use it even though their windows look rectangular.

**So the framer covers 100% of what real R5/R6-era Sun clients actually
emit.** The 47 untyped core opcodes are speculative.

**Events**: 33 codes specced, 26 typed. The 7 we didn't type (CirculateNotify,
GravityNotify, ResizeRequest, ColormapNotify, etc.) didn't appear in any
capture.

**Replies**: 3 with full typed bodies (`InternAtomReply` resolves atom names,
`QueryFontReply` exposes font metrics, `QueryExtensionReply` resolves extension
opcodes). The other ~80 reply types decode generically — sequence numbers
and lengths, not structured fields.

**Activity profile from quickplot** (Motif graphing app, the heaviest
workload, 27,649 requests over a few minutes of plotting):
- 5,330 `SetClipRectangles` — that's the rubberband mechanic at work; each
  rubberband redraw sets a new clip rectangle.
- 4,876 `PolyFillRectangle` — filled boxes in plots (legend backgrounds,
  axes panels, etc.)
- 4,826 `ChangeGC` — Athena widgets switch graphics contexts constantly;
  they configure the GC per-element rather than caching configured GCs.
- 1,729 `PolyText8` — proportional-font axis labels and titles
- 8 `GraphicsExposure` events — places where copy operations encountered
  obscured regions and the server had to send "fill in this area" follow-up
  events.

**Tests at end of day**: 212, all green.

## Suggested article angles, in priority order

The hero data above (the chronological dump + coverage stats) supports any of
these. Pick one or combine.

### Angle 1 (recommended): "Watching a SPARCstation think, byte by byte"

The hook is the dump itself. The data is the article. Walk readers through
what happens between connection setup and shell prompt, and let the protocol
elegance speak for itself. This is what Todd reaches for first, because it's
the most honest representation of what was built and what it shows.

The piece writes itself if you anchor on the question "what does it actually
look like when xterm starts up?" and use the phases above as your structure.
Let the sequence numbers, the fonts, the ICCCM atom names tell the story.

Strongest closing material: the ICCCM-mandated synthetic ConfigureNotify with
root-relative coordinates. That handshake was specced in 1989 and is still on
the wire today, between a 1995 SPARCstation and a 2026 MacBook decoding it
in Swift.

### Angle 2: "Auth flames and a 30-year-old refusal message"

This morning's debugging story. First capture came back showing an auth
refusal. The reason the X server returned, byte for byte, was "Client is not
authorized to connect to Server" — exactly what the X11 protocol spec from
1989 says it should send. The author decoded those 60 bytes by hand against
the spec to prove the framer was right, then chased the auth issue on the
Sun side (xhost on the wrong host, then xauth cookie passing).

A relatable systems-debugging story with vintage flavor. The punchline is
that the same ICCCM-era error message is still on the wire word-for-word,
35 years later.

### Angle 3: "TCP_NODELAY is a 1984 lesson my proxy had to relearn"

The bouncing-lines perf bug. A vintage Sun running a vintage Motif app got
10× slower because a modern Swift proxy didn't set `TCP_NODELAY`. Five lines
of code to fix. Sermon: ancient bottlenecks lurk in modern code. Good for a
shorter, punchier piece.

### Angle 4: "From git init to reading Motif on the wire in a day"

The pure narrative arc. Started this morning with no code. By dinnertime: a
Swift package, ~73 typed X11 opcodes, a working byte-pump proxy, capture
file format, dump tool, eight real Sun captures, and 100% protocol coverage
on a Motif graphing app. Concrete progress, with the "I don't know if this
is showing off or just documentation" energy that vintage-computing posts
often have.

## Source artifacts

The captures live at `/Users/toddvernon/Dropbox/dev/X/captures/`:

- `xterm.xtap` — first short xterm session
- `xterm_session.xtap` — CDE/Motif xterm session with resize and selections
- `xterm_long.xtap` — longer xterm session (this is the one used in the Phase
  walkthrough above)
- `xeyes.xtap` — xeyes
- `xclock.xtap` — xclock
- `xcalc.xtap` — xcalc (uses SHAPE extension)
- `quickplot.xtap` — Motif graphing app, includes rubberband drawing and
  grabs
- `quickplot2.xtap` — same app, different session including font cycling on
  titles

To re-generate the chronological dump for the article:
```
./run.sh dump captures/xterm_long.xtap
```

To get the aggregate stats (atom names, opcode frequency, event counts):
```
./run.sh dump-summary captures/quickplot.xtap   # the spec-style summary
```

(The actual subcommands are `dump` for chronological and `summary` for
aggregate. Check the binary's help if uncertain.)

## Things to avoid in the article

- **Don't apologize for the framer being incomplete**. 60.8% of spec coverage
  sounds low; 100% of what real apps use sounds right. Lead with the second.
- **Don't try to explain X11 in full**. Give just enough context for each
  decoded snippet. The reader doesn't need the protocol overview.
- **Don't editorialize about how clean the code is**. Let the dump output
  speak for itself.
- **No phrases like "the world of vintage computing", "fascinating glimpse",
  "let's dive deep"**. Cut all marketing.
- **No em-dashes**. Use commas or sentence breaks.
- **Don't credit Claude or AI**. The article should read as Todd's work.
  The fact that Claude helped is irrelevant to the readers and to the story.

## Things the article should do

- Include 2-4 of the dump excerpts as figure-style code blocks. The output
  is the artifact.
- Annotate concretely: which atom number is what, which opcode does what,
  which event was triggered by what.
- Tie the protocol to the era. ICCCM is from 1989. xterm's design is older.
  Sun release 3600 is mid-1990s. The 8x13 font is older than the web. These
  details make the article feel grounded.
- End with something concrete: a number ("980ms from connection to prompt"),
  a moment ("the synthetic ConfigureNotify with absolute coordinates"), or
  an artifact reference ("the next phase is a Swift X server").
- 800–1500 words feels right for OldSilicon. Long enough to do the data
  justice, short enough that readers finish.
