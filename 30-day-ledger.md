# macXserver: a 30-day ledger

Project start: 2026-05-05. Day 30: 2026-06-03.

The goal was to find out whether one person with an agentic coding setup
could build a usable X server on macOS in a month. Not a feature-complete
clone of XQuartz, and not a research prototype either. Something I would
actually use to display real X clients from my Sun workstations on my Mac,
with modern rendering and display scaling that I could live with day to day.

One short entry per day. What landed, and the occasional moment where
something clicked. Hours are estimated from git timestamps (first commit
to last commit, with adjustments for obvious meal breaks and the days
where most of the work happened before the first push). The opcode
count is the cumulative number of rows tracked in `OPCODE_STATUS.md`
by end of day, where a row is one X11 wire interaction (setup, a core
opcode, an event, or an extension entry). Three of the jumps were
audit-driven, not pure implementation work — the entries call those
out. Velocity is a rough four-tier read on the day: **high** (a major
unlock or a big block of work that all stuck), **solid** (productive,
everything landed), **mixed** (net forward, but some hours went into
work that got reverted or hit a dead end), or **off**. I never regressed
the test suite, but I did chase a few things that didn't pan out — those
are the mixed days.

---

## Day 1 — 2026-05-05 (~3h · 0 opcodes · solid)

Started with the capture tool, not the server. The idea: before I write a
single byte of server code, I want to record exactly what real X clients
are sending over the wire. So Day 1 is a framer plus a proxy that sits
between client and server and dumps every request and reply to disk. No
rendering yet. No NSWindow. Just bytes in, bytes out, decoded.

## Day 2 — 2026-05-06 (~3h · 22 opcodes · solid)

Capture v1 closed: replay subcommand, round-trip test against a real X
server, a small corpus of captured sessions. Then I pivoted to Product 2
(the server itself): reference infrastructure (X11R6 source, the protocol
spec, XQuartz source as a comparison), the first design docs, and the
review-gate convention. Scaffolding day, but a necessary one. Capture was
going to be the lens I used to debug everything that came after.

## Day 3 — 2026-05-07 (~11h · 36 opcodes · high)

First pixels on screen. M1 (socket + handshake), M2 (first NSWindow),
and M3 (xclock rendering) all landed on the same day. Then display-adaptive
integer scaling, an XLFD parser, a font resolver that maps X font names to
Core Text, ImageText8, PolyFillRectangle, and ListFonts. By evening live
xterm was working: keyboard input, scrolling, resize, focus cursor. Eight
hours from "blank window" to "I'm typing into it." The XLFD parser and
the font resolver are the start of what becomes the multi-day xterm
text rendering arc; today they map the names, the cell-size question
gets answered over the next two days.

## Day 4 — 2026-05-08 (~6h · 41 opcodes · high)

Color xterm with ANSI palette parsed per-bit out of the GC. xcalc from my
Ultra 5 running live with PolyText8 and AllocNamedColor. Scrollback fixed
after I tracked down a ChangeWindowAttributes path that was auto-repainting
and wiping scrolled content. Cut-to-clipboard round-trip working. The
+0.5 user-pixel CTM shift on the stroke plane killed the cursor-fragment
ghosts I'd been chasing all afternoon. Multi-client server now identifies
sessions by WM_CLASS in the logs. The xterm text arc gets its first
attempt today too: fit Monaco into xterm's requested cell by computing
the pointSize from `min(cellW/advance_ratio, cellH/lineHeight_ratio)`
and correcting Monaco's line-height ratio from 1.07 to 1.2. It rendered,
but Monaco at fractional pointSize was reading as "too bold" because
Core Text's hinter can't quite save fractional sizes. That set up
tomorrow.

## Day 5 — 2026-05-09 (~8h · 41 opcodes · mixed, ended on a Motif click-dispatch dead-end)

The xterm text arc resolves. Cell follows the selected font, not the
other way around — iTerm2's playbook. When xterm asks for `7x14`, pick
the integer pointSize closest to what fits, instantiate Monaco at that
size, ask Core Text for its actual advance / ascent / descent /
lineHeight, and report Monaco's actual cell in `QueryFont`. The XLFD
becomes a hint, not a contract. Integer pointSize is the unlock:
Core Text's hinter does its best work there, and the "too bold" stem
asymmetry from yesterday's fractional sizes disappears. Reported metrics
equal rendered metrics by construction. EnterNotify and LeaveNotify
wired up so Athena widgets hover correctly. NSCursor substitution gives
me an I-beam over the xterm text area. Then I broke through Motif /
quickplot init: GrabPointer, QueryBestSize, override_redirect,
SetInputFocus, real event time and state. By end of day quickplot from
the Ultra 5 was rendering and accepting clicks.

## Day 6 — 2026-05-10 (~5h · 66 opcodes · solid)

Big architectural day. I had been running per-session split read/write
threads, and there was a race I couldn't make go away. So I consolidated
to a single Grand Central Dispatch `protocolQueue` per session that owns the socket and the
session state. Same day: Xt menu support, fake CDE customization daemon
plus a SelectionNotify time-field fix that I would later discover was
the actual unlock for the dt-apps. Captured a corpus of SS2 gold pairs
to test against. Planned the week ahead because I was about to be away
from the workshop.

## Day 7 — 2026-05-11 (0h · 66 opcodes · off)

Day off

## Day 8 — 2026-05-12 (0h · 66 opcodes · off)

Day off

## Day 9 — 2026-05-13 (~6h · 66 opcodes · solid)

Back at it. Started the region work: built a small region algebra (type
plus the four set ops), wired `clipList` and `borderClip` into every
window entry, and made Expose emission use the rect list rather than
the bounding box. Locked Expose-event counts per captured app in the
test suite so I'd catch any regressions immediately. Also shipped
`swiftx-capture diff`: a markdown gold-vs-swiftx comparison tool with
LCS alignment. Adopted "XError honesty is the default" as policy:
silent drops are now a test failure.

## Day 10 — 2026-05-14 (~7h · 75 opcodes, +9 mostly from the XError sweep · high)

XError emission sweep. A wire-level XError is the protocol-correct way to
tell a client "I can't serve this request." Every handler that had been
silently dropping bad inputs got converted: 22 window handlers, 13 GC
handlers, drawable validators on CopyArea / GetGeometry / ClearArea /
PolyText, atom and font and pixmap and cursor validation on top. Most
real clients handle XErrors gracefully — what they don't handle is being
lied to. About forty silent-drop bugs surfaced and closed.

## Day 11 — 2026-05-15 (~7h · 86 opcodes · high)

Ran a comparison study against XQuartz and Xvfb on the same captured
corpus. Spec-honesty sweep on colormap opcodes, DestroyWindow,
CirculateWindow. ChangeWindowAttributes now honors and round-trips all
13 CW bits. QueryTextExtents fix turned out to be the unlock for Motif
menu-title spacing on quickplot. Audit of recent "good enough" shortcuts
caught four real bugs.

## Day 12 — 2026-05-16 (~3h · 86 opcodes · solid)

Visual day. Disabled anti-aliasing and interpolation on rect fills, then
baked it into the `withClip` helper for every non-text draw. Rectangles
were soft-edging at scale 3 because Core Graphics was happily resampling
them; the fix is one line per call site but I'd been seeing the ghosted
edges for a week before I traced it.

## Day 13 — 2026-05-17 (~6h · 86 opcodes · high)

Pixmap rendering. Built a `PixelBuffer` plus a `DrawTarget` that gives
the same drawing surface whether the destination is a window or an
off-screen pixmap. CopyArea now works across all five spec variants
(window→window, window→pixmap, pixmap→window, pixmap→pixmap, same
drawable). QueryFont got a charset-aware reply with proper CHARSET
FONTPROPS. Rebased the gold capture set onto SS2 + X.org R6 + MWM
(no CDE), which is closer to what most readers will recognize than the
dt-app-heavy Ultra 5 captures.

## Day 14 — 2026-05-18 (~10h · 87 opcodes · high)

Retired the CDE customization-daemon impersonation. It had served its
purpose on Day 6, but it was a lie I couldn't keep paying for. Instead,
I established the `MOTIF_TEXT_QUALITY` invariant: a single source of
truth for glyph advances, so the metrics we report to the client and
the metrics we render with are identical by construction. Tier 1
RESOURCE_MANAGER landed: curated Motif widget-class font defaults
shipped in the binary. The XmText caret now renders correctly because
pixmaps allocate at the window's device scale.

## Day 15 — 2026-05-19 (~5h · 87 opcodes · solid)

Honored the X server bg-paint contract end to end. Athena and Motif
widgets count on the server to paint window backgrounds — they set
`background_pixel` and trust us. We weren't, in a few specific cases
(clipping, paint-on-grow, GC bg default), and "white where the bg
should be" was the symptom. dtcalc LCD rendering fixed by translating
clip rects by the widget's window offset. 542 tests green by end of day.

## Day 16 — 2026-05-20 (~9h · 87 opcodes · high)

Ah-ha day. Motif menu clicks were silently dropping and I couldn't see
why. The unlock: ICCCM 4.1.5 says that when a rootless server acts as
the window manager, it has to emit a *synthetic* ConfigureNotify after
MapNotify and after any move. Motif caches each widget's root
coordinates at realization and only invalidates that cache on a
synthetic event. Without it, the click coordinates the toolkit compares
against are stale by exactly the frame offset, and every menu click
misses. One protocol detail, weeks of latent bugs gone.

## Day 17 — 2026-05-21 (~8h · 87 opcodes · high)

PutImage with format=Bitmap (1bpp source rendered into the destination
via GC foreground/background). Motif submenus unblocked after four
event-emission fixes plus drag-mode submenu transitions matching Sun's
boundary-crossing semantics. TranslateCoordinates now folds the
top-level's root position into the reply. ConfigureWindow on top-levels
pushes through to the actual NSWindow frame.

## Day 18 — 2026-05-22 (~8h · 108 opcodes, +21 from the x11perf + error-path sweep · high)

`x11perf -all` clean sweep: 254 of 254 tests pass against the server.
Same day, 69 new error-path tests caught six silent-drop bugs that the
happy-path coverage was missing. Theme pass on the CDE dt-apps: dtcalc,
dtterm, dthelpview, dtpad all looking right. Per-app dialog chrome
rules in place.

## Day 19 — 2026-05-23 (~7h · 109 opcodes · high)

Multi-session lookup-registry fix: invisible menu text in the second
running app was a bridge state collision between sessions. Themes
Phase 1: user-editable resource file in `~/`, with a Cocoa editor
window (line-number gutter and a dark code-editor theme). Font
substitution table also promoted to a user-editable file. Then the
capture v2 push: extracted a `CaptureSink` protocol, added a
SessionCapture path with a Listener byte tee, ListFontsWithInfo (op 50),
and the first six steps of the SwiftUI capture app: Record / Open / Replay.

## Day 20 — 2026-05-24 (~9h · 109 opcodes · mixed, one of three agent-driven fixes got reverted next morning)

Capture v2 done: one binary that routes between CLI and GUI. README
refreshed. Xcode workspace pipeline (xcodegen). Symmetric rename to
`MacXServer` / `MacXCapture`. Optional Motif window-frame for X
top-levels: `MotifFrameView`, opt-in via Preferences. Three subagent-
driven fixes for dtpad theming, resize-uncover Expose, and an idle-loop
diagnosis.

## Day 21 — 2026-05-25 (~10h · 109 opcodes · mixed, the resize-cascade marathon with three reverts before the delta cascade stuck)

The resize-cascade marathon. The original day's expose-on-resize
extension regressed dtpad badly, so I reverted it and worked the
problem from scratch. Took most of the day, but the result was a clean
"delta cascade": when a window's clipList changes, paint background and
emit Expose over only the new clipList, walk siblings whose clipList
grew, and walk parent chain for the right effective background when a
widget has none. Quickplot at 100% by evening. Three resize bugs gone.
Also ported the rest of `miregion` (inverse, reset, rects, append,
normalize) straight from the X11R6 source instead of re-deriving.

## Day 22 — 2026-05-26 (~6h · 109 opcodes · solid)

Pivoted off the Dropbox-shared bare git repo. Dropbox was conflict-copying
LMDB lock files in `.build/` and silently corrupting pack files in the
shared bare repo. Cut over to a private GitHub remote and moved the
working tree out of `~/Library/CloudStorage/` to a local path on both
Macs. Same day: a y-flipped CopyArea fix that gave the horizontal
scrollbar thumb its proper shadow, and a GC dash-state leak across
draws.

## Day 23 — 2026-05-27 (~8h · 109 opcodes · solid)

Y-flip primer doc + an asymmetric-source orientation test that every new
graphics op now has to pass. Closed four verified-fixed bugs and three
SHORTCUTS entries. Architectural: moved root-window properties up to
the ServerCoordinator so they're server-global rather than per-session.
That unblocked Motif clipboard cross-session copy/paste. Shipped a
remote app launcher: one-click X-app launch from a vintage Sun over
telnet with passwords in Keychain. Motif frame chrome configurable from
the resource file.

## Day 24 — 2026-05-28 (~4h · 118 opcodes, +9 from SHAPE and friends · solid)

SHAPE extension (major opcode 128). oclock renders round, xeyes
renders as a bare oval (it reshapes its top-level via Xmu + a 1-bit
pixmap mask), and the Motif frame integrates with `SetFrameShape` so
shaped clients get appropriate frame chrome. Negotiated TERM=xterm
over telnet on the launcher so the remote shell's prompt setup runs.

## Day 25 — 2026-05-29 (~10h · 138 opcodes, +20 from the macXcapture decoder-coverage audit · high)

Capture viewer windows with syntax-highlighted decoded chrono output.
Extracted `SwiftXCaptureUI` as a shared library so the capture app and
the server's debug viewer use the same widget. Redesigned the Record
screen as a stacked 6-step wizard. Distinct red `XTAP` icon for the
capture app vs the blue X icon for the server. Wrote the `macXcapture`
mission doc plus the phased decoder coverage plan.

## Day 26 — 2026-05-30 (~8h · 138 opcodes · high)

Decoder coverage push. Phase 1 of the framer closed 16 requests, 6
replies, and 5 events. Built an extension dumper registry. Added
BIG-REQUESTS, MIT-SHM, XKB, XInput v1, and RENDER decoders — the last
three are large surfaces and took three sessions each. Capture v2 picked
up a request/reply pairing glyph and field-level semantic diff. Also
shipped the inline narrative landmark detector: `# story-form` callouts
in the capture, with viewer-side navigation (sidebar + Cmd-] / Cmd-[).

## Day 27 — 2026-05-31 (~6h · 138 opcodes · high)

Capture decode polish day. Keysyms and modifiers now show symbolic
names instead of raw codes. Type-aware decode for ICCCM `WM_*` and
`_MOTIF_*` properties, ClientMessage payloads, and a type-driven
fallback for unknown properties. XC-MISC, XTEST, and RECORD decoders.
Session-wide resource registry with lineage and leak annotations
(promoted into live XError landmarks the same day). Then a server-side
afternoon: PutImage ZPixmap depth=1 + depth=8, CopyGC (op 57),
GetKeyboardControl (op 103), four bug closures from the audit.

## Day 28 — 2026-06-01 (~10h · 138 opcodes · solid)

Curated the captures corpus for the open-source launch, with a two-pass
fact-check. SHAPE bounding-and-clip shapes now apply on descendant
windows via clipList. Shipped a `--scale {2,3}` CLI flag with
auto-scaled Motif chrome and integer-point bevel snapping. WM_NAME
fallback for capture identification when no WM_CLASS is present, plus a
batch rename of eight previously-unidentified captures by wire
fingerprint.

## Day 29 — 2026-06-02 (~6h · 138 opcodes · solid)

Display Size radio in Preferences (Auto / Comfortable / Compact) wires
through to the `--scale` flag. Wrote the device-coords refactor plan:
internal regions had been carrying user-coord values that were getting
re-scaled at every draw site, which was the underlying cause of a
recurring class of resize bugs.

## Day 30 — 2026-06-03 (~10h · 138 opcodes · high)

Device-coords refactor end to end in six phases on one day. ClipListEngine
and the SHAPE extension converted to device-coord regions, the drawing
handler did a unit sweep, and the dual-representation patches from the
prior day were deleted clean. Closing fixes: server-global pointer
cache plus Motif-frame `mouseMoved` so xeyes tracks the cursor across
sessions, and per-app dialog enumeration replaced with a composite
chrome-thinning rule + borderWidth.

---

## Threads that spanned multiple days

A few pieces of the project were arcs, not single-day landings. Worth
calling out because the daily entries only show fragments.

**xterm text quality (Days 3–5).** The cell-fits-font story. Day 3 built
the XLFD parser and the font resolver. Day 4 tried fitting Monaco into
xterm's requested cell at fractional pointSize and rendered correctly
but read as too bold. Day 5 flipped it: pick the integer pointSize that
fits, instantiate Monaco at that size, and report Monaco's actual cell
back to the client. Cell follows font. Reported metrics equal rendered
metrics by construction. This is the principle that lets xterm sit
comfortably next to an iTerm2 window, which was the bar for the project.
The same invariant generalized to proportional fonts on Day 11
(QueryTextExtents) and got hardened into the `MOTIF_TEXT_QUALITY`
contract on Day 14 (per-character `characterWidth`, two-sided enforcement
of reporting versus rendering).

**Region tracking and bg-paint (Days 9–21).** The region work landed
incrementally. Day 9 built the algebra and wired `clipList` and
`borderClip` into every window entry. Day 15 honored the X server's
bg-paint contract end-to-end. Day 16 added the ICCCM 4.1.5 synthetic
ConfigureNotify that Motif relies on. Day 17 routed ConfigureWindow
through to the actual NSWindow frame. Day 21 was the resize-cascade
marathon that produced the delta-cascade rule (sibling whose clipList
grew gets bg-paint plus Expose), which closed the last of the visible
resize bugs across dtpad and quickplot.

**Pixmap rendering and graphics y-flip (Days 13, 22–23).** Day 13 built
the `PixelBuffer` plus `DrawTarget` foundation and made CopyArea work
across all five spec variants. The y-flip gotchas surfaced on Days 22
and 23 (the horizontal scrollbar thumb shadow, then the pixmap-writer
needing a counter-flip). Day 23 wrote the y-flip primer doc plus an
asymmetric-source orientation test that every new graphics op now has
to pass.

**Capture v1 → v2 (Days 1–2, 19–20, 25–27).** Day 1 was the framer plus
the CLI proxy. Day 2 was replay and the corpus round-trip. Day 19 was
the v2 architecture push (CaptureSink protocol, SessionCapture,
Listener byte tee, and the SwiftUI app skeleton). Day 20 unified it
into one binary. Days 25–27 were the decoder coverage push:
SwiftXCaptureUI as a shared library, the 6-step Record wizard,
framer Phase 1, the extension dumper registry, and the type-aware
decoders for keysyms / modifiers / ICCCM / Motif / RENDER / XKB / XInput.

---

## Where it landed on Day 30

Working server with display-adaptive integer scaling, anti-aliased font
rendering through Core Text, ICCCM 4.1.5 WM emulation, the SHAPE
extension, optional Motif window frames, multi-client and multi-session,
remote app launching from vintage Suns, server-side and client-side
session capture with a decoded chrono viewer, and `x11perf -all` clean.
Live X clients running so far: xterm, xcalc, xeyes, xclock, oclock,
quickplot, dtcalc, dtterm, dthelpview, dtpad, dticon, and a long tail of
smaller tools.

What's still rough is its own list. The challenge was whether 30 days
was enough to get a real X server I could use day to day. The answer
turned out to be yes.

Total time: roughly 205 hours over 28 working days. About five and a
half standard workweeks of focused effort, spread across the calendar
month.
