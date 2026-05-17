# Architecture

## End state vision

```
Local LAN:

[SS5]    ─┐
[SS2]    ─┼─ plain TCP X11 ──► [Mac running Swift X server]
[SS1]    ─┤
[Indigo] ─┘
```

The Sun stays vintage and unmodified. It does plain TCP X11 to whatever's at the IP in `DISPLAY` — in this
project, the Mac on the same LAN. The Sun doesn't know or care.

The Mac runs the Swift X server. It receives X protocol bytes over plain TCP and renders them using Core
Graphics / Core Text / Metal. It uses native macOS window chrome (rootless mode) and exposes X selections
as NSPasteboard.

Display scaling: the server runs at a logical resolution (1280×900 for Studio Display, smaller for 4K and
MacBook Retina displays per a preset table) with an integer-scale projection to device pixels. The X
protocol layer sees logical coordinates; the rendering layer projects to device pixels with the
three-plane scaling decomposition specified in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Coordinates
cross the boundary at the protocol/render layer and nowhere else.

## How the two products fit

Each product is its own deliverable; they share a single repo organized so reusable parts get reused.

```
swift-x/
  Framer/                  shared X11 wire codec (Swift)
                           used by Products 1 and 2

  CaptureTool/             Product 1: proxy + recorder + replay tool
                           depends on Framer

  SwiftXServer/            Product 2: X server (TCP transport)
                           depends on Framer
```

## Component breakdown

### Framer (shared library)

Pure protocol codec. Knows how to decode and encode X11 wire format. Does not interpret semantics, does not
render, does not network.

Reused by:
- Capture tool's decoder
- Swift X server's request/event handling

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

The main artifact. Receives X protocol bytes via TCP from a directly-connected Sun on the LAN, decodes them
with the framer, and renders.

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
  Transport/           # TCP listener
```

Single root window, size chosen at startup based on the connected display (preset table in
`SERVER_RESOLUTION_SCALING_AND_FONTS.md`). One screen. PseudoColor 8-bit and TrueColor 24-bit visuals
exposed.

## Key architectural decisions, summary

These are the load-bearing choices. Full reasoning lives in DECISIONS.md.

- X server, not framebuffer scraper. Higher-quality output (modern font smoothing, low Sun-side overhead,
	much less bandwidth) at the cost of writing protocol code, which is doable.
- Rootless window mode as primary, with the option to run mwm on the Sun for the full retro look. macOS
	handles window decoration in primary mode.
- No Motif implementation needed. Motif is a client-side toolkit; its widgets travel as ordinary X drawing
	primitives. The server just renders them.
- Capture tool first. Builds the framer, builds the test corpus, and produces a useful artifact before the
	server work begins.
- LAN only. No remote / WAN transport. Suns and Mac on the same network, plain TCP.

## What lives where, summary

| Component                       | Language                       | Host  | Product        |
|---------------------------------|--------------------------------|-------|----------------|
| Framer (shared library)         | Swift                          | Mac   | shared by 1, 2 |
| Capture tool                    | Swift                          | Mac   | 1              |
| Test corpus                     | captured bytes + JSON metadata | repo  | 1              |
| Swift X server                  | Swift                          | Mac   | 2              |

Sun side: nothing. The Suns run stock Xsun and stock X clients. They are not modified.

## Build system

Simple Makefiles matching the cmacs cross-system pattern. No imake, no autotools, no CMake. The Mac builds
Swift packages with `swift build`.

## Network and deployment

- Mac side: Swift X server runs as a regular macOS app. Listens on TCP :6000 (or per `DISPLAY`).
- Suns set `DISPLAY=mac.local:0`, talk directly to the server.
