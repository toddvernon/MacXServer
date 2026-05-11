# Post 1: The inception

**Date range**: May 5, 2026 (initial commit)
**One-line elevator**: Why I'm building a Swift X server from scratch instead of using XQuartz, and how the day-one decision matrix narrowed five candidate approaches down to one.

## What this post covers

The first day, before any X11 code existed. The shape of the problem, the alternatives I considered, and the architectural decisions that made the rest of the project possible.

## Setting

I have a fleet of vintage Sun workstations (SS1, SS2, IPC, IPX, Voyager, SS5, Ultra 1, Ultra 5, plus an SGI Indigo). They all run real Xsun and their stock X clients.

The motivation: my Suns should be able to display their X apps on my Mac at the proper size on modern hardware, with the rendering quality you'd expect from a Mac app. Not at 1x native pixel coordinates where xterm comes up two inches wide on a Studio Display. Not with bitmap fonts that XQuartz still ships in 2026. With anti-aliased scalable fonts and integer-scale projection to device pixels so glyphs land on the pixel grid.

## The two design drivers

The project pivots on two foundational drivers. Both shaped substantial chunks of design and both have their own post in this series.

1. **xterm pixel-perfect on modern hardware.** This is the rendering and scaling story. xterm is the simplest X client protocol-wise but the one everyone judges an X server by. If xterm doesn't look right at modern resolution, nothing else about the project matters. The whole `SERVER_RESOLUTION_SCALING_AND_FONTS.md` design doc came out of this driver. Post 6.
2. **Motif clients fully functional.** This is the protocol-correctness story. quickplot, dt-apps, the harder corners of Xt and libXm. If the server can't handle real Motif behavior, the project ships as "xterm replacement" and nothing more. Posts 9 and 10 of this series.

Both drivers determine what the next-level architecture has to look like. The scaling driver decides the three-plane rendering decomposition, no-pixel-fonts, integer scale, cell-snapping. The Motif driver decides the selection model, override-redirect popup handling, the depth of Xt-correctness work we have to do.

## The "just use XQuartz" objection (load-bearing section)

This is the headline rebuttal from anyone seeing the project for the first time. The article you're reading exists because XQuartz isn't good enough. The reasoning has to land before the rest of the series can.

### Short XQuartz history

- **2003**: Apple shipped `X11.app` in Mac OS X 10.3 Panther, built on XFree86 4.x. Aimed at Unix-workstation users and developers needing X clients on a Mac.
- **2007**: 10.5 Leopard moves X11.app to the X.org codebase. Same release where macOS gets UNIX 03 certification from The Open Group, and UNIX 03 requires an X Window System implementation. The X server was a load-bearing part of that certification, which is the institutional reason it existed.
- **2012**: 10.8 Mountain Lion removes X11.app from the OS. It becomes XQuartz at xquartz.org, maintained outside Apple by a small community (largely Jeremy Huddleston Sequoia).
- **2012 to today**: sporadic releases, mostly "keep it building on the current OS, fix critical bugs, don't break anything." Codebase still has 2007-era X.org bones with patches on top. No Apple investment since 2012.

### Why XQuartz isn't enough

Three concrete things, ordered by how immediate they are when you actually use XQuartz:

1. **Scale.** XQuartz windows render at native pixel coordinates on a 5K Studio Display. xterm comes up about two inches wide. There's no display-adaptive scaling, no Retina awareness in the rendering plane. The Phase 1 scaling work in `SERVER_RESOLUTION_SCALING_AND_FONTS.md` addresses exactly this: integer scale projection from a sensible logical resolution to device pixels.
2. **Font rendering.** XQuartz still ships bitmap fonts as the default for terminal use. Modern Core Text smoothing applied to drawing primitives in flight beats antialiased-bitmap-after-the-fact. xterm at 3x looks like a proper terminal on swift-x, looks like 1996 on XQuartz. Side-by-side screenshot makes the case in one glance.
3. **Window integration.** XQuartz's rootless mode has its own X11 title bars that don't match other Mac apps and don't integrate cleanly with Spaces, Mission Control, Cmd-Tab. swift-x uses real NSWindows from day one. Native chrome, native shortcuts, native behavior.

### The "literally didn't care" frame

XQuartz isn't bad because anyone was incompetent. It's the predictable result of thirteen years of unfunded community maintenance on top of a 2007-era code drop from Apple. Nobody at Apple has had the time or budget to revisit the rendering quality since UNIX certification stopped mattering as a marketing point. That's the texture of how it ended up where it is, and it's the kind of project I find interesting to take a swing at because the technical bar is just "do what a modern Mac app would do."

## X11 as a protocol vs X11 as an implementation (recurring thread)

This framing is the answer to "isn't writing an X server insane?" and it threads through the rest of the series.

X11 has two lives. As a **protocol**, it's one of the top technical successes of the Unix era. The wire format stabilized in 1987 and has been backward-compatible for forty years; a 1989 xterm binary connects to a 2024 X.org server and works. Network transparency, the open-source reference implementation under a permissive license, the toolkit ecosystem on top. Sat alongside TCP/IP, Unix itself, the C ABI as foundational infrastructure that the rest of the workstation era was built on.

As an **implementation**, X.org is a half-million lines of accumulated extensions, work-arounds, and architectural assumptions that don't survive modern displays or modern security models. The Render and Composite extensions tried to bolt thick-client rendering onto a server-side-drawing architecture. The xhost security model is unfixable without throwing it out. Wayland exists because the protocol is fine but the implementation is a tar pit.

swift-x targets the protocol, not the implementation. Sun clients from 1987-1996 use the core protocol that's been stable since X11R3. They don't use Render, don't use Composite, don't use RANDR, don't use GLX. The surface we have to implement is exactly the surface with the strongest stability guarantee. The successful part of X11 is the part we get to take advantage of, and we get to write the rendering layer for a 2026 Mac instead of a 1987 cgsix.

This is why writing a new X server in five days isn't insane. We're not reimplementing X.org. We're implementing a 40-year-stable wire protocol on top of Core Graphics, with a captured corpus from real Sun clients as the ground truth for what's actually needed.

This thread keeps coming back. The capture tool (Post 2) captures the protocol. M1's stubs (Post 3) honor the protocol's contracts. The scaling and font work (Post 6) is what happens when you take the protocol's commands and render them with modern technology instead of 1996 technology. The Motif debugging (Posts 9 and 10) is about libXm's expectations of the protocol, expectations that have been stable for thirty years. The protocol is the constant; everything else is choice.

## Five candidate approaches

## Five candidate approaches

Documented in `DECISIONS.md` 2026-05-05. The five paths I considered:

1. **Frame buffer scraper.** Custom daemon on the Sun that mmaps `/dev/cgsix0`, diffs tiles, ships pixels to the Mac. Like VNC but custom.
2. **Modified Xlib on the Sun.** Replace the transport layer in libX11 with one that talks to a custom server elsewhere.
3. **Custom SBus framebuffer card.** Dual-port RAM, FPGA, a Pi 5 watching the back side of the framebuffer memory and shipping pixels to the Mac. Pretends to be a cgthree to the Sun.
4. **Just use Xvnc.** Zero code, works tonight.
5. **Swift X server.** Build a modern X server in Swift on macOS, real Sun X clients connect to it.

## Why Swift X server won

- Lowest bandwidth (X requests are tiny compared to pixel data)
- Best output quality (modern font smoothing applied to drawing primitives in flight, not to bitmaps after the fact)
- Lowest Sun-side load (Sun sends drawing commands; Mac does the heavy work)
- Native macOS integration possible (rootless mode, one NSWindow per top-level X window)

## Why the others lost

- **Framebuffer scraper**: ships way more data than needed, results look like blurry pixel-doubled VNC. Doable in a weekend but the result is "VNC but worse."
- **Modified Xlib**: brittle across SunOS 4 vs Solaris 2, no clean security boundary, deployment hassle.
- **SBus card**: hardware engineering well outside my skill set. Filed as "if a collaborator appears."
- **Xvnc**: works tonight but doesn't move the project forward. Useful as a baseline reference but not the goal.

## The Pi-as-frontend decision

The single most important architectural decision in the project, also from day one. The Sun stays vintage and dumb. A Raspberry Pi on the Sun's LAN handles all modern protocol concerns (TLS, CrossFeed, encryption, auth). One Pi can serve multiple Suns; the Sun is never exposed to the internet directly. SunOS 4.1.4 can't do modern TLS anyway.

This eliminates an entire category of work and makes the whole thing cleanly tractable.

## The four-product plan

Day-one structure for what gets built and in what order:

1. Capture tool (Product 1). A passive proxy/recorder that captures real X traffic between two Suns. Building this first means the test corpus for Product 2 comes from real workloads, not from the protocol spec.
2. Sun-to-Sun Pi bridge (Product 3). CrossFeed transport validated against two reference Xsun implementations before introducing my own server as a third unknown.
3. Swift X server (Product 2). The main artifact.
4. Full WAN session via Pi bridge + Swift server (Product 4). Integration only.

In practice the order shifted: Product 1 first, then Product 2 (skipping the Pi bridge for now since LAN mode works fine). Pi bridge and CrossFeed are post-Product-2 work.

## What Todd should add

- The personal angle. Why this project, why now, what triggered the start.
- The connection to OldSilicon.com and the retirement-project arc.
- The "I'd been thinking about this for X months" backstory if any.
- What the day looked like. Did the four-product plan get written before any code? Was there a notebook session? A whiteboard? A conversation?
- The "this seemed doable" judgment call. What made you confident the X protocol layer was tractable to write from scratch, vs the project being a 2-year slog?
- Voice on the alternatives. The frame buffer scraper "VNC but worse" framing came from somewhere visceral; same with "imake is the single biggest barrier to anyone touching X11 source today."

## Evidence assets to gather (post-week)

- Side-by-side screenshot: same `xterm -fa Monaco -fs 12` on XQuartz vs swift-x, same Studio Display, default settings. The single strongest "just use XQuartz" rebuttal.
- Same for xclock (the analog clock with antialiased curves shows the difference even more).
- Optional: WM_NAME-titled NSWindow on swift-x next to XQuartz's X11-titled window for the chrome comparison.

## Anchors for fact-check pass

- Files: `PROJECT.md`, `ARCHITECTURE.md`, `DECISIONS.md` (entries dated 2026-05-05)
- Initial commit: `96021e3` 2026-05-05 "Initial commit: Phase 1 capture tool + framer for swift-x"
- README commit: `01b40e4` 2026-05-05 "Add README"
- Constraints chosen on day one: X11R5/R6 only, Swift on Mac, C on Pi, no cloud dependencies, no imake, minimal tooling, tests come from real captured traffic
- The Sun's `DISPLAY` environment variable as the only client-side configuration. The Sun stays unmodified.

## Working title alternatives

- "Why I'm writing an X server"
- "Five paths and the one I took"
- "Building swift-x: day one"
