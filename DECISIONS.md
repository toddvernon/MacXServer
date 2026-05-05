# Decisions

A log of architectural choices, with the alternatives considered and why they were rejected. Append-only, chronological. When something gets revisited, add a new entry referencing the old one rather than editing the old entry.

Format: each entry has a date, a one-line summary, what was chosen, what was rejected, and why.

---

## 2026-05-05: Project shape — Swift X server, not other approaches

**Chosen**: Write a modern X server in Swift on the Mac that real Sun X clients connect to.

**Alternatives considered**:

1. **Frame buffer scraper.** Custom daemon on the Sun that mmaps `/dev/cgsix0` (or similar), diffs tiles, ships pixels to the Mac. Mac reassembles into an `NSView`-backed image. Like VNC but custom.

2. **Modified Xlib on the Sun.** Replace the transport layer in libX11 with a custom transport that talks to a custom server elsewhere. Could be CrossFeed-based.

3. **Custom SBus framebuffer card** with dual-port RAM, FPGA-based, Pi 5 watching the back side of the framebuffer memory and shipping pixels to the Mac. Pretends to be a cgthree (or cgsix) to the Sun.

4. **Just use Xvnc.** Run VNC on the Sun, connect from a Mac VNC client. Zero code.

**Why Swift X server won**:

- Lowest bandwidth (X requests are tiny compared to pixel data)
- Best output quality (modern font smoothing applied to drawing primitives in flight, not to rasterized bitmaps after the fact)
- Lowest Sun-side load (Sun sends drawing commands; Mac does the heavy work)
- Native macOS integration possible (rootless mode with NSWindow per top-level X window)
- The chatty/latency-sensitive aspects of X are mitigatable with caching at the transport boundary, if needed

**Why others were rejected**:

- Frame buffer scraper: ships way more data than needed; can't take advantage of Mac's rendering quality; results look like blurry pixel-doubled VNC. Doable in a weekend but the result is "VNC but worse."
- Modified Xlib: requires per-Sun deployment of a forked library; brittle across SunOS 4 vs Solaris 2; no clean security boundary; deployment hassle. Replaced later by Pi-as-frontend (see below) which is strictly better.
- SBus card: hardware engineering well outside my skill set. Filed as "if a collaborator appears." Would be a beautiful project but not solo-feasible.
- Xvnc: works tonight but boring; doesn't move the project forward; doesn't take advantage of modern Mac rendering. Useful as a "does it work at all" baseline reference but not the goal.

---

## 2026-05-05: Pi as front-end, not modified Xlib on the Sun

**Chosen**: A Raspberry Pi on the Sun's LAN handles all modern protocol concerns (TLS, CrossFeed, encryption, auth). The Suns just do plain TCP X11 to the Pi.

**Rejected**: Modifying Xlib on the Sun to speak CrossFeed (or any modern transport) directly.

**Why**:

- SunOS 4.1.4 cannot do modern TLS (no usable OpenSSL, ancient TCP stack)
- Maintaining C90 code against gcc 2.7.2 with no modern libraries is a tar pit
- The Sun should never be exposed to the internet directly anyway (no security updates since the Clinton administration)
- The Pi is a clean security boundary
- One Pi can serve multiple Suns; no per-Sun software to install
- The pattern matches what I already do (Pi for DNS via dnsmasq on `example.com`)
- The Sun stays bit-perfect vintage

This is the single most important architectural decision in the project. It eliminates an entire category of work and makes the whole thing cleanly tractable.

---

## 2026-05-05: Capture tool / proxy first, before any server code

**Chosen**: Phase 1 is building a passive proxy/recorder that captures real X traffic between two Suns into a test corpus.

**Rejected**: Starting on the Swift X server directly, with the protocol spec as the guide.

**Why**:

- The protocol spec tells you what's legal; captures tell you what real clients actually do
- Real Xsun and real Xt/Motif clients are the ground truth
- Decoder code for the capture tool is reusable as the framer module in the server
- Test corpus from captures becomes regression tests for the server, with byte-level ground truth
- Building the protocol decoder against real traffic surfaces bugs immediately, vs. building it against the spec and finding bugs months later when apps misbehave mysteriously

---

## 2026-05-05: Dumb byte-pump bridge, not X-aware

**Chosen**: The Phase 2 Pi bridge is initially a generic TCP relay with no X protocol awareness. Just accepts a connection, opens an outbound connection, pumps bytes both ways.

**Rejected**: Building X-aware framing into the bridge from the start.

**Why**:

- The X protocol allows fully transparent relay; the client speaks first, the server responds, neither side needs the bridge to inject anything
- The bridge can be a few hundred lines instead of a few thousand
- X-awareness is only needed for optional features (compression, caching, multiplexing multiple Suns into one CrossFeed connection, capture/logging)
- Those features can be added incrementally on top of a working dumb bridge
- Simpler to validate: byte-identical pass-through is the cleanest possible correctness criterion

Earlier in the design conversation I incorrectly thought the bridge needed to synthesize a connection-setup reply before connecting to the real server. That was wrong — the client speaks first, so the bridge has plenty of time to open the outbound connection after reading the client's setup request and before producing any reply itself.

---

## 2026-05-05: Sun-to-Sun bridge phase before Swift server

**Chosen**: Phase ordering is capture tool → Sun-to-Sun bridge via two Pis → Swift X server → full WAN with Swift server.

**Rejected**: Capture tool → Swift server → bridge work later.

**Why**:

- The Sun-to-Sun bridge can be validated with two reference X implementations (real Xsun on both ends). Any bug is in the bridge.
- This separates "is the protocol bridge correct?" from "is my Swift X server correct?", which are two failure modes I want to debug separately
- The bridge is itself a useful artifact: lets me run X apps between two Suns over the internet, fun demo
- The bridge exercises CrossFeed under realistic load (sustained bidirectional binary traffic, latency-sensitive request/reply patterns), validating CrossFeed in a regime that probably isn't tested otherwise
- By the time I'm building the Swift server, the bridge is known-good and the corpus is known-good

---

## 2026-05-05: Build system — kill imake, use simple per-platform Makefiles

**Chosen**: If/when X11 source needs to build (e.g. for any future Xlib work, or for building reference clients for the test corpus), use simple `build/<platform>.mk` files matching the cmacs pattern. No imake, no autotools, no CMake.

**Rejected**: Keeping imake; using a modern build generator like CMake or Meson.

**Why**:

- Imake is the single biggest barrier to anyone touching X11 source today
- Imake encodes 1987 platform diversity that is no longer relevant; I have three platforms total (macOS, SunOS 4.1.4, Solaris 2.6)
- Simple per-platform Makefiles are 30 lines each and instantly understandable
- Matches the cross-system build pattern I already use for cmacs
- Pre-generate any imake-derived files (ks_tables.h, etc.) once and check them into the repo as source

---

## 2026-05-05: Rootless window mode as primary

**Chosen**: Each top-level X window becomes a native NSWindow with native macOS chrome. The X server intercepts top-level window creation and wraps in NSWindow.

**Rejected**: Rooted mode (one big NSWindow containing a virtual X screen) as the primary mode.

**Why**:

- Native Mac chrome integrates with Spaces, Mission Control, Cmd-Tab
- Window operations (move, resize, focus) happen at native Mac speed without round-tripping to clients
- This is where I can clearly improve on XQuartz, which has a clunky rootless mode

**Compromise / fallback**: Users who want full retro authenticity can run `mwm` on the Sun. The X server will then see mwm's reparenting and decoration windows as just more X windows, and they'll display correctly. So both options are available; rootless is the default.

---

## 2026-05-05: No Motif implementation on the Mac side

**Chosen**: The Swift X server does not implement any Motif-specific rendering. Motif is a client-side toolkit; its widgets travel as ordinary X drawing primitives.

**Rejected**: Building a "Motif renderer" on the Mac side.

**Why**:

- Motif (libXm) and its underpinnings (Xt) live entirely in the client process on the Sun
- A Motif scrollbar arriving at the X server is a series of `XFillRectangle` and `XDrawLine` calls; the server just renders them
- The Motif "look" emerges from how Motif draws over the wire, not from anything the server knows
- This significantly reduces server scope

The one related concern is making sure `AllocColor` is implemented faithfully so Motif can pick its specific bevel/shadow colors and have them honored.

---

## 2026-05-05: Subset extensions only

**Chosen**: Implement only SHAPE and BIG-REQUESTS as extensions. Stub MIT-SHM as "not supported" so clients fall back. Skip everything else.

**Rejected**: Trying to support Render, Composite, RANDR, GLX, XInput2, etc.

**Why**:

- Target era is X11R5/R6 and Sun-based apps from the 1990s
- Those apps don't use modern extensions
- Each extension is significant work
- Apps that ask for extensions and get "not supported" gracefully fall back to core protocol

If I find a specific app I want to run that needs another extension, I'll add it then.

---

## 2026-05-05: 8-bit PseudoColor + 24-bit TrueColor visuals

**Chosen**: The server exposes both an 8-bit PseudoColor visual and a 24-bit TrueColor visual to clients. Internally, render in 32-bit on the Mac.

**Rejected**: Exposing only one visual.

**Why**:

- Most R5/R6 era Sun apps assume PseudoColor 8-bit and behave correctly with it (it's what cgsix-equipped SPARCstations had)
- Some apps (Netscape 3, image viewers) prefer TrueColor and behave better with 24-bit
- Both visuals are easy to expose; the cost is just listing them in the connection setup reply
- All actual rendering happens in 32-bit on the Mac regardless; the visual is mostly a client-side abstraction

---

## Decisions still to make

These are open questions to resolve as the project progresses. Will become entries when decided.

- Bridge daemon language: C, Go, or Rust? Probably Go for ease of CrossFeed integration, but TBD.
- Capture file format: custom binary frames, or a sidecar metadata + raw byte log? Leaning toward the latter for simplicity.
- Whether to support multiple simultaneous client connections in the X server v1 (yes, but worth flagging that the auth and resource ID allocation per connection is a real piece of work).
- Whether the rendering backend is Core Graphics, Metal, or a switchable abstraction. Leaning Core Graphics first, Metal as optimization.
- How to handle the initial X core font requirement. Two options: ship actual bitmap font files and serve them faithfully, or do the "render with Core Text, lie about being a bitmap font" approach for font smoothing. The latter is much more interesting but much more work.
- Whether cursor rendering goes through the X cursor font (boring, easy) or substitutes modern crisp cursors (more interesting, more work).
