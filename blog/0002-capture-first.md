# Post 2: Capture tool first

**Date range**: May 5 - May 6, 2026
**One-line elevator**: Build the wire-format codec and a passive proxy/recorder before writing a single line of X server code, so that every later test is grounded in real-Sun behavior instead of in protocol-spec interpretation.

## What this post covers

Product 1: the capture tool. Why it shipped before the server, what it does, what it produces, and how the captured corpus shaped everything downstream.

## Thread anchor: protocol vs implementation

This is the post where "protocol-not-implementation" gets the most concrete. The framer IS the protocol. It knows nothing about rendering, nothing about X.org's internal data structures, nothing about display hardware. Just the bytes on the wire that X11R6 specified in 1989. Capturing real Sun traffic and decoding it byte-for-byte is exactly how you isolate the stable protocol layer from the implementation it happens to be running on. Worth weaving in early in the body.

## Setting

The X11 protocol spec is well-documented (XCB.PDF and the OReilly volumes), but a spec tells you what's *legal*, not what real clients actually do. The Xt and Motif libraries from 1995 make assumptions about server behavior that aren't in any spec. The only ground truth is captured traffic from real Sun workstations.

## The framer library

A pure protocol codec for X11 wire format. Decoders and encoders for requests, replies, events, and errors. No state tracking, no networking. Bytes in, structured values out.

Scope for Product 1:
- Connection setup (both byte orders, both auth paths)
- All core requests defined in X11R6 (~120 of them)
- Core replies, events, errors
- Encode for everything in scope (decode-only would suffice for Product 1, but Product 2 needs encode and doing it once avoids doing it twice)

What it doesn't do:
- Track resources (windows, GCs) as state
- Networking
- Extensions, except SHAPE and BIG-REQUESTS for Product 2

The framer is what makes the four products cohere into one project. It's reused by the capture tool, the X server, and eventually (in a C or Go port) the Pi bridge.

## The capture tool itself

A Swift CLI that sits between two Suns on the LAN as a passive proxy. Sun A is configured with `DISPLAY=mac.local:0`. The Mac listens on TCP :6000 and holds the port (no real X server). When Sun A connects, the Mac opens an outbound TCP connection to `sun-b:6000` (the real Xsun) and shovels bytes both ways while the framer decodes a side copy.

Three subcommands:
- (default): proxy + record. `swiftx-capture --listen :6000 --forward sun-b:6000 --output session.xtap`
- `dump`: chronological decoded-packet output from a `.xtap` file
- `replay`: feed C2S bytes from a capture back into a target X server

## Capture file format

Binary frames plus a JSON sidecar.

`session.xtap`: 8-byte header (`XTAP` magic + version) followed by frames. Each frame is direction (1 byte), nanosecond timestamp (8 bytes little-endian), payload length (4 bytes little-endian), payload bytes. The payload is X protocol bytes verbatim.

`session.xtap.json`: timing metadata, byte counts, recorded-at timestamp, auth name. Makes captures parseable in isolation.

Why not pcap: pcap operates at the IP layer; we don't need that level. The X protocol sits on a TCP byte stream, the frame container only needs direction + timestamp + length.

## The corpus

Recorded sessions from real Suns, checked into the repo as test fixtures:

- xterm (the canonical first capture, lots of font work)
- xclock (animation, simple, event timing)
- xeyes (cursor tracking, input event coverage)
- xcalc (Xt + Athena widget toolkit)
- quickplot (my custom Motif app, the real workload)

Each capture is paired with a markdown README describing what was on screen and what got clicked.

twm/CDE/OpenWindows captures were initially on the list, then dropped. The corpus's job is framer regression testing and article source material. Both well-served by what we have. Adding more captures for completeness wasn't earning its keep.

## The article

Written and published the same week. Walks through an xterm session on the wire with annotated bytes mapped to x.org spec sections. The article was both a forcing function (it required the dump output to be readable enough to publish) and a tool (it taught me the protocol in detail, since you can't explain something you don't actually understand).

## Replay tool

Subcommand of the capture binary. Reads a `.xtap`, opens TCP to a target, sends the C2S bytes. Two flags:
- `--realtime` paces each frame by its timestamp. Without it, replay pumps as fast as possible (useful for smoke tests, useless for visual inspection because drawing requests land before the WM has reparented the window).
- `--hold` keeps the connection open after the last frame, until SIGINT. Without it, the server's close-down tears down the windows before they're visible.

What replay is good for: smoke-testing the framer against real Sun behavior; visual demonstration; bug reproduction against the same Sun.

What replay is NOT good for: driving the Swift X server as a regression test. Product 2 hands out different resource-id-bases than the original Sun did, so byte-pump replay against Product 2 fails with `BadIDChoice`. Stateful replay translation would fix this but wasn't built. Replay stays as a smoke test, not a test harness. (`DECISIONS.md` 2026-05-06.)

## Pivotal moment

The first real capture: pointing u5 at the Mac, running xterm, watching the proxy forward bytes faithfully, watching the framer decode them in real time. That was the moment the project went from "speculative" to "this is going to work."

## What Todd should add

- The article link (I don't have the URL).
- What it felt like to see the first proxied xterm session work end-to-end. The "oh, this is real" moment.
- The pre-framer state. Did the framer come together in a sprint, or was it incremental? What were the moments where the spec was confusing or wrong?
- The article-writing process. Did writing it surface bugs in the decoder? Did the audience response shape anything?
- The capture corpus choices. Why xterm first, why xclock as the simplest non-trivial app, why quickplot as the "real workload"?
- The replay-isn't-a-test-harness realization on 2026-05-06. That's a real "huh, my plan was wrong" moment worth narrating.

## Anchors for fact-check pass

- Files: `PRODUCT_1_CAPTURE.md` (full spec), `DECISIONS.md` (2026-05-05 capture-tool-first entry, 2026-05-06 replay-not-test-harness entry)
- Commits: `96021e3` 2026-05-05 initial commit, `01b40e4` README, `c89f576` 2026-05-06 replay subcommand, `c00832b` 2026-05-06 --realtime/--hold flags, `3cbcd32` 2026-05-06 Product 1 close-out (corpus round-trip test + docs)
- Corpus location: `captures/*.xtap` + `Tests/SwiftXCaptureCoreTests/CorpusRoundTripTests.swift`
- Framer source: `Sources/Framer/`
- Capture tool: `Sources/SwiftXCapture/` (executable) + `Sources/SwiftXCaptureCore/` (library)

## Working title alternatives

- "Capture before code"
- "How I built the test corpus for an X server I hadn't started writing"
- "Product 1: the wire decoder"
