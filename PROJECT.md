# swift-x

## What this is

A modern X11 server written in Swift for macOS, plus the supporting infrastructure to display X applications
from real vintage Sun workstations on the Mac, with optional remote operation over the internet via CrossFeed.

The motivation is that XQuartz works but is clunky, dated, and doesn't take advantage of modern Mac rendering.
I have a fleet of restored Sun workstations (SS1, SS2, IPC, IPX, Voyager, SS5, Ultra 1, Ultra 5, plus an SGI
Indigo) that should be able to display their X apps on my Mac with crisp anti-aliased fonts, native window
decorations, and Retina-quality rendering. None of that exists today.

## Goal

A Swift X server on the Mac that real X clients running on real Sun hardware can connect to and display
correctly, with the rendering quality you'd expect from a modern macOS app. Stretch goal: do it over the
internet via CrossFeed so I can run X apps from my SPARCstation in Broomfield onto my laptop anywhere.

## Non-goals

These are explicitly out of scope. If I find myself reaching for them I should stop and ask whether I've drifted.

- Full Xorg compatibility. I'm targeting X11R5/R6 era apps from vintage Sun hardware. No DRI, no Composite,
	no RANDR, no XInput2, no GLX, no Render extension.
- Modern Linux desktop apps. GTK3/4, Qt, anything that wants client-side rendering with modern extensions.
	Not the audience.
- Hardware projects. The SBus framebuffer card idea is filed as "if a collaborator appears." I'm software only.
- Modified Xlib on the Sun. Originally considered, rejected in favor of Pi-as-frontend (see DECISIONS.md).
- Kernel drivers, custom hardware, or anything requiring me to write code that runs on the Sun beyond what
	the Sun already runs. The Sun stays vintage.
- 24/7 production reliability. This is hobby software for my own use, with the bar set at "I'd publish it
	to GitHub for other vintage Sun owners."

## Target users

In priority order:

1. Me, running X apps from my Sun collection on my Mac
2. Other vintage Sun / SGI / DEC owners who want a better-than-XQuartz experience
3. Possibly: vintage computing community as a published, documented tool

## Success criteria for the whole project

- xterm, twm, mwm, xclock, xeyes, xcalc running from a real SPARCstation against my Swift X server, looking
	good and behaving correctly
- A Motif app I wrote runs and is usable
- Anti-aliased font rendering on Retina, native macOS window chrome (rootless mode). Specifics in
	`SERVER_RESOLUTION_SCALING_AND_FONTS.md` — Core Text scalable substitutes, no bitmap fonts, cell-snapped
	terminal text. Quality bar: clearly beat XQuartz, approach iTerm2 for terminal rendering.
- Scalable display, since old computers had smaller screens and rendering them at native size on modern
	boxes makes everything too small. Display-adaptive integer scaling (3x or 4x for Retina, 2x for 1080p)
	picked at startup from a preset table per `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Three independent
	scaling planes (geometry / stroke / font) so lines stay crisp and glyphs stay hinted.
- Reasonable performance on a LAN; tolerable performance over the internet via CrossFeed
- Code I'd be willing to publish

## Constraints I'm choosing

- X11R5/R6 protocol target, not modern X
- Swift on the Mac side, C on the Pi side (modern gcc, not vintage)
- Real Sun hardware as the reference for "is this correct?"
- No cloud dependencies. Self-hosted everything. CrossFeed is the only network service in the loop and I own
	that too.
- Minimal tooling. No imake, no autotools, no CMake. Simple per-platform Makefiles like I use for cmacs.
- Tests come from real captured X traffic, not synthetic specs

## The shared piece: the framer library

Not a product on its own, but the highest-leverage code in the repo. A pure protocol codec for X11 wire
format: decoders and encoders for requests, replies, events, and errors. No semantics, no rendering, no
networking.

Written in Swift first (used by Products 1 and 2). When the Pi bridge gets X-aware features later, a C or Go
port may follow, sharing the captured-traffic test corpus as fixtures.

The framer is what makes the four products cohere into one project rather than four unrelated codebases.

## Product 1: Capture tool

A Swift CLI on the Mac that sits between two Suns on the LAN as a passive proxy. Forwards X traffic
faithfully, decodes it for human consumption, records sessions to disk for later replay.

Standalone value: lets me trace what real X clients actually do over the wire. Useful for documentation,
for learning the protocol, and for producing test fixtures.

Deliverables:
- Swift package with a clean wire protocol decoder (the framer)
- CLI tool that proxies, records, and dumps captures
- Captured data is between two real Sun workstations routed through the Swift capture app (man in the middle)
- A corpus of recorded sessions from real Suns: xterm, xclock, xeyes, twm, mwm, my Motif app, CDE if I have
	it, OpenWindows
- Replay tool that can feed a capture back into a fresh X server
- A document for my web site about the tool, plus a written article walking through what goes over the wire
	during a simple xterm session, with annotated packet traffic matched to x.org packet definitions

Why this gets built first: the framer is reused by every later product. Having a real captured corpus before
writing a server means the server's tests are grounded in reality, not in the spec.

## Product 2: Swift X server

The main event. A real X server in Swift, talking to real Sun clients. Selectable transport: standard TCP
for LAN clients, CrossFeed for remote clients. Reuses the framer from Product 1. Validated against the
corpus from Product 1 and against real Suns on the LAN.

Standalone value: better-than-XQuartz X server for anyone with a vintage workstation and a Mac on the same
LAN. Doesn't require any of the Pi/CrossFeed work to be useful.

Deliverables:
- Proof of concept, get xterm to display and interact
- Swift X server supporting the X11 core protocol subset that R5/R6 era apps actually use
- SHAPE and BIG-REQUESTS extensions
- Rootless window mode (each top-level X window becomes an NSWindow)
- Core Text-based font rendering with smart substitution of modern fonts for X core fonts, starting with
	xterm's
- 8-bit PseudoColor and 24-bit TrueColor visuals
- Selection bridging between X PRIMARY/CLIPBOARD and NSPasteboard
- Clean keyboard handling including Motif-specific keysyms
- Selectable transport (TCP or CrossFeed) so Product 4 can drop in without server-side changes

## Product 3: Pi-pair CrossFeed bridge

A daemon running on a Raspberry Pi (one on each end) that bridges X traffic between two real Suns over the
internet using CrossFeed transport.

Standalone value: lets me run X apps between two of my Suns over the internet. Useful demo of CrossFeed in a
demanding regime. Validates the bridge against two reference X implementations (real Xsun on both ends),
where any bug is in the bridge rather than in my server.

Deliverables:
- Bridge daemon that runs on the Pi (probably written in Go for ease of CrossFeed integration, TBD)
- Validated by running a real xterm session between two of my Suns through the Pi pair, with CrossFeed in
	the middle and a CrossFeed local server on a Pi 4

## Product 4: Swift X server with CrossFeed-bridged Sun

The full vision. Pi on the Sun side, Swift X server on the Mac, CrossFeed in between. A working remote X
session from any Sun in my shop to my Mac wherever I am.

Standalone value: this is the headline use case. Run a Motif app on my SPARCstation in Broomfield, see it on
my MacBook in a coffee shop, with native macOS rendering.

Deliverables:
- Working remote X session from any Sun in my shop to my Mac anywhere
- Possibly: caching/coalescing in the Pi bridge to make WAN latency tolerable for chatty apps

Mostly integration: Product 4 is Product 2 plus Product 3 wired together. Optimization work specific to the
WAN case (latency hiding, batching, X-aware compression) lives here rather than in either component.

## Build order

The four products can be built in any order in principle. In practice:
- Product 1 first, because its framer is reused by Product 2 and (possibly) Product 3, and because the
	captured corpus grounds Product 2's tests in reality
- Product 3 before Product 2, because it lets me validate CrossFeed transport against two reference Xsun
	implementations before introducing my own server as a third unknown
- Product 2 after Products 1 and 3, building on a known-good framer and a known-good transport
- Product 4 last, because it's the integration of 2 and 3

If I find myself wanting to start on Product 2 before Product 1 is done, I should re-read DECISIONS.md and
remember why I chose this order.

## Product principles

- Each product produces something useful even if the next product never happens
- Each product reuses code from earlier products (the framer especially)
- Each product is independently testable
- Order is chosen to validate riskiest assumptions earliest with the cheapest tests

## Voice and style for documentation in this project

Casual, first-person, direct. No em-dashes (they're an AI tell). No marketing language. Technical accuracy
over polish. Document why things are the way they are, not just what they are.
