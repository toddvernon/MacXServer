# Post 3: First bytes on the wire

**Date range**: May 6 - May 7, 2026 **One-line elevator**: With the capture tool done and a corpus in hand,
the X server's first milestone was making xclock connect and stay connected for sixty seconds. No window yet,
no pixels. Just bytes correctly parsed and stub replies sent.

## What this post covers

Product 2 milestone M1. The server's first day. Why xclock as the target. What "stay connected" actually
requires. The captured corpus paying off as test fixtures from day one.

TODD: From what i recall xclock was my idea, but might have been claude.  I wanted an x app that i knew
as all xlib based so fairly protol pure.  has no feed back from the user, i literally is all output
(its a clock face) and the graphics primitive are simple.  It literally doesn't get more simple than
xclock.  ( i also recall it was pretty easy to get working, but the commit record may say otherwise)

## Setting

Capture tool done. Corpus exists with xclock, xterm, xeyes, xcalc, quickplot. The framer decodes and
round-trips every C2S byte semantically. Server work begins on a known-good codec, with byte-level ground
truth for every test.

The first question: what's the smallest target that actually exercises the X server?

## Thread anchor: protocol vs implementation

M1's goal "xclock connects and stays connected" is a pure protocol-contract test. We're not implementing
X.org. We're implementing the wire-level handshake X11R6 specified, with stub replies whose only requirement
is the right byte format and right sequence numbers. The protocol's stability guarantee is what makes this
milestone meaningful: get the bytes right, the 1989-vintage xclock binary behaves correctly. Worth surfacing
in the body to keep the thread alive.

## Why xclock

xclock is the smallest possible X client that exercises:
- Connection setup (SetupRequest, SetupAccepted with realistic byte format)
- Resource creation (windows, GCs, pixmaps, fonts, atoms)
- Drawing primitives (PolySegment for ticks, FillPoly for hands, PolyLine for hand outlines)
- Mapping (CreateWindow + MapWindow on top-level)
- Exposes (drawing on first map, redraw on resize)
- The close protocol (WM_DELETE_WINDOW via ClientMessage)
- NSWindow integration (when M2 lands)

Every bigger client is a strict superset. xterm is xclock plus text. xcalc is xclock plus widgets. Get xclock
working and everything else is incremental.

TODD: or so we thought.  Forshadow that things went a bit off the rails with xfontsel.  Also seemed very
easy and the menu stuff was not easy.

## M1 goal

"xclock running on u5 against swiftx-server doesn't disconnect with a protocol error for 60 seconds."

Bare minimum:
1. Server listens on `:6000`. Reads SetupRequest from the connecting client.
2. Sends back a hardcoded SetupAccepted: one screen, one PseudoColor 8-bit visual, one pixmap format, vendor
   "swift-x", a fabricated resource-id-base.
3. For every C2S request, parse via the framer.
4. Send stub replies for the requests xclock waits on:
   - `GetProperty` (empty)
   - `AllocColor` (synthetic pixel)
   - `InternAtom` (monotonic ID assignment)
   - `QueryFont` (minimal valid stub)
   - `GetInputFocus`
   - `QueryExtension` (present=false, makes xclock fall back to core protocol)
5. Track resources internally (windows, GCs, pixmaps, fonts, atoms) but don't render anything.

## What "stay connected" requires that you might miss

The first time an X client connects, it does a flurry of probes: which extensions are present (we say no to
all), what fonts exist (we lie with a stub), what's the resource ID base (we fabricate). If any of these gets
the wrong reply size or wrong format, the client tears down with `Xlib: sequence lost` or similar.

Sequence numbers matter from byte one. The framer parses them; the server has to stamp them on every reply. We
learned this on day one when the first SetupAccepted shipped with a wrong-size reply and xclock immediately
disconnected.

## Resource tables

Six X11 resource types, each with its own table. Started simple, grew with the project:

| Resource | Table |
|---|---|
| Atom | `AtomTable`. monotonic IDs from 69, predefined 1-68 baked in |
| Window | `WindowTable`. full subtree, NSLock-protected (read thread + Cocoa main thread) |
| Pixmap | `PixmapTable`. id/depth/dimensions; bytes from PutImage discarded (xclock's icon pixmaps aren't used in rootless mode) |
| GC | `GCTable` + `GCState`. raw mask+valueList stored, materialised on demand |
| Font | `FontTable`. name stored, stub QueryFont reply |
| Colormap | `ColorTable`. synthetic monotonic pixels from 16, pixel→RGB16 cache |

Atoms predefined 1-68 are baked in. Anything beyond that the client interns and the server assigns
sequentially. Property atoms (`WM_NAME`, `WM_PROTOCOLS`, etc.) are predefined; toolkit atoms
(`_MOTIF_WM_HINTS`, `WM_LOCALE_NAME`, etc.) get assigned.

## The replay regression test

Once M1 was running, the captured xclock byte stream became the regression test. `XclockReplayTests` feeds the
C2S bytes through a fresh ServerSession and asserts:
- No XErrors emitted
- Expected resource counts (2 windows, 4 GCs, etc.)
- Byte-for-byte identical output across chunked vs one-shot delivery
- No unknown opcodes

This test catches regressions instantly. Any change to the framer or the dispatcher that breaks xclock's
protocol path breaks the test. It's been running on every commit since.

## Pivotal moment

The first time xclock connected and stayed connected for 60+ seconds. No pixels yet. there couldn't be, M2
wasn't started. but the protocol path was alive. Sequence numbers monotonic, atoms interned, replies sized
correctly. The corpus paid off immediately: the test that fired on every save catching every regression.

## What Todd should add

- The "stay connected" moment, the first long-running session with no errors.

TODD: it just worked.  Im like fuck, wow.

- Whether the M1 work felt mechanical or surprising. The X spec is precise but Xlib has assumptions that
  aren't always documented.

TODD: it felt surprising and energizing. We were day one, day two on the server itself and the protocol
path was clean enough that a real Sun client thought it was talking to a real X server. No pixels yet, no
window even, just a socket where the right bytes were arriving and the right bytes going back. That
shouldn't have felt like much, but it did.

[CLAUDE: the "looked amazing at the proper scale" sentiment from the prior draft of this TODD note has
been moved to Post 5, where pixels first land. M1 had no visible output, so it had no scale story yet.]

- The decision to do stub replies vs real replies for some things. AllocColor stub vs real, QueryFont stub vs
  real. these are choices that matter later but were "make it shut up" decisions on day one.
- The sequence-number invariant. We rediscovered the hard way that Xlib's sequence-loss bailout is
  unforgiving.

## Anchors for fact-check pass

- Files: `PRODUCT_2_SERVER.md` (M1 section), `Sources/SwiftXServerCore/ServerSession.swift` (the
  per-connection state machine), `Sources/SwiftXServerCore/ResourceTables.swift`,
  `Tests/SwiftXServerCoreTests/XclockReplayTests.swift`
- M1 commit: `4a0dd24` 2026-05-07 "Ship Product 2 M1-M3: xclock renders on swift-x server" (M1 + M2 + M3 all
  shipped same day apparently)
- Pre-M1 scaffolding: `1f80038` 2026-05-06 "Scaffold Product 2 design docs and working conventions", `4775d58`
  2026-05-06 "Set up Product 2 reference infrastructure"
- Captured xclock corpus: `captures/xclock.xtap` + transcript
- Decision: PseudoColor 8-bit + TrueColor 24-bit visuals (DECISIONS.md 2026-05-05)
- Decision: Subset extensions only (SHAPE, BIG-REQUESTS) (DECISIONS.md 2026-05-05)

## Working title alternatives

- "M1: xclock just connects"
- "First sixty seconds"
- "The protocol stub that became an X server"
