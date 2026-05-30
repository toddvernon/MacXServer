# Product 1: Capture (CLI tool → library + GUI app + server-side capture)

## Mission

macXcapture is a first-class X11 protocol capture and inspection tool. Think of it as the modern
equivalent of xscope, xtrace, or Wireshark's X11 dissector — but built as a native macOS app, with
syntax-highlighted decoded output, a real editor-window viewer for `.xtap` files, and a capture wizard
that walks you through the proxy setup.

**You don't have to buy into anything else in this repo to use it.** macXcapture is just a proxy:
point your X client at it, point it at any X server (on this Mac, on the LAN, anywhere TCP reaches),
and watch the protocol go by. Save the capture as a `.xtap` file, reopen it later, export the decoded
transcript as text, share it with someone debugging the same problem. The Swift X server is a separate
product in this repo; macXcapture stands on its own.

**You do need a Mac.** That part is unapologetic. Cross-platform tools are the least common
denominator — they look anonymous and work like the worst of every platform they target. macXcapture
is built for macOS the way a good macOS app should be: a real menu bar, a real save panel, a real
syntax-highlighted code-editor viewer, a real toolbar wizard, a native app icon. Use it and enjoy it,
or use one of the cross-platform tools that already exist and look like they were drawn in 2001.

The intended audience is wider than this repo's other product:

- Vintage workstation hobbyists (Sun, SGI, DEC, NeXT — anyone with a real X client still alive on
	the LAN).
- Linux developers who use a Mac as their dev box and want to inspect X traffic between their Mac
	and a remote Linux build host without firing up a Wireshark capture.
- Anyone reverse-engineering an X client, debugging a Motif widget, or writing their own X server
	and wanting a clean readout of what it emits.
- Curious people who want to see what a 35-year-old wire protocol actually looks like under load.

The bar for OSS launch is: a capture from any of those audiences should decode cleanly with zero
`opcode=N (untyped)` lines for opcodes the X protocol documents. The work to get there lives in the
"Decoder coverage phase" section at the bottom of this doc.

---

## Two implementation phases

- **v1** — the CLI proxy tool that produced the framer, the corpus, and the article.
	Status: done 2026-05-06. Content of this doc through the end of "Order of work (as built)"
	covers v1.
- **v2** — refactor format/decode into a library, build a SwiftUI capture app over it, add
	server-side capture to `swiftx-server` for public-release bug reporting. Status: largely landed
	2026-05-29 (library extracted as `SwiftXCaptureUI`, capture app shipped with stacked-wizard
	Record screen + .xtap viewer windows + Save As / Export as Text, server-side auto-capture
	working). See the "v2: Public-ready capture" section.

v1 and v2 share the `.xtap` format. v2 is additive: v1 binaries and v1 captures keep working
throughout the transition. The framer is unchanged.

The post-v2 work is the **Decoder Coverage Phase** at the bottom of this doc — what gets macXcapture
to OSS-launch quality.

---

# v1: CLI capture tool (done 2026-05-06)

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
	works as if Sun A were talking to Sun B directly. Bit-faithful pass-through. ✅
- The tool decodes both directions (client requests, plus server replies / events / errors) into
	human-readable form, in real time and after the fact from a saved capture. ✅
- Saved captures replay into a target X server with original timing. ✅ (with known limits — see
	"Replay tool" section and 2026-05-06 entry in DECISIONS.md. Replay is a smoke test, not a Product 2
	regression harness.)
- A captured corpus exists with the common workloads represented: xterm, xclock, xeyes, xcalc, my
	Motif app (quickplot). ✅ (twm/mwm/CDE/OpenWindows captures dropped — the corpus's actual job is
	framer regression testing and article source material, both well-served by what we have.)
- A written article exists on my web site walking through what an xterm session looks like on the wire,
	with annotated bytes mapped to x.org packet definitions. ✅
- The framer decodes and round-trips every C2S byte in the corpus (semantic round-trip, since X11
	allows uninitialized padding so byte-identity is the wrong bar). ✅ — see
	`Tests/SwiftXCaptureCoreTests/CorpusRoundTripTests.swift`.

Status as of 2026-05-06: Product 1 is effectively done. Remaining work for the project moves to Product 2.

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
the C2S bytes. Two flags shape behavior:

- `--realtime` paces each frame by its `.xtap` timestamp. Without it, the replay pumps everything as fast
	as possible (useful for smoke tests, useless for visual inspection because drawing requests land
	before the WM has reparented the window).
- `--hold` keeps the connection open after the last frame, until SIGINT. Without it, the server's default
	close-down mode tears down all the windows we just mapped, before they're visible.

What replay is for:

- Smoke-testing the framer against real Sun behavior (decode → encode → send → observe response).
- Visual demonstration: pointing the tool at a Sun and watching a recorded session render.
- Bug reproduction against the *same* Sun, when no other clients are connected (because Sun's X server
	hands the first client a deterministic resource-id-base; this is empirically tested but narrow).

What replay is not for:

- Driving Product 2 (the Swift X server). Product 2 will hand out different resource-id-bases and atom
	IDs than the capture's original server, so byte-pump replay will fail with BadIDChoice. Stateful
	replay translation would fix this but isn't being built. See 2026-05-06 in DECISIONS.md.
- Replaying captures that included user-driven window resizes. Drawing requests after a resize are aimed
	at the new dimensions; in replay the WM never resizes, so the drawings land at coordinates relative
	to a window that doesn't exist.
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

## Open questions resolved during the build

- Real Sun setup: u5.example.com is the reference Sun. Confirmed working as both capture target and
	replay target.
- Captures committed directly into git (small enough; the largest is under 1MB). No git-LFS needed.
- `--annotate-spec` not built. The article is done and the bare decoder + dump output were enough
	source material. Drop unless a future need surfaces.
- Replay timing: built `--realtime` for visual inspection. Default is fast-pump for smoke tests. The
	"constant-rate is fine for Product 2 testing" framing turned out to be moot since replay isn't
	driving Product 2 testing anyway (see DECISIONS.md 2026-05-06).

## Order of work (as built)

1. Swift package skeleton with empty Framer and SwiftXCapture targets. ✅
2. Framer: connection setup encode/decode + tests. ✅
3. Framer: common requests (CreateWindow, MapWindow, ChangeProperty, GetProperty, OpenFont, CreateGC,
	PolyFillRectangle, ImageText8) + tests. ✅
4. Capture tool: byte-pump proxy with no decoding, faithful pass-through. ✅
5. First real capture: xterm from a Sun, end-to-end verified. ✅
6. Capture file format: writer + reader + tests. ✅
7. Framer: filled out core protocol coverage to "all common requests" — not exhaustively every R6
	opcode, but every opcode that appears in the corpus. ✅
8. `dump` and `summary` subcommands: human-readable decode. ✅
9. `replay` subcommand with `--realtime` and `--hold`. ✅
10. Recorded corpus: xterm, xclock, xeyes, xcalc, quickplot. (twm/CDE/OpenWindows dropped — not
	earning their keep.) ✅
11. Article written. ✅
12. Corpus regression test: framer round-trips every C2S byte semantically. ✅

Product 1 v1 is done. Product 2 (the server) is in progress; the v2
work below was scoped on 2026-05-23 to make capture public-release ready.

---

# v2: Public-ready capture (in design 2026-05-23)

## What this is

A redesign of how capture works now that swift-x is heading toward a public
release. Two complementary capture paths driven by the same library, so
hobbyists running the server can hand back useful bug reports without
running a separate tool.

1. **Server-side capture** — `swiftx-server` gains a `--capture` flag (and a
   matching "Capture every client" toggle in Preferences). When on, every
   client that connects writes its own `.xtap` to `/tmp/swift-x-captures/`.
   One client = one file. Reboot wipes everything; that's the only privacy
   gate.

2. **Capture app** — `swiftx-capture` becomes a SwiftUI app with three modes:
   record-proxy (between two real Suns or a Sun and a real server), open
   an existing `.xtap` and browse it, and replay an `.xtap` against a
   target server. Replaces the v1 CLI tool, which serves only me.

Both apps use the same `SwiftXCaptureCore` library for the file format,
the framing, and the decode/annotation logic. The library is the single
source of truth; the two binaries are thin shells over it.

## Why now

v1 capture is functionally done but its UX is "Todd uses the CLI."
Going public means:

- **A hobbyist running the server hits a rendering bug.** They have no way
  to send me a capture today unless they happen to know that a separate
  proxy tool exists and how to set it up. Server-side capture turns this
  into "toggle the checkbox, hit the bug, send me the file."
- **A hobbyist who wants to look at what their app does on the wire** has
  to learn the CLI subcommands. A GUI examiner makes "what's actually
  happening when xterm scrolls?" approachable.
- **The replay-as-smoke-test path** isn't going away (it's how I verify
  framer round-trips against new captures). Better in a GUI too — fewer
  flag memorizations, easier to tweak timing and target while watching.

## Topology (the two paths)

### Server-side capture (the new path)

```
[Sun A: xterm]   [Sun A: xclock]   [Sun A: quickplot]
       │                │                    │
       ▼                ▼                    ▼
                  [Mac: swiftx-server --capture]
                            │
                            ▼
            /tmp/swift-x-captures/
                2026-05-23T14-32-11-xterm.xtap
                2026-05-23T14-32-11-xterm.xtap.json
                2026-05-23T14-37-02-xclock.xtap
                2026-05-23T14-37-02-xclock.xtap.json
                2026-05-23T14-41-58-quickplot.xtap
                2026-05-23T14-41-58-quickplot.xtap.json
```

Each X client connection gets its own capture file. The server is also
the actual X server; the capture is a tee, not a proxy. The user sees
no extra latency in the common case (see "Performance" below).

### Proxy capture (the v1 path, now with a UI)

```
[Sun A: clients]                                       [Sun B: real Xsun]
       │                                                       ▲
       │  DISPLAY=mac.local:1                                  │
       │  TCP to mac.local:6001                                │  TCP to sun-b:6000
       ▼                                                       │
   [Mac: swiftx-capture (Record mode)]  ─forwards both ways───┘
       │
       ▼
   session.xtap
```

Same as today's v1 tool, but:
- Default listen port is `:6001` so it can run alongside `swiftx-server`
  on `:6000` without a flag dance.
- Live status: bytes in/out per direction, packet counts, last few
  decoded requests in a window. The user can see something is happening
  without `--decode-stdout`.

## Goals

v2 is "done" when:

- `swiftx-server --capture` writes a per-client `.xtap` to
  `/tmp/swift-x-captures/` with no measurable latency hit on interactive
  workloads. The Preferences toggle has the same effect.
- The CLI flag and the Preferences toggle compose with documented
  precedence: CLI when present wins, Preferences applies otherwise.
- `swiftx-capture` opens with a mode picker, can record a proxy session,
  can open an `.xtap` and let the user browse it (request tree, decoded
  payload, jump to events), and can replay against a target.
- `SwiftXCaptureCore` is the only place that knows the `.xtap` format,
  the framer wiring, and the annotation logic. Both apps link it.
- A first-time user on a friend's Mac can hit a bug, find the capture
  file in Finder, and email it to me without consulting documentation.

## Non-goals

- **Encrypted or authenticated capture transport.** Captures are local
  files. If you want to encrypt before emailing, use whatever you'd use
  for any other attachment.
- **Capture filtering.** No "only record GetImage" or "exclude this
  client" mode. The file is the file; analysis is the examiner's job.
- **Cross-session capture in one file.** One client connection, one
  `.xtap`. Always.
- **Capture playback as a recovery tool.** Replay is for smoke tests
  and bug reproduction, not "redo my session."
- **Live capture editing.** Captures are append-only at write time and
  read-only at examine time.
- **A "capture daemon" model.** Capture is a feature of the server
  binary, not a separate process the server talks to over IPC.

## Library boundary

`SwiftXCaptureCore` becomes the canonical home for everything format-
and decode-related. The current contents (`CaptureFile`, `CaptureReader`,
`Recorder`, `Proxy`, `Replay`, `Dumper`, `ChronoDumper`, `Direction`,
`StartupHint`, `CaptureDiff`, `NetworkInterfaces`, `CLI`) mostly stay,
with one cut and one addition:

**Cut**: `CLI.swift` moves out. It's a CLI argument parser specific to
the current binary; the new capture app has a SwiftUI front end and
the server's flag handling lives in the server's `main.swift`.

**Add**: `CaptureSink` — a thin protocol for "something that consumes
wire bytes plus direction plus timestamp and writes them out." Today
`Recorder` is a concrete struct; promoting it behind a protocol lets
the server install a per-session sink alongside its normal protocol
handlers without depending on the proxy machinery.

```swift
public protocol CaptureSink {
    func record(direction: Direction, bytes: UnsafeRawBufferPointer, at: ContinuousClock.Instant)
    func finalize()
}
```

What stays library-internal vs binary-side:

| Concern | Library (`SwiftXCaptureCore`) | App (`swiftx-server` or `swiftx-capture`) |
|---|---|---|
| `.xtap` file format read/write | yes | no |
| Sidecar JSON read/write | yes | no |
| Framing/decoding (via Framer) | yes | no |
| Decoded packet annotation | yes | no |
| TCP listen/forward (proxy mode) | yes | no |
| TCP forward-only (replay mode) | yes | no |
| Per-session sink lifecycle (start, write, finalize) | yes | no |
| CLI argument parsing | no | yes (server has one, capture-app has none) |
| SwiftUI views | no | yes (capture app only) |
| Preferences storage (UserDefaults) | no | yes (both) |
| Status-menu items | no | yes (both) |

## Server-side capture: how it wires in

### Activation

Two inputs:
1. CLI flag `--capture` (boolean, defaults to "use preferences value")
2. Preferences toggle "Capture every client to /tmp"

**Precedence**: CLI when present wins. So:

| Pref | CLI | Effect |
|---|---|---|
| OFF | absent | no capture |
| ON | absent | capture |
| OFF | `--capture` | capture (CLI overrides) |
| ON | `--no-capture` | no capture (CLI overrides) |
| any | `--capture=false` | no capture (explicit off) |

A small status-menu indicator shows the active state ("Capturing" badge
when on) so the user can tell at a glance. Toggling from the menu
persists to Preferences.

### Per-session lifecycle

1. **On client connect**: `ServerCoordinator` allocates a `Recorder`
   (the library's `CaptureSink` implementation) writing to a temp file
   `/tmp/swift-x-captures/.in-progress-<sessionId>.xtap`. The temp
   name avoids confusion if the server crashes mid-capture.
2. **On first SetupRequest decoded**: the session knows the client's
   byte order and, after the connection completes, often a human-readable
   client name (from `WM_CLIENT_MACHINE` / `WM_COMMAND` or the first
   `CreateWindow`'s `WM_NAME`). At that point we rename the in-progress
   file to `<timestamp>-<client-name>.xtap`. If no name resolves within
   30 seconds we fall back to `<timestamp>-client-<sessionId>.xtap`.
3. **During the session**: every byte that crosses the protocolQueue's
   read or write boundary is fed to the session's sink (see Performance
   for the threading).
4. **On disconnect (clean or dirty)**: sink writes the sidecar JSON,
   closes the file.
5. **On server crash**: in-progress files remain on disk; next launch
   doesn't try to recover them (`.in-progress-` prefix keeps them
   distinguishable from real captures so a UI listing can hide them).

### File naming

```
/tmp/swift-x-captures/
    2026-05-23T14-32-11-xterm.xtap
    2026-05-23T14-32-11-xterm.xtap.json
    2026-05-23T14-32-58-xterm.xtap                  # second xterm
    2026-05-23T14-32-58-xterm.xtap.json
    2026-05-23T14-41-58-quickplot.xtap
    2026-05-23T14-41-58-quickplot.xtap.json
```

ISO-8601-ish timestamps with `T` separator, `-` instead of `:` (legal
in filenames everywhere). Client name comes from the best signal
available at "rename time" (~50 ms after `SetupRequest`); good enough
for triage.

### Status-menu additions

- **"Capture Sessions" toggle** (mirrors Preferences value).
- **"Reveal Captures Folder"** (opens `/tmp/swift-x-captures/` in
  Finder). Important because /tmp is invisible to normal users.
- **"Discard All Captures"** (rm everything in the folder, confirm
  first). Useful after a multi-app debugging session.

## Performance

Capturing every byte of every session has two cost vectors:

1. **Copy cost on the hot path** — every read and write on the
   protocolQueue has to fork bytes to the sink. This must be cheap
   (memcpy at most) or it slows down rendering.
2. **Disk write cost** — flushing to `/tmp` is async-able but real;
   200+ MB/s SSD writes are fast but blocking the protocolQueue on
   them is unacceptable.

### Threading model

```
                    ┌──────────────────────┐
                    │ protocolQueue        │
                    │ (per session)        │
                    │                      │
                    │  read socket ───┐    │
                    │  decode ────────┤    │
                    │  dispatch ──────┤    │
                    │  encode reply ──┤    │
                    │  write socket ──┤    │
                    │                 │    │
                    │  sink.record() ─┘    │  (memcpy into ring buffer)
                    └──────────────────────┘
                              │
                              ▼
                    ┌──────────────────────┐
                    │ captureQueue         │
                    │ (per session, serial)│
                    │                      │
                    │  drain ring → write  │
                    │  flush on:           │
                    │    - 64 KB filled    │
                    │    - 100 ms timer    │
                    └──────────────────────┘
                              │
                              ▼
                       /tmp/.../*.xtap
```

- Each session owns a serial `captureQueue` distinct from its
  `protocolQueue`. The protocolQueue does a memcpy into a 64 KB
  ring and dispatches a drain on the captureQueue if a threshold
  triggers (every 100 ms or 64 KB filled).
- The drain is `write(2)` to the temp file. No `fsync`. A crash
  loses at most the last ~half-second.
- The ring is per-session, so high-traffic clients (Motif Expose
  floods) don't starve quiet ones (xterm idle).

### Expected overhead

Rough numbers from the existing capture tool's proxy path:
- Memcpy of 1 KB packets: tens of nanoseconds.
- Ring enqueue: a few cache lines of pointer bumping.
- Compare to the protocolQueue's actual work (decode + dispatch +
  bridge call): microseconds.

Capture overhead should be in the <1% range for interactive workloads.
x11perf-style stress tests would see it more clearly but those aren't
the workload we care about.

### Crash-loss tradeoff

64 KB buffer means up to ~500 ms of activity can be lost on crash.
For a hobbyist bug-report tool, that's fine. If the user is hitting a
crash and the last half-second is exactly what's interesting, they
can re-trigger after restart. If we ever need it: a fsync-every-frame
mode behind a flag, off by default.

## The capture app: UI shape

Launch with a mode picker (window-style chooser, like Xcode's "what
kind of project"). Once a mode is chosen, that window stays in that
mode until closed.

### Mode 1: Record (proxy)

```
+--------------------------------------------------------+
| Record — Proxy Capture                          [Stop] |
| Listen on:   [:6001]                                   |
| Forward to:  [sun-b.lan:6000]                          |
| Output:      [~/Desktop/session.xtap]   [Choose...]    |
|                                                        |
| Status: connected — 12,847 bytes in / 91,283 bytes out |
| Last requests:                                         |
|   PolyFillRectangle  win=0x2a  gc=0x10  rects=1        |
|   PolyText8          win=0x2a  gc=0x10  "Hello"        |
|   ChangeProperty     win=0x2a  prop=_NET_WM_NAME       |
|   ...                                                  |
+--------------------------------------------------------+
```

Fields are saved between launches (UserDefaults). Live byte counts.
Last N decoded requests scroll past as they happen (read-only
window). Stop button finalizes and offers to open the file in a new
Examine window.

### Mode 2: Open (examine)

```
+------------------------------------------------------------+
| Open: 2026-05-23T14-41-58-quickplot.xtap                   |
|                                                            |
| Tree                  | Detail                             |
| ────────────────────  | ─────────────────────────────────  |
| ▶ Connection Setup    | Request 47: PolyFillRectangle      |
| ▼ Window Creation     |   drawable: 0x2a00007 (window)    |
|     CreateWindow 0x2a |   gc: 0x2a00010                    |
|     ChangeWMProps     |   nRects: 1                        |
|     MapWindow         |   rect[0]: (10, 20, 100, 30)       |
| ▼ Drawing             |                                    |
|     PolyFillRect (47) |  [bytes] [annotation] [hex view]  |
|     PolyText8         |                                    |
| ▼ Events              |  ◀ prev   [   timeline   ]   next ▶|
+------------------------------------------------------------+
```

- Tree groups requests by phase. Phase boundaries are inferred from
  the request stream (setup → window creation → drawing → events).
- Detail pane decodes the selected packet with three views: structured,
  annotated (spec excerpt), raw hex.
- Timeline scrubber across the bottom: jump by time, by request count,
  by request type filter.
- "Open in Replay mode" button hands the current file off.

### Mode 3: Replay

```
+--------------------------------------------------------+
| Replay: 2026-05-23T14-41-58-quickplot.xtap             |
|                                                        |
| Target:    [localhost:6000]                            |
| Mode:      ○ Real-time   ● Fast pump                   |
| Hold open: [✓] (keeps connection alive after replay)   |
|                                                        |
| Progress: ████████████░░░░  142 / 287 requests         |
|                                                        |
|                              [Start]  [Pause]  [Stop]  |
+--------------------------------------------------------+
```

Same semantics as the v1 CLI `replay` subcommand. Hold-open defaulted
on because that's almost always what you want when visually
inspecting.

## Migration from v1

v1's `swiftx-capture` binary stays — its CLI is what I use for corpus
capture and won't break. The new SwiftUI app is *additionally* named
`swiftx-capture` though, so there's a name conflict to resolve.

Two options:
- **(a) Rename the new app `swiftx-capture-app`** and keep the CLI at
  `swiftx-capture`. Ugly name, but no breakage.
- **(b) Move the CLI's subcommand interface into the new app and
  retire the old binary.** The SwiftUI app gets a `--headless` mode
  that exposes the v1 CLI behavior, so my corpus-capture scripts keep
  working. Cleaner long-term but more refactor up front.

Leaning toward (b) but won't decide until the SwiftUI app is real
enough to know if `--headless` is awkward.

## Implementation order

1. **Extract `CaptureSink` protocol** in `SwiftXCaptureCore`. Refactor
   `Recorder` to implement it. Existing CLI continues to work
   unchanged.
2. **Wire capture into `swiftx-server`** behind `--capture`. Per-
   session captureQueue, ring buffer, drain-to-disk. File naming and
   in-progress-then-rename logic.
3. **Preferences UI for "Capture every client"**. Status-menu indicator
   plus "Reveal Captures Folder" and "Discard All Captures" items.
4. **Cross-session test**: launch the server with capture on, run the
   captured-app replay tests against it, verify a `.xtap` lands in
   `/tmp/swift-x-captures/` and round-trips through the framer.
5. **New SwiftUI app skeleton**: mode picker + empty Record / Open /
   Replay windows. Three modes, three SwiftUI scenes.
6. **Record mode**: bind to existing `Proxy` + `Recorder` in
   `SwiftXCaptureCore`. UI for listen/forward/output, live byte
   counters.
7. **Open mode**: bind to existing `CaptureReader` + `ChronoDumper`.
   Tree-view of requests; detail pane with structured/annotated/hex
   tabs.
8. **Replay mode**: bind to existing `Replay`. Real-time vs fast,
   hold-open, progress bar.
9. **Name collision resolution** (see Migration section).
10. **Docs pass**: README updates, blog post on the new server-side
    capture flow, screenshots.

## Test strategy

- **Library** (`SwiftXCaptureCore`): existing tests cover format and
  round-trip. Add tests for the new `CaptureSink` protocol against a
  mock sink.
- **Server-side capture**: a new server test that connects a synthetic
  client, runs through a known request sequence, and verifies the
  resulting `.xtap` decodes back to the same sequence. Verify naming
  (timestamp + client name) and finalize-on-disconnect.
- **Performance**: a benchmark that times protocolQueue throughput with
  and without capture enabled, asserts <5% regression on representative
  workloads (existing captured-app replay set).
- **Capture app**: SwiftUI views are notoriously hard to unit-test;
  cover the model layer (CaptureBrowserModel, ReplayModel,
  RecordModel) with XCTests and accept that the actual view code is
  validated by use.

## Open questions to settle during build

- **First-launch behavior of the server when `--capture` is on but
  `/tmp/swift-x-captures/` doesn't exist**: just `mkdir -p`. No prompt.
- **What "client name" means at rename time**: I'm proposing the first
  of (a) the program-class from `WM_CLASS`, (b) `WM_NAME`, (c) the
  first `CreateWindow`'s window-name property, (d) fallback to
  `client-<sessionId>`. Need to verify which one fires fastest in
  practice across xterm / Motif / Athena.
- **Ring buffer sizing**: 64 KB is a guess. Might want to scale by
  observed throughput (e.g., bump to 256 KB if the drain falls behind
  more than once per minute). Measure first.
- **Replay-against-Swift-X**: per DECISIONS.md 2026-05-06, replay
  doesn't drive Product 2 testing because resource-id-base differs.
  The capture app's Replay mode inherits the same limitation. Worth
  surfacing in the UI (warning banner when target is `localhost:6000`
  and the target is detected to be `swiftx-server`).

## What this doesn't change

- v1's existing CLI continues to work for my corpus-capture scripts
  during the transition.
- The `.xtap` format is unchanged. Files captured by the v1 CLI open
  in the new examiner; files captured by the server open in the v1
  CLI's `dump` subcommand. Format compatibility is the whole point of
  putting it in the library.
- The framer is unchanged. All annotation goes through the existing
  `ChronoDumper` path.
- Product 2's M1/M2/M3 milestones are unaffected. Capture is a
  cross-cutting feature, not a milestone gate.

---

# Decoder Coverage Phase (post-v2, pre-OSS launch)

> **Status as of 2026-05-30 — see `macXcapture-feature-checklist.md` at the top level for the live
> ledger of what's done vs what's left.** Phases 0-3 (Tier 1) are done: every core X11 opcode +
> SHAPE / BIG-REQUESTS / MIT-SHM / XKEYBOARD / XInput v1 / RENDER all decode to typed dumper output.
> Suite is at 1007 tests, 0 failures. Phase 4 (Tier 2 extensions), Phase 5 (output polish), and a
> few deferred typed-trailer walkers remain. The phase plan below is the original journey; the
> checklist doc is the authoritative live state.

The mission stated at the top of this doc — macXcapture as a first-class X11 protocol inspection tool
— sets a concrete coverage bar: a capture from any reasonable X session should decode cleanly, with no
`opcode=N (untyped)` lines for opcodes the X protocol documents.

Today the framer covers what the swift-x server needs and what the captured corpus exercised. Plenty
of core opcodes and most extensions beyond SHAPE are still decoded as raw bytes. Closing that gap is
the last meaningful chunk of work before macXcapture stands on its own publicly.

This is mechanical work against a well-specified target. No design risk, no behavioral risk. Read the
section in `reference/x11-protocol-spec/x11protocol.html` or the extension spec in `reference/`, write
the decoder, write the dumper printer, write a round-trip test. Repeat.

## Phases

**Phase 0 — Audit.**

Single focused session. Inventory every X11 core opcode (1-127), every reply, every event against the
existing framer source (`Sources/Framer/Requests/`, `Replies/`, `Events/`) and against `ChronoDumper`'s
typed-print paths. Output: extend `OPCODE_STATUS.md` with two new columns:

- **Decoder** — yes / no / partial. Is there a typed struct in the framer that round-trips this wire
	form?
- **Dumper** — yes / no / stub. Does `ChronoDumper` produce a human-readable line for it, or fall
	through to the untyped hex dump?

The existing **Status** column stays unchanged — it's about server implementation, which is a
different question. Three columns, one row per opcode, single source of truth.

Exit: every row populated honestly. We know the actual size of Phases 1-5 only after this.

**Phase 1 — Core completion.**

Every core opcode that audited `Decoder = no` or `partial` gets a typed decoder and a dumper printer.
Many of the gaps are header-only (`GrabKeyboard`, `UngrabKeyboard`, `ForceScreenSaver`, etc.) — fast.

Each lands with a small round-trip test in `Tests/FramerTests/`: encode a synthetic struct, decode the
bytes, compare. No capture-driven tests needed — unit tests are enough and they're cheap.

Exit: re-dumping any historic capture or the new ss2 batch produces zero `opcode=N (untyped)` lines
for core ops (1-127).

**Phase 2 — Extension negotiation infrastructure.**

Today the dumper recognizes SHAPE because it's hardcoded by major opcode number. Generalize: track
which major opcodes the `QueryExtension` responses bind to which names *per-session*, then route
extension requests / replies / events through name-keyed decoders. For unknown extensions, the dumper
falls back to a labeled line — `extension MIT-SUNDRY-NONSENSE request opcode 3` — rather than
`opcode 134:3 (untyped)`. Useful even before that extension has a real per-request decoder.

Exit: every extension request gets a labeled line. Unknown extensions degrade gracefully.

**Phase 3 — Tier-1 extension decoders.**

In order of expected real-world traffic:

- **BIG-REQUESTS** — length-extension prefix, one opcode, trivial.
- **MIT-SHM** — finite, well-documented, already in our captures' unhandled list.
- **XKEYBOARD / XKB** — gnarly spec but high impact; modern clients hit it constantly.
- **XINPUT v1** — common. XINPUT2 is deferred to Tier 2.
- **RENDER** — used by Cairo/Pango, hit by basically every modern toolkit. Long spec; bound the
	work to the request set that real clients emit, not exhaustive coverage of obscure variants.

Each lands with the same per-opcode round-trip test discipline. Extension specs live in `reference/`.
Verify against those, not against guesses or other implementations.

Exit: a capture of a modern Linux X session decodes with no untyped lines for these five extensions.

**Phase 4 — Tier-2 extensions (decision point).**

RANDR, XFIXES, DAMAGE, XINPUT2, COMPOSITE. Less common in vintage-Sun traffic; near-universal in
modern Linux. Decide at the end of Phase 3 whether the OSS launch waits on these or ships without.
Leaning ship-without; Tier-2 is a natural post-launch contribution magnet for whoever cares about
modern Linux X traffic specifically.

**Phase 5 — Output polish.**

With every opcode decoding, the dumper can finally show the protocol as a *conversation*:

- A request line is followed by its reply or error, indented and aligned by sequence number.
- XErrors land inline next to the request that triggered them, not a hundred lines later.
- The `[seq=N]` column already supports this; the join logic in the dumper does not yet.

Same phase covers field-level diff in `CaptureDiff` (compare two captures' decoded streams field by
field, with tolerance rules for `serverTime`, resource-id base, and atom-id renumbering). Pays for
the paired-capture testing strategy from the May 2026 testing-strategy discussion: once decoders are
complete, `ss2->ss2` vs `ss2->swiftx` can be diffed semantically instead of byte-for-byte.

Exit: a user opening any capture in the viewer can scroll and read the protocol as a story. That's
the OSS-launch quality bar.

## Sequencing notes

Phase 0 drives everything. Until the audit is done, the size of Phase 1 is a guess. Run it first as
its own focused session.

Within each phase, the workflow is:

- Decoder + dumper printer land in one commit.
- Round-trip test in `Tests/FramerTests/` lands in the same commit.
- `OPCODE_STATUS.md` row (Decoder + Dumper columns) updates in the same commit.

The pre-implementation planning agent (CLAUDE.md) should fire on each Tier-1 extension before
implementation — the specs are large enough that getting a header field wrong compounds across every
later request in the extension. Core opcodes are usually trivial enough to skip the agent.

## Non-goals for the decoder phase

- **Implementing the things we decode.** Decoder coverage is independent of server implementation
	per the PROJECT.md non-goals clarification. macXcapture decoding RENDER doesn't mean swift-x
	implements RENDER.
- **Exhaustive extension coverage.** Tier 1 + Tier 2 (if shipped) covers the long tail of
	real-world traffic. Niche extensions stay as labeled-but-untyped lines.
- **Pretty-printing every field in every spec-perfect way.** The bar is "a reader of the X11 spec
	can follow what this line says without rereading the wire bytes." Not "this looks like xscope's
	output." Many of xscope's choices were terminal-only and don't translate to a syntax-highlighted
	GUI viewer.
- **Field validation.** The decoder reports what's on the wire; if a client sends a malformed
	request, the dumper shows the malformed request. macXcapture is a *passive observer*.
