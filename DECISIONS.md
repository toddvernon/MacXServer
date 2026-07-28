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

## 2026-05-14 — Skip backing-store advertise + Expose suppression

**Decision**: don't advertise `backing-store = Always` in SetupAccepted, and don't pursue server-side Expose suppression on region-uncovering events. Keep the current "emit Expose, client redraws" pattern.

**Background**: `WHAT_TO_DO_THIS_WEEK.md` Tier 1 #2 proposed advertising backing-store=Always plus suppressing Expose for region-uncovering events (sibling unmap, descendant move, etc.). The rationale claimed we already have de-facto backing-store at the NSWindow level because every top-level has a persistent CGContext, so suppression should be cheap. By end of week with the Region work + SubstructureNotify + VisibilityNotify shipped, time to re-evaluate.

**Why the original rationale was wrong**: the persistent CGContext per top-level retains the *live composite* of what's been drawn, not a per-child save-under buffer. When a child window maps on top of parent pixels, our code paints the child's background over the parent's pixels (`paintRectsForWindow`). The parent's content in that region is gone the moment the child maps. When the child later unmaps, `repaintParentOverUncovered` paints parent.bg over the uncovered region — but that's the background color, not the content the parent client had drawn there.

Real backing-store servers maintain a save-under buffer: stash parent pixels before a child obscures them, blit them back on uncovering. We don't have that. Without it, the persistent CGContext is NOT save-under-equivalent.

**The two real options**:
1. **Advertise backing-store=Always while still emitting Expose.** Dishonest — spec-compliant clients read the flag and decide they can skip Expose-driven redraws. Result: regions stay as parent.bg even though the client believed it had drawn over that area. Breaks every working client.
2. **Implement real save-under buffers.** Per-window pixel cache, save-on-obscure, restore-on-uncover, eviction policy. Multi-commit project comparable in scope to PutImage-on-depth-1.

**Rejected**:
- **Selectively suppress Expose where we can prove pixels are preserved.** Walked every Expose-emission path in the codebase. First-map (newly viewable, no prior content), resize-grow (newly revealed area has no content), descendant unmap (we paint parent.bg over the uncovered region), descendant move (same). None have a "pixels are actually preserved, skip the notify" path under the current architecture. The supposed "suppression case" doesn't exist for our code.

**The deeper reason to skip**: the dt-Motif Expose-count investigation drove us to *match* gold's Expose pattern (Region Step E1+ collapsed dtcalc 248 → 8 Exposes, matching gold within 1). Gold emits Exposes despite running with its own backing-store mode. So matching gold's pattern is the right target — not minimizing Exposes.

**When this might be revisited**: save-under has real value for popup menus (close-without-flicker) and other transient overlays. If/when that matters visually, the work is a save-under buffer attached to override-redirect windows specifically. Tracked as a future feature, not a foundational gap.

**Follow-up**: removed Tier 1 #2 from any future "things to do without hardware" list — the implicit assumption of "small win" was incorrect, and the current pattern is right.

---

## 2026-05-16: Project scope cut to two products — drop CrossFeed, Pi bridge, WAN entirely

**Chosen**: The project is the capture utility and the Swift X server, full stop. LAN-only. Suns and Mac on
the same network. No remote / internet operation, no Raspberry Pi bridge daemon, no CrossFeed transport.

**Rejected** (i.e. supersedes earlier intent): the four-product plan in prior versions of `PROJECT.md` and
`ARCHITECTURE.md` that included Product 3 (Pi-pair CrossFeed bridge) and Product 4 (Swift X server +
Pi + CrossFeed end-to-end). Those products are out of scope now and not deferred — they're cut.

**Why**:

- Hobby project. The LAN use case (vintage Sun in the shop, Mac on the same network, X app on screen with
	modern rendering) is the actual itch. The "Motif app from Broomfield onto my laptop in a coffee shop"
	scenario was always stretch; it isn't worth carrying the architectural weight of CrossFeed / Pi / TLS /
	NAT traversal through every doc, decision, and design conversation when the core LAN goal already keeps
	the server work busy for the foreseeable future.
- Scope discipline. Every doc that mentioned "selectable transport for Product 4" was a tiny tax on every
	architecture decision and a slow drift toward designing for a use case I wasn't going to build. Cutting
	it now makes the remaining work easier to reason about.
- The earlier "Pi as front-end" decisions (2026-05-05 entries above) are preserved as historical record of
	why we considered them and what tradeoffs they involved; they're no longer the architecture.

**What this changes in the repo**:

- `PROJECT.md`, `ARCHITECTURE.md`, `README.md`, `CLAUDE.md`, `PRODUCT_2_SERVER.md` updated to two-product
	scope. Remote / WAN moved to non-goals.
- No code changes. The server's `Transport/` directory was always TCP-only in practice; the "selectable
	listener" never got built.
- The prior CrossFeed-related entries in this file (2026-05-05) remain in place as historical record.
	They were valid decisions at the time. This entry supersedes them on scope.

**What's still in scope, just to be unambiguous**:

- Product 1: capture utility (done)
- Product 2: Swift X server over plain TCP on the LAN (in progress)
- Framer library shared between them

---

## 2026-05-16: Anti-aliasing off for all drawing primitives except text glyphs

**Chosen**: Every drawing primitive in `CocoaWindowBridge` runs with `setShouldAntialias(false)` and `interpolationQuality = .none`. The only exception is glyph rasterization inside `ImageText8` / `PolyText8`, which explicitly re-enables AA for the glyph fill. Enforced via the `withClip` helper, which every non-text primitive now flows through.

**Why**:

X11 is a pixel-aligned protocol. Clients send integer coordinates. The spec defines exactly which pixels each primitive covers — lines via Bresenham-style coverage, rects via half-open `[x, x+w) × [y, y+h)` interiors, arcs via specific scanline rules. Real X servers produce sharp aliased output. Vintage clients (Athena, Motif, Xt) were designed assuming that crispness — they draw and erase pixel-exact rectangles, expect adjacent fills to tile seamlessly, and rely on `XFillArc` / `XDrawArc` to clear back to exact pixel coverage.

Anti-aliasing breaks the contract in three observable ways we've hit:

1. **Halo accumulation on erase-then-redraw loops.** xclock's hands and xeyes' pupils both run "erase old position with bg color, draw new position with fg color" tick loops. AA leaves a partially-opaque fringe on the previous draw that the next erase only partially covers. Each tick deposits more AA residue; over minutes it reads as a halo around the moving element.
2. **Tile-seam blending.** Quickplot tiles `XClearArea(0, 0, W, 50)` and `XClearArea(0, 50, W, M)` edge-to-edge. With AA on and a fractional CTM, the y=50 boundary blends both fills with whatever's underneath the backing — which is the desk's blue when the page is selected. Manifests as a thin blue line at y=50.
3. **Sub-pixel positioning drift.** Stroke primitives at AA-on land on fractional pixel positions; CG's stroke-center convention pushes 1-pixel lines into 2-pixel soft bands, inconsistent across runs.

**Text is the deliberate exception.** Core X text drawing (PolyText8 / ImageText8) was bitmap, aliased. But we substitute scalable Core Text fonts (the original Sun bitmap fonts don't exist on the Mac), so turning AA off on glyph rasterization gives stair-stepped vector glyphs that look worse than the original bitmaps did on a 1990 Sun monitor. AA on for text is what makes the substitution defensible — covered by `SERVER_RESOLUTION_SCALING_AND_FONTS.md`'s quality bar.

**Why the +0.5 stroke offset (in `applyStrokePlane`) stays.** Without it, CG with AA off picks one of two adjacent pixel rows arbitrarily — flips between runs. With the +0.5 offset, every horizontal/vertical X-pixel-address stroke lands deterministically on its nominal row. Diagonals stair-step rather than smooth, which is the correct X11 behavior.

**Alternatives considered**:

1. **AA on everywhere with smarter erase logic.** Have the server track AA fringes and over-erase. Massively complex; the fringe shape depends on the path geometry. Rejected as YAGNI — accepting "correct X11" output is honest and trivial.
2. **AA on except for fills.** Half-measure. Fixes tile-seam blending but leaves halo accumulation on strokes (xclock hands). Inconsistent rule, harder to remember.
3. **User-tunable per-primitive AA via a settings table + config dialog** (Todd's idea). Right shape if we had multiple rendering knobs, but right now we have one knob with one exception. Premature abstraction. Revisit when we have 3+ user-tunable rendering settings.

**Honest cost**: xclock's hands and xeyes' eyeballs now have stair-stepped diagonal edges. That's accurate to what a Sun monitor produced in 1992. We're trying to be a Sun X server, so correct wins over modern smooth.

**Enforcement**: bake the AA-off into the `withClip` helper rather than relying on each call site to do it. New drawing primitives that flow through `withClip` get the right behavior for free. Text sites opt out explicitly inside the body. Any new primitive that bypasses `withClip` is a code-review red flag.

## 2026-05-18 — Retire the CDE customization daemon impersonation and CDE-flavored RESOURCE_MANAGER fixture

**Chosen**: stop pre-publishing the `Customize Data:0` selection ownership + `SDT Pixel Set` property + 3910-byte CDE-flavored `RESOURCE_MANAGER` fixture at session init. `GetProperty(RESOURCE_MANAGER)` now returns the spec-correct empty (`type=None, format=0`) like SS2 does. Selection ownership of `Customize Data:0` is left unowned, so dt-apps' `ConvertSelection` probe gets a spec-correct `SelectionNotify(property=None)` reply.

Retires both pieces: the 2026-05-10 decision above (customization daemon impersonation) and the 2026-05-17 RESOURCE_MANAGER fixture commit `aa5a674` (not a formal DECISIONS entry at the time but closed here).

**What stays**: `_MOTIF_DRAG_WINDOW` and `_MOTIF_WM_INFO` on root — both predate CDE and match what an SS2 box running plain `mwm` publishes. The 2026-05-09 quickplot-SIGSEGV rationale for `_MOTIF_DRAG_WINDOW` still applies. `ColorTable`'s pre-seeded CDE palette (pixels 1-23) remains in code but dormant now that no SDT Pixel Set indirection routes through it; deletion deferred until we confirm nothing else references those pixels by index.

**Why the 2026-05-10 rationale no longer applies**:

The "dt-apps wedge indefinitely after `SelectionNotify(property=None)`" diagnosis was wrong. The real wedge was our own `MATCH_SELECT`-time bug — we substituted `serverTime` for the request's `time` field on `SelectionNotify`, and `Xt`'s `MATCH_SELECT` macro silently dropped events where `event->time != info->time` (`reference/X11R6/xc/lib/Xt/SelectionI.h:165`). That bug was fixed separately. Once `time` round-trips verbatim, dt-apps tolerate `SelectionNotify(property=None)` exactly as the spec promises.

**Evidence the cut is safe**:

1. SS2 gold capture (`captures/dtcalc-running-on-u5-display-on-ss2.xtap`) shows SS2 publishes none of these: no Delphinium-flavored `RESOURCE_MANAGER`, no `Customize Data:0` owner, no `SDT Pixel Set`. ASCII-keyword search across the entire 37 KB S2C stream yields zero hits for `background`, `foreground`, `color`, `delphinium`, `palette`. dt-apps render correctly to SS2 anyway — they fall through to Motif built-in widget defaults (the "ugly blue" look).

2. Smoke-tested 2026-05-18 u5 → swiftx with the cuts applied:
   - dtcalc: full SS2 visual parity (Motif fallback blue panel + crisp white labels on every button — fixes the invisible-grey-label and white-on-white-LCD bugs from 2026-05-17 STATUS in one cut)
   - dtterm: terminal renders, normal usage works (separate BadRequest on opcode 93 surfaced via Motif Help menu — unrelated CreateCursor gap, stubbed)
   - quickplot, dthelpview, dticon, dtpad, dtmail: unchanged from pre-cut behavior. dtpad/dtmail/dticon still misbehave through swiftx the same way they misbehave through the `swiftx-capture` proxy when forwarding to SS2 (which they don't, when going u5→ss2 direct) — suggesting a Framer-shared bug, separate from this cut.

3. The "cutting CDE signals might unmask a hidden ToolTalk dependency" worry did not materialize. All apps that present render correctly; apps that don't present misbehave for the same reason they misbehaved through the capture proxy.

**Framing that makes this right**: the goal is "behave like SS2 running plain mwm, no CDE." mwm-era signals stay; CDE-only signals go. dt-apps falling back to Motif built-in widget defaults is exactly what they look like on a real SS2 with mwm — spec-correct, contrast-correct, visually consistent with the gold display.

**Code state**: `installCDECustomizationDaemonImpersonation` and the `CDEResourceManagerFixture.bytes` publish are commented out in `ServerSession.swift` rather than deleted. Re-enabling is a comment-strip if a future dt-app surprises us. Plan to delete the dead code (and the `CDEResourceManagerFixture` source file) after another round of dt-app testing confirms no regression.

## 2026-05-18 — Publish curated Tier 1 `RESOURCE_MANAGER` (Motif widget defaults)

**Chosen**: bake a 7-line hand-curated `*XmText.fontList:` / `*XmLabel.fontList:` / etc. set into `Sources/SwiftXServerCore/DefaultMotifResources.swift` and publish it as `RESOURCE_MANAGER` on root at session init. Different in purpose and content from the morning's retirement: we're not impersonating CDE, we're steering Motif's widget-class defaults toward `-adobe-helvetica-*` and `-adobe-courier-*` XLFDs that route cleanly through `FontResolver`'s substitution table to Mac fonts (Helvetica Neue, Courier New) that render nicely at retina.

Tier 1 is the first of three staged delivery tiers laid out in `MOTIF_TEXT_QUALITY.md`:
- Tier 1 (this): hardcoded in Swift source, identical per session.
- Tier 2: user-editable Xresources file in app support.
- Tier 3: macOS settings panel.

**Why this isn't a reversal of the morning's retirement**: the morning's cut removed CDE-flavored content (Delphinium palette, `-dt-interface` XLFDs, dtwm + OpenWindows resources, 3910 bytes of stuff a non-CDE server has no business publishing). Tier 1 is ~250 bytes of widget-class font defaults — strictly the control surface from the playbook, no CDE-flavored content. The morning's "be SS2 with mwm" framing still holds: SS2 with no xrdb loaded publishes nothing, but SS2 with `xrdb $HOME/.Xresources` loaded publishes whatever the user put there. Tier 1 is "the user has a curated default `.Xresources`, baked in."

**Pairs with the same-day MOTIF_TEXT_QUALITY invariant fix**: now that `FontResolver.integerAdvances` is the single source of truth for both reported CHARINFO widths and rendered glyph positions, Tier 1's XLFDs route through a pipeline where what we say is what we draw. The two pieces compound — Tier 1 alone would render against the prior float-drift bug, the invariant alone would have nothing to render with.

## 2026-05-19 — ColorTable becomes server-global; AllocColor honors shared cells

**Chosen**: Move `ColorTable` from `ServerSession` to `ServerCoordinator` (parallel to `atoms`), add thread-safe `NSLock`-guarded `rgbToPixel` reverse map, and rewrite `allocate(...)` to return the existing pixel when the requested RGB is already in the table (shared read-only cells, per X11 spec). Delete the 22-pixel CDE-palette pre-seed left dormant by the 2026-05-18 retirement; only whitePixel (0), blackPixel (1), and 0xFFFFFF=white stay pinned at init.

**Trigger**: dtcalc's LCD widget was rendering white-on-white. Diagnosis traced through dtcalc/motif.c lines 735-760: when `colorSrv=True && BlackWhite=False`, the LCD's foreground is hardcoded to `white_pixel` and its background to `pixels[6].bg`. On real SS2, Motif's no-color-server fallback walks the `BlackWhite=True` branch instead, because `AllocColor(rgb=65535,65535,65535)` returns `whitePixel` (0) — which the equality check `pixels[0].bg == white_pixel` then satisfies. Our `ColorTable.allocate(...)` was purely monotonic — every call returned a fresh pixel, even for an RGB that matched a pinned entry — so the equality check failed, BlackWhite stayed False, and the LCD landed on the white-on-near-white branch.

**Alternatives rejected**:

1. *One-line RGB-match in the per-session table.* Closes the visible bug but leaves SHORTCUTS:32's structural half — two sessions still allocate "the same" pixel value 16 and get different colors, and whoever draws last wins. Half-fix that masks the remaining bug.
2. *Re-publish a curated SDT Pixel Set under a stub-owned `Customize Data:0` selection.* Would fix dtcalc by giving Motif a real pixel-set source. But this is step (3) of the DECISIONS.md 2026-05-18 "Whether and how to re-add CDE support" path, which intentionally puts it AFTER (1) per-session-vs-global cleanup and (2) Xrm-aware RESOURCE_MANAGER. Sequencing matters; this fix advances (1) for ColorTable while leaving (2) and the SDT story for follow-ups.
3. *Make whitePixel resolve to a dark color in our palette.* Breaks every legitimate use of WhitePixel everywhere. Non-starter.
4. *Keep the dormant CDE palette as a safety net.* Pre-seeding pixels 1-23 with greys means that with shared-cell matching, any client allocating one of those RGBs by coincidence would land on a CDE-palette index — conflating dormant CDE state with new live allocations. Cleaner to delete now that the SDT indirection is gone.

**What's still missing on the colormap (deliberately, scoped follow-up)**: a `FreeColors` round-trip (so pixel slots can be reclaimed), `AllocColorCells` for read-write cells, `StoreColors` to update RGB on an already-allocated pixel, and a 256-cell cap to honor the depth-8 visual we advertise. Tracked in the rewritten SHORTCUTS entry.

**Validation**: 540 tests pass (7 new `ColorTableTests` cover whitePixel/blackPixel canonical IDs, repeated-RGB sharing, distinct-RGB distinctness, cross-session sharing via the coordinator). `CapturedAppReplayTests` baselines rebased — each app's `colors` count drops by 22 (deleted CDE palette) plus any shared-cell deduplication.

This entry advances step (1) of DECISIONS 2026-05-18 line 470 for the colormap. Properties scoping (the other half of step 1) is still open — see SHORTCUTS for that entry.

**Postscript**: this fix turned out not to be the dtcalc-LCD-invisible-text bug after all — same-day capture+diff showed wire-level identity with SS2 (same opcodes, same pixel values, fg=0x1 black on bg=0x0 white). The actual LCD bug was a separate `SetClipRectangles`-translation bug closed later the same day (see SHORTCUTS Closed 2026-05-19 "SetClipRectangles' rects weren't translated by the widget windowOffset"). The ColorTable fix is still a real X-spec correctness improvement and the SHORTCUTS:32 retirement still stands — it just wasn't the LCD's bug.

---

## 2026-05-23 — Font substitution table promoted to user-editable `~/.swiftx-fonts`

**Chosen**: Move the XLFD-family → Mac-font mapping from a hardcoded switch in `FontResolver.resolveFamily` to a user-editable file at `~/.swiftx-fonts`, with the same shape as the resources file: parsed by `FontMappingFile` in `SwiftXServerCore`, seeded from `DefaultFontMappings.seedContent` on first run via `FontMappingFileLoader.loadOrSeed`, edited via a SwiftUI panel (`FontMappingsPanelView` in an `NSPanel`) opened from a new "Edit Font Mappings…" menu item. `FontResolver.installMappings()` is called from `main.swift` at server startup and again by the editor on Save/Revert so newly-launched X clients pick up edits without a server restart. Existing clients keep their cached font metrics from QueryFont; banner makes this explicit.

**File format**: line-oriented `<xlfd-family>  ->  <mac-font>  mono|prop`. The `->` separates family from Mac font; the trailing `mono`/`prop` token separates Mac font from spacing kind. This supports multi-word X family names (`new century schoolbook`) and multi-word Mac fonts (`Helvetica Neue`) without ambiguity. Two special keys hold the wildcard fallbacks: `*fallback-mono` (used when a client requests spacing `c` or `m` with an unknown family) and `*fallback-prop` (everything else).

**Alternatives rejected**:

1. *INI sections like the resources file* (`[mono] ... [prop] ... [fallbacks]`). Adds hierarchy the data doesn't need — the substitution table IS a flat lookup. Flat format makes diffs and edits trivially readable.
2. *Whitespace-only delimiters with the trailing `mono`/`prop` as disambiguator* (no `->`). Was the first cut; broke as soon as `new century schoolbook` (multi-word family) was added because there's no way to tell where the family ends and the Mac font starts.
3. *Keep the table hardcoded and skip the editor entirely.* The seed/revert/save story already exists for resources; making fonts editable cost ~600 lines including chrome and tests, and it lets us iterate font substitutions live during dt-app tuning without rebuilding the server.

**This is not a change to the substitution table architecture** (which `CLAUDE.md` explicitly asks me to ask before changing). The default contents are byte-identical to the prior hardcoded switch and the spec table in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Tier-2 delivery, not a redesign — same pattern this doc already calls out as a follow-on for `RESOURCE_MANAGER`.

**Files**:
- `Sources/SwiftXServerCore/FontMappingFile.swift` — parser + `FontMappingFileLoader.loadOrSeed` (~150 lines)
- `Sources/SwiftXServerCore/DefaultFontMappings.swift` — seed content (~60 lines)
- `Sources/SwiftXServerCore/FontMappingTokenizer.swift` — syntax-highlight tokenizer (~150 lines)
- `Sources/SwiftXServerCore/FontResolver.swift` — `resolveFamily` now hits the loaded `FontMappingFile`; new `installMappings()` startup hook
- `Sources/SwiftXServer/FontMappingSyntaxHighlighter.swift` — `NSTextStorageDelegate` painting the file (~75 lines)
- `Sources/SwiftXServer/FontMappingsPanelView.swift` — SwiftUI root + model (~170 lines)
- `Sources/SwiftXServer/FontMappingsWindowController.swift` — NSPanel + NSHostingView shell (~35 lines)
- `Sources/SwiftXServer/SyntaxHighlighter.swift` — extracted protocol so `CodeEditorView` takes either highlighter via a factory closure
- `Sources/SwiftXServer/AppDelegate.swift` — new menu items in both status menu and app menu
- `Sources/SwiftXServer/main.swift` — `FontResolver.installMappings()` at startup
- `Tests/SwiftXServerCoreTests/FontMappingFileTests.swift` + `FontMappingTokenizerTests.swift` — 25 tests

---

## 2026-05-23 — Chrome dialogs use SwiftUI in an NSPanel; X server windowing stays AppKit

**Chosen**: The Mac-side chrome (Resources editor, Preferences) is SwiftUI hosted in an `NSPanel` via `NSHostingView`. The X server's per-X-window `NSWindow` + custom `NSView` rendering layer stays AppKit. The two boundary classes (`ResourcesWindowController`, `PreferencesWindowController`) keep their `showWindow()` API so AppDelegate's menu wiring doesn't move. The Resources editor uses a dark code-editor theme (near-black background, warm coral section headers, green keys, soft cyan values, muted green-grey italic comments) with a `ResourceSyntaxHighlighter` (`NSTextStorageDelegate`) that paints color values in their actual color (with a luminance-lift fallback for values too dark to read on black). **Line-number gutter was attempted as an `NSRulerView` and deferred** — see SHORTCUTS "Line-number gutter deferred" for the iteration history; an `NSRulerView` inside a SwiftUI-hosted `NSScrollView` couldn't be made to coexist with the surrounding VStack layout, so the editor ships without one.

**Alternatives rejected**:

1. *Keep everything AppKit and refine the existing NSStackView layouts.* Achievable but expensive in code per pixel — every spacing, font, button bezel, focus ring decision is manual, and the defaults skew older with each macOS release. The earlier passes on the Resources editor (two extreme versions then a settling middle on 2026-05-23 morning) demonstrated the cost.
2. *Port the X server side to SwiftUI too.* SwiftUI hides NSWindow internals we depend on for rootless WM emulation: `NSEvent.addLocalMonitorForEvents` cross-window tracking during X grabs, direct backing-scale-factor control for pixmap-at-device-scale, raw key-event interception for the keymap, per-window custom-draw `NSView` subclasses. Fighting the framework constantly would cost far more than the chrome benefit.
3. *Use SwiftUI's `TextEditor` for the resources file editor.* Weak for code editing — no find-bar, no horizontal scroll, no good monospace handling, slow on long buffers. We wrap `NSTextView` in `NSViewRepresentable` instead (`CodeEditorView.swift`, ~110 lines) and keep all the AppKit knobs we already had.
4. *Light-themed editor matching Covey chrome.* Todd wanted iTerm/Xcode dark-theme vibe for the editor specifically — code is code. Surrounding chrome (header, theme picker, action row, banner) still follows system light/dark via SwiftUI semantic colors.

**Why this is structurally clean**: SwiftUI and AppKit cross at exactly two boundary classes (the window controllers). The X server windowing layer doesn't know SwiftUI exists. The chrome doesn't know about ServerSession or the protocol queue. The Preferences settings still flow through the same `Preferences` (UserDefaults-backed) class that `ServerSession` reads — the SwiftUI panel is a thin `ObservableObject` wrapper that proxies writes back. Removing SwiftUI later would touch only the chrome files.

**File map after this change**:
- `Sources/SwiftXServer/EditorTheme.swift` — palette + token → NSColor mapping (~75 lines)
- `Sources/SwiftXServer/CodeEditorView.swift` — `NSViewRepresentable` around NSScrollView + NSTextView (~95 lines)
- `Sources/SwiftXServer/ResourceSyntaxHighlighter.swift` — `NSTextStorageDelegate` + color-value rendering (~120 lines)
- `Sources/SwiftXServer/ResourcesPanelView.swift` — SwiftUI root + view model (~230 lines)
- `Sources/SwiftXServer/PreferencesPanelView.swift` — SwiftUI tabs + view model (~140 lines)
- `Sources/SwiftXServer/ResourcesWindowController.swift` — NSPanel + NSHostingView shell (~35 lines, replaces ~400-line AppKit version)
- `Sources/SwiftXServer/PreferencesWindowController.swift` — same shape (~30 lines)
- `Sources/SwiftXServerCore/ResourceTokenizer.swift` — pure-Swift tokenizer in Core for test coverage (~150 lines)

---

## 2026-05-23 — Capture v2: split into library + GUI app + server-side capture for public release

**Chosen**: Refactor capture into three pieces that share one library, in service of a public release where hobbyists need to send bug reports without running a separate proxy tool.

1. `SwiftXCaptureCore` (existing library) becomes the single source of truth for `.xtap` file format, framing, decode/annotation, sink lifecycle, and the proxy + replay TCP machinery. A new `CaptureSink` protocol lets the server install its own per-session sink without depending on proxy code.
2. `swiftx-server` gains `--capture` (CLI flag) and a matching "Capture every client to /tmp" Preferences toggle. When on, every X client that connects writes its own `.xtap` to `/tmp/swift-x-captures/`. One client = one file. Per-session `captureQueue` separate from `protocolQueue`, 64 KB ring buffer, flush on size or 100 ms timer. Status menu gets an indicator + "Reveal Captures Folder" + "Discard All Captures."
3. A new SwiftUI app (working name `swiftx-capture`, name-conflict resolution deferred) with three modes on a launch picker: Record (proxy capture, replaces v1 CLI's default subcommand), Open (browse an existing `.xtap`), Replay (send a capture at a target server).

Capture v1's CLI keeps working through the transition for my corpus-capture scripts. The `.xtap` format is unchanged — v1 captures open in the new examiner, server-emitted captures open in the v1 CLI's `dump`. Format compatibility is the whole reason the library is the boundary.

**Why now**: A public-release user can't currently send a useful bug report. They'd need to know a separate proxy tool exists, set it up, and run their client against it. Server-side capture turns that into "toggle the checkbox, hit the bug, send the file." Plus a GUI examiner makes "what does this app do on the wire?" approachable for hobbyists who aren't going to learn CLI subcommands.

**Alternatives rejected**:

1. *Leave v1 alone and write a separate examiner GUI later.* Loses the chance to make capture genuinely useful for end users. A capture they can't send is a capture that doesn't exist for bug-report purposes.
2. *Put server-side capture in a separate daemon process the server talks to over IPC.* IPC overhead and lifecycle bugs for no benefit. The server already owns the wire bytes; teeing them in-process is the cheap path.
3. *Write captures to `~/Library/Application Support/swift-x/captures/`.* Discoverability cost is high — `~/Library` is hidden on macOS and most users don't know it exists, so files would accumulate invisibly and never get cleaned up. /tmp is shorter to type, gets wiped on reboot (self-cleaning), and a status-menu "Reveal Captures Folder" item handles the discoverability hit.
4. *Always-on capture as the default.* Privacy concern in principle (captures contain keystrokes, clipboard, window titles), but for a LAN-only hobby tool used by nerds the right default is still off — captures should be opt-in via flag or pref, so the user knows they're recording.
5. *Skip the GUI app, just ship server-side capture + the v1 CLI.* Half a solution. The CLI examiner subcommand (`dump`) is fine for me but unusable for anyone who doesn't already know the X protocol. The browser is what makes captures legible.
6. *Fork the format/decode code into the server.* Drift guaranteed within weeks. Library-as-single-source-of-truth is the reason this whole split works.

**Decisions deferred to during build**:

- *Name collision between v1's `swiftx-capture` binary and the new SwiftUI app of the same name.* Two options on the table: rename the new app `swiftx-capture-app`, or move the CLI behavior into the new app behind a `--headless` flag and retire the v1 binary. Leaning toward the second but won't decide until the SwiftUI app is real enough to know if `--headless` is awkward.
- *Ring buffer sizing (64 KB starting guess).* May want to scale by observed throughput once measured.
- *Best client-name signal for file naming.* Pick from `WM_CLASS`, `WM_NAME`, the first `CreateWindow`'s window-name property — verify which fires fastest in practice across xterm / Motif / Athena.

Full design spec: `PRODUCT_1_CAPTURE.md` § "v2: Public-ready capture."

## 2026-05-24 — Close out 2026-05-10 "Park dt-Motif widget chrome redraw"; keep current Expose model

**Decision**: the 2026-05-10 parking entry above is closed. dt-app button chrome (shadows + labels) renders correctly. The hypothesis behind the parking — "Motif's PushButton ignores our flood because it expects sparse visibility-tracked Expose like real Sun" — was wrong. We are not implementing visibility tracking at the Expose-emission layer.

**What actually closed the visible symptom** (during May 13–18 sweeps, before today):
- VisibilityNotify state derived from `borderClip ∩ interiorBox` instead of post-children `clipList` (SHORTCUTS:79, 2026-05-14). The original derivation reported container windows as `FullyObscured` — the exact signal Motif's PushButton uses to skip shadow chrome.
- `QueryTextExtents` shipped (SHORTCUTS:155, 2026-05-15). CascadeButton uses it to measure menu titles; falling through to `BadRequest` broke the chrome path.
- PolySegment pixmap path shipped (OPCODE_STATUS:83, 2026-05-17). "Heavily used by Motif PushButton for top-shadow / bottom-shadow chrome lines drawn into backing pixmaps."
- PutImage Bitmap + cross-window/pixmap CopyArea (2026-05-17).
- Retire the CDE customization daemon impersonation (DECISIONS 2026-05-18). The earlier 2026-05-10 SDT-Pixel-Set impersonation was routing Motif's foreground through a grey-on-grey palette slot, making labels invisible. Removing it left buttons rendering in plain Motif fallback colors.

**The architectural call** (informed by today's Motif-source survey, now possible because `reference/motif/` is local):
- Per-widget Expose method survey across 21 Motif widget classes (`reference/motif/lib/Xm/*.c`) shows: the dominant gates are `XtIsRealized` and `MenuShell.popped_up`, both purely client-side state we have no leverage over. Motif widgets universally declare `visible_interest = FALSE` (Label.c:488, ToggleB.c:496, Text.c:511, …all 21), so VisibilityNotify expansion gates nothing on the Motif side — only X-aware apps like xterm/xeyes would consume it.
- Xt's `XtExposeCompressMaximal` (the default for every manager — BulletinB.c:372, RowColumn.c:837, ScrollBar.c:448, List.c:824, …) accumulates our per-clip-rect Exposes into one region client-side. Our `count = n-1-i` field already drives that compression correctly. So our model is effectively single-region-per-Map even when we emit many Expose events.
- `XmeRedisplayGadgets` (`reference/motif/lib/Xm/GadgetUtil.c:132-185`) dispatches to gadgets only when our Expose region intersects each gadget's geometry. The *shape* of our rects matters but the *count* doesn't.
- We already suppress Expose for fully-covered descendants: `ServerSession.swift:2075-2089` skips when `exposeRects.isEmpty`, and `MockWindowBridge.swift:169-186` no-ops on empty.

**What NOT to add**:
- Server-side visibility-tracking suppression of Expose for partially-covered descendants. Would require a full region engine + stacking-order tracking. No surveyed Motif widget cares — they re-clip against widget geometry on receipt. Real implementation cost, no measurable widget benefit.
- VisibilityNotify tuning for Motif. Nothing subscribes.

**Optional polish items, deferred until a concrete cosmetic bug points at them**:
- Coalesce per-window Expose rects to one bounding rect before emission (wire-efficiency, since Xt accumulates client-side anyway). No correctness change.
- Suppress Expose for descendants whose Map didn't actually grow their visible region (compare pre/post clipList in `recomputeClipsForSubtreeContaining`). Matches Xsun behavior more closely without building a parallel region engine.

**Residual bug to NOT conflate with this one**: `STATUS.md:179` (2026-05-19) and `project_dt_apps_theme_pass_open.md` both flag a resize-uncover repaint gap (dthelpview buttons thinner after resize; dtpad text-area paint loss on resize). That's `ServerSession.handleConfigureWindow`'s descendant-uncover branch, not Expose architecture. Separate investigation when it gets prioritized.

## 2026-05-25 — Resize architecture: minimal-spec position, matching XQuartz consensus

**Decision**: strip the `mappedBackgroundPaints` descendant-cascade from `handleTopLevelResize`. Keep `Step 1` (top-level NW blit in `FlippedXView.resizeBacking`) as local Mac-compositor latency-hiding. Keep `paintRectsForWindow` on descendant `sizeChanged` (the xcalc fix). Keep `mappedDescendantSnapshots` Expose cascade. Add `layerContentsPlacement = .topLeft` and fix the draw-method anchor (translate by image height, not view height) so all three layers (CoreAnimation gravity, draw, blit) agree on top-left anchoring during resize. Continue advertising `backingStores = .never` and `saveUnders = false`.

**Background**: two days (2026-05-24 → 25) of stacking optimizations on the descendant resize path produced a series of regressions: dtpad menu-bar erase on dialog popup, xcalc upper-left-only buttons, quickplot SlateBlue bleed. Each was caused by some flavor of "try to preserve widget bits across pure-move." Reverting each in turn led to writing up the minimal-spec position as `RESIZE_THESIS.md` and putting it to two background agents (validation + 3-way MIT/XQuartz/us comparison).

**Why this is the right landing point** (per the 3-way comparison agent):

XQuartz has shipped this architecture for ~20 years. `RootlessNoCopyWindow` in `reference/xquartz-xserver/miext/rootless/rootlessWindow.c:635` is literally a no-op CopyWindow callback — every gravity-bucket bit-blit miSlideAndSizeWindow tries to do gets dropped on the floor. Modern xorg-server defaults to `backingStoreSupport = NotUseful` (`dix/window.c:646`) and `saveUnderSupport = NotUseful` unconditionally. The X11R6 `backingStoreSupport = Always` default was a single-framebuffer optimization that has been abandoned everywhere it stopped being economic — which is "any X server that's not single-framebuffer," which includes us.

Per-window bit preservation is economically rational only in single-framebuffer designs where preserving bits is free. We aren't in that architecture; XQuartz isn't either. The 2026-05-14 entry above already documented "skip backing-store advertise"; this entry extends that decision to the resize/move semantics across the rest of the protocol.

**Why two specific things stay** (per the validation agent):

1. **`paintRectsForWindow` on descendant `sizeChanged`** — Athena Command's `Redisplay` paints an interior highlight rectangle but NOT the X-window border. The 1-pixel CWBorderPixel ring is server-painted per the bg-paint contract. Without this call, xcalc on shrink shows "button surrounds either not there at all or only the top-left is partially rendered" — exactly the symptom observed 2026-05-25 before `25c3822` fixed it.

2. **`mappedDescendantSnapshots` Expose cascade** in `handleTopLevelResize` — Xt's `XtResizeWidget`/`XtConfigureWidget` (`reference/X11R6/xc/lib/Xt/Geometry.c:434-585`) only emit XConfigureWindow on the wire when geometry actually changes. For NorthWest-anchored top-left children that don't move on parent grow, the toolkit's per-child loop is a no-op — zero wire traffic. Without our cascade Expose, those children get no wake-up call when the top-level's bitmap was reallocated.

**Three things kept that aren't strictly minimal but defensible**:

- Step 1 NW blit in `FlippedXView.resizeBacking` — local Mac-compositor latency-hiding for the gap between AppKit's resize event and the Sun's redraw. Invisible to the X protocol. Analogous to XQuartz's `xp_window_changes.bit_gravity` plumbing (`reference/xquartz-xserver/hw/xquartz/xpr/xprFrame.c:246-262`) but in-process rather than handed to Quartz.
- `layerContentsPlacement = .topLeft` on FlippedXView — CoreAnimation backstop that matches NWG.
- `draw(_:)` anchors image to top-left via `translateBy(0, imgPointsH)` rather than `bounds.height` — fixes a pre-existing bug where the comment said "top-left anchor" but the math anchored bottom-left.

**Future enhancement (not built)**: per-resize-edge gravity in Step 1, matching XQuartz's `ResizeWeighting` (`rootlessWindow.c:765`). Currently we always pin top-left; XQuartz picks NW/NE/SE/SW based on which corner stayed pinned during the drag. Not load-bearing for any current bug.

**What stays open**:

- dtpad Gap B (text-area paint loss on resize). Predates `ef0d6eb`, not caused by preservation work, separate fix.
- dtpad menu-bar erase on dialog popup. Different code path (dialog map/unmap), unaffected by this decision.
- Horizontal scrollbar reverse-image rendering. Multi-app, pure rendering, separate.

**Code delta**: ~20 lines (the strip is much smaller than the thesis estimated because most of the optimization machinery the thesis envisioned was already not implemented — only one cascade was actually running).

---

## 2026-05-28: SHAPE extension — implement, bounding-on-top-level first

**Context**: SHAPE was committed back on 2026-05-05 (only SHAPE + BIG-REQUESTS, skip the rest). Implemented it now. oclock (round clock) and xeyes (oval, just the eyes) are the test apps — both hit the identical path: render a circle/oval into a depth-1 pixmap, then `XShapeCombineMask(..., ShapeBounding, ShapeSet)` on the top-level. (Confirmed against `reference/X11R6/xc/lib/Xmu/ShapeWidg.c` that xeyes DOES use SHAPE — an earlier `.claude-memory` note claiming it never did was wrong and was corrected.)

**Chosen**:
- **Major opcode 128, event base 64, no errors.** We advertise exactly one extension, so a fixed major opcode beats a dynamic allocator. Event base 64 = the X server's `EXTENSION_EVENT_BASE`, so ShapeNotify = 64. SHAPE defines no errors (reports core BadWindow / BadValue / BadPixmap / BadMatch). The gold SS2 captures happen to also assign SHAPE = 128, so our captured-replay tests for xcalc/xeyes now exercise the real handlers (zero XErrors).
- **Full protocol, phased visual application.** All 9 requests implemented and the region state stored/queryable. The *visual* application covers the **bounding** shape on a **top-level** only (the demoable win). Clip shape and descendant-window shape are stored but not yet applied to rendering. Rejected "protocol-only" (no payoff) and "everything visual at once" (drags clip-shape into the resize/clipList machinery for no client benefit today). See SHORTCUTS for the exit plan.
- **Mask via clipping the blit in `FlippedXView.draw(_:)`, NOT a CAShapeLayer mask.** The view is `isFlipped` and presents its backing through `draw(_:)`, so clipping there happens in the view's natural X-aligned (top-left, y-down) coordinate space — the shape rects map directly with no y-inversion. A CAShapeLayer mask would have reintroduced CALayer geometry-flip confusion (the exact class of bug `GRAPHICS_Y_FLIP.md` exists to prevent). The window is made non-opaque + clear-background so the clipped-away area shows the desktop through.
- **Shape-aware hit-test (swallow), not passthrough.** Clicks inside the NSWindow rect but outside the bounding region are dropped (no X event), matching that those pixels aren't part of the window. True click-through to windows behind was rejected as more work for no benefit on the target apps.
- **Region algebra is a faithful port of `Xext/shape.c:RegionOperate`** onto our existing `Region` engine (the 5 ops × nil/concrete destination), per the lift-don't-intellectualize rule.

**Rejected**: dynamic opcode allocation (one extension, no need); CAShapeLayer mask (y-flip risk); MIRegion-first (the existing `Region` already has union/intersect/subtract/inverse/translate — no new engine needed).

---

## 2026-05-31 -- Don't wire capture-side decoders into macxserver's live console

**Context**: A pile of new decoders landed in `SwiftXCaptureCore` (`WMProperties`, `Keysyms`, `ResourceRegistry`, full reply-body decode for 33 opcodes, ClientMessage payload decode, _MOTIF_* property decoders, type-driven property fallback). They're consumed by the capture viewer windows. The natural follow-up question: should the macxserver also use these in its live console output, since the server emits per-session log lines via `ServerSession` that currently stay terse (raw hex atom/window/keycode IDs)?

The capture viewer and server's "Open .xtap..." debug menu *already* share `ChronoDumper.dump(path:)`, so post-mortem viewing is consistent. The question is specifically about the live, running-time emissions to `/tmp/macxserver/<session>.log` (plus stderr when `--verbose`).

**Chosen**: **Don't do the wiring.** Use the `--capture` workflow when you want rich-decoded server-side wire visibility:

```
swiftx-server --capture       # tee every session to .xtap
... reproduce the bug ...
open /tmp/swift-x-captures/<instance>-<ts>.xtap
```

That gives the full benefit of today's decoders without crossing module boundaries (`SwiftXServerCore` would otherwise have to depend on `SwiftXCaptureCore`, or we'd extract a third shared module).

The server's live console serves a different purpose: human-narrated running events ("WM_CLASS identified as xterm", "copy: 84 bytes written to NSPasteboard", "BadDrawable at seq=412 from CopyArea on 'Command Window'"). Story-form, intentionally narrow. Bolting on the full chrono-dump decoder soup would duplicate the viewer's job and crowd out the narration that's the live console's reason to exist.

**One narrow follow-up that is worth doing**: populate `ResourceRegistry` on the server side so `ServerSession`'s XError landmarks pick up the `(freed at seq=Y, created at seq=X)` use-after-free annotation that the capture viewer already gets. That's the one decode-class that fits the live console's narrative style and matters for server debugging. Bounded (~30 min) and uses the same code we already use capture-side. Skipped on 2026-05-31 to keep scope tight; recorded here so next session can pick it up.

**Rejected**:
- **Wholesale `--verbose` decoded output in the live console** -- crowds the narration, blurs the live console's purpose vs the viewer's.
- **Extract decoders into a third shared module** -- premature; the two consumption modes are distinct enough that sharing would force compromises on both sides.
- **Have the server emit chrono-dump-style structured lines** -- that's literally what `--capture` already produces.

---

## 2026-06-09 — Emulate hardware pointer grab via NSWindow.isMovable + chrome-click synthesis

Real X11 pointer grabs are server-wide and hardware-rooted: when a Motif menu shell holds a grab, the WM's title-bar widget never receives a click. Our rootless server can't reach that layer — Mac AppKit owns the title bar independently of the X event pipeline — so we have to emulate the property "window is unmovable while an X grab is active" in software.

**Chosen**: A ref-counted lock on `WindowBridge` (`lockNativeWindowDrag(token:)` / `unlockNativeWindowDrag(token:)`) that sets `NSWindow.isMovable=false` on every session window and toggles a `MotifFrameView.isDragLocked` flag that short-circuits the chrome's `mouseDown` before drag state is seeded. Called from every `pointerGrab` transition in `ServerSession` (passive activation, implicit grab install/release, explicit `XGrabPointer`, `XUngrabPointer`). On session disconnect, `removeHandlers(token:)` drops the token's contribution so a mid-grab disconnect doesn't strand any window non-movable.

Layered on top: a chrome click during a grab fires a synthetic ButtonPress + ButtonRelease pair to the X client at clientView-local coords (negative — well outside the popup geometry, so Motif's outside-popup detector dismisses), and `CocoaWindowBridge.releaseNativeWindowDragImmediate()` tears down the lock and the cross-window drag tracker locally without waiting for the client's `XUngrabPointer` round-trip. `MotifFrameView` then seeds `dragOrigin` so the user's continuing `mouseDragged` events in the same physical gesture move the window. Net UX: click-and-drag the title bar with a menu up → menu dismisses AND window moves, atomic.

**Alternatives considered**:

1. **XQuartz's path: kernel-private `xp_*` APIs to intercept pointer events below AppKit.** That's how XQuartz's title bars (drawn by quartz-wm via `xp_frame_*`) flow clicks through the X event pipeline naturally — the grab steals title-bar clicks like it would any other window. We can't use these APIs from a regular Swift AppKit app; they require XQuartz's pre-existing kernel-extension pipeline (see `.claude-memory/reference_xquartz_drag_routing.md`).

2. **Match real X11 exactly: two-click pattern.** First click dismisses, second click drags. Strict spec-faithful, no surprises, smaller code. Rejected because Mac users expect click-and-drag to be a single atomic gesture; the X11 idiom is the wrong cultural default on macOS.

3. **Don't lock; let the user drag and re-emit a catch-up synthetic ConfigureNotify on grab release.** Tried this mentally — relies on the client processing queued events correctly post-grab, which the bug symptoms suggested isn't guaranteed (Motif's per-pulldown coord cache snapshots root coords at popup-post time and re-keys on synthetic ConfigureNotify only at known dispatch points). The lock-the-drag approach prevents the corruption entirely, so we don't need to reason about Motif's internals.

4. **Lock per-session only** (only this session's windows go non-movable when this session grabs). Closer to "session scope" but diverges from real X11's server-wide grab semantics. Bridge-wide lock (all session windows lock when any session has a grab) matches X11 behavior and was no harder to implement.

**Why this won**:

- Prevents the corruption at the trigger layer instead of trying to repair the downstream cache state. No speculation about Motif's internal event-queue dispatch order.
- Real X11 facsimile is good enough: a user who drags during a menu wouldn't be allowed to in real X11 either, and the synthesized chrome click + drag-origin seed makes the "click to dismiss" half feel atomic on Mac.
- Falls out cleanly along existing seams: `WindowBridge` protocol extension, per-session token already exists (`bridgeHandlerToken`), `MotifFrameView` already has handler-callback wiring for `pointerMovedHandler`.
- Companion one-line spec-compliance fix in `handleGrabPointer` (`implicitGrab = false`) was the actual root cause for the original bug; the lock layer is defense-in-depth + UX. Both keep their own correctness story.

**Cost / scope flagged**:

- Native title-bar windows (Motif Frame OFF) only get the `isMovable=false` layer — title-bar clicks during a grab do nothing visible. Closing that gap needs an `NSEvent` local monitor filtering hit-tested areas. Acceptable trade for now since Motif Frame is the dominant path for the apps that exercise menubar grabs.
- Multi-session lock contributions sum (bridge-wide); single chrome-click `releaseNativeWindowDragImmediate` clears all of them at once. Edge case: if two sessions independently hold grabs and the user dismisses one via chrome click, the other session's lock contribution goes too. Acceptable — when the other session's `XUngrabPointer` arrives, its matched `unlock` call hits empty state and no-ops; if it issues another grab afterward, the lock re-installs normally.

See `.claude-memory/reference_implicit_grab_replaced_by_explicit.md` for the spec-semantics gotcha that made this bug class possible.

---

## 2026-06-11 — Logical root size is screen-derived, not the gate preset

The display picker (`DisplayConfig.pick`) used to return both the integer scale AND a fixed logical-root size from a preset table (1280×900 on a 5K, etc.). That size became the screen the X clients see. **Chosen instead**: keep using the preset table only to *gate* which integer scale we pick, then derive the logical root from the actual panel as `floor(native ÷ scale)`. Touches the preset-table contract in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`, so taken as an explicit decision.

**Why**: macXserver is rootless — each X window is its own NSWindow, and a window's X-root position is computed `NSWindowPoints × backingScale ÷ scale`, so the *whole* panel spans `native ÷ scale` X-root units. Advertising the smaller preset size left an L-shaped dead strip on the right/bottom of the display (a 1280×900 root on a 5K covers only ~1920×1350 of the 2560×1440-point screen). A window dragged into that strip reported an X-root x past the advertised screen width; clients that clamp popup menus to the screen edge (xterm's Ctrl-button menus, Motif pulldowns) then pinned the menu to the *advertised* right edge while the window sat physically further out. Net symptom: menus drift off their window, worse the further you drag — diagnosed from an in-process-tee capture where the post-move ButtonPress `root=(1558,511)` was correct but xterm placed the menu at `1141 ≈ 1280−137(menuWidth)`, i.e. clamped to the 1280 root. The same mismatch would mis-feed root `GetGeometry`, maximize math, and pointer queries.

**Alternatives considered**:

1. **Keep 1280×900, clamp windows to the X-root rectangle.** Smaller change, preserves the Sun-authentic literal screen size. Rejected as a partial fix: a wide window straddling the edge can still put the *pointer* past the advertised width (the click lands in the dead strip), so menus still clamp. The only fully consistent options are "root covers the panel" or "confine the pointer to a sub-rect," and we can't confine the macOS cursor without fighting other Mac apps.

2. **Per-axis (non-uniform) scale to map the panel onto exactly 1280×900.** Rejected outright — non-uniform scaling distorts pixels (circles → ellipses), unacceptable for a graphics server.

**Why this won**: the advertised screen and the draggable area become the same rectangle, so every screen-size-dependent client behavior lines up. The integer scale the picker chooses is **unchanged** for every display (verified: same scale outputs in `DisplayConfigTests`), so font cell-sizing — which keys off scale + pointSize, not the root's total dimensions — is untouched. The "Sun-authentic small screen" goal is preserved by the scale gate (it keeps the derived logical screen in ~1000–1700-wide territory rather than Retina-dense pixel counts), just not as a hardcoded literal. Cost: the app-facing screen is now an odd size like 1706×960 instead of a round 1280×900; acceptable, X clients don't care about round numbers.

---

## 2026-06-12 — SSH launcher: no X11 forwarding, keys-only auth

The telnet launcher (shipped 2026-05-27) covers vintage Sun boxes that don't have sshd. To extend the menu to modern Linux/BSD/Solaris hosts, added a second transport `transport = ssh` on the launcher-file host block. Two design choices worth pinning so we don't relitigate.

**Chosen**: spawn `/usr/bin/ssh` with `-T -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15`, pass a wrapped remote command that sets `DISPLAY=mac.local:0; nohup CMD &` (same shape as the telnet path), and let the X client open a direct TCP connection back to our server on 6000. No `-X`/`-Y` X11 forwarding. Keys-only — no password injection, no Keychain prompt; a password field on an ssh entry is parsed but ignored with a load-time warning.

**Alternatives considered**:

1. **`ssh -X` (X11 forwarding) instead of direct-DISPLAY.** Encrypted X traffic, automatic xauth cookie, sets `DISPLAY=localhost:10.0` on the remote. Rejected: requires `X11Forwarding yes` in remote sshd (often firewalled by default on minimal Linux installs), adds an xauth wrinkle on the Mac side (we currently don't publish a cookie, so ssh would warn or need a stub `xauth add`), and the encryption gain is irrelevant on the LAN this is used on. The direct-DISPLAY path reuses every piece of plumbing the telnet flow already has — the only diff is which binary we spawn.

2. **Password injection via `sshpass` or a PTY-driven expect loop.** Would give parity with the telnet password/Keychain UX. Rejected as scope creep: keys are the normal Linux convention, `sshpass` is a separate Homebrew dep we'd have to detect or bundle, and the PTY path duplicates most of TelnetLauncher's state-machine complexity for marginal gain. `BatchMode=yes` makes ssh fail fast instead of hanging if keys aren't set up, so the failure mode is clean.

3. **One launcher type with a per-block `auth = keys|password` knob.** Rejected: muddles the two transports' very different auth stories. `transport = ssh` already implies keys (BatchMode is on); `transport = telnet` already implies the password flow.

**Why this won**: zero new user-side state (no xauth, no remote sshd config, no extra deps), small code surface (one new `SSHLauncher` plus a `RemoteLauncher` protocol shared with `TelnetLauncher`), and the X11 wire path is identical to telnet — so any visual bug reproducible over ssh is also reproducible over telnet, no new debug axis.

**Cost / scope flagged**:

- Remote sshd must allow the wrapped command's outbound TCP to our 6000. On a tightly firewalled host this fails silently from the client's perspective (ssh exits 0, app never appears). Acceptable: same failure mode as telnet, and the verbose progress window shows what we ran.
- If a user really does want encrypted X traffic, the answer is to add an `X11Forwarding=yes` option later, not to flip the default — keep the simple direct-DISPLAY path as the documented baseline.

---

## 2026-06-13 — Honor vintage X client size hints, no Mac-style UX floor

When WM_NORMAL_HINTS arrived for server-side application (2026-06-13), the question came up: vintage X clients commonly declare microscopic or zero minimum sizes. xterm publishes `min=10×17` X pixels (one character cell plus chrome). Sun-era dtpad publishes `flags=PMinSize|PResizeInc|PBaseSize` with every value as `0×0` — literally an empty WM_SIZE_HINTS struct with the bits flipped. Same shape across most of the vintage corpus.

**Chosen**: honor what the client declares, period. `NSWindow.contentMinSize` is set to the spec-correct value (decoded `min_width` / `min_height` plus Motif chrome padding); we don't impose a Mac-style minimum floor on top.

**Alternatives considered**:

1. **Bridge-side policy floor** (`max(declaredMin, 360×220)` X pixels, or similar). Would make vintage X windows feel more "Mac-y" — you couldn't accidentally shrink dtpad to a square millimeter. Rejected: a legitimately small floating panel (a color picker, an xfontsel-style chooser, the kind of tools palette quickplot might pop) wants to be that small, and a hardcoded floor over-enforces. Linux WMs (fvwm, twm, mwm) don't do this; they trust the client. Macxserver's charter is "vintage X clients on Mac," not "Mac-feeling clients" — fidelity to what the client asked for is more important than averting an unlikely user accident.

2. **Per-app-class policy floor** driven by WM_CLASS. Larger floor for `dtpad` and `xterm`, no floor for small panels. Rejected as premature config: nobody has actually been bitten by the no-floor behavior yet (Todd tried it deliberately and decided to accept it); building a config layer for the imagined complaint adds maintenance with no proven demand.

**Why this won**: the spec-correct path is also the simplest. The hint pipeline does exactly what ICCCM 4.1.2.3 says to do; clients that want a meaningful minimum can declare one (quickplot's plot window declares `PAspect` and the aspect constraint is verified working on the Studio Display 2026-06-13, which is the concrete evidence the pipeline functions); clients that don't get the freedom to shrink small. The "user accidentally shrinks dtpad to a sliver" scenario is real but reversible — drag the corner back out — so it doesn't justify trading away spec correctness for it.

**Cost flagged**: Mac users new to vintage X may be surprised that dtpad / xterm / dtterm have no enforced minimum. The README / first-launch docs should mention this expectation gap if it surfaces in user feedback. Until then, accept and watch.

---

## 2026-06-13 — Switch advertised visual from PseudoColor 8-bit to TrueColor 24-bit (supersedes 2026-05-05)

The 2026-05-05 entry chose PseudoColor 8-bit "for Sun-era authenticity." On 2026-06-13 we revisited the question after the WM-proxy contract pass surfaced (a) the "wacky colors on capture replay" pain Todd had been seeing, and (b) the realization that the SSH launcher (2026-06-12) opens a real path for modern Linux X clients that explicitly require TrueColor at window create.

**Chosen**: advertise a single TrueColor 24-bit visual (RGB888, masks `red=0x00FF0000 / green=0x0000FF00 / blue=0x000000FF`), drop PseudoColor entirely. `whitePixel=0x00FFFFFF`, `blackPixel=0x00000000` (the canonical Linux values).

**Why this won — the costs of keeping PseudoColor**:

1. **Replay-color fidelity.** Captured Sun sessions reference 8-bit pixel cookies from the original server's colormap. On replay, our PseudoColor allocator returned different cell numbers for the same RGBs, so subsequent captured `CreateGC(foreground=N)` references resolved to whatever some *other* client's earlier AllocColor happened to put at cell N. The "wacky colors" symptom. Fixing this in PseudoColor needs a per-replay pixel-remap table; TrueColor sidesteps it (pixel value IS the RGB).

2. **GetImage fidelity.** Our PseudoColor GetImage reverse-mapped 32-bit ARGB backing back to 8-bit pixel via `ColorTable.pixel(for:)`. AA glyph edges and any RGB not in the table returned pixel 0. xwd / xmag / screen-capture clients saw text with white-fringed edges. TrueColor: lossless direct pack.

3. **AllocColor ceiling / leak.** PseudoColor has a 256-cell limit. We were running with no cell cap (SHORTCUTS open item) so long-running sessions leaked. Fixing the cap would have meant cells-exhausted failures we don't currently hit. TrueColor: degenerate alloc, no ceiling, FreeColors becomes legitimately no-op.

4. **Modern Linux apps via SSH launcher.** Firefox / GTK / Qt all explicitly request TrueColor at `CreateWindow`. Under our PseudoColor visual they'd either fail with "no matching visual," downgrade to PseudoColor mode and render badly, or refuse to map. With the SSH launcher we shipped 2026-06-12, the door is open for these clients; the visual needed to follow.

5. **InstallColormap / UninstallColormap / ListInstalledColormaps** were on the "we should eventually implement" list under PseudoColor (color-flash territory). Under TrueColor they're effectively no-ops forever — one less open area to keep on the list.

**Cost paid**:

- Color-cycling apps (xcolorize, xmorph, screensaver hack collection) require PseudoColor's writable cells + StoreColors. They no longer work. None are in the charter daily-flow corpus. If one ever surfaces, we could add a PseudoColor compatibility visual back — but YAGNI today.
- Some real X servers offered BOTH visuals (PseudoColor for legacy apps, TrueColor as default). We chose single-visual for simplicity; the diff is "one drawing path instead of two" everywhere.
- Existing capture corpus was thought to need re-recording. Todd's audit corrected that — `CapturedAppReplayTests` only verifies dispatch + resource counts (not rendered output), so the captures stayed valid and all 1284 tests pass post-switch with zero corpus changes.

**Vintage Sun apps in the daily charter flow** (xterm, xcalc, xclock, xeyes, oclock, quickplot, dtcalc, dtterm, dthelpview, dtpad, dticon, the Athena/Motif/Xt widget set generally) use `DefaultVisual` and `AllocColor`. They render identically on TrueColor — the API is the same, the pixel value is opaque to them, the resulting RGB at draw time matches. Verified by `swift test` (1284 green, 27 skipped) and to be verified by live smoke test after the switch ships.

**Alternatives considered**:

1. **Dual-visual (PseudoColor + TrueColor, default = TrueColor).** Defers the cleanup; doubles the maintenance burden (two drawing paths, two GetImage / PutImage layouts). The vintage-app compat case for PseudoColor turned out empty — nothing in the corpus required it. Rejected.

2. **TrueColor with a PseudoColor compatibility shim accessed via explicit `XMatchVisualInfo(... 8 PseudoColor ...)`.** Same maintenance cost as dual-visual for a zero-app benefit. Rejected.

3. **Keep PseudoColor, add per-replay pixel-remap table.** Solves the replay-color pain but leaves the GetImage fidelity issue, the AllocColor ceiling question, and the modern-Linux-app blocker. Bigger maintenance burden for a smaller win. Rejected.

The 2026-05-05 "Sun-era authenticity" argument doesn't survive scrutiny — vintage apps don't *require* PseudoColor, they just got it because that's what the hardware supported. Authenticity at the cost of functionality is the wrong trade for a charter that's about running those apps comfortably on a Mac.

---

## 2026-06-13 — WM_TRANSIENT_FOR uses z-order maintenance, NOT NSWindow.addChildWindow

When the X client sets WM_TRANSIENT_FOR on a top-level (Motif XmDialogShell does this on every dialog), we need to keep that window visually above its parent regardless of focus. The obvious Mac primitive is `NSWindow.addChildWindow(child, ordered: .above)`. We tried it first (commit `7d95474`), then reverted to a manual z-order approach (commit TODO).

**Chosen**: maintain a per-bridge `transientForParent` map on the slot table. On every `windowDidBecomeKey` of the parent, walk the table and call `child.order(.above, relativeTo: parent.windowNumber)` for each transient. Same on the initial WM_TRANSIENT_FOR property change.

**Why we did NOT use addChildWindow** (this is the divergence-from-Mac-convention choice that this entry exists to document):

`NSWindow.addChildWindow` is a tight Mac primitive that does FIVE things at once:

1. Keeps child above parent in z-order
2. Couples child position — child moves with parent
3. Carries child through Spaces with parent
4. Minimizes child when parent minimizes
5. Closes child when parent closes

For Mac-native apps that's the right bundle (Xcode's document window + inspector panels behave this way and it feels natural). For X clients ported to Mac via macXserver it breaks (2) in a way that creates a real user-trap:

> A modeless transient dialog can land on top of a button on its parent
> window. On Sun mwm the user slides the parent out from under the
> dialog independently to reach the button. With addChildWindow, the
> parent can't be moved without the dialog coming along — the button
> stays covered forever.

Verified user-visible with quickplot 2026-06-13: About dialog covering a Command Window button. Sun mwm lets the user move Command Window independently to access the button. Our addChildWindow implementation didn't, and Todd called this out as a problem.

**Alternatives considered**:

1. **`addChildWindow` + observe `windowDidMove` on the parent to snap the child back to its pre-move screen frame.** Hybrid approach. Rejected: flicker-prone (every drag tick fires the notification), fights AppKit's positioning, and the snap-back is racy with `setFrame` calls that AppKit makes mid-drag.

2. **Use `NSWindow.level = .floating`** to put the transient above everything. Rejected: that puts it above every Mac app's windows too (other macXserver clients, the user's editor, etc.), not just above its X parent. Wrong scope.

3. **Mac collectionBehavior with `.transient`.** Rejected: doesn't enforce z-order on focus changes; just tags the window for special Spaces handling. Doesn't solve the actual symptom.

**Why this won**: the manual z-order maintenance gives us exactly what Sun mwm gives — child stays above parent regardless of focus, child is independently positionable — at the cost of losing the Mac coupling for Spaces, minimize, and follow-on-move. The project charter is "vintage X clients on Mac with proper modern rendering"; **vintage X behavior fidelity wins over Mac UX coupling** when they conflict, per the original project shape decision (2026-05-05 entry).

**Cost flagged**:

- Transient dialogs DON'T follow their parent through Spaces. If the user drags the parent main window to a different Space, the transient stays in the original Space. That's the Sun behavior (Sun didn't have Spaces) but a Mac user might be surprised.
- Transient dialogs DON'T minimize with the parent. Minimizing the parent leaves the dialog as a floating window with no obvious owner. On Sun this didn't matter because there was no minimize-to-Dock concept; on Mac it might feel wrong.
- Transient dialogs DON'T close with the parent. If the parent is closed via the WM (red Mac button → WM_DELETE_WINDOW → client unmaps the parent and its descendants), the transient closes when the client itself decides to close it — typically immediately, since the client knows the parent went away. So this gap is usually invisible.

The Spaces and minimize gaps could be closed by adding NSWindow observers that mirror those specific operations onto transients, WITHOUT taking on position coupling. Punted until a user actually complains.

The implementation lives at `CocoaWindowBridge.applyTransientForOnMain` / `restoreTransientsAbove` / the hook in `handleNSWindowFocusChange`. The 4 dispatch tests in `WMTransientForTests` exercise the wire path; the live z-order behavior is verified manually on a real quickplot session.

---

## 2026-06-16: SPARCplug — engine bundled in the app, QEMU source in a separate repo

**Chosen**: Ship the bundled SPARCstation as one notarized `MacXServer.app`. The QEMU engine (`qemu-system-sparc` + glib dylibs) lives *inside* the app as a nested helper executable, spawned as a subprocess. The QEMU source lives in its own standalone private repo, `github.com:toddvernon/SPARCplug` (vendored qemu-9.2.4, not a fork). Only the Solaris disk image is downloaded on demand into Application Support; the engine is always present. Full detail and the licensing posture are in `SPARCSTATION_PLUGIN.md` (the 2026-06-16 sections).

**Alternatives considered**:

1. **Engine in the downloadable plugin** (the original `SPARCSTATION_PLUGIN.md` plan): a self-contained `SPARCstation.macxplugin` bundle carrying the qemu binary + dylibs + image, fetched on demand.
2. **One fused binary**: link QEMU into the macXserver process so there's a single executable.
3. **SPARCplug source merged into the macXserver repo** (one repo for everything, since the product ships together).
4. **A `.pkg` installer** instead of drag-to-Applications.

**Why this won**:

- **Code-vs-data is the right seam.** The only genuinely hard packaging problem is trusting a downloaded *executable* (Developer ID signing, notarization, JIT entitlements, hardened-runtime load checks, the no-sandbox constraint). Putting the engine in the app folds all of that into the app notarization we already run, and leaves the on-demand payload as pure *data* (no signing, no quarantine xattr via NSURLSession, no Gatekeeper prompt). The cost of coupling the engine to the app release cadence is near-zero because QEMU's sun4m emulation is frozen.
- **Subprocess, not fused.** QEMU owns its own main loop, threads, signals, and process exit; fusing would mean two event loops fighting, would spread the JIT entitlement to the whole app and gut its hardened-runtime posture, and would couple crashes. They communicate over sockets anyway (X over slirp). The subprocess boundary also keeps the GPL clean: mere aggregation, so macXserver does not become GPL (it would be murky if fused).
- **Separate repo.** macXserver is public and lean; SPARCplug is private and vendors 163 MB of GPLv2 QEMU. Merging would force that source public and bloat every macXserver clone forever, for a benefit (independent release) we don't need now that the engine ships with the app. The build only needs the engine *artifact*, not QEMU's source, so we couple at the build output, not the source tree. (Precedent: macXcapture co-habits the repo fine, but it's small first-party same-license code; the GPL bulk is what makes SPARCplug different.)
- **No installer.** Drag-to-Applications survives because the engine rides in the app and the image lands in user-writable Application Support with no privileged files. A `.pkg` would add a separate Developer ID Installer cert and its own notarization for zero benefit. (One rule: read/write the image by absolute Application Support path, never relative to the bundle, so app-translocation can't hide it.)

---

## 2026-06-17: Helios access — Sun-side agent on a port; NFS/NAS deprecated

**Chosen**: Helios reaches the guest through a single **Sun-side guest agent** that listens on a TCP port (reached from the Mac via slirp `hostfwd`) and proxies two things: command execution (fork/exec, returns stdout/stderr/exit code) and filesystem access (read/write/list/stat/search on the Sun's local disk). The serial console stays as a **secondary mix-in** for boot/recovery (single-user, `fsck`), human observation, and interactive prompts. The primary target is SPARCplug (the bundled emulator); the same port protocol generalizes to a real Sun over its real network. This **deprecates** the NFS/NAS file plane and the terminal-fd command channel that earlier Helios drafts assumed. Full model in `Helios-Mission.md`; the superseded NFS design is fenced off in `SPARCSTATION_PLUGIN.md`.

**Alternatives considered**:

1. **NFS/NAS file plane** (the prior `Helios-Mission.md` design): the Mac runs `nfsd`, the Sun mounts it over slirp, files are shared bytes; commands submitted by writing to the terminal fd.
2. **SSH into the guest**: run `sshd` on Solaris 2.6 and drive it over ssh exec.
3. **Terminal puppeteering**: drive everything through the serial console (and therefore a full terminal emulator).

**Why this won**:

- **Self-contained appliance, zero NFS overhang.** No `nfsd`/`/etc/exports`/portmapper-port-pinning/uid-squashing/`nolock` workarounds. The reachability is one slirp `hostfwd` line. NFS was a large infrastructure lift for a product whose whole pitch is "open the app, it works."
- **Total filesystem visibility for free.** The agent runs *on* the Sun, so it reads and writes any local path. The entire "Option A/B/C boot-architecture spectrum" and the Option-B blind-spot workarounds (symlink logs into NFS, snapshot `/etc`, etc.) simply vanish.
- **Clean structured results.** `fork`/`exec`/`waitpid` hands back stdout, stderr, and the real exit code directly — no escape codes, no 80-column wrapping, and none of the `cmd > out 2>&1; echo $? > status`-over-NFS dance (that was an NFS-era workaround).
- **It generalizes.** The same port protocol reaches a real bare-metal Sun over its own network later; the design isn't welded to the emulator, even though SPARCplug is where it starts.
- **The console keeps the jobs it's uniquely good at.** Boot/recovery before the agent is up (you can't run a guest agent to `fsck` the disk the agent lives on), human observation, and interactive prompts. A corollary: a full VT100 terminal *emulator* is not on the Helios critical path — Helios routes commands through the agent and full-screen observation through the X-side framebuffer (Phase 2), so the console can stay a glass TTY.
- **Not SSH**: Solaris 2.6's `sshd` is ancient (weak ciphers, heavy to configure into the image) and still only gives a terminal channel — we'd build a structured file+exec protocol on top of it anyway. A purpose-built agent is smaller, period-correct (plain C + BSD sockets), and exposes exactly the two primitives the loop needs.
- **Not terminal puppeteering**: screen-scraping a serial line is fragile (escape codes, wrapping, races) and forces a terminal emulator we otherwise don't need.

**Trade accepted**: we lose "Mac-side ripgrep/git over a shared mount." Mitigated — Claude's edit logic still runs Mac-side (read through the agent, edit in the harness, write back through the agent; only the bytes cross the port), and search runs through the agent (grep/find on the Sun, or pull-and-search on the Mac). Todd's call: a really capable agent on a port beats the NFS overhang.

---

## 2026-06-20 — Console is observation-only; control moves to the agent (or ssh), drop console auto-login

**Decision**: macXserver must stop using the serial console as a *control*
channel. Today `QemuEngine` scrapes the console for `login:`, types `root`,
and later drives graceful shutdown by writing `init 5` into that console root
shell. That is the observation plane doing control's job. Control — starting
with graceful shutdown — moves to a real channel: **ssh key now** (available
as of today), and the **Helios guest agent on its port** as the end state.
The console auto-login gets dropped; the observation window then shows the
real `login:` prompt as the glass-TTY it's meant to be.

**Trigger**: setting a root password on the guest (for ssh, before key auth
existed) broke the console auto-login — it sends `root` with no password step
— and therefore the console-driven `init 5` shutdown too. That's a symptom,
not the disease: console-scraping is fragile against prompts, locale, boot
races, and now passwords.

**Why this won**:
- It's already the architecture. Helios-Mission.md: console = observation
  glass-TTY, agent on a port = control plane. Auto-login was always a
  workaround pulling control back into the console.
- Decouples macXserver from the image's password policy entirely — macXserver
  never authenticates at the console, so passwordless-vs-password becomes a
  pure guest concern.
- Removes a class of brittleness (every console prompt/locale/timing change
  is a potential auto-login break).

**Migration (in order)**:
1. *Interim (now)*: keep the shipped image's root console **passwordless** as
   a deliberate appliance posture (local VM, network root login already off
   via `CONSOLE`, remote access key-only). Don't set per-image root passwords.
2. Move graceful shutdown off console-scraping onto **ssh key** (works today).
3. *End state*: shutdown + control via the **Helios agent**; drop the console
   auto-login code. See PLUGIN_V1_PUNCHLIST (L3) — same direction as moving
   console+control onto unix sockets.

**Trade accepted**: an ssh-shutdown path needs a macXserver-owned keypair
provisioned into the image; a baked private key in the app is a mild smell
(low risk for a localhost-only appliance). The agent path removes even that,
so ssh-shutdown is the bridge, not the destination. Until control is off the
console, passwordless root console is the shipped posture.

---

## 2026-06-20: Helios mission refinement -- control-first, daemon-as-mechanism (Mac-first), Claude Code + MCP (not an in-app loop)

**Context**: The 2026-06-17 access-model decision (Sun-side agent on a port) stands. What changed is everything *around* it, driven by the SPARCplug control holes we hit on 06-19/20 (the orphan/lock/shutdown work), which postdate the original `Helios-Mission.md` (06-16). Three linked decisions:

**1. Priorities inverted to control-first.** The guest agent's first job is to plug macXserver's *control* gaps -- graceful shutdown (the dead telnet path and the console-scrape `init 5` both retire onto a daemon `shutdown` verb that also works on an orphan), a real liveness signal (replaces console `login:`-scraping), orphan recovery, and the image-repair GUI -- not the agentic-coding hello-world loop. The earlier doc made the agentic MVP "Phase 0"; that is now Phase C. The **SPARCplug release is parked behind having the control plane in place** (Todd, 06-20: want agent capability before a release).

**2. The daemon is pure mechanism, built Mac-first.** One daemon (exec + file + liveness), knowing nothing about control policy or LLMs; both the control plane and the agentic loop are *clients* over it. Because it is plain POSIX C++ on cx (cross-platform), the daemon + its test suite are built and proven **on the Mac** (localhost, no qemu), and Solaris becomes a *validation* step, not a dev environment. Extends the project's dev/deploy parity to: dev on Mac -> validate on emulator -> deploy on iron, same code.

**3. The agentic client is Claude Code + a SPARCplug MCP server, NOT an in-app loop.** We expose the daemon verbs through an MCP server (a CLI shim is the smaller intermediate form) and let the **Claude Code app (or Claude Desktop)** drive it. We build the bridge; Claude Code's mature agent loop is the workbench. This **supersedes** the "promote-to-AI" split-window chat + Anthropic-loop-inside-macXserver from earlier drafts. That in-app chat demotes to a possible later feature for end-users who don't run Claude Code; the deterministic repair GUI already covers most of their needs.

**Alternatives considered**:

1. *Keep the agentic MVP as Phase 0* (original doc). Rejected: the control holes are more urgent, lower-risk, and gate the release; and building control first builds the agentic substrate for free.
2. *Build the Anthropic loop + chat UI inside macXserver* (original "Workbench"). Rejected: far more code to write and maintain, and it would be strictly less capable than Claude Code, which Todd already uses daily.

**Why this won**:
- **Less code, more capability.** Claude Code's loop beats anything we'd build; macXserver's job shrinks to lifecycle + deterministic control + repair GUI + shipping the daemon.
- **One daemon, two clients, clean layering.** Control and agentic use cases share the exact verb set; the daemon stays policy-free.
- **Same MCP server reaches emulated and real Suns**, so Claude Code is the constant operator across all three deploy rungs.
- **Cheap self-hosting bootstrap.** Once the bridge exposes run_command + file ops, Claude Code does the Solaris-side grind itself (validate cx, fix configs). This week's image-lock + auto-backup + control verbs are the safety floor that makes letting the agent mutate the real image sane.

**Trade accepted**: an MCP/CLI bridge is a new (small) artifact to build and version, and the agentic experience requires the user to have Claude Code/Desktop. For Todd's own use and for proving the thesis that is exactly right; the in-app chat remains available later as the no-Claude-Code fallback. Full model in `Helios-Mission.md` (rewritten 2026-06-20). Protocol/codec specifics (newline-JSON + base64 content, cx json fix `75b8304`) noted there and in the cx repo.

---

## 2026-06-21: Helios access topology -- peer clients, not a hub; macXserver owns the path, not the protocol

**Context**: With all 8 daemon verbs validated on the real 2.6 image and a Mac-side CLI bridge working, the topology question got concrete: when Claude Code drives the guest, does it route *through* macXserver, or straight to the daemon? This pins down the "one mechanism, two clients" shape from 2026-06-20.

**Decision**: macXserver and Claude Code are **co-equal clients of the one daemon**, each opening its own connection. Neither proxies the other. macXserver owns the **network path** to the emulator's daemon (its qemu adds `hostfwd=tcp::2125-:2125`, C2) and **discovery** (it advertises the port + liveness), but it **never brokers the protocol** -- Claude's MCP server connects directly to `localhost:2125` (the ssh `-L` tunnel used during bring-up was a stopgap until the hostfwd lands). macXserver-as-a-client (Swift `HeliosClient`, C1) covers liveness, graceful shutdown, the launcher-over-Helios transport (C7), and the guided-admin GUI (C6).

**Consequence -- guided sysadmin surface (expands C6)**: because the daemon exposes pure mechanism (`run_command` + file verbs), macXserver can offer *curated, deterministic recipes* for common Solaris admin tasks as Settings dialogs -- set up DNS, add a user, set timezone/hostname, NFS shares -- so a novice does them without knowing Solaris. Two styles: **tool-driven** where a Solaris tool exists (add-user = `useradd`/`passwd` via `run_command`, let the OS keep passwd/shadow/group consistent -- never hand-edit `/etc/passwd`), and **template-driven validated file edits** otherwise (DNS = read/transform/write `/etc/resolv.conf` + the `hosts: files dns` line in `/etc/nsswitch.conf`). Rules: validate against known templates, never guess, **snapshot the image first** (the image-lock + auto-backup floor), idempotent + reversible, and **no LLM in the dialog path** (these are frozen recipes; the agent is for open-ended work). Nice pipeline: the agent works out a tricky task once on the real image, the validated sequence then *hardens* into a macXserver dialog.

**Alternatives considered**:
1. *macXserver as the hub* -- Claude routes through macXserver, which brokers to the daemon. Tempting for the emulator because macXserver owns the qemu process and port-forward. Rejected.

**Why this won**:
- **The real-Sun case breaks the hub.** Displaying X apps from actual vintage Suns is the whole project; that box's daemon is on the LAN and macXserver isn't hosting it. Peer-model is the only one architecture that works across emulator *and* iron -- the deploy-parity line is load-bearing.
- **Keeps the GUI out of the agentic hot path.** A build/fix loop is potentially thousands of verb calls; routing them through macXserver's event loop adds a hop and couples agent throughput to GUI-app health for zero gain. The daemon's fork-per-connection + stateless verbs already serialize cleanly.
- **Different concerns, different cadence.** Lifecycle (macXserver) and the inner dev loop (Claude) shouldn't entangle.

**Trade accepted**: two genuine coordination seams stay, handled as thin side-channels, never as a proxy. (1) *Discovery* -- Claude needs the port; macXserver advertises it (a small local file/endpoint) rather than Claude hardcoding 2125 (matters once there are two guests). (2) *VM-up dependency* -- a down box gives Claude `ConnectionRefused`; v1 assumes the user has macXserver up with the VM running, and "agent asks macXserver to boot it" is a later thin coordination, not a data path. I/O contention on the shared box (a user's xterm launch vs. the agent's `make`) is just normal multi-user Unix.

---

## 2026-06-20: Control-plane floor/ceiling -- Helios is the zero-config floor, ssh is the opt-in ceiling

**Context**: We have several ways to reach the guest (Helios daemon, ssh, telnet, console), and OpenSSH now runs on the 2.6 image (06-20). The temptation is to lean on ssh for the agentic loop since it's the richer channel (PTY, streaming, interactive `dbx`). The constraint that settles the matter is the audience and the product promise: this has to "just work" for people reliving their Sun days, many of them older, who find ssh key setup a mess until it clicks. ssh keys on the critical path at first launch would lose exactly the users we're building for. So the multiple control planes get assigned by how much the user must configure, not by which is technically richest.

**Chosen -- a floor/ceiling rule with three parts**:

1. **Helios is the floor: the zero-config default, and the critical path may never depend on anything else.** The daemon is baked into the image, autostarts, and listens on a known hostfwd port with no key, no password, no setup. Everything customer-facing rides it: liveness/readiness detection, graceful shutdown, the image-repair GUI, and the default launcher transport. Because the daemon *is* the "it just works" promise, its unglamorous bring-up (rc seed script, autostart, liveness) is product-critical plumbing, not background plumbing.

2. **ssh is the ceiling: opt-in, additive only, never gating.** Once a power user (or a dev like Todd) sets up a key, ssh buys the richer interactive channel and the agentic coding loop. But nothing on the critical path -- boot detection, shutdown, repair, app launch -- may *require* ssh. ssh unconfigured means everything core still works over Helios; ssh failing degrades to Helios, never breaks. The agentic path uses ssh today purely as a dev convenience on Todd's own Mac; if that capability ever ships to customers it rides Helios too.

3. **One plane owns each job; the others are explicit, one-directional fallbacks, never co-owners.** Liveness is owned by Helios, full stop -- ssh does not also poll "is the guest up" on its own clock. Shutdown is owned by Helios. Two planes doing the same job on their own schedules is how you get races and "which one is authoritative" bugs (same class as overlapping grab routing). Assign the owner, make any fallback explicit and one-way (e.g. Helios down to telnet), and the benefit of several planes survives without the divergence.

This maps onto existing structure: the launcher's `transport` field (telnet / ssh / planned `helios`) is where the tiering surfaces, and the floor-default / advanced-toggle shape is the same hardcoded-to-config-to-UI delivery philosophy used for resources.

**Alternatives considered**:

1. *ssh as the primary transport for the agentic loop (and maybe more).* Rejected for anything customer-facing: ssh key provisioning per customer image does not scale and breaks "it just works" at first launch. Kept as the opt-in ceiling, where its after-setup richness is a genuine win for power users and dev.
2. *Pick one transport for everything (all-Helios or all-ssh).* All-ssh fails the zero-config floor. All-Helios is the long-run product answer but needlessly forgoes ssh's PTY/streaming for the dev loop *today*, before Helios grows a job/streaming/pty verb family.
3. *Let any plane do any job, choose at runtime.* Rejected: co-ownership of liveness/shutdown invites races and authority ambiguity.

**Why this won**: it makes the product promise ("just works" for a non-sysadmin audience) an architectural invariant rather than a hope, while still letting capable users opt into the richer channel. It also resolves the dev-vs-product seam cleanly: dev rides ssh for the richer loop, everything shipped rides keyless Helios, and the shared Mac-side tool logic (the read/substitute/write edit model) sits above the transport so the choice is reversible and per-consumer.

**Trade accepted**: maintaining more than one transport (telnet legacy, ssh opt-in, Helios default) is more surface than a single channel. Bounded by the owner-per-job rule and by keeping telnet maintain-only. Builds on 2026-06-17 (agent-on-a-port access) and 2026-06-20 (console observation-only; control moves to the agent or ssh).

---

## 2026-06-22: Helios daemon drops privileges to a validated user per request (not run-everything-as-root)

**Context**: C7 (launcher-over-Helios) shipped the X client running as **root**, because `run_command` inherits the daemon's root uid. That surfaced immediately — an xterm came up with root's shell instead of the user's. The deeper issue is permissions: the daemon does everything as root, and an unauthenticated-but-root control surface that runs arbitrary commands is not a posture to ship. Todd's call: implement proper "run as a validated user," don't skate it with a `su`-shell hack.

**Chosen**: `run_command` gains an optional `user` field. The daemon stays root (it must — only root can `setuid` to an arbitrary user, and shutdown/system-config writes need it), but when `user` is set it **drops privileges in the forked child before exec**: `getpwnam`-validate (unknown user → `ok:false`), then `initgroups` + `setgid` + `setuid` (groups/gid while still root, uid last and irreversible), plus a login-ish `HOME`/`USER`/`LOGNAME`/`SHELL` env. A failed drop `_exit(127)`s — it can never fall through to running as root. The drop lives in shared `CxProcess` (additive 4-arg overload; existing callers unchanged). Absent `user` = root, reserved for explicit admin tasks; user-facing work (the launcher, and the future agent) always names a user. `HeliosLauncher` passes `user=entry.user`, which also let it drop the temp-file/`su` stopgap (the daemon's /bin/sh + setuid gives both the right user AND Bourne syntax, dodging the tcsh login-shell trap).

**Portability**: deliberately uses only lowest-common-denominator calls — `getpwnam` (NOT `getpwnam_r`, whose signature differs Solaris-vs-POSIX; safe because single-threaded post-fork), `initgroups`, `setgid`, `setuid`, `putenv` (NOT `setenv`, absent on Solaris 2.6). Compiles with no `#ifdef` across Solaris 2.6 / SunOS 4 / BSD / Linux / macOS / Irix — matching the deploy-parity goal (same daemon reaches the emulator and a real Sun/any Unix).

**Trade accepted**: the daemon process is still root (standard privsep model, like sshd/inetd — start root, drop per request). Validation is "getpwnam resolves" only for now; a uid-floor/allowlist (refuse system accounts) is noted as later hardening. Builds on 2026-06-20/21 (Helios as the control plane). Pairs with the deferred daemon-auth (shared secret) work (HELIOS_PLAN open questions). **Built + deployed + live-validated on the real 2.6 image 2026-06-22** (`run id --user tvernon` → `uid=1000(tvernon)`; the 117 daemon tests now also pass on Solaris under g++ 2.95).

---

## 2026-06-22: Helios bulk transfer is a streaming raw body (put_file / get_file), not base64-in-JSON

**Context**: `write_file`/`read_file` carry content as base64 in one newline-JSON line — fine for a config, but moving a 4.7MB build tar that way **timed out at 55s** (the daemon buffers a ~6MB line and hands a ~6MB string to the JSON parser). FTP/scp move the same bytes in seconds because they stream raw straight to disk. The daemon needed the same for bulk.

**Chosen**: two new verbs, `put_file` (upload) and `get_file` (download), carrying a **length-prefixed raw body** after the JSON header — streamed to/from disk in 64KB chunks, no base64, no full-file buffering. This is the **one place the protocol deviates from one-JSON-object-per-line**; everything else stays pure line-JSON (still telnet-debuggable). Framing is clean because `CxSocketImpl::recvUntil` reads one byte at a time, so the byte after the header's `\n` is body byte 0 — no read-ahead to reconcile. Handled in the connection loop (`heliosHandleStreaming`), not the line-only `heliosDispatch`, because the verbs need the socket; a header with no usable `bytes` closes the connection (unframeable), a recoverable error drains the body to stay framed. `write_file`/`read_file` stay the small-file/base64 path (deliberately two tiers).

**Considered + rejected**: (a) a *new* verb that still sends one base64 line — fixes nothing. (b) chunked-append to write_file — keeps pure line-JSON but pays base64's 33% + many round-trips; fine for moderate files, not the bulk answer. (c) "just use scp" — the daemon shouldn't depend on sshd being present (a locked-down or real-Sun box may lack it), and the control plane owning its own transfer is the point.

**Validated 2026-06-22**: 4.7MB put+get round-trip byte-identical at ~0.2s each (vs the 55s timeout). Capstone — the daemon **redeployed itself using only helios** (`put_file` the 7.3MB tar in 0.28s, `run_command` to build + deploy.sh, surviving its own restart because the forked connection-child outlives it). The first deploy bootstrapped over scp since the verbs didn't exist on the running daemon yet. Trade accepted: a second framing mode in the connection loop and a not-telnet-pokeable payload for these two verbs — worth it for bulk; HMAC/TLS for the untrusted-LAN case stays the documented later concern alongside the deferred shared-secret auth.

---

## 2026-06-22: Helios auth = per-boot random secret delivered through OpenBoot firmware (-prom-env), not a config file

**Context**: with run-as-user and bulk transfer landed, the daemon does privilege-sensitive work, and an unauthenticated root-capable control socket is not shippable. The deferred plan was a static secret in a root-only config file generated at install. Todd proposed a better key-distribution: have macXserver pick a **random secret each launch** and pass it to the guest through the qemu/OpenBIOS boot channel, so the daemon learns it without it ever being baked into the image.

**Chosen**: macXserver generates a fresh 128-bit secret per launch (`QemuEngine.generateHeliosSecret`) and passes it via qemu **`-prom-env 'helios-secret=S'`** (a custom OpenBoot NVRAM variable). The daemon's init script reads it back with **`eeprom helios-secret`** and starts the daemon with `-s S`; the daemon then requires a matching `auth` field on every request (dispatch-layer, constant-time compare, `ok:false "unauthorized"`), **require-if-configured** (no secret -> open, for dev/`make test`). macXserver's own daemon calls + the launcher present S; a **"Claude development"** Preferences checkbox (off by default) writes S `0600` to `/tmp/sparkplug` so Claude Code can authenticate for agentic work.

**Why this beats the config-file secret**: it's per-boot (no long-lived credential) and, crucially, **never touches the guest disk** — validated 2026-06-22 that `-prom-env` is *runtime-only*: a custom OBP var is readable via Solaris `eeprom` while set, and is **gone on the next boot that doesn't pass it** (does not persist to the qcow2 NVRAM). So a stolen image leaks no key. Deliberately **not echoed to the boot console** (the console is captured to `.xtap`/logs — printing it would defeat the disk-free property; macXserver already knows S and the guest reads it from OBP, so nothing needs the echo).

**Honest scope (unchanged from the earlier note)**: a plaintext secret over the cleartext newline-JSON channel is a speed-bump — kills unauthenticated / cross-VM / port-scan access and is solid on the loopback hostfwd, but is sniffable + replayable on a real LAN. NOT crypto. HMAC-over-a-nonce or TLS stays the documented upgrade if the untrusted-LAN case becomes real. **Emulator-specific**: `-prom-env` is the qemu/OpenBIOS channel; a real bare-metal Sun has no such injection and would provision the secret another way (manual `eeprom`, or a config file) — scoped out for now (the bundled emulator is the shipping product).

**Validated 2026-06-22 on the real 2.6 image**: custom OBP var surfaces in `eeprom` and does not persist; the daemon enforces auth live (no-auth/wrong -> `unauthorized`, correct -> ok); 122 daemon tests pass on Solaris under g++ 2.95. Built on the run-as-user + streaming work the same day; the daemon self-deployed the auth build over helios (`put_file` + `run_command`).

---

## 2026-06-24: macXserver controls the captive VM through QMP, not just the guest console + signals

**Context**: a "what's brittle in SPARCplug control" pass (2026-06-24) traced every soft spot back to the same root: macXserver treats qemu as a black box. We launch with `-nographic` (serial console to a parent-owned stdio pipe), read that console as text, and stop the VM with SIGTERM/SIGKILL. So clean-halt detection is a console string match (`syncing file systems... done`), Force Quit is a SIGKILL that can tear the qcow2 mid-write, an orphaned qemu spins at 100% CPU (the console pipe's reader died, qemu busy-polls the hung-up fd), and liveness is latch-once. None of this is a bug -- the control story grew bottom-up from the guest side (console scrape -> `init 5` over console -> the Helios agent), and the early `-nographic` choice quietly made the serial console our only window into the VM. QMP, qemu's standard machine-control socket, was never turned on. Verified against the vendored qemu-9.2.4 source that QMP and the relevant signals are all available for `-M SS-5` / sun4m specifically (machine-specific gaps were the whole risk).

**Chosen**: in the captive case, macXserver runs **two** control channels and stops treating qemu as a pipe. **Helios** stays the *guest-OS* plane (exec, files, OS-liveness, and the only FS-clean shutdown, `init 5` -- unchanged, and the only plane on real iron). **QMP** (`-qmp unix:<sock>,server=on`) becomes the *VM/hypervisor* plane for the things the guest plane structurally can't do. Division of labor: graceful FS-clean shutdown stays Helios `init 5`; the "halted cleanly?" gate moves from the console string to the QMP `SHUTDOWN` event (`reason: guest-shutdown`, which sun4m's `AUX2_PWROFF` path raises *after* the FS sync -- `hw/misc/slavio_misc.c:266`); Force Quit becomes QMP `quit` (drains + `bdrv_close_all`, leaving the qcow2 container consistent) with SIGKILL only as the wedged-qemu fallback; the console moves from the stdio pipe to a `-serial unix:` socket (reconnectable, kills the orphan CPU-spin); VM liveness comes from QMP `query-status` (distinct from OS-liveness via Helios `hello`, so we can tell "VM dead" from "daemon wedged"). The image lock grows into a **VM handle** (adds the QMP + console socket paths next to the per-boot secret), so any later process can fully reattach to an orphan -- QMP `quit` it cleanly, drive Helios `init 5`, re-attach the console. A new async `QmpClient` (SwiftXServerCore) owns the QMP socket; it is NOT a `HeliosClient` variant (QMP interleaves async events with command responses, vs Helios's strict one-in-flight). Full design + the source-cited capability evidence + the staged rollout live in `VM_CONTROL.md`.

**Why this is the right shape**: the two planes barely overlap, and that's correct. QMP-only capabilities (snapshot, VM liveness, clean container quit, orphan handling) are emulator concepts that **don't exist on real hardware** -- a real SS-5 has no snapshot, no orphan-qemu, no qcow2 to flush. So the planes diverging by deployment is not a gap: captive gets emulator-specific control for emulator-specific concerns, real iron stays Helios-only and needs nothing more. This also keeps the "one mechanism, two clients" Helios story intact -- QMP is a third channel but not a third Helios client; it's the macXserver<->emulator channel, orthogonal to everything Helios. Bonus: the same QMP channel de-risks and unlocks the deferred snapshot fast-launch feature (verified all sun4m devices have `VMStateDescription`, no migrate blockers, so `savevm`/`loadvm` should work -- wants a live round-trip before we bank it).

**Considered + rejected**: (a) keep inferring clean-halt from the console string -- it fails *safe* (a miss means no auto-backup, never a corrupt one), so it's not dangerous, but it's a guest string gating a safety-critical action when the emulator will just tell us structurally. Kept as a UI banner / backstop, demoted from the gate. (b) a state-machine clean-halt (back up iff we-initiated-graceful AND never-killed AND clean-exit) -- needs no QMP, but misses an externally-triggered clean halt (the helios CLI, a manual `init 5`) that the `AUX2_PWROFF` event catches regardless of who ran it. (c) keep SIGKILL for Force Quit -- leaves the qcow2 container possibly torn; QMP `quit` is strictly better when reachable. (d) a kqueue watchdog as the orphan answer -- still wanted as true *prevention* (auto-reap on parent-death-by-SIGKILL, new signed helper, maintainer sign-off), but the serial socket already kills the *symptom* (the spin), so the watchdog drops from "fixes a fire" to "nice-to-have," and is out of scope for this decision.

**Trade accepted**: a new async component (`QmpClient`) and a change to core lifecycle (launch args, console transport) -- real work, and it's the working boot/shutdown/orphan core, so it is **staged, not big-bang** (Stage 0 no-progress shutdown watchdog; Stage 1 QMP socket + SHUTDOWN-event clean-halt + `quit` Force Quit, additive and low-risk; Stage 2 console-to-socket; Stage 3 lock-as-VM-handle + orphan reattach; Stage 4 snapshot fast-launch). For plugin v1, Stage 0 + Stage 1 are the cut. Each stage is gated by the `SPARCPLUG_LIVE_TEST` harness. **Status: proposed 2026-06-24, no code yet** -- this entry records the shape; `VM_CONTROL.md` is the burn-down.

---

## 2026-06-26: the interactive console terminal is libvterm-core + our renderer, not SwiftTerm and not a port of xterm

**Context**: now that VM control no longer depends on the serial console for anything (Helios drives the guest, QMP drives the VM -- 2026-06-24), the console is free to become an interactive surface so a user can run `vi` / `top` / `format` when the graphical path is broken (PROM `ok`, boot, single-user, fsck) -- the guided-repair story (Helios C6). The blocker is terminal emulation: the current console (`SparcPlugConsoleWindowController` + `ConsoleSanitizer`) is a teletype -- an `AttributedString` line buffer with no screen grid, no cursor addressing, no attributes -- so `vi`'s `ESC[2J ESC[H` renders as literal garbage. The job splits cleanly: an emulator state machine (the escape-sequence tar-pit) and rendering (which we already do well for xterm via `FontResolver` + `XTERM_FONT_QUALITY.md`).

**Chosen**: vendor **libvterm** (Paul Evans, MIT -- the `:terminal` backend in Vim and Neovim) as a C target built from source, and keep **our** Core Text cell renderer. libvterm is *just* the state machine: feed it bytes, it maintains a screen model and fires damage callbacks, we draw the grid with the cell-metric rules we already own. v1 emulates **vt100** (`TERM=vt100`, guaranteed present on Solaris 2.6), fixed 80x24, bounded scrollback, 16-color + attributes. Full scope in `CONSOLE_TERMINAL.md`.

**Why this shape**: it owns the part that matters (the pixels -- reusing the font-quality work) and borrows the part that's genuinely hard to get right (the escape-sequence long tail) from the most battle-tested small core available. Linking C *source* also sidesteps the qemu signing pain entirely: it's object code in our own binary, so no separate executable, no separate signature, no AMFI helper-kill class of bug (that needs a distinct child process), and no new entitlements (libvterm does no I/O -- we own the socket).

**Vendoring posture** (same as the bundled qemu): we copy the libvterm source *into the tree* and build it ourselves -- nothing fetched at build time, nothing linked from a prebuilt `.a`/`.dylib`. The honest framing is **zero external / runtime dependencies, one vendored third-party source we own**: ours to read/patch/freeze, MIT `LICENSE` kept alongside, updates a deliberate manual copy-in (never an auto-bump), and small enough (a handful of C files) that the "understand the stack" rule still binds -- that's the line between vendoring and depending. SwiftTerm-via-SwiftPM was the only option that would have added a real external dependency, which is part of why we passed.

**Considered + rejected**: (a) **port xterm to Swift** -- the one clearly-wrong option. xterm's emulator (`charproc.c`) is 30 years of VT100/VT220/xterm/DEC-private-mode accretion *welded to* Xt/Xaw widgets and X11 draw calls; there is no self-contained emulator core to lift, so our "port the 30-year classic straight" rule (miregion, mi cursor) doesn't apply -- it's the highest-effort, highest-bug path. (b) **SwiftTerm** (Miguel de Icaza, MIT, pure Swift) -- the fastest path to "vi works" and the most xterm-complete, but it's a whole `NSView` widget with *its own* rendering, so we'd inherit a big dependency we don't control and drop our font-quality work. Right call only if the console were a throwaway side feature; it isn't. (c) **roll our own on the Williams parser** (pure Swift, zero deps, the canonical DEC ANSI state machine under vte/st/alacritty) -- the purest own-the-stack option and on-brand, but the escape-sequence long tail is real and becomes our permanent burden; reserve it only if we object to any C dependency on principle. libvterm's completeness (it's what millions run vi/curses against daily) is the deciding factor over (c).

**Trade accepted**: a vendored C target (built from source, never a prebuilt `.a`) and a new `TerminalEmulator` wrapper + `TerminalView` (new component, maintainer-approved) replacing the teletype path. Bounded: the renderer reuse is metrics-only (the grid draw is new code honoring reported-cell === rendered-cell), and v1 deliberately omits resize, mouse, sixel, and select-to-copy. **Status: scoped 2026-06-26, no code yet** -- `CONSOLE_TERMINAL.md` is the burn-down. Success metric: `vi` over the console, navigate + edit + `:wq`, clean render and correct cursor throughout.

---

## 2026-07-05: macXserver becomes a machine manager — the X server recedes to a stated-but-secondary service (inverts the "one machine, not a VM list" stance)

**Context**: the app has quietly become two things. The original charter
(`SPARCSTATION_PLUGIN.md` Phase 2: "NOT a VM list, NOT a configuration panel. One
machine, one set of controls… resist the temptation to expand scope") was written
when the emulator was genuinely a hidden appliance under the X server. It isn't
anymore — there's a console, backups, orphan reconnect, image locking, Helios
management, a DNS admin panel, and now *real hardware* (the ss5) in the picture.
The moment there's more than one box — emulated or real — "one machine, one set of
controls" stops describing reality. Todd's driving "why," sharper than the doc's:
managing a heterogeneous collection of old machines is genuinely hard (OS config
drift, hard to build things everywhere), and this app is the control plane that
makes it not-hard, identically whether a box is emulated or real iron — plus the
consumer angle, an "experience what Sun machines were like" tool for people who'll
never own the hardware. Full design in `MACHINE_MANAGER_REFACTOR.md`.

**Chosen**: invert the product identity. The app is organized around a **machine
list** (a `Machine` model with two kinds — `.emulatedVM` full-lifecycle, and
`.externalHost` real Sun with no lifecycle we own, differentiated by *capability
sets* not a uniform interface, because a real Sun genuinely has no QMP/start/stop).
A `MachineController` (per-machine `{QemuEngine, QmpClient, console, ImageLock,
secret, ports}`) is extracted from the ~1500-line AppDelegate god-object, held in a
keyed `MachineRegistry` instead of the single `qemuEngine?`. The X server keeps
running exactly as-is (same per-connection `protocolQueue` model, still usable with
zero VMs, still the technical heart) but becomes a *stated-but-secondary service*.
Phased, each phase shippable: P0 extract controller (no behavior change) → P1
registry + list window, one-at-a-time → P2 concurrency (dynamic ports, unique
MACs, per-machine sockets/locks/secrets, N engines) → P3 external hosts +
launchers-under-machines → P4 catalog + verified downloads → P5 the identity
reframe. Stop after P1 and reassess.

**Four sub-decisions settled the same day** (each detailed in the doc):
- **Golden-master config story lives OUTSIDE the app.** NOT building
  fleet/config-management (no Ansible-for-Suns). Dial the reference VM in by hand,
  then *Claude* deploys the delta over Helios to bring real boxes into compliance.
  So the app needs only lifecycle + external-host kind + a registry Claude can see.
  This forces one architectural rule: **the `MachineRegistry` is visible to the MCP
  bridge**, not private AppDelegate state — it's the discovery layer Claude reads
  to know the fleet. Consistent with peer-clients-not-a-hub (2026-06-21): the
  manager owns lifecycle + network path + discovery and brokers nothing.
- **Networking**: slirp stays the default (free outbound NAT). Add a `-netdev
  socket` **fabric as a second NIC** so VMs can talk to each other (unprivileged,
  static `le1` config into `guest-config/`); hostfwd incl. `0.0.0.0`-bind for
  inbound-from-LAN on demand. **vmnet-bridged is out of scope** — it needs qemu as
  root or the Apple-gated `com.apple.vm.networking` entitlement or a shipped
  privileged helper, all of which break the unprivileged + minimal-tooling story,
  and bridging unpatched 30-year-old OSes onto real LANs is a security exposure the
  LAN-only/hobby-grade non-goal exists to fence out. `Machine.networkMode` field
  carries the choice.
- **App flow = separate first-class windows**, not a unified sidebar shell (the
  lower-risk path; doesn't turn this into a big multi-surface app). **Machines**
  window is the front door (opens on launch, close ≠ quit — the status item is the
  persistent presence); **X Server** is an on-demand live-runtime window (clients,
  listener, drop). Menu bar goes thin: App / Machines (replaces SPARCstation,
  rebuilt from registry, launchers nested per-machine) / Server / Edit / Window.
  The status item becomes an "N running" dashboard.
- **Capture is not a peer surface** — server-side capture is a feature of the
  running X server (Preferences toggle + App-menu actions); the standalone
  macXcapture app is a separate target, out of this reorg.

**Considered + rejected**: (a) keep the X-server-primary framing and only make the
*plumbing* multi-machine — the smaller fallback, still worth doing, but Todd bought
the full inversion with eyes open, so the UI reframe is in. (b) a unified
window-with-sidebar-surfaces shell (Machines/X Server/Capture as source-list rows)
— cleaner-scaling but a bigger application-shell commitment; separate windows
chosen for lower risk. (c) an in-app config-management feature — rejected in favor
of golden-master-plus-Claude, which needs no new app surface. (d) full
vmnet-bridged networking — rejected on privilege + security grounds above. (e) a
uniform Machine interface across both kinds — rejected because capability
divergence between emulated and real is load-bearing (2026-06-24 QMP-only-on-
emulator split).

**Trade accepted**: this overturns a written charter stance and adds new top-level
types (`Machine`/`MachineRegistry`/`MachineController`, kept in `SwiftXServerCore`
alongside `QemuEngine`, not a new module) — both maintainer-sign-off gates, which
this conversation cleared. The hard boundary held: **"VM manager primary" means UI
organization, NEVER a protocol broker** — the manager never proxies X or Helios
bytes; Claude Code and macXserver stay co-equal Helios peers; the X server keeps
its own per-connection session model. The two genuinely un-built prerequisites
(concurrent multi-engine runtime = deferred milestone #6; Helios-on-real-iron =
HELIOS_PLAN C9) are scoped, not blocking P0–P1. **Status: approved AND P0+P1
shipped 2026-07-05** (same day) — `Machine`/`MachineRegistry`/`MachineController`
landed as flat-JSON config + registry + Machines list window + registry-driven
menu/status reorg, and per-external-host Helios secrets (most of the "external
hosts" phase) proven against the real ss5. See the "Shipped 2026-07-05" section
of `MACHINE_MANAGER_REFACTOR.md`. At the reassess boundary now; next candidates
are the add/edit-machine UI and the MCP bridge (P2 concurrency deferred).
`SPARCSTATION_PLUGIN.md` ("NOT a VM list") and `PRODUCT_2_SERVER.md` still to be
updated to match the shipped reframe.

---

## 2026-07-06: P2 concurrency — sticky port assignment (not dynamic), per-machine MACs, secrets via the image lock (not /tmp/sparkplug), one image editor

**Decision**: the multi-VM runtime (the refactor doc's P2, milestone #6) shipped
with four calls that refine or supersede pieces of the 2026-07-04 doc:

1. **Host ports are assigned once, at machine creation — "dynamic by assignment
   time, not by invocation" (Todd's framing).** The doc's original call was a
   dynamic allocator that hands out ports at every start. Rejected: since that
   doc was written, the fixed per-OS blocks became load-bearing across the whole
   tooling ecosystem (SPARCplug emu scripts, the helios CLI, Claude-side
   conventions — a given machine is always at its ports). Instead the registry
   materializes a persistent block onto a user-created emulated VM the moment it
   exists (`MachineRegistry.assignPortsIfNeeded` → `ImagePorts.block(n)`,
   n = 5, 6, … in the same mnemonic pattern 21n3/22n2/21n5; blocks 2–4 stay the
   bundled fixtures' well-known per-OS blocks, still derived, never moved). A
   machine's ports never change for its lifetime; clones get a fresh block; a
   start-time `portConflict` check is a belt-and-suspenders guard that can only
   fire on a hand-edited machines.json.

2. **The /tmp/sparkplug Claude-dev secret file is retired outright** (the
   Preferences toggle, the Config window, and the write/clear plumbing are
   deleted). It was redundant since 2026-06-22: the image lock next to the qcow2
   already records the per-boot secret, and as of P2 it records the **helios
   hostfwd port** too, so the lock is a complete reach-the-daemon handle
   (pid + secret + port). Claude-side tooling reads the lock (or takes
   HELIOS_SECRET); the **MCP bridge is the real hand-off channel** and is the
   next work item — `MachineRegistry.snapshot()` now carries `heliosPort` as
   groundwork. (The SPARCplug repo's emu scripts still write their own
   /tmp/sparkplug for standalone runs; unaffected.)

3. **One image editor.** The Machines window's Settings tab is the only place a
   machine's disk image is set. The old Machines → Config → "Disk Image" window
   died with the Preferences path it edited (`sparcplug.diskImagePath` is now
   migration-read-only legacy); its auto-backup toggle moved onto the machine
   (`Machine.autoBackup`, per-machine — you can auto-back-up the precious
   Solaris image and not a throwaway NetBSD experiment). "Shared Folder" is the
   only Config window left (genuinely global) and moved to the Machines menu's
   top level. The welcome/install flow now attaches its picked image to the
   machine whose Start was pressed.

4. **Guest MACs derive from the machine id** (locally-administered
   `02:` + five id bytes, `Machine.resolvedMacAddress`; explicit override still
   wins). Deterministic per machine (stable guest identity across boots), unique
   across machines — kills the latent duplicate-`DE:AD:BE:EF:F3:E5` collision
   the doc flagged. The old MAC survives only as the default for a config built
   without a machine (tests, bare `defaultConfig`).

Mechanically, P2 is: a fresh `MachineController` per start built from
`machine.makeEngineConfig()` (so config edits apply at next boot with no rebuild
bookkeeping), per-machine console windows keyed by machine id (fixes the
console-follows-the-wired-machine steal), per-machine DNS-admin windows,
per-machine readiness/progress on the controller, the orphan
scan/reconnect/shutdown flows iterating every machine (ports from the lock), the
quit dialog covering N running guests, and `heliosSecret` keyed by helios port
so several loopback guests' secrets can't cross. The single-target
`bundledMachine` resolver and the `telnetHostPort`/`heliosHostPort` globals are
gone; `HeliosClient` now requires an explicit port.

**Considered + rejected**: (a) the doc's dynamic port allocator — see above;
(b) per-port secret files (/tmp/sparkplug-2125 etc.) as a transitional bridge —
rejected by Todd as redundant with the lock file; (c) keeping the Disk Image
config window rebound to the machine — two editors for one field plus permanent
sync glue for zero gain.

**Trade accepted**: the helios CLI's auto-read of /tmp/sparkplug no longer works
against app-launched guests until it learns the lock file or the MCP bridge
lands (emu-script-launched guests are unchanged). User-VM blocks above n = 9
climb into the 2200s; the pattern's arithmetic keeps them collision-free, and
nobody should be running 8+ concurrent sun4m guests on one Mac anyway.

---

## 2026-07-07: VM memory is not a setting — every guest gets the SS-5's 256MB

The Settings tab briefly (2026-07-06 → 07-07) exposed a per-machine "Memory"
field feeding qemu's `-m`. Removed outright, Todd's call: "pointless to
change it." qemu's SS-5 machine caps at 256MB (`max_mem` in sun4m.c — also
the real hardware's maximum), exceeding it is an instant `exit(1)` that
presents as a mystery launch failure, and there is no scenario where starving
a vintage guest below the max helps anything on a modern host. So: no knob,
no validation problem. `Machine.memoryMB` is gone from the model and the
JSON (a legacy `memoryMB` key in machines.json decodes to nothing);
`QemuEngineConfig.memoryMB` survives as an engine-level parameter (tests pin
the argv) defaulting to 256.

**Considered + rejected**: validating/clamping the field (1–256) — fixing a
knob nobody should turn is polish on the wrong thing; removing it removes
the failure mode. Guests observed happy at 256 already (NetBSD ran with
`RAM=256` in the boot scripts since the beginning; Solaris/SunOS ran 128 by
script default, and 256 is within what the real SS-5 and both OSes support).

---

## 2026-07-07: Admin Agents availability rule — answering over Helios, plus a known OS for OS-sensitive verbs

The Overview's Admin Agents verbs (File Transfer, DNS, and whatever joins
them) gate on the machine actually ANSWERING over Helios: an emulated guest
that's running and ready (readiness is already a helios hello), or an
external host whose last prober hello succeeded (which, against the
fail-closed agent, also proves the saved secret is right). On top of that,
verbs that do OS-specific things (DNS today; most future admin verbs, per
Todd) also require knowing the machine's OS — external boxes declare it via
a new OS picker in Settings → Identity; emulated machines get it from image
detection. Genesis: the real SS5's DNS chip sat dimmed because the old gate
was `isEmulated && ready`, unreachable for external hardware by definition.

**Supersedes** the one-day-old "gating is configuration, fail at use"
posture for external verbs (2026-07-07 morning, File Transfer's original
gate): with the prober live, reachability data is at worst minutes stale and
a dimmed-with-tooltip button beats a working-looking button that always
errors. Launch X11 clients (launcher chips) keep their existing gating —
they're not admin verbs.

**Companion slimming (same day):** the launcher definition lost two fields.
`fileBrowser` launchers are superseded outright by the automatic File
Transfer verb (legacy entries are dropped on load; the old launcher-file
migration skips them). Per-launcher `display` is gone too — the machine's
DISPLAY is the only level, shown in Settings with the real computed default
("what blank means") as its placeholder. And the box's own uname (sysinfo)
auto-populates + locks an external machine's OS, same source-of-truth
doctrine as image detection on emulated VMs.

---

## 2026-07-08: Telnet password is a machine-level field, edited in Settings → Connection

The 2026-07-07 launcher slimming dropped the password from the launcher
editor but left the per-launcher `password` key in the model, so the
passwords the migration had seeded (one copy on EVERY launcher of a box —
Todd's live file had 92) kept working with no way to edit them. The password
is a credential for the machine's user@host, and launchers can't override
either, so per-launcher copies were pure duplication — same reasoning that
moved `display`, `fileBrowser`, and `shellPrompt` up. Now: `Machine.password`
(optional, cleartext in machines.json, same trust level the old launchers
file had), edited via a Password secure-field with a Show checkbox in
Settings → Connection, shown when telnet is in play, right next to Prompt.
Legacy per-launcher keys are lifted on load (first non-empty wins, an
explicit machine key wins over stale launcher copies) and never re-encoded,
mirroring the `fileBrowser` drop. Resolution injects the password only into
telnet entries — ssh stays keys-only (no spurious ssh-with-password
warnings), helios has its own secret. Blank keeps the old contract: prompt
on first launch, store in the Keychain (Debug builds: the 0600 dev-secrets
file, since ad-hoc signing churn makes the real Keychain unusable in
development).

---

## 2026-07-08: Verbose is a launch gesture, not launcher config

The per-launcher `verbose` flag (persisted in machines.json, edited via a
toggle in the launcher sheet) is gone. You want the live progress window
when you're debugging a launcher, not as a standing property of it — the
old flow meant open editor, toggle on, launch, open editor, toggle off.
Now: right-click a launcher (the Overview chips, and the X11 Launchers rows
on the Settings page) → "Run with Progress Window" streams that one
launch's transcript live; a plain click runs silently. Todd's call. The
verbose bit rides the launch path as a parameter (`onLaunch(id, name,
verbose)`), nothing is persisted, and a legacy `verbose` key in
machines.json is ignored on decode and dropped on the next save (same
treatment as `memoryMB` / per-launcher `display`). The failure-path
transcript is unaffected: every launch still captures a bounded transcript
and a failing silent launch still shows its tail in the error dialog.

---

## 2026-07-09: Guest hostfwds bind loopback only; the networkMode knob is deleted

Two halves of the same audit finding (MACHINE_SETTINGS_AUDIT.md F2). The
qemu nic string used empty-hostaddr hostfwds (`hostfwd=tcp::2123-:23`),
which libslirp binds to ALL interfaces — so every guest's telnet/ssh/helios
forward was reachable from the whole LAN, while the `networkMode` doc
claimed loopback-only. And `networkMode` itself was dead config: decoded,
encoded, defaulted, read by nothing (`makeEngineConfig` never passed it).

The fix is to make the doc's claim true and delete the lie: hostfwds now
bind `127.0.0.1` explicitly, and `MachineNetworkMode` + `Machine.networkMode`
are gone. A legacy `networkMode` key in machines.json is ignored on decode
(Codable drops unknown keys) and vanishes on the next save.

This changes wire behavior: guests stop being LAN-reachable. That's the
intent — the app on this Mac is the only thing that dials guest ports, and
an unauthenticated vintage telnetd listening on the LAN is a real (if
small) security surface. Guest-to-guest still works through the host:
slirp delivers a guest's connection to `10.0.2.2:PORT` onto the host's
loopback, where the other guest's hostfwd lives. If LAN-exposed guests or
a true shared inter-VM segment (qemu socket networking / vmnet) ever become
real needs, they get designed fresh with UI and a DECISIONS entry — not a
dormant enum waiting to be wired. Todd's call, 2026-07-09.

---

## 2026-07-09: Machine settings speak plain English, grouped by what they answer

The MACHINE_SETTINGS_AUDIT.md cleanup locked in a naming + grouping
doctrine for the Settings tab. Sections answer questions: **Machine**
(what is this? Name, Kind, OS), **Connection** (how does the app reach
it? Host, Connect with, Ports, Helios Secret), **Login** (as whom? User,
Password, Shell prompt), **X11 Launchers** (what runs, and where do
windows go? Show windows on + the launcher list), **Disk Image**
(emulated only). Conditional fields appear inside the section that owns
them, so telnet's password materializing no longer mutates a different
section of the form.

Renames follow the existing no-jargon rule (user-facing labels avoid
protocol vocabulary): Transport -> "Connect with" with options Telnet /
SSH / Helios agent, DISPLAY -> "Show windows on", Prompt -> "Shell
prompt", Identity -> "Machine", OS picker shows displayName not raw enum
values. Every non-obvious field carries an always-visible caption
(fieldCaption, the helpNote style indented under the control) instead of
a hover-only tooltip -- if a setting needs explaining, the explanation is
visible without knowing to hover.

Two placement doctrines worth keeping: **Settings holds only things with
an edit affordance** -- the read-only Runtime section dissolved to a
monospaced ports+MAC facts line on the Overview, next to the live system
line; and **credentials are settings, not operate verbs** -- the Helios
Secret button left the Overview's lifecycle slot (it only sat there
because an external's slot happened to be empty) for Settings ->
Connection. The Machines menu mirrors the Overview's operate verbs, so
the secret has no menu item anymore.

---

## 2026-07-09: Telnet Keychain slot is per-machine (user@host:port)

The telnet password Keychain account was `user@host`, and every emulated
VM is host 127.0.0.1 -- so all loopback VMs sharing a username shared
ONE stored password (first-launch prompt for VM A silently became VM B's
stored password; the mismatch surfaced as a bare "Authentication
failed"). The account key is now `user@host:port`; the telnet port is
per-machine (sticky block assignment), so it disambiguates without
inventing a new identity scheme. Lookup falls back to the legacy
`user@host` entry once and copies it forward under the new key; the old
entry is deliberately left in place -- a lookalike `user@host` item may
belong to some other app, so it isn't ours to delete. (The helios secret
account `helios:user@host` is unaffected: it's external-only, where
hosts are genuinely distinct.)

(Superseded same-day for the HELIOS account -- see the evening entry
below: the helios secret is keyed by host alone now, because it's a
per-box fact. The telnet password stays user@host:port -- a login
password genuinely is per-user.)

---

## 2026-07-09 (evening): Settings group by plane; transport is launcher config; helios secret keyed by host

Todd's manual pass on the morning reorg surfaced a real tension: the
Connection section mixed two unrelated planes, and "Connect with" was
doing two jobs -- the default transport for launcher commands AND the
prober's opt-in (transport == helios meant "watch this box"). Unwound as
three linked decisions:

**Sections are planes now.** Machine (name/kind/OS), Connection (host +
user: the genuinely shared facts), **Helios** (agent port, secret,
live status line), **Telnet / SSH** (their ports, password, shell
prompt -- always visible; fields materializing when a picker two
sections away said telnet was the old muddle), X11 Launchers ("Show
windows on", "Connect with", the list), Disk Image. The three-field
Ports row dissolved into the plane sections; the collision check still
spans the triple and warns under both rows.

**Transport is launcher config.** "Connect with" lives in X11 Launchers
and means one thing: how launcher commands sign in (per-launcher
override unchanged, bundled still locked to Helios agent). Prober
candidacy no longer reads it: an external box is watched iff a Helios
secret is saved. Probing a secretless box against fail-closed agents
could only yield "unauthorized" -- a confusing dot for what's really
"you haven't set the secret" (the 2026-07-09 ipc incident). No secret =
neutral gray "not watched" dot, and both the status text and the Helios
section say how to turn monitoring on.

**Launchers are their own tab** (added later the same evening): the
detail pane is Overview / Settings / Launchers now. Machine config is
write-once; launchers are a working list you keep tweaking -- different
edit cadences get different tabs (the Xcode target-editor precedent).
The launcher-scoped defaults ("Show windows on", "Connect with") moved
into the tab with the list, so Settings is purely machine facts. The
Launchers form commits ONLY the fields it owns onto the live machine
(and the Settings form adopts the live launcher-scoped values at commit),
so the two tabs' drafts can't clobber each other.

(The "candidacy = saved secret" rule below lasted one day -- superseded
by the 2026-07-10 entry: the prober is an aliveness oracle now and
probes every external with a host.)

**The helios secret is keyed by host alone** (`helios:<host>`,
lowercased). It's a per-box fact -- one daemon, one secret, whatever
login telnet/ssh/run-as uses -- so editing User must not detach it
(under `helios:user@host` it did, which is what made ipc read "refused
the secret" for an app-side key miss). Legacy user@host entries migrate
forward on first read, old entry left alone. "Unauthorized" can now only
mean the SAVED secret was refused, and the UI says "refused the saved
secret" plus a re-enter hint in the Helios section's status line.

---

## 2026-07-10: The prober is an aliveness oracle; launchers dim on knowledge, not heuristics

Todd's laptop-away-from-home session surfaced it: external xterm chips
stayed clickable while every machine was unreachable. The old doctrine
("launch verbs never gate on probe results -- probes are minutes stale")
was a VM argument misapplied to real machines, which run for months; and
the deeper issue was that we threw away what the TCP layer already knew.
Todd's model, adopted wholesale:

**A helios probe classifies box-aliveness independent of helios
configuration.** Connect REFUSED (RST) = the host answered; it's alive,
just no agent on the port. Timeout / no-route / no-resolve = the box
isn't there (or we aren't on its network). Agent answers but denies =
alive with an agent; auth is the only problem. `HeliosClient` gained a
typed `.connectionRefused`, and `HeliosReachability` is now
{unknown, up, unauthorized, noAgent, unreachable}.

**Every external with a host is probed, secret or not** (supersedes
yesterday's secret-saved candidacy, which lasted one day). A secretless
box maps to honest states: "up, no Helios agent" (green outline dot),
"agent present, set its secret" (orange, with words), "unreachable"
(red outline). Telnet-only machines finally get a live dot.

**Launcher gating -- one shared rule** (`launcherEnabled`, used by both
the Overview chips and the Machines menu): emulated = up and ready, as
before. External chips dim only on KNOWLEDGE of failure: the box is
confirmed unreachable (no transport can work), or the launcher's
effective transport is helios and the agent isn't answering (guaranteed
failure). Telnet/SSH launchers on an alive box stay enabled -- a refused
helios connect is positive proof of aliveness, so that's optimism backed
by evidence. Unknown (first probe pending) stays optimistic.

**Words ride the colors everywhere** (Todd: "the colors start to get
confusing"): the master list subtitle ends with the state in a word or
two (reachable / no agent / needs secret / wrong secret / unreachable /
running / stopped ...), the Overview status text spells the state out, a
caption under the chips explains why anything is dimmed, and the
Settings Helios section's status line describes the state in a sentence.

---

## 2026-07-10: Curated-image catalog lives on macxserver.com, not oldsilicon.com

The IMAGE_DOWNLOAD_PLAN.md design (2026-07-06) settled hosting on
oldsilicon.com, where the images already live for the ZuluSCSI workflow.
Todd's call at build time: the app fetches from the product's own domain
instead — `https://macxserver.com/images/catalog.json`, payloads beside it
(pinned in `ImageCatalog.defaultURL`; `SPARCPLUG_CATALOG_URL` is the dev
override, same pattern as `SPARCPLUG_ENGINE_DIR`). Keeps the shipped app's
network traffic pointed at its own site, and the catalog rides the same
hosting the download button already depends on. oldsilicon.com keeps
distributing the ZuluSCSI copies; the two audiences never needed to share
a URL. `build-catalog.sh` (SPARCplug repo) emits a staging dir whose
contents upload to macxserver.com/images/ as-is.

---

## 2026-07-10: User management is host-driven; first run is an in-window guided flow

Two calls from the first-launch design session (full designs in
HELIOS_USER_MANAGEMENT.md and FIRST_RUN_EXPERIENCE.md):

**Add/delete user rides the existing Helios verbs, host-driven.** A
`UserAdmin` module composes per-OS sequences of read_file / run_command /
write_file over `HeliosClient`, with the per-OS knowledge (passwd/shadow/
master.passwd formats, pwd_mkdb, home paths) in pure unit-testable
builders keyed by exhaustive `MachineOS` switches. Rejected: first-class
`add_user`/`delete_user` agent verbs -- one-round-trip atomicity wasn't
worth a fleet-wide agent redeploy, version gating, policy code in a
deliberately-primitive agent, and guest-only testability. The
transactional risk is handled by ordering (home dir first, the atomic
login-enabling passwd write last). DES hash is computed host-side
(macOS crypt(3) still does DES; verified) so cleartext never crosses the
wire. The images were pre-staged for this by the 2026-07-04 convergence
(`template` account, uid 1001+ reservation, gid 100).

**First run guides inside the Machines window, not a wizard.** Fresh
install: a text bubble over the detail area ("Just getting started?
Download a starter image and launch a SPARCstation"), the Download button
rendered blue while it's the next thing to do, then a "one more thing --
add a user" popup when the download lands. Enter collects the credentials,
boots the VM, and applies the login at ready (deferred-apply: the agent
must be answering first); the boot bar carries a "creating your login"
tail phase. Rejected: a self-contained wizard -- the guided flow teaches
the real UI it leaves behind and doesn't duplicate the download/boot/user
surfaces. The bubble is state-derived (shows while no emulated machine
has an image), not a dismissed-once flag. Requires seeding fixtures with
`machine.user = ""` (the NSUserName() fallback wrote a lie for anyone who
isn't Todd). Still open: root-password policy for published masters.

## 2026-07-11: One active user per machine; switching it requires the password

The launcher login model, settled after the Users panel shipped (design
in HELIOS_USER_MANAGEMENT.md, decision #5):

**Each machine has exactly one "active user"** (`machine.user` plus the
per-machine telnet Keychain slot), and every launcher logs in as it until
it's switched. Switching is a first-class Users-panel action ("Set
Active..."): pick an account, prove you know its password, and the
account is adopted via the same `adoptMachineLogin` path the add-sheet
checkbox and the first-run flow use. The proof is host-side --
`UserAdmin.verifyPassword` reads the guest's hash-bearing file (shadow /
passwd / master.passwd per OS) over Helios as root, re-hashes the entered
password with the stored salt, and compares. Cleartext never crosses the
wire; a wrong password changes nothing anywhere. Locked hash fields
(`*`, `*LK*`, `NP`) never verify, which keeps `template` out. Two hash
formats are spoken: classic DES (what UserAdmin writes on all three
guests) and NetBSD sha1crypt (what the installer's passwd(1) wrote for
the NetBSD image's pre-existing accounts; ported from
lib/libcrypt/crypt-sha1.c after tvernon failed to verify on day one,
pinned against vectors minted by the guest's own pwhash(1)). Unknown
modular-crypt formats throw an honest unsupported-hash error rather
than reporting a false "wrong password".

Rejected: **per-launcher user fields** (multiplies Keychain slots and
launcher-editor UI for a need only multi-account users have; can return
later as an optional override falling back to the machine default) and
**ask-at-launch** (a credentials prompt per click un-invents one-click
launchers).

Related call: the panel header now states that administration itself runs
as root over the admin connection. It's unorthodox that the user never
selects root to do admin, so the UI says it out loud instead of leaving
it implicit -- the active user is only about what launchers log in as,
not about what admin runs as.

## 2026-07-11: Add-user learns the box's conventions; templates live app-side

Todd's field test on ipc (a real IPC over Helios) broke the template
assumption within a day of shipping: `cp -r /home/template` failed
because real hardware never got the convergence staging. The failure was
clean (pre-commit, no record written -- the ordering design held), but
the fix is a rethink, proposed by Todd and built same day (mechanics in
HELIOS_USER_MANAGEMENT.md, decision #6):

**The curated dotfiles are embedded in the app** (byte-exact base64 of
SPARCplug guest-config/dot.{cshrc,login,profile}; a literal ESC/BEL in
the cshrc prompt block rules out string literals) and written into the
new home over the existing write_file verb. The guest template account
is now vestigial everywhere -- strip it from published masters at E1.

**The account's shape is derived from the box, not assumed**:
`planAddUser` reads passwd + group and probes for tcsh (read-only),
then derives uid (first free >= 1001), gid (most common human gid,
system gids < 10 never count -- ipc's real passwd had a user parked in
gid 1/daemon; fallback users -> staff -> honest refusal), home parent
(where the box's humans actually live: /home2 on ipc; ties prefer
/home), and shell (tcsh if present, else /bin/csh). The Add sheet
previews the plan before anything commits, and the previewed plan is
the one that runs. The delete rm-guard accepts the same learned parents
and no others.

**No OS re-validation at add time** (Todd's pushback, accepted): the
Users chip already gates on the agent answering + a known OS; probing
uname again would re-litigate established knowledge.

Rejected along the way: a guest-side degradation ladder (probe for the
template, fall back to skel dirs -- 4.1.4 has none, and it keeps the
staging on the guest where real boxes can't be trusted to have it).

---

## 2026-07-12: Clock admin sets guest time from the Mac; 4.1.4 year changes gate on a live Y2K probe

**Context.** The fleet's clocks drift (Mostek TOD chips, no NTP anywhere),
and SunOS 4.1.4 has a trap: the stock `/bin/date` mis-parses a year
argument (Sun BugId 1086103) and writes a corrupt year to the TOD chip --
the box then won't boot, and recovery is booting install media just to
re-enter the time. Sun's fix is patch 105143-03 (deployed to Todd's whole
4.1.4 fleet + the VM image 2026-07-12, originals kept as `date.FCS`;
patches staged in Dropbox SPARCplug/patches). The public app can't assume
a patched guest.

**Decision.** A per-machine Clock admin agent (Overview → Helios Admin
Agents → Clock): shows the machine's clock against the Mac's (skew from
`sysinfo.time`, plain English) and sets it as root over Helios, with the
Mac's NTP-true clock as the reference.

- **The normal set never carries a year.** BSD date parses its digit
  string right-to-left, so the 8-digit `date -u mmddhhmm.ss` form can't
  touch the year field even on a stock 4.1.4 date. Field-proven on the
  real fleet (including two reboots on ipx after year-sets).
- **A year change on 4.1.4 gates on a live probe of the box's own date:**
  `date '+%Y'` prints a 4-digit year only on a Y2K-patched date (the %Y
  fix and the set-year fix shipped in the same patch); stock date answers
  "bad format character - Y". Probe passes → normal Set Clock. Probe
  fails (or is inconclusive -- fail closed) → the button becomes **Force
  Set** behind an explicit warning that spells out the unbootable risk
  and names the patch (Todd's call: the human owns the gamble, the app
  never silently takes it).
- Solaris 2.6 / NetBSD have no trap; they take the year form directly
  (SVR4 `mmddHHMMccyy` suffix grammar vs BSD year-first). Every set runs
  in UTC (`-u`) so guest TZ config can't skew it, a year set is always
  followed by the precise no-year set, and every sync ends with a `date
  -u` read-back verified against the Mac (15s tolerance).
- Each set/verify is its own Helios request -- a compound set+read once
  wedged a NetBSD guest.

**Rejected:** rdate/NTP cron jobs on the guests (guest-side moving parts,
and anything in rc-file reach can hang a boot when the network's away --
the app-side button has no boot-path footprint at all); checksum-matching
`/bin/date` against known patched sums as the gate (the functional probe
recognizes any Y2K-capable date, not just the one binary we shipped).

Core: `ClockAdmin.swift` (+15 tests, suite 1570). UI: `ClockPanelView` /
`ClockWindowController`, gated like Users (agent answering + known OS).

---

## 2026-07-14: Change… is tiered by capability; Settings stops editing the user

**Context.** The 2026-07-13 identity-first Overview put the active user
front and center, but changing it still depended on an invisible
condition: the Users panel needs the Helios agent, so on an agent-less
box (real hardware that never got heliosAgent) the Change… button was
permanently dead and the only editor was the Settings form's free-typed
User field -- on the second page, with no password proof, and a second
writable copy of the most consequential per-machine fact.

**Decision.** The Overview is the one place the active user changes, and
what "change" means degrades with what the box supports:

- **Agent answering** (emulated ready / external prober-up): Change…
  opens the Users panel, exactly as before -- hash-verified Set Active,
  add/delete, the works.
- **External box, no agent** (helios port refused, or first probe still
  pending): Change… opens a lightweight **Change Login** sheet --
  username + password, proven by *actually logging in over the box's own
  telnetd* (`TelnetLauncher` probe mode: reach a shell, run nothing,
  exit) before `adoptMachineLogin` touches anything. Same "prove you
  know the account's password" doctrine, different proof backend per
  capability tier -- the same shape every admin verb has had since
  2026-07-07.
- **Agent exists but can't serve** (emulated not running, agent
  unauthorized, box unreachable): Change… stays dead and the tooltip
  says why. Deliberate: where the full mechanism exists, the weak one
  isn't offered as a bypass.

The Settings User field is now **declare at birth, prove to change**:
free-typed only while the machine has no user yet; once one is set it
renders read-only with a caption pointing at the Overview. Machine
creation and the first-run flow are unchanged (declaring the first login
needs no proof -- there's nothing to protect yet).

**Also fixed while wiring it** (surfaced by the probe's tests):
`adoptMachineLogin` now updates a cleartext `machine.password` when one
is set (it used to leave the OLD account's password winning over the
fresh Keychain entry at launch time); `TelnetLauncher` treats a
`.waiting` NWConnection (refused/unreachable connect) as failure instead
of hanging with no timeout armed; and `looksLikeShellPrompt` splits on
real newlines -- Swift's `"\r\n"` is one grapheme, so the old
`split(separator: "\n")` never broke CRLF telnetd lines and the
bracket-prompt detection could only ever fire when an explicit
`shellPrompt` needle saved it.

**Rejected:** keeping the Settings field writable next to the Overview
editor (two writable copies is how they drift); offering the telnet
proof as a fallback when a known agent is merely down (invites
side-stepping the panel); gating agent-less changes on nothing (a wrong
password in the Keychain slot breaks every launcher -- the proof is the
point).

Core: `TelnetLauncher.loginProbe` (+3 tests incl. a scripted fake
telnetd; suite 1573). UI: `ChangeLoginSheet` in MachinesWindowView,
tiered tooltips, `MachineRow.canChangeLogin`. SHORTCUTS: proof channel
is telnet-only for now.

**Same-day addendum (the nuc).** Todd's Linux NUC broke both edges at
once: it firewall-DROPs the helios port (so the TCP aliveness oracle
reads "unreachable" -- the REFUSED-proves-alive assumption is a Sun-fleet
fact, not a Linux fact) and it runs only sshd (so the telnet proof could
never verify). Two changes, ratified same day:

- **The proof follows the machine's transport.** ssh → an
  `SSHLauncher.loginProbe` BatchMode key check as the typed user (remote
  command `true`, exit 0 = proven); the sheet drops its password field
  because there's nothing a password would protect -- ssh launchers are
  keys-only, so "the key logs in as that user" is the exact trust level
  they run at. telnet/helios transports keep the live telnet login.
  `adoptMachineLogin` takes an optional password now: the ssh path
  adopts the user and touches no stored credential.
- **The gate widened to "the panel can't serve it".** Change… opens the
  sheet on ANY external state except panel-available and unauthorized --
  including "unreachable", because the helios dot is blind to
  firewall-DROP boxes and the login attempt is its own truth. The
  unauthorized carve-out stands (an agent exists; fix the secret).

Residue in SHORTCUTS: helios-transport boxes still prove over telnet,
and a DROP-firewalled box's dot still undersells it ("unreachable"
while ssh works); the honest fix is folding a transport-port TCP check
into the prober's aliveness verdict. Suite 1574.

**Next-day addendum (2026-07-15): unreachable boxes get an explicit
Save Without Checking hatch.** Field experience (ipx powered off): the
proof-first rule made a offline box's login permanently uneditable, and
the failure surfaced as raw NWError text ("-65554 NoSuchRecord"). Two
changes, same doctrine. (1) Probe failures now split into "the box
answered and REJECTED the login" (authoritative -- retype is the only
path, exactly as before) vs "the proof couldn't run" (name didn't
resolve, nothing answering, conversation died). Only the second reveals
the warned escape hatch: the sheet's Change button relabels to **Change
Without Checking** and adopts as-is (one affirmative button with two
meanings, Todd's call -- a separate third button read as a duplicate of
Change). The clock panel's Force Set shape: when the honest path is
gone the override is explicit, never silent. The rejected alternative from the main entry ("gating
agent-less changes on nothing") stays rejected; this hatch only exists
where no proof is POSSIBLE, and the warning says what a wrong login
costs (launchers fail to sign in until corrected). (2) The unreachable
message is now plain English naming the likely cause (powered off / not
on the network; refused; no answer) instead of NWError vocabulary. Also
the Overview's Active User line now shows fixed-width dots after the
username when a password is on file (existence only, never length --
cleartext field or the telnet Keychain slot).

**Next-day addendum (2026-07-15): the Settings User field is gone
entirely, and the Connection section with it.** The declare-at-birth
carve-out turned out to be redundant too: a fresh VM declares its first
login through the FirstLogin window (offered after image download,
re-offered on every boot while user-less), and a fresh external box
through the Change Login sheet (its gate already covers never-probed
boxes) -- so Settings never needs to write `machine.user` at all, and
the read-only row was just a second place to look. With the User row
gone, Connection held only Host, which moved up into the Machine
section (an external host's address is identity anyway). Settings'
`commit()` now adopts the live `user` (and `password`, unless this form
actually edited it -- adoptMachineLogin updates both on a switch) so a
draft that sat open through an Overview user switch can't write the old
account back; that stale-write hazard predated this change but the
invisible field made it worth closing now.

## 2026-07-15: Adding a machine is a wizard; nothing commits until Create

**Decision:** The Machines window's + button opens an Add Machine wizard
(`AddMachineWizardView`) -- the one and only add path -- and the machine
doesn't touch the registry until the wizard's Create. The name moved to
the detail header the same day (a plain-style field that commits straight
to the registry on Return / focus loss; Settings adopts the live name at
commit and has no Name row), and new external machines default to telnet
transport, not helios.

**Why:** Todd's field test adding a powered-off external box surfaced
the whole birth story at once. (1) Integrating a machine meant visiting
every surface -- name in the header, host + OS on Settings, user via
Change Login on Overview, an xterm launcher on Launchers -- fine if you
already know the app, hopeless if you don't. (2) The old +-creates-a-
"New Machine"-stub design made a zombie: the Settings draft refused to
commit while the host field was empty (canCommit's external-host gate),
so a typed name silently reverted when you left the pane. Creating
nothing until the wizard finishes kills the zombie class outright --
Cancel leaves no residue. (3) A just-added box has never had an agent
found on it, so helios-by-default was a lie; every vintage box can at
least telnet. (The persisted-JSON convention is untouched: absent
transport still decodes as helios, which is what the bundled fixtures
mean.)

**Shape:** External hosts get the full walk: name -> host + OS -> login
(proved with the same probe as Change Login via a new endpoint-based
`onProbeLoginEndpoint` -- the machine has no registry id yet -- with the
same authoritative-rejection vs continue-without-checking split) -> a
pre-filled xterm launcher (bare `xterm`; the per-OS xBinDirs already put
the X program folders on the PATH) -> summary/Create. Emulated VMs
establish ONE thing fast -- hooking up an existing disk image (picker +
GuestOSDetector + image-claim check) vs creating a new machine from a
downloaded starter image (OS pick; download kicks off right after
Create) -- and get out; FirstLogin and the Download choreography own the
rest. Telnet passwords go to the launcher-read Keychain slot
(user@host:port), never machines.json.

**Rejected:** a modal name prompt on + (fixes only birth, not the tab
scatter); promoting the Machine section onto Overview (unwinds the
2026-07-09 operate/configure tab split); keeping a quick-add stub path
alongside the wizard (two add paths, and the stub is the zombie).

---

## 2026-07-15: Beta hosting is GitHub on both sides; published root password rotates at publish

Three calls from the beta-planning session (the full sequencing lives in
BETA_PLAN.md; Todd confirmed the shapes same day). The premise: everything
left before seeding friends is gated on Todd testing like a stranger, which
needs gold images and gold app builds downloadable from real hosting.

**Images move to GitHub** (reverses the 2026-07-10 "catalog lives on
macxserver.com" entry -- that hosting was never uploaded, so nothing real
moves). New public repo `toddvernon/macxserver-images`: `catalog.json` is
IN the repo, fetched via the raw URL (stable across image releases,
diffable history for free); the ~250 MB gzipped qcow2 payloads are release
assets, one tag per published image set (`v2026.07`, ...), 2 GB/file
ceiling and free egress. Public because the app fetches anonymously; same
distribution posture as the oldsilicon.com ZuluSCSI copies.
`ImageCatalog.defaultURL` now pins
`https://raw.githubusercontent.com/toddvernon/macxserver-images/main/catalog.json`;
`SPARCPLUG_CATALOG_URL` stays the dev override. `build-catalog.sh` grows
the matching BASE_URL + upload tail (SPARCplug side, phase 1).

**Beta app builds go to a new private repo** `toddvernon/macxserver-beta`,
NOT the public MacXServer releases page -- half-tested 0.9.x builds
shouldn't be a visitor's first impression, and inviting a friend as a
collaborator hands them Releases and the Issues tab (the feedback channel)
in one gesture. `release.sh` grows a `--beta` mode (phase 2): repo
override + skip the Hugo site bump/deploy tail, which must never run for
a beta cut.

**Published masters get a fresh documented root password at publish prep**
(closes HELIOS_USER_MANAGEMENT decision 3 for beta). Rotate at publish,
print it on the download/quickstart page: the VMs are loopback-bound
(2026-07-09), the exposure story is local-Mac, and a documented root
password is a feature for the tinkerer audience. Folding a
root-password-set step into the first-run wizard remains open for the
phase-3 wizard reshape, deliberately not a gate now.

**Deferred, not decided:** the images-directory wizard step (whether the
user picks where images land, or the App Support default stays fixed) --
phase 3 will decide from testing.

---

## 2026-07-16: The bundled-machine install is a wizard; the in-window bubble flow is retired

Supersedes the "first run is an in-window guided flow" half of the
2026-07-10 entry. That call predated the Add Machine wizard, and the wizard
won in the field (Todd, field-testing 2026-07-15: "that turned out really
good"): commit-nothing-until-the-end, no half-configured state on Cancel,
every question asked once in walk order.

**Shape (built same day):** An imageless machine with a known OS shows a
**hero pane** as its entire Overview -- marketing copy ("a complete vintage
Sun workstation... emulated right here on your Mac") + one prominent
"Install a Bootable Starter Disk Image..." button + a quiet
existing-image escape. The button opens `InstallStarterWizardView`:
location -> login -> network -> summary/Install & Boot.

- **Location** asks where images live (resolves the deferred D4 from
  2026-07-15): prefilled with the effective directory, persists as ONE
  global preference (`images.directory`), stored only when it differs from
  the App Support default so an untouched prefill tracks a future default
  move. Filenames stay derived, never user-chosen.
- **Login** is the old "one more thing" panel as a step (same username
  rules, same 8-char caption); the wizard collects it BEFORE the download,
  so completion boots straight into the deferred-apply pipeline with no
  post-download popup.
- **Network** defaults to "built-in, nothing to configure" and never
  touches the guest; the explicit alternative writes `nameserver <ip>` to
  /etc/resolv.conf in the same onReady window as the account creation.
  DNS failure is soft (login is the product; DNS is a preference).
- **Summary is the confirm** -- the wizard path skips the old NSAlert
  size-confirm sheet; legacy paths (welcome window, + wizard's
  download-starter fork) keep it and keep the post-download FirstLogin
  panel.

**Retired:** the first-run bubble, the blue-prominent Download button, and
`MachinesModel.isFirstRun` (the hero pane is per-machine state-derived, so
the "honestly comes back if images are deleted" property survives).
Credentials stashed by the wizard are cleared on catalog failure, download
failure, and cancel -- a pending login must never outlive the install that
collected it.

---

## 2026-07-26: Reserved usernames ride the catalog, not a hardcoded list

The install wizard's typing-time username check now validates against the
ACTUAL account list of the catalog image: `strip-release.sh` captures the
surviving /etc/passwd names to `<os>-release.accounts` right after the
publish surgery (a live helios is already talking to the guest, so the
capture is free), and `build-catalog.sh` bakes them into each catalog
entry as `reservedUsernames`. The wizard fetches the catalog when it
opens and passes the entry's list into `UserAdmin.usernameProblem` via
its new `reserved:` override.

The static `UserAdmin.reservedNames` list is trimmed to stock system
accounts plus our `template` plumbing name -- `tvernon` is out -- and
survives only as the fallback (older catalog without the field, fetch
failure, and the non-wizard surfaces). `addUser`'s live duplicate check
against the guest's real passwd stays the apply-time authority
everywhere.

**Why:** the hand-maintained list went stale the moment the images
changed, in both directions. Stripped images no longer carry tvernon, so
the "is a system account on this machine" refusal became a lie there
(Todd hit exactly this in wizard testing); meanwhile fred and synology
were never listed, so on gold-based images they still hit the opaque
apply-time wall the list existed to prevent. We build these images -- the
honest reserved list is the image's own passwd, captured when it's
authoritative.

**Rejected:** dropping typing-time validation entirely and leaning on the
live check alone. The wizard collects the username before the 250 MB
download and the multi-minute first boot; the collision would surface as
an error alert minutes later instead of red text under the field, which
is the worst possible first-run moment for a stranger.

---

## Decisions still to make

These are open questions to resolve as the project progresses. Will become entries when decided.

- Whether to support multiple simultaneous client connections in the X server v1 (yes, but worth flagging that the auth and resource ID allocation per connection is a real piece of work).
- Whether the rendering backend is Core Graphics, Metal, or a switchable abstraction. Leaning Core Graphics first, Metal as optimization.
- Whether cursor rendering goes through the X cursor font (boring, easy) or substitutes modern crisp cursors (more interesting, more work). `SERVER_RESOLUTION_SCALING_AND_FONTS.md` leans toward NSCursor substitution but that's not yet a hard commitment.
- **Whether and how to re-add CDE support** (retired 2026-05-18). The retirement was correct given what we knew: the wedge that drove the original 2026-05-10 impersonation was a `MATCH_SELECT`-time bug in our own server, and SS2-with-mwm publishes none of the CDE-flavored signals we were faking. But "be SS2 with mwm" is a deliberately less-polished position than "be SS2 with CDE": dt-apps fall back to compiled-in Motif defaults (small `fixed` font, no Delphinium-blue widget theme, no inter-app messaging via ToolTalk). If we ever want the polished CDE look on macOS, the right path is NOT to bring back the 2026-05-10 hardcoded impersonation. Instead it's three correctness-first pieces, in order: (1) fix the per-session vs server-global property scoping bug (see SHORTCUTS), without which no CDE service can register its presence durably; (2) implement a real Xrm-aware `RESOURCE_MANAGER` publish driven by a config file or settings UI (the resource-editor idea Todd raised 2026-05-18), so we can choose to advertise CDE-flavored XLFDs + palette without hardcoding them in the server source; (3) make the customization-daemon impersonation runtime-generated from the configured palette rather than from captured-bytes-from-u5. ToolTalk support is intentionally NOT on this list — implementing `ttsession` on the Mac is huge scope for a feature the project doesn't need (cross-app file-open messaging between dt-apps), and `-standAlone` modes exist for the apps that depend on it (verified dtpad works in standAlone against swiftx 2026-05-18; dticon has no documented bypass and is the casualty).
