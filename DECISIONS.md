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

## 2026-05-06: No stateful replay translation; replay stays as a smoke test

**Chosen**: The replay subcommand stays as a dumb byte-pump (with `--realtime` and `--hold` flags for visual inspection). It does not translate resource IDs or atoms between captures and replay targets. Replay is a smoke test, not a Product 2 integration test.

**Rejected**: Building a stateful replay translator (parse the captured C2S stream, track resource-id-base and atom mappings between original server and replay target, rewrite IDs in flight). Yesterday's plan flagged this as the next step.

**Why this changed**:

- Empirically tested on 2026-05-06: replaying `captures/xclock.xtap` against u5 with `--realtime --hold` rendered xclock correctly with 0 protocol errors. Same-server byte-pump replay just works as long as no other client has connected since the capture, because Sun's X server hands the first client a deterministic resource-id-base and the WM has already pre-interned the relevant atoms.
- The original justification for translation was Product 2 testing: feed captures into the Swift X server to validate it. But Product 2 will hand out a different resource-id-base than u5 did, and InternAtom replies will assign different atom IDs, so byte-pump replay against Product 2 will fail. Translation would fix that, but at the cost of a parser-rewriter pipeline of meaningful complexity.
- The honest answer is that Product 2 testing wants live Sun clients connecting through real Xlib to Product 2, not replayed bytes. That's a more realistic test (driven by the same client logic that drove the original capture) and exercises Product 2 against the same workload it'll see in production. Replay translation buys us "deterministic regression test of past sessions" but at significant code cost, against an alternative (live clients) that is both simpler and more representative.
- The capture corpus's job is now narrower: framer round-trip regression tests (see `Tests/SwiftXCaptureCoreTests/CorpusRoundTripTests.swift`) and source material for documentation. The "fixtures for Product 2" framing was always optimistic.

**What replay is good for now**:

- Smoke-testing the framer against real Sun behavior (decode → encode → send → observe response)
- Visual demonstration: pointing the tool at a Sun and seeing a recorded session render
- Bug reproduction against the *same* server when no other clients are connected

**What it isn't good for**:

- Driving Product 2 (different IDs and atoms; would need translation)
- Replaying captures that included user-driven window resizes (drawing requests are aimed at dimensions the replay doesn't cause)
- Any case where the original session depended on server timing or events that won't reproduce identically

If at some later point we have a specific need that translation would solve and live clients won't, revisit this entry.

---

## 2026-05-07: Display scaling and font handling — defer to SERVER_RESOLUTION_SCALING_AND_FONTS.md

**Chosen**: A separate design doc (`SERVER_RESOLUTION_SCALING_AND_FONTS.md`) holds the load-bearing decisions for how the server renders to Retina displays of different sizes and how X font requests resolve to Mac fonts. Headline points:

1. Display-adaptive integer scaling at startup. The server inspects the connected display and picks the highest integer scale (4x / 3x / 2x) and matching logical-root size that fits cleanly. One binary serves Studio Display (1280×900 @ 3x), 4K (1280×720 @ 3x), Pro Display XDR (1280×900 @ 4x), MacBook Pro Retina, etc.
2. **No bitmap fonts.** Every X font request resolves to a scalable Mac font via Core Text — Monaco, Helvetica Neue, Courier New, Andale Mono, Times New Roman, Symbol, Charter — using a substitution table from XLFD families.
3. Cell-snapping with **subpixel positioning OFF**. Reported metrics === rendered metrics. Crisp glyphs, predictable cursor positions, no drift.
4. Three independent scaling planes (geometry / stroke / font), each with its own snapping rules.
5. Phased rollout: Phase 1 startup-time integer scale + Phase-1 font set, Phase 2 user-overridable, Phase 3 fractional scales, Phase 4 polish (multi-monitor, full xlsfonts, custom cursors).

**Rejected**:

1. **Hardcoded single scale.** Studio-Display-only would leave 4K and MacBook Pro displays sub-optimal. The whole motivation of the project is to look great on Retina; that means all Retina, not one Retina.
2. **Ship X11 bitmap fonts and serve them faithfully.** Bitmap fonts upscaled to Retina look terrible. Shipping multiple sizes is a maintenance load that perpetuates exactly the cell-aligned-bitmap aesthetic this project is trying to escape.
3. **Subpixel positioning ON.** Conflicts with cell-snapped layout — glyphs would shift sub-pixel away from the X cell grid, breaking xterm's cursor alignment.

**Why**:

- iTerm2 is the explicit bar for terminal rendering on macOS. We need to clear it. XQuartz's rendering is the failure mode we exist to avoid.
- The X cell-grid model is fundamentally about predictable column positions; modern Mac fonts hint cleanly at integer sizes; the marriage works as long as we own the metrics.
- Display-adaptive lets one binary serve every Retina-class display without per-display configuration or shipping multiple binaries.
- Phased rollout lets us ship something working fast and improve it without churn.

This decision supersedes the "How to handle the initial X core font requirement" open question that previously lived in "Decisions still to make."

---

## 2026-05-09: Cell-fits-font, not font-fits-cell — iTerm2's playbook

**Chosen**: When a client opens a font (XLFD or named alias like `7x14`), pick the integer pointSize where Monaco's natural cell is closest to the request, then report Monaco's *actual* cell metrics in QueryFont. The named-alias dimensions become a hint, not a contract.

**Rejected**:
- **Force the requested cell exactly** (the previous rule). Required driving Monaco at fractional pointSizes to fit, which lost the Core Text hinter's sweet spot. Glyphs rendered "too bold" at 3× — asymmetric AA fringe from the mismatch between hinted advance and forced cell width. Even with `setShouldSmoothFonts(false)` and the metrics-tightening fix from 2026-05-08, the residue persisted.
- **Asymmetric font-matrix stretch** to fit Monaco into the named cell. Distorts stems anisotropically; the cure is worse than the disease at any visible stretch.
- **Per-alias substitution** (Monaco for some aliases, SF Mono for others). Font identity drift across cell sizes is visible and corrosive — programmers get mad when the font changes out from under them.
- **Smart-stretch** via CGPath stem-correcting transforms. Real engineering work; algorithmic stretch from one master is always inferior to picking a master that already fits. iTerm2 demonstrates we don't need to invent stretching when Apple already ships fonts that hint clean at integer pointSize.

**Why**:
- iTerm2's central architectural insight: it never tries to fit a font into a cell. It picks the user's font + integer pointSize, asks Core Text for the natural cell, and that becomes the cell. We do the same: alias names a target, integer pointSize picks the closest Monaco-natural cell, the cell follows.
- Integer pointSize is where CT's hinter does its best work. Fractional pointSizes lose stem crispness in ways that read as "weight noise" — different glyphs end up subtly heavier than others.
- Reported metrics === rendered metrics is preserved because both come from the same `CTFontCreateWithName(font, integer-pointSize, nil)` call.
- Monaco identity is preserved because Monaco is the only substitute on the monospace path.

**Concrete consequence**: Some named aliases drift from their literal dimensions. `7x14` reports as 6×13 (Monaco at 10pt). `9x15` reports as 7×15 (Monaco at 11pt). `12x24` reports as 11×24 (Monaco at 18pt). The user's `xterm -fn 7x14` window is therefore slightly smaller than the named dimensions suggest — but renders Monaco crisply, which is what they actually wanted.

See `FontResolver.swift` and the empirical alias map in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`.

## 2026-05-10 — Single-thread protocol model + Athena/Motif menu support

Two architectural changes shipped together to unblock real Xt/Motif client usability:

**1. Single protocol thread per session.** Replaced the prior two-thread (read + write) model with one GCD serial queue per session that owns all session state, the client socket, and event synthesis. AppKit-side bridge callbacks now hop onto this queue instead of touching session state on the main thread. Mirrors R6's `Dispatch()` loop and XQuartz's pthread-based server thread (see `SERVER_CONCURRENCY.md`).

Reason: Xlib "sequence lost" warnings from quickplot proved real wire-order corruption from the writeLock race; cross-thread reads of `sequenceNumber`/`pointerGrab`/`focusWindow` etc. were structurally racy regardless. One thread eliminates both classes of bug.

**2. Cross-NSWindow drag tracking via `NSEvent.addLocalMonitorForEvents`.** Athena and Motif menus rely on the X server delivering drag events to the popup-menu window even when the user pressed the button on the menu title (in a different NSWindow). AppKit's `mouseDragged` is sticky to the origin view, so the popup never sees pointer motion natively. When an X-protocol pointer grab is active, `CocoaWindowBridge` now installs a local NSEvent monitor that intercepts drag/up events, looks up which managed NSWindow contains the global pointer position (popup-level NSPanels first per z-order), translates coordinates, and routes to the right window's X-id.

XQuartz solves this with macOS-private `xp_*` kernel APIs we don't have; the local-monitor approach is the public-API approximation. See `SHORTCUTS.md` "Cross-NSWindow drag tracking" entry.

Plus a sweep of opcode coverage on the path to making this work: TranslateCoordinates, QueryTree, GetAtomName, QueryPointer, ListExtensions, QueryKeymap, ChangeActivePointerGrab, override-redirect popup windows (NSPanel at `.popUpMenu` level), passive button grab activation, mode=Grab/Ungrab on crossing+focus events, GC function (GXxor → `CGBlendMode.difference` for Athena's menu-item XOR-fill highlight). See `OPCODE_STATUS.md` for the full per-opcode status. The systematic sweep replaces a "find one missing opcode at a time, ship it, repeat" pattern that was accumulating tech debt.

Validated end-to-end against xfontsel font-menu drag-and-select on a real SS2 over the LAN; same machinery applies to Motif (quickplot) menus.

## 2026-05-10 — Impersonate the CDE customization daemon

**Chosen**: ServerSession registers a server-internal stub window (id `0xFFFE_0003`) as a child of root, claims selection ownership of `Customize Data:0`, and pre-publishes a hardcoded `SDT Pixel Set` property containing the exact byte string captured from u5's real CDE daemon. ConvertSelection requests for stub-owned selections short-circuit (write empty bytes + emit success).

**Rejected**:
- Returning `owner=None` for `Customize Data:N` and letting dt-apps take the fallback path — Solaris Xt's "no daemon" code path is apparently untested in real installs (CDE always runs `dtsession`) and dt-apps wedge indefinitely after our `SelectionNotify(property=None)`.
- Running a real CDE customization daemon in-process — way more code; serves only to drive the same outcome.
- Synthesizing a *minimal* SDT Pixel Set string — without knowing the format precisely, the captured-from-gold bytes are the safe choice.

**Why**:
- dt-apps (dtcalc, dtterm, dthelpview, dticon) are real-world clients we want to support. They wouldn't even render before this change.
- The customization daemon is a CDE-specific dependency that exists nowhere in the X11 protocol; impersonating it is a clean way to satisfy the contract without inheriting CDE's ToolTalk + dtsession + dtwm machinery.
- Hardcoded palette bytes are documented in `SHORTCUTS.md` so a later refactor can swap them for a runtime-configurable scheme.

**Concurrent fix that unblocked this**: `SelectionNotify`'s `time` field must be the verbatim value from the `ConvertSelection` request. Earlier we substituted `serverTime` when `r.time == 0` (correct for ButtonPress/KeyPress which the server generates from physical input), which broke `Xt`'s selection-event match. See `reference/X11R6/xc/lib/Xt/SelectionI.h:165` `MATCH_SELECT` macro: `event->time == info->time` is required for HandleSelectionReplies to fire. Any future X-protocol event generated *in response to* a client request should round-trip every reflected field.

## 2026-05-10 — Park dt-Motif widget chrome redraw

**Decision**: dt-apps render their main panels + the LCD-style readout widget + any window with non-default `BackPixel`, but the deep button hierarchy renders as flat unpainted grey with no visible button labels or shadows. We are not going to fix this in this round.

**Background**: per gold-vs-swiftx trace diff, gold emits **7 Expose events** during the whole dtcalc boot (sparse, targeted at LCD widgets); we emit **451** (one per mapped descendant). Gold's dtcalc fires 86 `PolyText8` (button labels) + 311 `PolyFillRectangle` (button fills); ours fires 0 + 20. dtcalc receives our flood of Expose events and doesn't redraw on any of them.

**Likely root cause**: real Sun X server does proper visibility tracking — it suppresses Expose for window regions about to be covered by child windows. Our X server emits Expose for every newly-mapped descendant without checking what covers what. Motif's PushButton redraw method, tuned for the sparse gold Expose pattern, treats our flood as spurious and doesn't fire.

**Fix is non-trivial**: implementing visibility tracking properly requires walking the window tree, computing per-window visible regions (the intersection of parent's visible region minus higher-stacked siblings minus children's covered regions), and emitting Expose only for the truly visible parts. Region arithmetic + stacking-order tracking adds real complexity. Logged in `SHORTCUTS.md`.

**Net status**: dt-apps run, accept input, have correct geometry, and pass through every protocol-level checkpoint. The visual gap is button-shadow + button-label drawing. Acceptable parking point given dt-apps are a stretch goal beyond the core PRODUCT_2_SERVER.md scope.

## 2026-05-13 — XError honesty becomes the default

**Decision**: shift the server from "forgiving by default" to "XError-honest by default." When a request can't be served, emit the correct XError on the wire and log the condition. Faking a success to dodge an error becomes a documented exception, not an unspoken pattern.

**Why now**: the forgiving-stub pattern (empty `GetProperty`, synthetic `AllocColor` pixels, track-and-ignore clip rectangles, silent-drop unknown opcodes) was a deliberate trade for the M1–M3 push. Each stub unblocked dependent work; replay-as-test required a server that didn't choke on Sun-captured bytes referencing Sun-allocated IDs; we knew it was tech debt. That was the right call at the time.

The trade has flipped. M3 is done and we're in the comparison-and-diagnostic phase: real clients, diffs against gold captures, finding out *why* swiftx behaves differently. The same forgiving stubs that bought velocity now hide the divergences we're trying to find. Concrete example surfaced by `swiftx-capture diff` on 2026-05-13: the CreateGC `mask=0xc` (gold) vs `mask=0x8` (swiftx) divergence shows up identically in xeyes *and* dtcalc, plausibly driven by `GetProperty(RESOURCE_MANAGER)` returning empty so the client falls back to compiled-in defaults. That class of bug is invisibly absorbed by a forgiving stub and would either resolve or be cleanly ruled out if we returned the correct reply or the correct error.

**Operational rules (also in `CLAUDE.md`)**:

1. **XErrors on the wire, not internal panics.** Emit `BadWindow`, `BadValue`, `BadAtom`, etc. per the X11 spec. Real clients handle these routinely. In tests, an XError emitted on a path we claim to support is a failure.
2. **Lying is a ledgered exception.** If we deliberately fake-success because the correct XError would break a working client we care about, the lie must be (a) listed in `SHORTCUTS.md` with a "what real looks like" exit plan, (b) annotated at the call site with a comment referencing the SHORTCUTS entry, and (c) revisited periodically.
3. **SHORTCUTS is now an active ledger** of currently-justified lies with paid-down dates, not a wish list of things we forgot to do.

**Follow-up sweep**: each open SHORTCUTS entry gets re-classified into one of three buckets: implement-for-real, convert-to-honest-error, or keep-as-justified-lie-with-contract. The fake CDE customization daemon and hardcoded SDT Pixel Set bytes already pass the contract (documented, scoped, rationale clear). Items like "GetProperty returns empty for unknown properties" don't and need either a real Xrm database or honest `BadAtom`.

**Note on replay tests**: `XclockReplayTests` and cousins assert "no XErrors emitted." Once XErrors are real, that splits into "no XErrors on supported paths; expected XErrors on known-bad inputs." More broadly, replay tests are construction tests, not correctness tests. A captured C2S stream is what the client said *given Sun's specific replies*, so replaying it against our different replies can't tell us whether we'd behave like Sun on a live run. The correctness oracle is the diff tool against live captures, not bigger replay suites.

---

## Decisions still to make

These are open questions to resolve as the project progresses. Will become entries when decided.

- Bridge daemon language: C, Go, or Rust? Probably Go for ease of CrossFeed integration, but TBD.
- Capture file format: custom binary frames, or a sidecar metadata + raw byte log? Leaning toward the latter for simplicity.
- Whether to support multiple simultaneous client connections in the X server v1 (yes, but worth flagging that the auth and resource ID allocation per connection is a real piece of work).
- Whether the rendering backend is Core Graphics, Metal, or a switchable abstraction. Leaning Core Graphics first, Metal as optimization.
- Whether cursor rendering goes through the X cursor font (boring, easy) or substitutes modern crisp cursors (more interesting, more work). `SERVER_RESOLUTION_SCALING_AND_FONTS.md` leans toward NSCursor substitution but that's not yet a hard commitment.
