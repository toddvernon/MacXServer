# Architecture

## End state vision

```
Local LAN (Broomfield):                                     Wide internet:                  Wherever I am:

[SS5]    ─┐                                                                                 ┌─ [MacBook running
[SS2]    ─┼─ plain TCP X11 ──► [Pi: bridge daemon] ──CrossFeed (TLS)──► [CF relay] ──-──────┤   Swift X server]
[SS1]    ─┤                      running on                                                 │
[Indigo] ─┘                      example.com LAN                                             └─ [optional: another
                                                                                                Mac, iPad, etc]
```

The Sun stays vintage and dumb. It does plain TCP X11 to whatever's at the IP in `DISPLAY`. Could be the Pi,
could be the Mac directly on a LAN, could be another Sun. The Sun doesn't know or care.

The Pi is the modernization boundary. It speaks vintage X11 on the LAN side and modern TLS / CrossFeed on
the internet side. All the cryptography, authentication, NAT traversal, and protocol modernization lives
there. The Pi is also where any optional X-aware optimization (caching, coalescing, compression) would go in
a later phase.

The Mac runs the Swift X server. It receives X protocol bytes (whether from a local LAN connection or via
CrossFeed through a Pi) and renders them using Core Graphics / Core Text / Metal. It uses native macOS
window chrome (rootless mode) and exposes X selections as NSPasteboard.

Display scaling: the server runs at a logical resolution (1280×900 for Studio Display, smaller for 4K and
MacBook Retina displays per a preset table) with an integer-scale projection to device pixels. The X
protocol layer sees logical coordinates; the rendering layer projects to device pixels with the
three-plane scaling decomposition specified in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Coordinates
cross the boundary at the protocol/render layer and nowhere else.

## How the four products fit

Each product is its own deliverable, but they share a single repo organized so reusable parts get reused.

```
swift-x/
  Framer/                  shared X11 wire codec (Swift)
                           used by Products 1 and 2

  CaptureTool/             Product 1: proxy + recorder + replay tool
                           depends on Framer

  SwiftXServer/            Product 2: full X server with TCP and CrossFeed transports
                           depends on Framer

  PiBridge/                Product 3: Go (or C) daemon for the Pi
                           initially no X awareness; later may need a C/Go port of Framer

  Product 4 is integration only: Product 2's CrossFeed transport + Product 3's bridge wired together
```

## Component breakdown

### Framer (shared library)

Pure protocol codec. Knows how to decode and encode X11 wire format. Does not interpret semantics, does not
render, does not network.

Reused by:
- Capture tool's decoder
- Swift X server's request/event handling
- Eventually, the bridge daemon if/when X-aware features are added (caching, coalescing, compression). At
	that point a C/Go port matched to the Swift implementation by shared captured-traffic fixtures.

The framer is mechanical to write (the X protocol is well-specified) but must be correct. Validated against
captured byte streams from real Suns.

### Product 1: Capture tool

Mac-side Swift CLI. Acts as a passive proxy between two X participants on the LAN. Records traffic, decodes
for human consumption, serializes for replay.

```
[Sun A: clients] ──TCP──► [Mac: capture tool] ──TCP──► [Sun B: real Xsun]
                            framer + recorder
                            writes capture.xtap
```

Does not modify traffic. Forwards bytes faithfully while observing.

### Product 2: Swift X server

The main artifact. Receives X protocol bytes via TCP (from a directly-connected Sun on the LAN) or via
CrossFeed (from a Pi-bridged Sun across the internet), decodes them with the framer, and renders.

Internal structure:

```
SwiftXServer/
  Wire/                # uses the shared Framer
  Resources/           # X resource tracking (windows, pixmaps, GCs, fonts, colormaps)
  Dispatch/            # request handlers, one file per opcode group
  Render/              # Core Graphics (initially) / Metal (later) backend
  Fonts/               # XLFD parser, Core Text bridge, metrics cache
  WM/                  # rootless window management; each top-level X window → NSWindow
  Input/               # NSEvent → X event translation, keysym mapping
  Selection/           # PRIMARY/CLIPBOARD ↔ NSPasteboard bridge
  Transport/           # TCP listener + CrossFeed listener (selectable)
```

Single root window, size chosen at startup based on the connected display (preset table in
`SERVER_RESOLUTION_SCALING_AND_FONTS.md`). One screen. PseudoColor 8-bit and TrueColor 24-bit visuals
exposed.

### Product 3: Pi-pair CrossFeed bridge

A daemon that runs on a Raspberry Pi at each end. In the simplest form, it's a `socat`-equivalent: accept a
connection, open an outbound connection, pump bytes both directions. No X awareness needed for basic
operation, because the X protocol allows fully transparent relay.

Two deployment modes:
- Server-side: Pi listens on :6000 pretending to be an X server. When a client connects, the Pi opens an
	outbound connection to its peer and forwards.
- Client-side: Pi listens for incoming connections from a peer. When one arrives, opens a connection to a
	real local X server (e.g. real Xsun on a Sun on the same LAN) and forwards.

Same daemon binary, different config. Initial transport between the Pis is plain TCP for bring-up.
Production transport is CrossFeed.

### Product 4: Swift X server with CrossFeed-bridged Sun

This is integration, not new code (mostly). Wires Product 2's CrossFeed transport listener to a Pi running
Product 3 as the client-side bridge, with the Sun connected to the Pi via plain TCP on the LAN side.

Open question to revisit at this point: is CrossFeed message-oriented in a way that requires X-message
framing in the bridge, or can it carry arbitrary byte streams? If the former, the bridge becomes X-aware
here and pulls in a C or Go framer. If the latter, the bridge stays a dumb pump.

## Key architectural decisions, summary

These are the load-bearing choices. Full reasoning lives in DECISIONS.md.

- Pi as front-end to the Suns rather than modified Xlib on the Sun. Avoids maintaining vintage C code; keeps
	the Sun unmodified; provides a clean security boundary; generalizes to other vintage hardware.
- X server, not framebuffer scraper. Higher-quality output (modern font smoothing, low Sun-side overhead,
	much less bandwidth) at the cost of writing protocol code, which is doable.
- Rootless window mode as primary, with the option to run mwm on the Sun for the full retro look. macOS
	handles window decoration in primary mode.
- No Motif implementation needed. Motif is a client-side toolkit; its widgets travel as ordinary X drawing
	primitives. The server just renders them.
- Capture tool first. Builds the framer, builds the test corpus, and produces a useful artifact before the
	server work begins.
- Dumb byte-pump bridge for v1. The X protocol allows full transparent relay; the bridge does not need
	protocol awareness for basic correctness.

## Cross-language considerations

The framer logic exists in Swift (Mac) and possibly C or Go (Pi, when the bridge becomes X-aware in a later
phase). They must agree on framing semantics exactly. Strategy: write each carefully against the X11
protocol spec, share unit tests via captured byte streams as fixtures. Different languages, same test
inputs, same expected outputs.

## What lives where, summary

| Component                       | Language                       | Host  | Product        |
|---------------------------------|--------------------------------|-------|----------------|
| Framer (shared library)         | Swift                          | Mac   | shared by 1, 2 |
| Capture tool                    | Swift                          | Mac   | 1              |
| Test corpus                     | captured bytes + JSON metadata | repo  | 1              |
| Swift X server                  | Swift                          | Mac   | 2              |
| Bridge daemon                   | Go (probably) or C             | Pi    | 3              |
| C/Go framer port (if needed)    | C or Go                        | Pi    | 3 or 4         |
| CrossFeed transport in bridge   | same as bridge                 | Pi    | 3              |
| Integration wiring              | n/a                            | both  | 4              |

Sun side: nothing. The Suns run stock Xsun and stock X clients. They are not modified.

## Build system

Per-platform Makefiles, matching the cmacs cross-system pattern. No imake, no autotools, no CMake. The Mac
builds Swift packages with `swift build`. The Pi builds C/Go with simple Makefiles. If Xlib source ever
needs to build on the Sun (e.g. if the modified-Xlib idea ever resurrects for some reason), it does so with
`gcc 2.7.2` (SunOS 4.1.4) or `gcc 2.95` (Solaris 2.6) using a small platform `.mk` file.

## Network and deployment

- Mac side: Swift X server runs as a regular macOS app/daemon. Listens on TCP :6000 (or per `DISPLAY`), and
	optionally on a CrossFeed endpoint.
- LAN deployment (Product 2 standalone): Suns set `DISPLAY=mac.local:0`, talk directly to the server. No Pi
	involved.
- WAN deployment (Product 4): Suns set `DISPLAY=pi.lan:0`, the Pi bridges to CrossFeed, the Mac side accepts
	the CrossFeed connection directly into the X server's CrossFeed listener.

The Mac side X server doesn't know whether it's talking to a directly-connected Sun on the LAN or to a
Pi-bridged Sun across the internet. Either way, X11 bytes arrive in order over a reliable byte stream.
