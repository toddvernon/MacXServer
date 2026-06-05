# swift-x

## What this is

A modern X11 server written in Swift for macOS that displays X applications from real vintage Sun
workstations on the Mac, plus a passive capture tool that records and decodes X11 traffic between two Suns
on a LAN.

The motivation is that XQuartz works but is clunky, dated, and doesn't take advantage of modern Mac rendering.
I have a fleet of restored Sun workstations (SS1, SS2, IPC, IPX, Voyager, SS5, Ultra 1, Ultra 5, plus an SGI
Indigo) that should be able to display their X apps on my Mac with crisp anti-aliased fonts, native window
decorations, and Retina-quality rendering. None of that exists today.

## Goal

A Swift X server on the Mac that real X clients running on real Sun hardware on the same LAN can connect to
and display correctly, with the rendering quality you'd expect from a modern macOS app.

## Non-goals

These are explicitly out of scope. If I find myself reaching for them I should stop and ask whether I've drifted.

- Full Xorg compatibility *in the server*. I'm targeting X11R5/R6-era apps from vintage Sun hardware. No
	server-side DRI, Composite, RANDR, XInput2, GLX, or Render extension. (The capture tool may decode
	any of these — that's an independent product decision driven by macXcapture's standalone mission.
	See PRODUCT_1_CAPTURE.md.)
- Modern Linux desktop apps. GTK3/4, Qt, anything that wants client-side rendering with modern extensions.
	Not the audience.
- Hardware projects. The SBus framebuffer card idea is filed as "if a collaborator appears." I'm software only.
- Modified Xlib on the Sun. The Sun stays vintage and unmodified.
- Kernel drivers, custom hardware, or anything requiring me to write code that runs on the Sun beyond what
	the Sun already runs.
- Remote / WAN operation. LAN only. No Pi bridge, no CrossFeed, no internet-tunneled X. Suns talk plain TCP
	to the Mac on the same network.
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
- Reasonable performance on a LAN
- Code I'd be willing to publish

## Constraints I'm choosing

- X11R5/R6 protocol target, not modern X
- Swift on the Mac side, C on the Pi side (modern gcc, not vintage)
- Real Sun hardware as the reference for "is this correct?"
- No cloud dependencies. Self-hosted everything.
- Minimal tooling. No imake, no autotools, no CMake. Simple per-platform Makefiles like I use for cmacs.
- Tests come from real captured X traffic, not synthetic specs

## The shared piece: the framer library

Not a product on its own, but the highest-leverage code in the repo. A pure protocol codec for X11 wire
format: decoders and encoders for requests, replies, events, and errors. No semantics, no rendering, no
networking.

Written in Swift, used by both products.

## Product 1: Capture (CLI tool → library + GUI app + server-side capture)

A two-phase product. v1 is the CLI proxy tool that produced the framer, the corpus, and the article.
v2 is the public-release evolution: refactor the format/decode logic into a library, build a SwiftUI
app over it for hobbyists who want to record / examine / replay captures, and bolt server-side capture
into `macxserver` so users can hit a bug and hand back a `.xtap` without running a separate tool.

Standalone value (v1): lets me trace what real X clients actually do over the wire. Useful for
documentation, for learning the protocol, and for producing test fixtures.

Standalone value (v2): bug-report-grade capture for any swift-x user, plus an approachable GUI for
the "what's on the wire?" question.

Deliverables (v1, done 2026-05-06):
- Swift package with a clean wire protocol decoder (the framer)
- CLI tool that proxies, records, and dumps captures
- Captured data is between two real Sun workstations routed through the Swift capture app (man in the middle)
- A corpus of recorded sessions from real Suns: xterm, xclock, xeyes, xcalc, my Motif app (quickplot)
- Replay tool that can feed a capture back into a fresh X server
- A document for my web site about the tool, plus a written article walking through what goes over the wire
	during a simple xterm session, with annotated packet traffic matched to x.org packet definitions

Deliverables (v2, in design 2026-05-23 — full spec at the bottom of `PRODUCT_1_CAPTURE.md`):
- `SwiftXCaptureCore` as the single source of truth for `.xtap` format and decode
- `macxserver --capture` (and matching Preferences toggle) writing per-client `.xtap` files to
	`/tmp/macxcapture/` with no measurable hot-path latency
- New SwiftUI capture app with three modes: Record (proxy), Open (examine), Replay
- Library + apps stay in lockstep on file format; format is unchanged from v1

Why this gets built first: the framer is reused by Product 2. Having a real captured corpus before
writing a server means the server's tests are grounded in reality, not in the spec. v2's library
refactor doesn't gate Product 2 work; the two run in parallel.

## Product 2: Swift X server

The main event. A real X server in Swift, talking to real Sun clients over plain TCP on the LAN. Reuses the
framer from Product 1. Validated against the corpus from Product 1 and against real Suns on the LAN.

Standalone value: better-than-XQuartz X server for anyone with a vintage workstation and a Mac on the same
LAN.

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

## Build order

Product 1 first, then Product 2. The framer from Product 1 is reused by Product 2, and the captured corpus
from Product 1 grounds Product 2's tests in reality. Product 1 is done as of 2026-05-06; Product 2 is in
progress.

## Product principles

- Each product produces something useful even if the next product never happens
- Both products reuse the framer
- Each product is independently testable

## Voice and style for documentation in this project

Casual, first-person, direct. No em-dashes (they're an AI tell). No marketing language. Technical accuracy
over polish. Document why things are the way they are, not just what they are.
