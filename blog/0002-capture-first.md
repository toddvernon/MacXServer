# Post 2: Capture before code

Day one of MacXserver, I didn't write any X server code. I wrote a codec for the X11 wire protocol and a
passive proxy that sits between two Suns on the LAN and records every byte going in both directions.
Forty-eight hours later I had a corpus of real captured sessions for xterm, xclock, xeyes, xcalc, and
quickplot, all decoded byte-for-byte by the codec I'd just written, all checked into the repo as test
fixtures.

Then I started thinking about the server.

This is the patience move. The X protocol spec is precise about wire format. It tells you what's legal.
It does not tell you what a 1995 Sun client actually does in practice. The Xt and Motif libraries make
assumptions about server behavior that aren't quite written down anywhere. xterm on SunOS 4.1.4 has its
own per-build quirks. If I'd started by guessing at SetupAccepted byte layouts and seeing what hung, I'd
be debugging two unknowns at once: my code, and my mental model of what real Sun bytes actually look
like on the wire.

So the order of operations was: codec first, capture corpus second, server third. The codec lives in its
own Swift package (I call it the framer). The capture tool is another package on top of it. The server
that this series is mostly about will import both. Every test I write for the server is going to have,
as its ground truth, real bytes captured from a real Sun.

If you want the byte-level walkthrough of what xterm actually sends across the wire to an X server, I
wrote a companion piece on OldSilicon.com with Claude that walks an xterm startup byte by byte against
the X protocol spec. This post is the meta-story: why I built the codec before the server, and what
that bought me.

## The framer

A pure protocol codec for X11 wire format. Decoders and encoders for requests, replies, events, and
errors. No state tracking, no networking, no resource management. Bytes in, structured values out, and
back.

Scope: connection setup in both byte orders, both auth paths. Every core request defined in X11R6
(about 120 of them). All core replies, events, and errors. Encode for everything in scope, even though
decode alone would have been enough for the capture tool. The server I'd write next was going to need
encode. Doing it once and well meant not doing it twice.

Extensions deliberately deferred, with two exceptions: SHAPE (for cursor outlines and the override-
redirect popup windows Motif likes to use) and BIG-REQUESTS (because some clients send requests over
256KB). Everything else, Render, Composite, RANDR, GLX, is out of scope. The Sun clients I care about,
from 1987 through 1996, don't use those.

The framer ended up being the connective tissue of the whole project. Every piece of MacXserver reads
or writes through it. The capture tool decodes through it. The server decodes incoming requests and
encodes outgoing replies through it. One protocol library, multiple consumers.

## The capture tool

A Swift CLI that sits between two Suns on the LAN as a passive TCP proxy. Sun A is configured with
`DISPLAY=mac.local:0`. The Mac listens on `:6000` and holds the port. When Sun A opens an X
connection (because the user ran `xterm` or whatever), the Mac opens an outbound TCP connection to
`sun-b:6000`, the real Xsun on the second Sun, and shovels bytes both ways while the framer decodes a
side copy. Sun A thinks it's talking to the real X server. Sun B thinks it's talking to a real client.
The Mac records everything that flies between them.

Three subcommands. Default is proxy and record:
`swiftx-capture --listen :6000 --forward sun-b:6000 --output session.xtap`. The `dump` subcommand reads
a `.xtap` file and prints chronological decoded packets. The `replay` subcommand reads a `.xtap` and
feeds the client-to-server bytes back into a target X server.

The recorded file format is simple. An 8-byte header (`XTAP` magic plus version), then direction-
tagged framed records: a direction byte, an 8-byte nanosecond timestamp, a 4-byte payload length, then
the payload bytes verbatim. The payload is X protocol bytes unchanged. Not pcap. The X protocol sits
on a single TCP byte stream and the container only needs direction, timestamp, length.

A separate `session.xtap.json` sidecar holds metadata: byte counts, timing, recorded-at timestamp, the
auth name. Makes captures parseable in isolation without spelunking the binary.

## The corpus

Real sessions from real Suns, checked in as test fixtures. xterm (the canonical first capture, the
canary for everything text-related). xclock (animation, simple, no input, useful for event timing).
xeyes (cursor tracking, the input event paths). xcalc (Xt and the Athena widget toolkit). quickplot
(my own Motif app from thirty years ago, the real workload I care about).

Each capture has a paired markdown README describing what was on the screen and what got clicked. The
corpus is both the framer's regression test and the ground truth for every later server bug. When
something breaks, the question is always "what does the Sun-to-Sun gold trace do here that we don't?"
The corpus is the gold.

twm, CDE, and OpenWindows session-level captures were on the early list and got cut. The corpus's job
is framer regression testing plus protocol ground truth for the server tests; both well served by the
five apps I have. Adding more captures wasn't earning its keep.

## The OldSilicon article as a forcing function

I wrote the X11 wire-protocol piece on OldSilicon.com with Claude the same week the codec landed. The
article walked through an xterm startup byte by byte, annotated and mapped to the X protocol spec
sections. It served two purposes, neither of which was "I wanted to write an article."

First, it forced the `dump` output to be readable enough to publish. The decoded format had to make
sense to a reader who hadn't looked at the spec in a while. That pressure caught half a dozen places
where the framer was right but the human-facing output was wrong: lazy field names, inconsistent
number bases, missing context. The article shipped polished, and the framer benefited from the
pressure.

Second, writing it made me actually understand the protocol, not just compile it. You can't explain
something you don't actually understand. Several decisions the server code makes later (sequence-
number invariants, the post-Map event sequence, how property bytes encode trailing nulls) came from "I
had to explain this in writing and realized I didn't know why it had to be that way." Writing forced
the missing pieces forward.

It was also a real Claude-Code moment. Claude read the X protocol spec pages I pointed at, drafted
byte-level walkthroughs that I corrected against the actual captures, and held all the spec details
across multiple drafting sessions while I kept losing my place between byte tables. The article ended
up co-authored honestly. The OldSilicon piece opens with "Claude and I wrote" for that reason.

## What Claude-Code looks like at this stage of the project

The framer wasn't a "write me an X11 decoder" prompt. It was several days of iteration. I knew what
the byte format had to be (I read the spec the first time in 1991, after all). Claude wrote the Swift.
I sat with captures, comparing decoded output to the spec section the bytes came from. Round trip,
correction, round trip, correction. Maybe twenty cycles before the codec passed corpus round-trip
tests cleanly.

Every round trip was me reading a capture, finding a place the decoder was wrong, telling Claude
precisely what the bytes meant and where the existing code had misread them, and watching Claude fix
it. Sometimes I was wrong, Claude pushed back, I'd reread the spec, and Claude was right. That kind of
push-back is exactly what you want from a competent partner. It's also exactly what people who haven't
worked this way assume you don't get from AI.

The thing this isn't: me typing "build the framer" and waiting for a deliverable. The thing it is: me
providing protocol knowledge and judgment, Claude providing fast hands and a working memory that holds
the spec in view for hours at a time while I jump between captures.

I kept a running set of notes about what I'd asked, what came back wrong the first time, what came
back right. By the end of the codec week I had a clear sense of where Claude is strong (encode/decode
mechanics, test scaffolding, refactor execution) and where I have to drive (architectural choices,
when real-client behavior deviates from the spec, what's load-bearing versus cosmetic). That mapping
has held up for everything since.

## Replay turns out not to be a test harness

End of day two I had the `replay` subcommand working. Read a `.xtap` file, open a TCP connection to a
target X server, send the captured client-to-server bytes back. With `--realtime` it paces each frame
by the original timestamp. With `--hold` it keeps the connection open after the last frame so the
windows don't get torn down on close.

The original plan was that replay would be the regression test for the swift-x server. Capture once
from a real Sun, replay against my server, assert the bytes I get back match the bytes the real Xsun
sent in the gold trace. Automated. Byte-perfect. No Sun required for the daily testing loop.

It doesn't work.

The swift-x server hands out different resource-id-bases than the original Sun did. When a client
opens an X connection, the server's SetupAccepted reply tells the client what range of resource IDs
to use for its own windows and pixmaps. Different servers hand out different ranges. The client then
derives the IDs for its CreateWindow requests from that range. When I replay the captured client-to-
server bytes verbatim against my own server, the CreateWindow requests reference IDs the original Sun
allocated, not the IDs my server told the client to use. My server sees those IDs, doesn't recognize
them, fails the first CreateWindow with `BadIDChoice`. Game over.

Stateful replay translation, rewriting the IDs at the boundary as they fly through, would fix this
but it was real work I wasn't going to do this week. Logged it in DECISIONS.md: replay is a smoke
test, not a test harness. The corpus is the framer's regression test (where the codec is the unit
under test and replay isn't needed). For server testing, live verification against a real Sun is the
daily loop. Replay stays useful for bug reproduction against the Sun-side stack and for visual
demonstrations.

Building the wrong tool clearly enough to see exactly why it's the wrong tool is better than spending
more time abstractly arguing for the right one.

## Pivotal moment

Pointing u5 at the Mac with `DISPLAY=mac:0`, running xterm, watching the proxy forward bytes
faithfully while the framer decoded them in real time and the side log filled up with cleanly
formatted requests. Real xterm bytes flowing across the LAN, decoded byte-for-byte from a 1989 wire
format, by code Claude and I had written the previous afternoon.

I now had: a working codec, a way to capture real traffic, a corpus of real Sun sessions for the five
apps that mattered, and a real-time decoder I could leave running while I worked on the server
itself. Every test the server would ever need to pass was now grounded in real Sun behavior, not in
my interpretation of the spec.

Time to write a server.

---

## Anchors

- Files: `Sources/Framer/`, `Sources/SwiftXCapture/` (executable), `Sources/SwiftXCaptureCore/`
  (library), `PRODUCT_1_CAPTURE.md` (full spec), `DECISIONS.md` (2026-05-05 capture-tool-first entry,
  2026-05-06 replay-not-test-harness entry)
- Commits: `96021e3` 2026-05-05 "Initial commit: Phase 1 capture tool + framer", `01b40e4`
  2026-05-05 README, `c89f576` 2026-05-06 replay subcommand, `c00832b` 2026-05-06 `--realtime` and
  `--hold` flags, `3cbcd32` 2026-05-06 Product 1 close-out (corpus round-trip test plus docs)
- Corpus location: `captures/*.xtap`, regression test:
  `Tests/SwiftXCaptureCoreTests/CorpusRoundTripTests.swift`
- Companion article on OldSilicon.com (URL: [Todd to insert])

## Working title alternatives

- "Capture before code"
- "The codec came first"
- "Why I didn't write a single line of server code on day one"
- "Day one and two: ground truth"
