# Product 1: Capture tool

## What this is

A Swift CLI on the Mac that sits between two real Suns on the LAN, faithfully forwards their X traffic
both ways, decodes it as it passes through, records it to disk, and can replay a recorded capture back into
a fresh X server.

Two artifacts come out of this work:

- The `Framer` Swift library: the X11 wire codec, reused by every later product
- A captured corpus from real Suns: the test fixtures for everything downstream

## Goals

This product is "done" when:

- I can point Sun A at the Mac as its X server, the Mac forwards to Sun B's real Xsun, and the X session
	works as if Sun A were talking to Sun B directly. Bit-faithful pass-through.
- The tool decodes both directions (client requests, plus server replies / events / errors) into
	human-readable form, in real time and after the fact from a saved capture.
- Saved captures replay correctly into a fresh X server, producing the same visible result.
- I have recorded sessions for: xterm, xclock, xeyes, xcalc, twm, mwm, my Motif app, and (if accessible)
	CDE and OpenWindows.
- A written article exists on my web site walking through what an xterm session looks like on the wire,
	with annotated bytes mapped to x.org packet definitions.

## Non-goals for this product

- Modifying traffic. The capture tool is a passive proxy. Bytes pass through unchanged.
- X protocol awareness beyond decoding. No filtering, no rewriting, no synthesizing requests.
- Performance optimization. Faithful and slow beats fast and wrong.
- Any UI. CLI only.
- Authentication handling. If MIT-MAGIC-COOKIE-1 traffic flows through, the tool just forwards the bytes;
	it does not validate them or care what they mean.

## Topology

```
[Sun A: clients]                                       [Sun B: real Xsun]
       │                                                       ▲
       │  DISPLAY=mac.local:0                                  │
       │  TCP to mac.local:6000                                │  TCP to sun-b:6000
       ▼                                                       │
   [Mac: capture tool]  ──────forwards bytes both ways─────────┘
       │
       ▼
   session.xtap
   session.xtap.json
```

How it works:

- Sun A sets `DISPLAY=mac.local:0` and runs an X client.
- The Mac listens on TCP :6000 (X display 0). The capture tool holds the port; no real X server is running.
- When Sun A connects, the Mac opens an outbound TCP connection to `sun-b:6000` (the real Xsun).
- The Mac shovels bytes both ways faithfully while the framer decodes a side copy of each direction for
	logging and recording.

Decisions baked in:

- App-level proxy. No routing tricks, no IP-level interposition. Sun A is configured to talk to the Mac
	directly via its `DISPLAY`.
- The Mac is not running an X server during capture. Port :6000 is held by the capture tool.

## The Framer library

A pure protocol codec for X11 wire format. Reused by Product 2.

Scope for Product 1:

- Decode the X11 connection setup (request and reply, both byte orders, both auth-accepted and
	auth-rejected paths)
- Decode all core requests defined in X11R6 (about 120 of them)
- Decode core replies, events, and errors
- Encode for everything in scope. Strictly speaking, decode-only would suffice for Product 1, but Product 2
	needs encode and writing it now avoids doing the work twice.

What it doesn't do:

- Track resources (windows, GCs, etc.) as state. The framer parses one packet at a time.
- Networking. It takes bytes in and produces structured packet values out.
- Extensions, except for SHAPE and BIG-REQUESTS, which Product 2 will need.

Test strategy:

- Hand-crafted byte fixtures for each request, reply, event, and error, verified byte-for-byte against the
	X11 protocol spec.
- Round-trip tests: encode a packet, decode it, assert equality with the original.
- Once captured corpus exists: regression tests that decode every byte of a real session without errors and
	re-encode it byte-identically.

The byte-identical re-encode test is the strongest correctness check available short of running everything
through a real server, and it's mechanical to run on every recorded capture.

## The capture tool CLI

```
swiftx-capture --listen :6000 --forward sun-b:6000 --output session.xtap
swiftx-capture --listen :6000 --forward sun-b:6000 --output session.xtap --decode-stdout
swiftx-capture dump   session.xtap
swiftx-capture replay session.xtap --target localhost:6000
```

Subcommands:

- (default): proxy + record. Required: `--listen`, `--forward`, `--output`.
- `dump`: read a capture file, print decoded packets to stdout.
- `replay`: read a capture file, send the client-to-server bytes to a target X server, with original
	timing.

Flags worth supporting from the start:

- `--decode-stdout`: print each decoded packet as it goes by, in addition to recording.
- `--annotate-spec`: when decoding, include the relevant section of the x.org protocol spec for each
	packet type. Useful for the article and for learning.
- `--max-bytes N`: hard cap on capture size, paranoia switch for runaway sessions.

Behavior under failure:

- If Sun B closes the connection: forward the close to Sun A, finalize the capture, exit clean.
- If Sun A closes the connection: same in the other direction.
- If decoding fails on a byte stream the tool can still pass through: log the decode error, keep proxying.
	The job of the capture is to forward correctly even if the decoder has bugs.

## Capture file format

Sidecar approach: a binary byte log plus a JSON metadata file.

`session.xtap` (binary):

```
File header (8 bytes):
  magic       4 bytes   "XTAP"
  version     uint8     starts at 1
  reserved    3 bytes   zero, padding for future header growth

Each frame (13 bytes header + payload):
  direction   uint8     0 = client-to-server, 1 = server-to-client
  timestamp   uint64    nanoseconds since start of session, little-endian
  length      uint32    payload length, little-endian
  payload     length bytes  raw bytes from the wire, exactly as seen
```

All `.xtap` integers are little-endian regardless of the byte order negotiated by the X11 protocol inside.
The frame format is the container, the payload is the X protocol; they're independent.

`session.xtap.json` (UTF-8 JSON):

```
{
  "recorded_at": "2026-05-05T14:32:11Z",
  "tool_version": "0.1.0",
  "listen":  "0.0.0.0:6000",
  "forward": "sun-b.lan:6000",
  "client_endianness": "MSB",
  "client_protocol_major": 11,
  "client_protocol_minor": 0,
  "client_auth_name": "MIT-MAGIC-COOKIE-1",
  "duration_ns": 23847291834,
  "total_bytes_c2s": 18472,
  "total_bytes_s2c": 91283,
  "notes": "free-form, optional, written by --note flag if I want to label the capture"
}
```

Why this:

- Raw bytes are the ground truth. Any other format is a step removed.
- A sidecar JSON makes the binary file parseable in isolation while still letting humans see what's in a
	capture without running the dump tool.
- Frame format is trivial to write a parser for in any language, which matters once a Pi-side tool needs
	to read captures.

What this isn't:

- pcap. pcap operates at the IP layer; we don't need that level. Our frames sit on the TCP byte stream.
- A heavyweight container with indexing, compression, etc. If I need any of that later I'll add it then.

## Replay tool

A subcommand of the capture binary. Reads a `.xtap` file, opens a TCP connection to the target, and sends
the C2S bytes with their original inter-packet timing.

What replay is for:

- Driving a fresh X server (eventually Product 2) with a known-good byte stream and seeing if it survives.
- Reproducing a bug deterministically: capture once, replay forever.
- Performance baselining.

What replay is not for:

- Round-tripping against the same Sun B. The X server is stateful; replay won't reproduce identical state.
- Replaying S2C bytes. Those are responses; they only get produced if a client asks.

## Swift package layout

One package, two products (a library and an executable).

```
swift-x/
  Package.swift
  Sources/
    Framer/                 library, public API
      Wire/                 byte readers, byte writers, byte-order helpers
      Setup/                connection setup request and reply
      Requests/             one file per request opcode group
      Replies/              one file per reply
      Events/               one file per event
      Errors/               error codes
    SwiftXCapture/          executable, depends on Framer
      Proxy.swift           TCP listen + forward, the byte pump
      Recorder.swift        writes .xtap and .xtap.json
      Decoder.swift         drives Framer, produces human output
      DumpCommand.swift
      ReplayCommand.swift
      main.swift            argument parsing, subcommand dispatch
  Tests/
    FramerTests/            unit tests against hand-crafted byte fixtures
    SwiftXCaptureTests/     integration tests using captured corpus once it exists
    Fixtures/
      handcrafted/          tiny byte sequences I wrote
      captured/             real captures from real Suns (binary, committed)
```

Decisions baked in:

- One package, not two. The capture tool depends on the framer, and they evolve together. Two packages
	means two release cadences and is over-engineering this early.
- Library + executable, not library + multiple executables. Capture, dump, and replay all live in one
	binary because they share the framer and the file format.
- Fixtures live in `Tests/Fixtures` so they can be referenced by the test bundle and inspected by hand.

## Toolchain target

- Swift: latest stable (whatever ships with current Xcode).
- macOS: latest stable as the dev target. The audience is me and a small number of vintage-computing folks
	who can be expected to run a current Mac.
- Sun side: SunOS 4.1.4 and Solaris 2.6 with their bundled X. Not Mac-side concerns; we're testing against
	them, not building on them.
- Build: `swift build` for the dev loop. Eventually a `Makefile` that wraps `swift build` so the build
	pattern matches the rest of my projects (cmacs, etc.).

## Test corpus

The corpus is its own deliverable. Captures to record, in roughly increasing complexity:

1. xterm (the canonical first capture; lots of font work)
2. xclock (animation, simple; good for event timing)
3. xeyes (cursor tracking, input event coverage)
4. xcalc (Xt + Athena widget toolkit)
5. twm (window manager, focus events, restacking)
6. mwm (Motif window manager, more complex)
7. My Motif app (the real workload)
8. CDE if I can get it running
9. OpenWindows / OpenLook clients if I have any

Each capture should:

- Run long enough to exercise the interesting paths: open the app, interact with it, close it cleanly.
- Get checked in as `Tests/Fixtures/captured/<name>.xtap` and `<name>.xtap.json`.
- Have a short README in the same directory describing what was on screen and what I clicked.

The annotated walkthrough article uses xterm. That capture gets extra metadata: a paired markdown doc that
walks through every packet with a short explanation referencing the x.org spec section.

## Open questions, to resolve while building this

- Real Sun setup. I need two Suns on the LAN reachable as `sun-a` and `sun-b` with X working. Confirming
	this is already standing, or whether "build the test bed" is itself a step in this product.
- Whether to commit captures (binary blobs) directly into git or use git-LFS. They will be small (a few
	hundred KB each), so direct seems fine, but worth flagging before the corpus grows.
- Whether the `--annotate-spec` decoder feature ships in the first usable version or comes later as a
	separate pass for the article. Leaning later; the bare decoder is more important.
- Whether replay needs original-timing fidelity, or constant-rate is acceptable. Constant-rate is much
	simpler and probably fine for early Product 2 testing.

## Order of work

Rough sequence. Adjust if any earlier step reveals something that invalidates a later one.

1. Stand up Swift package skeleton with empty Framer and SwiftXCapture targets.
2. Framer: connection setup encode/decode + tests.
3. Framer: a handful of common requests (CreateWindow, MapWindow, ChangeProperty, GetProperty, OpenFont,
	CreateGC, PolyFillRectangle, ImageText8) + tests.
4. Capture tool: byte-pump proxy with no decoding, faithful pass-through.
5. First real capture: xterm from a Sun. Verify the session works normally end-to-end.
6. Capture file format: writer + reader + tests using the captured xterm session.
7. Framer: fill out the rest of the core protocol (events, errors, remaining requests).
8. `dump` subcommand: human-readable decode of a saved capture.
9. `replay` subcommand: send a saved capture to a target X server.
10. Record the rest of the corpus.
11. Write the article.

If anything in steps 1 through 6 reveals that an architectural decision needs revisiting, stop and revisit
before continuing.
