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

## Decisions still to make

These are open questions to resolve as the project progresses. Will become entries when decided.

- Whether to support multiple simultaneous client connections in the X server v1 (yes, but worth flagging that the auth and resource ID allocation per connection is a real piece of work).
- Whether the rendering backend is Core Graphics, Metal, or a switchable abstraction. Leaning Core Graphics first, Metal as optimization.
- Whether cursor rendering goes through the X cursor font (boring, easy) or substitutes modern crisp cursors (more interesting, more work). `SERVER_RESOLUTION_SCALING_AND_FONTS.md` leans toward NSCursor substitution but that's not yet a hard commitment.
- **Whether and how to re-add CDE support** (retired 2026-05-18). The retirement was correct given what we knew: the wedge that drove the original 2026-05-10 impersonation was a `MATCH_SELECT`-time bug in our own server, and SS2-with-mwm publishes none of the CDE-flavored signals we were faking. But "be SS2 with mwm" is a deliberately less-polished position than "be SS2 with CDE": dt-apps fall back to compiled-in Motif defaults (small `fixed` font, no Delphinium-blue widget theme, no inter-app messaging via ToolTalk). If we ever want the polished CDE look on macOS, the right path is NOT to bring back the 2026-05-10 hardcoded impersonation. Instead it's three correctness-first pieces, in order: (1) fix the per-session vs server-global property scoping bug (see SHORTCUTS), without which no CDE service can register its presence durably; (2) implement a real Xrm-aware `RESOURCE_MANAGER` publish driven by a config file or settings UI (the resource-editor idea Todd raised 2026-05-18), so we can choose to advertise CDE-flavored XLFDs + palette without hardcoding them in the server source; (3) make the customization-daemon impersonation runtime-generated from the configured palette rather than from captured-bytes-from-u5. ToolTalk support is intentionally NOT on this list — implementing `ttsession` on the Mac is huge scope for a feature the project doesn't need (cross-app file-open messaging between dt-apps), and `-standAlone` modes exist for the apps that depend on it (verified dtpad works in standAlone against swiftx 2026-05-18; dticon has no documented bypass and is the casualty).
