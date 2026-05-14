# Post 1: I have a basement full of Sun workstations

I have a basement full of Sun workstations. An SS1, an SS2, an IPC, an IPX, a Voyager, an SS5, an Ultra 1,
an Ultra 5. Plus an SGI Indigo, because I couldn't help myself. Real CRTs, real type 4 and type 5 mice,
real Sun keyboards with the L-key column on the left. The complete late-80s-through-mid-90s Unix
workstation experience, set up on real desks, about ten feet from where I'm typing this on a Mac Studio
with a Studio Display.

I like the retro setup. I sit in front of it and the environment is what it was in 1995, hardware and
all. But sometimes, usually, I'm working at the Mac, and I want to pop a couple of xterms up so I can do
some maintenance on the collection (which, with eight aging Suns, is a real ongoing job), and I want
that experience to be good. Not "fire up XQuartz and squint." Good.

There's a Mac terminal I admire here. iTerm2. Those folks have done excellent work: anti-aliased text,
Retina-aware rendering, every knob you'd want for tuning the look of a terminal. The kind of terminal you
set up once and never think about again. iTerm2 is the standard any terminal on a modern Mac gets judged
by, and for this project it became the guiding light for what xterm rendering should look like. If I'm
shipping a Mac-side X server in 2026 and the xterm I render doesn't sit comfortably next to an iTerm2
window, the project has failed.

xterm is the easy case. I also wanted Motif apps. Specifically one.

Thirty years ago, my first job out of college, I was a contract engineer at NASA in flight test. I got
into programming in a big way and wanted to write a real app, one that people would use. The facility,
being a flight test facility, needed a 2D time-history plotting application. I wrote one. The first
version was pure Xlib. I wrote my own widgets, raw, no toolkit underneath. I was so excited to be
programming on the (then very new) Unix Sun SPARC platforms that I sold my home Mac, a Mac II, and
bought a Sun IPX. Not an easy box to buy for the home in 1990. Sun did not sell directly to consumers.
I had to go through my employer, who placed the order on my behalf. I spent the next year writing the
second iteration of the plotting app on my own time, nights and weekends. The new version used Motif as
the widget foundation and Xlib as the graphing layer. Command window and dialogs in Motif. The graphing
surfaces themselves were raw Xlib drawing: autoscaling, clipping, data plotting, line styles, symbols,
labeled axes, the whole thing. Interactive, but also completely scriptable, which mattered for this
application.

Frankly, I think it was put together better than most Motif apps of its day. It was called quickplot. I
ended up leaving NASA shortly after I finished the app and sold it to NASA on my way out the door. NASA
is a government agency and its technology transfer office will provide the code to you if you ask. It's
still available today.

I've compiled it several times for different platforms it supports (Sun, IRIX) and it still works
great and displays great on those boxes. But I really want it to display on my Mac as well. Keeping
retro gear like old monitors and LCD displays working is a bit of a challenge, to be honest. The actual
Sun boxes are a little easier; they were built like tanks.

So I started thinking. Given the productivity gains of Claude-Code, the agentic coding platform from
Anthropic, could I actually build a working X server on the Mac, with better performance and some
different design choices than XQuartz? Alone, or even as a small group of people, this project would
literally be a year or more. But from what I've personally experienced, agentic coding is astoundingly
productive, especially if you actually know how to code to begin with. I estimated I could probably
get something to work in a week.

So that was my goal for the project. Start simple, and see where it goes.

## Just use XQuartz?

The headline objection. Everyone who hears about a from-scratch X server for the Mac has the same first
thought. Doesn't macOS already have an X server? Yes. It's called XQuartz. It works, and was hand-crafted
over literally decades. It made some design decisions I don't agree with, and support is waning.

A short history. In 2003, Apple shipped X11.app in Mac OS X 10.3 Panther, built on XFree86. In 2007 they
moved it to the X.org codebase, the same release where macOS got UNIX 03 certification from The Open
Group. The Open Group's UNIX 03 spec requires an X Window System implementation, so Apple shipping an X
server was a load-bearing piece of certification compliance more than a product. In 2012 with 10.8
Mountain Lion they removed X11.app from the OS, and it became XQuartz at xquartz.org, maintained outside
Apple by a small community (largely Jeremy Huddleston Sequoia). Since 2012, XQuartz has had sporadic
releases focused on keeping the build working on the current macOS, fixing the worst bugs, and not
breaking anything. The codebase still has 2007-era X.org bones with patches on top. No Apple investment
since 2012.

XQuartz isn't bad because anyone was incompetent. It's the predictable result of thirteen years of
unfunded community maintenance on top of a 2007-era code drop from a company that had stopped caring once
UNIX certification stopped mattering as a marketing point. It is what it is.

Here's what that looks like in 2026 when I sit down to use it.

I run an xterm. It comes up about two inches wide on the Studio Display. Two inches because xterm assumes
the pixel coordinates of a 1280×1024 cgsix-equipped SPARCstation in 1995, the Studio Display has 200+
pixels per inch in 2026, and XQuartz doesn't have a scaling plane to bridge the difference. Same X
protocol coordinates, much smaller window. I have to manually pass `-fa Monaco -fs 24` or whatever to
even read the thing.

The fonts are bitmaps. XQuartz still ships bitmap fonts as the default for terminal use. The result on a
5K display is exactly what bitmap fonts on a 5K display look like: stair-stepping on diagonals, no
anti-aliasing on curves. You can pass `-fa` to get a Core Text scalable font, but the default experience
for a fresh user is 1996.

The windows have their own X11 title bars that don't pick up Mac keyboard shortcuts, don't co-exist with
native apps in Cmd-Tab, and look exactly 1996 next to a 2026 Safari window. XQuartz can run rootless but
its rootless mode still draws X11 chrome instead of using AppKit. xterm in XQuartz on my desktop, next to
Safari and iTerm2 and a Notes window, looks like an artifact from a different decade. Which, in fairness,
it is.

So when I want to administer a Sun from the Mac, I have a choice. Either run XQuartz and accept that
everything looks small and slightly wrong, or VNC into the Sun and accept blurry pixel-doubled output.
Neither feels like what 2026 should look like. iTerm2 is actually my go-to for interacting with the Sun
boxes, but older SunOS versions have very poor terminal resize support over telnet (ssh really isn't an
option), so a real xterm on the Mac would be a very welcome addition.

So I decided. Let's give it a try. Spend a day with Claude-Code and see what I could get working. Could
I actually create MacXserver?

I started.

## What X11 actually is

A short orientation for readers who know of X11 but don't really know exactly what it is.

**The server runs on the machine with the display.** "Server" and "client" are inverted from how most
modern network software uses those words. In X11, the **server** is the program that owns your screen,
keyboard, and mouse. The **clients** are the applications. If I sit in front of an SS2 running xterm
locally, the X server AND the X client are both running on my SS2. But if I run xterm with a different
display address on my network, the rendering is done and displayed on another Unix box running an X
server. Or, if I'm successful, my Mac running my new X server process.

This whole project exists to make my Mac a better X server for the clients running on my Suns.

**The protocol is network-transparent.** The X wire protocol (the bytes that go over the network) is
designed to run over any intermediate transport: Unix domain sockets (same box) or TCP/IP to another
box somewhere else in the world.

The X protocol is a TCP byte stream of length-prefixed requests, replies,
events, and errors. swift-x listens on `:6000` and accepts connections from any Sun on the LAN with
`DISPLAY=mac.local:0` set in its environment.

**The wire protocol is drawing commands, not pixels.** xclock doesn't ship pixels of the clock face. It
ships a PolySegment with the sixty tick endpoints and a FillPoly with the hour-hand polygon vertices. The
server turns those into pixels on its own hardware, with its own font rendering, on its own framebuffer.
A tiny amount of data drives a potentially complex display. This is the architectural fact that makes "modern
rendering for vintage clients" tractable: I get to write a 2026 Mac-native renderer for a 1989 command
stream.

**Toolkits stack on top of Xlib.** Xlib is the C library that turns function calls into wire bytes. On
top of Xlib sits Xt, the toolkit intrinsics: widget infrastructure, the inheritance model. On top of Xt
sit the actual widget sets: Athena (the spartan MIT default, what xcalc uses), Motif (the polished
commercial standard ubiquitous on commercial Unix in the 1990s, what quickplot uses), OPEN LOOK (Sun's
house style, OpenWindows). Each toolkit makes its own assumptions about server behavior that aren't quite
written down in any spec.

**Everything is a window. Literally everything.** This is the X11 design choice that surprises people
whose mental model came from macOS or Windows. In modern systems, a "window" is the framed rectangle
with a close button, and everything inside is a "widget" or a "view" handled by the application layer.
In X11 it's the opposite. Every button is a window. Every scrollbar is a window. Every label is a
window. The blinking cursor inside a Motif text field is, you guessed it, a window. A "window" in X11
is more of an abstract construct than a thing you see.

An xcalc has dozens of X windows: the top-level shell, the form widget that contains everything, the
LCD readout, and one X window for every key on the keypad. The application I wrote in Motif, quickplot,
contains hundreds of windows.

An X server implementation has to track all of them as first-class objects with parents, children,
mapping state, event masks, properties, geometry, z-order placement, message inheritance, the works.
When the client program calls `CreateWindow`, that window might be a top-level shell or a single button
inside one.

The reason is network transparency, again. If buttons were "just drawing the client did on top of one big
window," the client would have to know where every button was at all times to dispatch clicks. By making
each button its own server-side window, the X server can route a `ButtonPress` event to the right window
based on pointer position, and the client just listens. The toolkit on the client side gets clean events
with no geometry tracking.

The cost is a lot more server state than a modern compositor carries. Whether to mirror every X window
as an NSView on the Mac side, or to fake it with a single NSView and clip internally, is a non-trivial
design question. The trade-offs aren't obvious until you start drawing.

**The wire protocol stabilized in 1989 and has been backward-compatible ever since.** An xterm binary
built against libX11 in 1990 connects to a 2025 X.org server and works. That stability is the central
reason an X server in Swift, written in a week, is even possible. The surface area I have to implement
is fixed and well-documented, and with the aid of Claude-Code, a doable thing (I think).


## X11 as a protocol vs X11 as an implementation

Worth saying directly because it's the answer to "isn't writing an X server insane?"

X11 has two lives. As a **protocol**, it's one of the top technical successes of the Unix era. Wire
format stable since 1987. Backward-compatible for forty years. Network transparency. Open-source
reference implementation under a permissive license. The toolkit ecosystem on top. X11 sat alongside
TCP/IP and Unix itself and the C ABI as foundational infrastructure that the entire workstation era was
built on.

As an **implementation**, X.org is half a million lines of accumulated extensions, work-arounds, and
architectural assumptions that don't survive modern displays or modern security models. The Render and
Composite extensions bolted thick-client rendering onto a server-side-drawing architecture and never
quite fit. The xhost security model isn't fixable without throwing it out. Wayland exists because the
protocol-side X11 is fine but the implementation is a tar pit.

swift-x targets the protocol, not the implementation. The Sun clients I care about, from 1987 through
1996, use the core protocol that's been stable since X11R3. They don't use Render, don't use Composite,
don't use RANDR, don't use GLX. The surface I have to implement is exactly the surface with the strongest
stability guarantee. The successful part of X11 is exactly the part I get to take advantage of, and I
get to write the rendering layer for a 2026 Mac instead of a 1987 cgsix framebuffer driver.

This is why writing a new X server in five days isn't insane. I'm not reimplementing X.org. I'm
implementing a 40-year-stable wire protocol on top of Core Graphics, with a captured corpus of real Sun
traffic as ground truth.

Xlib at its heart is quite simple. It's a line-level expression of the wire protocol, and I know it
quite well. Everything in classic X (Xt, Motif, OPEN LOOK) eventually comes down to Xlib bytes on a
TCP stream. There are protocol extensions, and they fall into the same framing. If you understand the
wire protocol, you understand the system. That was the judgment call on day one. The protocol layer
was tractable to write from scratch because I knew it quite well. Err, at least I did in 1994.

## A note on how this was actually built

This is the load-bearing paragraph for a reader who's seen four AI hype cycles and isn't here for the
fifth. I am not going to try to convince you AI made this project possible. I'm going to tell you what
the partnership shape actually was, and you can decide.

I'm the architect. Thirty years of writing C and C++ on Unix, Linux, Windows and the Mac.

People think of AI agentic coding as "Build me an X server for my Mac." Well, that's not the way it
works. It's more like having a co-collaborator. You spend a lot of time talking with Claude about the
project, the design goals, the methodology. Then Claude builds a piece, you test it, you check the
work, you ask more questions.

What Claude does well: reads source files I don't have time to read. The X11R6 codebase is half a
million lines, the relevant pieces live in `lib/Xt` and `lib/Xm`, and Claude has read more of them this
week than I have in the last twenty years. Writes test scaffolding I don't want to write. Runs builds
and tests in tight loops while I think about the next architectural problem. Notices contradictions
across multiple design docs faster than I do. Holds the X spec in working memory across hour-long
debugging sessions in a way I genuinely can't.

What Claude does badly: confidently wrong about subtle things, sometimes. Misjudges scope when I haven't
bounded it. Suggests refactors that look reasonable but break invariants I haven't articulated. Doesn't
have the thirty-year context to know which API rough edges in X11 are load-bearing and which are
historical accidents worth cleaning up. Claude knows how the collective of people think it works, knows
how it's documented to work, but hasn't actually written an application using that information.

## Closing

On day five, my SPARCstation 2 in the basement booted my thirty-year-old Motif app, connected to an X
server I'd written this week in Swift, and dispatched its widget callbacks against it. The plot
rendered. The buttons clicked. The dialog opened when I asked it to. Things were not all the way right
(still aren't), but quickplot displayed on the Mac, fast, from a real Sun, over the LAN, looking like a
Mac app.

That's the rest of this series.

---

## Anchors for fact-check pass

- Files: `PROJECT.md`, `ARCHITECTURE.md`, `DECISIONS.md` (entries dated 2026-05-05)
- Initial commit: `96021e3` 2026-05-05 "Initial commit: Phase 1 capture tool + framer for swift-x"
- README commit: `01b40e4` 2026-05-05
- Constraints chosen day one: X11R5/R6 only, Swift on Mac, C on Pi, no cloud dependencies, no imake,
  minimal tooling, tests come from real captured traffic
- The Sun's `DISPLAY` env var is the only client-side configuration

## Evidence assets to gather (post-week)

- Side-by-side screenshot: same `xterm -fa Monaco -fs 12` on XQuartz vs swift-x, same Studio Display,
  default settings. The single strongest "just use XQuartz" rebuttal.
- Same for xclock (antialiased curves show the difference even more).
- WM_NAME-titled NSWindow on swift-x next to XQuartz's X11-titled window for the chrome comparison.

## Working title alternatives

- "I have a basement full of Sun workstations"
- "Why I'm writing an X server"
- "Five paths and the one I took"
- "Building swift-x: day one"
