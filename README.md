# MacXServer

A modern X11 server in Swift for macOS, plus the capture and protocol
infrastructure to display X applications from real vintage Sun workstations
on the Mac with proper modern rendering. The Swift package is internally
called `swift-x`.

This repo currently holds Phase 1 of the project: a passive capture tool
that records and decodes X11 traffic between two Sun workstations on a LAN,
plus a typed Swift decoder for the X11 wire protocol. The decoder library
will be reused later by the actual X server.

## What's here

- `Sources/Framer/` — typed Swift decoders for the X11 core protocol. 73
  request opcodes, 26 events, 3 typed reply bodies, all 4 connection-setup
  variants. ~45,000 captured requests across 8 real Sun sessions decode at
  100% for every core opcode the apps emit.
- `Sources/SwiftXCaptureCore/` and `Sources/SwiftXCapture/` — a POSIX TCP
  byte-pump proxy that forwards X11 traffic between two Suns while recording
  it to an `.xtap` file. Includes a chronological per-message dump tool and
  an aggregate summary tool for inspecting recordings.
- `captures/` — `.xtap` files captured from real Sun workstations: xterm
  (three sessions), xeyes, xclock, xcalc, and quickplot (a Motif graphing
  app, two sessions).
- `Tests/` — 212 passing tests covering the framer, the capture tool, the
  proxy, and the file format.

## Quick start

Build:

```
swift build -c release
```

Capture a session (edit `connection.json` to point at your upstream X server):

```
./run.sh
```

The script prints listen address, candidate Mac IPs for the Sun's `DISPLAY`,
and starts recording. Then on the Sun:

```
xterm -display <mac-ip>:0
```

When the Sun's X client closes, the proxy writes `<output>.xtap` and a
`<output>.xtap.json` sidecar with metadata.

Inspect a recorded session chronologically:

```
./run.sh dump captures/xterm_long.xtap
```

Aggregate statistics for a recording:

```
./run.sh summary captures/quickplot.xtap
```

Replay a recorded session's client-to-server bytes against a target X server
(useful for driving a fresh server with a known-good byte stream):

```
./run.sh replay captures/xterm_long.xtap --target localhost:6000
```

`--target` defaults to `127.0.0.1:6000` if omitted. Replay sends bytes as fast
as the target accepts them; original timing is not honored.

## Tests

```
swift test
```

## Documentation

The full project context lives in markdown at the repo root:

- `PROJECT.md` — what we're building, the four-product plan, explicit non-goals
- `ARCHITECTURE.md` — how the components fit together
- `DECISIONS.md` — architectural choices with reasoning, append-only
- `PRODUCT_1_CAPTURE.md` — scope and order-of-work for the capture tool
- `ARTICLE_BRIEF.md` — briefing for writing up Phase 1 publicly
- `CLAUDE.md` — instructions for collaborator agents

## Status

**Phase 1** (capture tool + framer): functionally complete. All requests
from the captured Sun sessions decode by typed name. The framer covers ~60%
of the X11 spec but 100% of the opcodes any of these vintage apps actually
use. SHAPE extension calls pass through correctly but are not yet typed.
Capture, dump, summary, and replay subcommands all work.

**Phase 2** (Sun-to-Sun bridge over CrossFeed via a Raspberry Pi pair):
not started.

**Phase 3** (the Swift X server itself, the headline of the project): not
started. This is what reuses the framer.

**Phase 4** (Swift X server + Pi + CrossFeed end-to-end): not started.
