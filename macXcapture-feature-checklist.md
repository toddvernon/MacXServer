# macXcapture Feature Checklist

## Why This Document Exists

macXcapture is a transparent X11 proxy that captures the wire protocol to a binary `.xtap` file,
with a viewer that decodes frames into a syntax-highlighted form. The thesis of the project is that
X11 has never had a real `pcap` equivalent: a capture format and tooling pair that makes
protocol-level debugging routine, shareable, and archivable.

Wireshark's X dissector exists but is incomplete on the extension surface and isn't
workflow-integrated for X work. `xtruss` is good for tracing a single client live but doesn't
produce shareable artifacts. `xscope` and `xmon` are ancient and barely maintained. None of these
cover the modern extension surface — RENDER, XKB, XInput2, RandR, DAMAGE, COMPOSITE, XFIXES, Present
— well enough to be the standard tool.

The opportunity is to become that standard tool. If `.xtap` files become something X developers
exchange the way network engineers exchange `.pcap` files — attached to bug reports, used in
regression tests, archived against future debugging — then macXcapture stops being "a useful tool"
and becomes infrastructure the community standardizes on. That's a substantially larger outcome than
the obvious framing of "a debugging utility for macXserver."

This document is a scorecard. It's meant to give an honest inventory of where macXcapture is today
against the full value chain of X11 protocol capture and analysis, and to surface where the
highest-leverage gaps are. For each item below, mark **Yes / Partial / No / N/A**, and back each
answer with a concrete code reference (file:line or symbol name) so a third party can verify.
"Partial" answers should specify what's missing to reach Yes.

Items that score No today but rank high on potential audience impact — especially items in §8
(Replay), §6 (Analysis Aids), and §4 (Extension Coverage) — are the ones most likely to turn
macXcapture from a useful tool into infrastructure.

---

## 1. Core Capture

- [x] Transparent TCP proxy (listens on `:N`, forwards to real display) — **Yes**.
      `Sources/SwiftXCaptureCore/Proxy.swift` `Proxy.start()` + `Proxy.run()`. Two GCD `pump()`
      directions, in-process tee to `CaptureSink`.
- [ ] Transparent Unix socket proxy (`/tmp/.X11-unix/XN`) — **No**. `Proxy.swift:115` hardcodes
      `AF_INET` + `SOCK_STREAM`. No `sockaddr_un` anywhere. Would require a separate listen path.
- [~] Handles X11 connection setup (byte order, auth, server reply) — **Partial**. Setup is
      **decoded** end-to-end (`Sources/Framer/Setup/SetupRequest.swift`, `SetupReply.swift`,
      `ChronoDumper.formatSetupRequest/Reply`). The proxy itself is a dumb byte-pump — it does not
      interpret setup, just forwards. Byte order is sniffed downstream by the dumper from the first
      c2s byte.
- [~] Supports MIT-MAGIC-COOKIE-1 authentication passthrough — **Partial**. Forwarded by virtue of
      the proxy being byte-faithful — `RecentRequestSink.swift:117` parses
      `authProtocolName`/`authProtocolData` for length math, but there's no validation, no awareness
      of MIT-MAGIC-COOKIE-1 specifically, and it's an explicit non-goal per
      `PRODUCT_1_CAPTURE.md:98`.
- [~] Supports XDM-AUTHORIZATION-1 passthrough — **Partial**. Same as above: forwarded as opaque
      bytes; no protocol-specific handling.
- [~] Handles abrupt client/server disconnects without losing buffered frames — **Partial**.
      `Recorder.swift:105` buffers all frames in RAM and only writes at `finalize()`. Clean
      disconnect via EOF reaches finalize (`Proxy.pump` returns on `n <= 0`). SIGKILL or crash
      before finalize loses everything — explicitly documented at `Recorder.swift:111`.
- [~] Survives partial reads/writes on either side (proper framing recovery) — **Partial**.
      `Proxy.pump()` is byte-level, so partial reads are fine. As of 2026-05-30 it now mirrors the
      server-side `Listener.swift` read path: EINTR / EAGAIN / EWOULDBLOCK retry the loop, anything
      else logs `proxy: read/write failed errno=N (text)` to stderr before tearing down. The decoder
      side (`ChronoDumper.StreamWalker`) buffers and only extracts when a full message is present.
      The remaining framing concern is at `Recorder.record()` which takes raw chunks with no framing
      — replay reassembles by length-prefix per frame, so a torn write in the middle of a request is
      preserved as torn.
- [ ] Multi-client capture in a single session (multiple clients through one proxy) — **No**.
      `Proxy.run()` does a single `acceptConnection()` then closes the listen socket
      (`Proxy.swift:48`). One client per `Proxy` instance, period. Multiple proxies = multiple OS
      processes / output files.
- [~] Concurrent independent capture sessions (multiple proxies, multiple files) — **Partial**. The
      library supports it (`SessionCapture.swift` is per-session, used by the server-side tee in
      MacXServer). But the GUI Record screen and CLI `--listen` both run one proxy at a time.
      Server-side `--capture` does fan out per-client to per-file `.xtap`s.
- [x] Configurable listen address and forward target — **Yes**. `CLI.parseCapture` +
      `CLI.parseHostPort` (`Sources/SwiftXCaptureCore/CLI.swift:60,156`). Host:port for both sides,
      `--listen :6000` shorthand binds 0.0.0.0.
- [~] SSH-tunnel friendly (works behind `ssh -X` style forwarding) — **Partial**. Works if the user
      sets up the SSH tunnel themselves (point `--forward` at the local end of the tunnel). The
      proxy has no awareness of SSH; doesn't speak the `.X11-unix` socket that `ssh -X` typically
      lands on.
- [~] IPv4 and IPv6 support — **Partial**. IPv4 only. `Proxy.swift:115` and `Replay.swift:145` both
      hardcode `AF_INET`. `getaddrinfo` is given `AF_INET` hints. No IPv6.

## 2. Capture File Format (.xtap)

- [~] Documented binary format with public spec — **Partial**. Documented inside the repo at
      `PRODUCT_1_CAPTURE.md:190` ("Capture file format" section: 8-byte header + 13-byte per-frame
      header). There's no standalone, audience-facing spec document — it's mixed in with product
      narrative. Closing this to Yes would mean a stable `.xtap-format-v1.md` file at the top level.
- [x] Magic bytes for file type identification — **Yes**.
      `Sources/SwiftXCaptureCore/CaptureFile.swift:2` — `"XTAP"` (4 bytes).
- [~] Major/minor version field with defined compatibility rules — **Partial**. Single `version:
      UInt8 = 1` field (`CaptureFile.swift:3`); `CaptureReader` rejects anything other than 1
      (`CaptureReader.swift:32`). No major/minor split, no documented compat rules, 3 reserved bytes
      in the header for future use but no policy.
- [ ] Endianness flag in header — **No**. The `.xtap` container is always little-endian
      (`PRODUCT_1_CAPTURE.md:209`); the X11 payload's endianness is sniffed from the SetupRequest's
      first byte at decode time (`ChronoDumper.swift:16`). No flag in the file header records it.
- [~] Capture metadata block (timestamp, hostnames, capture tool version, OS) — **Partial**. Stored
      in a **sidecar** `.xtap.json` (`Recorder.swift:137` `Metadata`: `recordedAt`, `toolVersion`,
      `listen`, `forward`, `durationNs`, byte counts). Not in the binary file, no hostname or OS
      fields. The sidecar can get separated from the .xtap on copy.
- [x] Per-frame timestamps (microsecond or nanosecond resolution) — **Yes**. `Recorder.swift:86`
      writes `DispatchTime.now().uptimeNanoseconds` as a UInt64 nanosecond delta from session start.
      `CaptureReader.swift:44` reads it back.
- [x] Direction tag per frame (client→server, server→client) — **Yes**. `Direction` enum UInt8
      (`Sources/SwiftXCaptureCore/Direction.swift`) written as first byte of each frame header
      (`Recorder.swift:94`, `CaptureReader.swift:40`).
- [~] Captured QueryExtension exchanges stored or indexed for opcode resolution — **Partial**.
      Stored implicitly — the QueryExtension request and reply are just frames in the stream.
      `ChronoDumper.ChronoContext.extensionMajorToName` and `extensionFirstEventToName` are rebuilt
      by re-walking the file. No index, no precomputed mapping.
- [ ] Extension opcode mapping embedded in file (not derived at view time) — **No**. Always
      re-derived by walking QueryExtension replies (`ChronoDumper.swift:584`). A capture truncated
      before the QueryExtension reply leaves later extension frames undecodable.
- [x] Frame length-prefixing for safe forward-skipping — **Yes**. Each frame header has a `len:
      UInt32` LE (`Recorder.swift:96`, parsed in `CaptureReader.swift:45`). 13-byte frame header =
      dir(1) + ts(8) + len(4).
- [ ] Optional compression (gzip, zstd, or none) declared in header — **No**. Not implemented; raw
      bytes only.
- [ ] Append-safe (can resume captures, or merge files) — **No**. `Recorder.finalize()` does a
      single `createFile` overwrite (`Recorder.swift:113`). No append codepath, no merge tool.
- [ ] Checksum or integrity field per frame or file — **No**. No CRC anywhere.
- [ ] Indexable for fast seek (jump to frame N without scanning from frame 0) — **No**.
      `CaptureReader.parse` walks linearly from offset 0 building the entire `[CaptureFrame]` array.

## 3. Protocol Decoding — Core X11

- [x] All core requests decoded with field names — **Yes**. 120 of 120 core opcodes have typed Swift
      structs + dumper lines. `Sources/Framer/Requests/Request.swift` (enum) +
      `Sources/SwiftXCaptureCore/ChronoDumper.swift:291` `formatRequest`. Per
      `OPCODE_STATUS.md:201`, Phase 1 closed the 16 audited gaps 2026-05-29.
- [~] All core replies decoded — **Partial**. All reply-producing opcodes have typed reply
      **decoders** (`Sources/Framer/Replies/` — 39 files). The dumper's reply-body **printing** is
      rich for 5 opcodes (InternAtom, QueryExtension, QueryFont, AllocColor, AllocNamedColor at
      `ChronoDumper.swift:567-614`) and minimal (just `Reply (opName)`) for ~30 others. Per
      `OPCODE_STATUS.md:207-213` — Phase 5 polish enriches the rest.
- [x] All core events decoded — **Yes**. 33 of 33 core events have typed decoders.
      `Sources/Framer/Events/` covers Input/Window/Selection/Misc + Phase1Events.swift (the 5 added
      2026-05-30). Dumper detail at `ChronoDumper.swift:637-696`. Per `OPCODE_STATUS.md:204`.
- [x] All core errors decoded — **Yes**. `Sources/Framer/Wire/XError.swift` (struct) +
      `ChronoDumper.swift:706` paints `errorName` from `Sources/Framer/OpcodeNames.swift`. Phase 1
      reply-body work covers all 16 core error codes.
- [x] Atom values resolved to names (tracking InternAtom and GetAtomName) — **Yes**.
      `ChronoContext.atomToName` populated from InternAtom replies (`ChronoDumper.swift:577`);
      `atomDisplay` at `ChronoDumper.swift:227` resolves to predefined atoms first
      (`Sources/Framer/PredefinedAtoms.swift`), then session-interned, then hex. GetAtomName reply
      harvesting is **not** implemented (only the request side prints the atom number).
- [~] Resource IDs (windows, pixmaps, GCs, fonts, cursors, colormaps) tracked across the session —
      **Partial** (as of 2026-05-30). The `LandmarkDetector`
      (`Sources/SwiftXCaptureCore/LandmarkDetector.swift`) tracks **windows** session-wide: the
      full parent map for every CreateWindow, a `topLevels` table keyed by wid carrying name + size
      + mapped state, plus `windowSizes`, `mappedWindows`, and `transientFor` maps. This is what
      enables the landmark click-contextualization to walk up from a child to its named top-level
      ancestor. Pixmaps / GCs / fonts / cursors / colormaps are still **not** tracked. The window
      data is also internal to the detector — there's no public registry exposed to other passes.
- [ ] Resource creation lineage shown (this Pixmap was created at frame N) — **No**. Not implemented
      anywhere.
- [ ] Resource lifetime tracked (freed at frame M, used-after-free flagged) — **No**. Not
      implemented anywhere.
- [x] Keysym values decoded to symbolic names — **Yes** (as of 2026-05-31). 1224-entry table
      generated from `reference/X11R6/xc/include/keysymdef.h` lives at
      `Sources/SwiftXCaptureCore/Keysyms.generated.swift` (regen script
      `Tools/regen_keysyms.sh`). Public API `keysymName(_:)` in `Keysyms.swift`. `ChronoContext`
      now tracks a session keymap, populated from `GetKeyboardMapping` replies and
      `ChangeKeyboardMapping` requests, so `KeyPress`/`KeyRelease` events render as
      `L (keycode=92)` instead of `keycode=92`. `ChangeKeyboardMapping`'s payload now prints
      keysym rows inline (capped to 8 keycodes + ellipsis). Unmapped keysyms fall back to hex.
- [x] Modifier masks decoded symbolically — **Yes** (as of 2026-05-31). `modifierMaskString(_:)`
      and `grabModifierString(_:)` in `Keysyms.swift` render KEYBUTMASK bits as
      `Shift|Ctrl|Mod1|...`; `0x8000` on grab requests renders as `AnyModifier`; empty mask is
      `none`. Wired into `GrabButton`, `GrabKey`, `UngrabButton`, `UngrabKey`, and the
      `KeyPress`/`KeyRelease`/`ButtonPress`/`ButtonRelease`/`MotionNotify` state field.
- [ ] Visual and depth references resolved against the server's setup reply — **No**. SetupReply is
      decoded and dumped once (`formatSetupReply`), but the visual catalog isn't kept in
      `ChronoContext`. CreateWindow / CreateColormap / etc. print the visual id as hex with no
      lookup. Depth is shown as a raw integer.
- [~] Property values decoded with type awareness (STRING, UTF8_STRING, ATOM, CARDINAL, etc.) —
      **Partial**. The ChangeProperty request previews the data as ASCII when `format==8` and ≤64
      bytes (`previewBytes` at `ChronoDumper.swift:1014`). No type-driven decode: ATOM-valued
      properties don't show atom names, CARDINAL doesn't decode to integers, UTF8 isn't treated
      differently from STRING. GetPropertyReply body is decoded by
      `Sources/Framer/Replies/GetPropertyReply.swift` but the dumper doesn't print its data section.

## 4. Protocol Decoding — Extensions

For each: requests + replies + events + errors decoded.

- [x] BIG-REQUESTS — **Yes**. `Sources/SwiftXCaptureCore/Extensions/BigRequestsDumper.swift`,
      `Sources/Framer/Requests/BigRequests.swift`, `Sources/Framer/Replies/BigReqEnableReply.swift`.
      1 request, 1 reply, 0 events — complete per `OPCODE_STATUS.md:270`.
- [ ] XC-MISC — **No**. Not in `ExtensionDumperRegistry.builtins`. Would degrade to `XC-MISC
      opcode=N minor=M (undecoded)`.
- [x] SHAPE — **Yes**. `Sources/SwiftXCaptureCore/Extensions/ShapeDumper.swift` (reference impl for
      the registry pattern, migrated 2026-05-30). Requests + ShapeNotify event + replies in
      `Sources/Framer/Requests/ShapeRequests.swift`, `Replies/ShapeReplies.swift`,
      `Events/ShapeEvents.swift`.
- [x] MIT-SHM — **Yes**. `Sources/SwiftXCaptureCore/Extensions/ShmDumper.swift`. 6 requests, 2
      replies, 1 event. `Sources/Framer/Requests/ShmRequests.swift`, `Replies/ShmReplies.swift`,
      `Events/ShmEvents.swift`. Test coverage at
      `Tests/FramerTests/BigRequestsAndShmRoundTripTests.swift`.
- [~] XInput / XInput2 — **Partial**. **XInput v1 complete**
      (`Sources/SwiftXCaptureCore/Extensions/XInputDumper.swift` — all 35 requests + 24 replies +
      all 15 events with typed shared union codecs). **XInput2 not implemented** — would be a
      separate registry entry; XI2 listed under "Tier 2" in `OPCODE_STATUS.md:275`.
- [~] XKEYBOARD (XKB) — **Partial**. Per `OPCODE_STATUS.md:272`: all 22 core requests + 6 replies +
      all 11 events decoded with full typed payloads for GetMap/SetMap/IndicatorMap/CompatMap
      (`Sources/SwiftXCaptureCore/Extensions/XkbDumper.swift`). **GetGeometry/SetGeometry tree
      trailer and GetNames/SetNames Atom-list trailer kept raw** — deferred typed walkers, "not
      blocking OSS launch."
- [x] RENDER — **Yes**. `Sources/SwiftXCaptureCore/Extensions/RenderDumper.swift`. All 32 shipping
      requests + 4 replies. Tier A backbone + glyph stack + Tier B
      trapezoids/triangles/gradients/etc. + Tier C cursors/scale. 5 reserved holes (opcodes 3, 14,
      15, 16, 21) labeled. Per `OPCODE_STATUS.md:274`. Test coverage at
      `Tests/FramerTests/RenderRoundTripTests.swift`.
- [ ] RANDR — **No**. Listed as Tier 2 in `OPCODE_STATUS.md:275`. Not in registry; degrades to
      `RANDR opcode=N minor=M (undecoded)`.
- [ ] COMPOSITE — **No**. Tier 2. Not in registry.
- [ ] DAMAGE — **No**. Tier 2. Not in registry.
- [ ] XFIXES — **No**. Tier 2. Not in registry.
- [ ] Present — **No**. Not in registry. Modern Linux desktop extension.
- [ ] DRI3 — **No**. Not in registry.
- [ ] SYNC — **No**. Not in registry. Used by xterm + Motif on Linux; would matter for the
      modern-Linux audience.
- [ ] GLX (at least request/reply structure; opaque GL bytecode acknowledged) — **No**. Not in
      registry.
- [ ] DPMS — **No**. Not in registry.
- [ ] XTEST — **No**. Not in registry. Notable gap for anyone doing input-injection automation
      captures.
- [ ] RECORD — **No**. Not in registry.
- [ ] SECURITY — **No**. Not in registry.
- [ ] XINERAMA — **No**. Not in registry.
- [ ] XF86VidMode — **No**. Not in registry.
- [ ] DBE (Double Buffer Extension) — **No**. Not in registry.
- [ ] XKB virtual modifiers and group state shown symbolically — **No**. XKB payloads decode to
      typed structs but the dumper prints raw bytes/integers. No symbolic modifier-name or group
      decode. Would build on top of the existing XkbDumper.
- [ ] RENDER Picture/GlyphSet objects tracked across requests — **No**. RENDER requests print
      Picture/GlyphSet ids as hex — no cross-request lineage, no "GlyphSet 0x... was created at
      frame N with N glyphs."
- [ ] RENDER glyph uploads previewable (visual glyph display, not just bytes) — **No**. `AddGlyphs`
      payload bytes print as a count; no glyph image rendering in the viewer.

## 5. Viewer — Display and Navigation

- [x] Syntax-highlighted decoded frame view — **Yes**.
      `Sources/SwiftXCaptureUI/CaptureViewerPanelView.swift` + `CodeEditorView.swift` +
      `CaptureSyntaxHighlighter.swift`. Dark theme with direction-colored opcodes (cRequest green,
      cResponse blue, cError red), hex/string/seq highlighting.
- [ ] Hex dump pane synchronized with decoded view — **No**. The viewer is a single text pane of the
      chrono dump. No raw-bytes panel.
- [~] Frame list with timestamps, direction, opcode summary — **Partial**. The chrono dump **is**
      that list, rendered as text — one line per message with timestamp + direction arrow + opcode +
      key fields. But it's not a structured list view with sortable columns; no clickable rows, no
      fast jump.
- [ ] Jump to frame by number — **No**. No "go to frame N" UI. The text viewer has line numbers
      (`LineNumberGutter.swift`) but no goto-line command surfaced.
- [~] Jump to next/previous frame matching filter — **Partial** (as of 2026-05-30). Cmd-]/Cmd-[
      jump to the next/previous landmark line in the dump
      (`Sources/SwiftXCaptureUI/CaptureViewerPanelView.swift` invisible-button shortcuts +
      `CaptureEditorController.firstVisibleLine`/`jump(toLine:)`). The "filter" is fixed — landmark
      lines only — and there's no UI for arbitrary opcode / resource-id filters. Cmd-F text search
      still handles the generic case.
- [ ] Filter by opcode / extension / direction / resource ID — **No**. The dump is fully
      materialized text; no in-viewer filtering.
- [ ] Search by atom name, resource ID, or arbitrary byte pattern — **No**. Inherited NSTextView
      find works on the decoded text (so a user can find an atom name that the dumper already
      resolved), but there's no structured search and no byte-pattern search.
- [ ] Per-frame "follow this resource" navigation (show all frames touching window 0x4000003) —
      **No**. Would need a resource-tracking pass that doesn't exist.
- [ ] Timeline view (frames over time, optionally grouped by client) — **No**. `OpenModel.swift:12`
      explicitly defers this ("no phase-tree grouping and no timeline scrubber").
- [~] Side-by-side request/reply pairing for round-trip requests — **Partial** (as of 2026-05-30
      Phase 5 polish landed). `[seq=N]` is printed on both lines (`ChronoDumper.swift:282`
      `seqField`), the dumper resolves the reply's request name in parens, and the direction
      arrow on replies / XErrors is `↙` (south-west) instead of `←` so the downward component
      visually attaches each reply to the request line above it. Highlighter paints both arrows
      in the response color (`CaptureSyntaxHighlighter.swift` `reArrowIn = ←|↙`). Visually they're
      still separate lines (not a true side-by-side pane), but the linkage is unambiguous.
- [ ] Latency annotations between request and matching reply — **No**. Both lines carry timestamps
      but the delta isn't computed/shown.
- [ ] Bookmark frames within a capture — **No**. Not implemented.
- [~] Export selected frames as a new `.xtap` file — **Partial**. `CaptureViewerPanelView.swift:73`
      `saveXtap()` copies the **whole** .xtap (plus sidecar) under a new name. There's no per-frame
      selection / subset export. Export-as-Text dumps the full decoded transcript.

## 6. Viewer — Analysis Aids

- [ ] Resource leak detection (resources created but never freed) — **No**. No resource registry
      exists; can't be built without one.
- [ ] Use-after-free detection (resource referenced after FreeX) — **No**. Same — no registry. The
      protocol error highlighting (below) does paint the resulting BadFoo in red, but that's
      downstream of the actual use-after-free.
- [~] Unknown opcode flagging (extension used without QueryExtension first) — **Partial**. The
      dumper emits `Request opcode=N (untyped)` for any extension request with no prior
      QueryExtension reply (`ChronoDumper.swift:553`). The syntax highlighter doesn't treat that
      line specially — it just looks like a regular request.
- [x] Protocol error highlighting (error replies linked to causing request) — **Yes** (as of
      2026-05-30). Errors print on their own line and the syntax highlighter paints
      `Bad[A-Za-z]+` and `Error#N` in red (`CaptureSyntaxHighlighter.swift`). On top of that, the
      `LandmarkDetector` emits an explicit correlation comment immediately after each XError, e.g.
      `# BadDrawable at seq=412 from CopyArea on "Command Window"`. Resource-bearing errors
      resolve the bad id through the window hierarchy; BadValue renders the bad id as the
      offending value; extension errors get named via `extensionMajorToName` so SHAPE-major
      requests read as `SHAPE request (minor=N)` instead of bare opcode numbers. Same correlation
      fires live on the server side from `ServerSession.emitError`.
- [ ] Round-trip latency histogram — **No**. Not implemented.
- [~] Frame size statistics — **Partial**. The `summary` CLI subcommand (`Dumper.summarize`,
      `Sources/SwiftXCaptureCore/Dumper.swift:10`) reports total c2s/s2c bytes, request count by
      opcode, reply count, largest single reply. No per-frame histogram, no time-series. The GUI
      doesn't expose this view.
- [~] Most-used opcodes / extensions report — **Partial**. Same as above — `summary` lists request
      counts by opcode descending (`Dumper.swift:185`) and registered extensions with their
      major/firstEvent/firstError (`Dumper.swift:266`). CLI-only.
- [ ] Glyph cache hit/miss inference for RENDER traffic — **No**. RENDER glyph traffic is decoded as
      wire bytes only.
- [ ] Damage region overlay visualization (if COMPOSITE/DAMAGE in capture) — **No**.
      COMPOSITE/DAMAGE aren't even decoded.
- [ ] Pixmap content preview (where image data is captured) — **No**. PutImage prints byte count
      only; no decode-to-image, no rendering.
- [x] Inline narrative landmarks for structural events — **Yes** (as of 2026-05-30).
      `Sources/SwiftXCaptureCore/LandmarkDetector.swift` watches the decoded request + server-
      message stream and emits `# ...` story-form comment lines at structurally important moments:
      top-level window mapped (tagged primary / auxiliary), window identified by WM_NAME, dialog
      opened (via WM_TRANSIENT_FOR), window hidden / closed / dialog dismissed, click
      contextualized to the named ancestor and child window-size, XError correlated to its
      causing request, session-end summary with totals. All gated on the "namability rule":
      emit only if a top-level can be referenced by a name (or as a known unnamed top-level, or
      as the desktop). The same `LandmarkDetector` runs server-side in `ServerSession.dispatch`
      so the live Xcode console gets the same vocabulary as the post-mortem viewer.
      `CaptureSyntaxHighlighter` paints landmark lines in saturated yellow (`#f0c674`).
      Viewer sidebar in `CaptureViewerPanelView.swift` lists every landmark as a clickable row;
      Cmd-]/Cmd-[ jump to next / previous landmark relative to the current scroll position.

## 7. Live Mode and Streaming

- [~] Live view while proxy is capturing (tail mode) — **Partial**. The Record screen shows live
      cumulative byte counts (c2s/s2c) and a sliding window of the last 24 request opcode **names**
      via `Sources/SwiftXCaptureCore/RecentRequestSink.swift`. Not a full live decode of frames as
      they arrive — just opcode-name ticker. CLI v1 had a `--decode-stdout` flag mentioned in
      `PRODUCT_1_CAPTURE.md:164` but it doesn't appear in the current `CLI.usage`.
- [ ] Live filtering (drop frames matching filter from on-disk capture) — **No**. Not implemented.
- [ ] Configurable capture truncation (max bytes per frame) — **No**. Every byte is recorded
      verbatim; no `--snaplen` style flag.
- [ ] Configurable file rotation (size-based or time-based) — **No**. One session = one file; no
      rotation.
- [ ] Ring buffer mode (keep last N MB only) — **No**. `Recorder` buffers the entire session in RAM
      and writes at finalize (`Recorder.swift:30`). Long sessions = unbounded RAM growth.

## 8. Replay and Test

- [x] Replay capture as a synthetic client against a real X server — **Yes**. CLI:
      `Sources/SwiftXCaptureCore/Replay.swift` `Replay.run()`. GUI:
      `Sources/SwiftXCaptureCore/ReplayEngine.swift` with cancellation + progress callback, driven
      by `Sources/SwiftXCapture/ReplayView.swift`. Supports `--realtime` (paced by original
      timestamps) and `--hold` (keep connection open after C2S done). Per `PRODUCT_1_CAPTURE.md:78`,
      replay is a smoke test, not a regression harness.
- [ ] Replay capture as a synthetic server against a real client — **No**. Only client-replay. The
      S2C side is decoded but never played back. Would require a TCP listener that hands its bytes
      to the recorded S2C stream.
- [x] Diff two captures (frame-level structural diff) — **Yes**.
      `Sources/SwiftXCaptureCore/CaptureDiff.swift` `CaptureDiff.compare(pathA:pathB:)`. LCS-aligned
      per-direction comparison on ChronoDumper-formatted lines, producing `same / different / onlyA
      / onlyB` rows. Phase 5 (2026-05-30) added field-level semantic tolerance: per-stream
      `StreamMetadata` extracted from the SetupAccepted reply (resource-id base, mask, root window
      ids, root visual ids, default colormap ids) drives `normalizeIdentifiers(_:metadata:)` which
      rewrites client-allocated ids to `0xC<offset>`, root window → `0xROOT`, visual → `0xVISUAL`,
      cmap → `0xCMAP` before LCS keying. Plus `applyToleranceRules(_:)` for InternAtom reply atom
      values, QueryExtension major/firstEvent/firstError, and AllocColor / AllocNamedColor pixel
      values. Displayed lines keep the original values. Real-world impact: editres gold-vs-swiftx
      C2S `same` rows went from 27 → 118 (4.4×). Markdown rendering at `CaptureDiff.render`. Tests
      at `Tests/SwiftXCaptureCoreTests/CaptureDiffTests.swift`.
- [ ] Generate conformance test from capture (golden-file style) — **No**. No "fixture this capture
      as a regression" codepath. `Tests/SwiftXCaptureCoreTests/CorpusRoundTripTests.swift` is
      hand-written against fixed gold files; not user-facing tooling.
- [ ] Inject latency / packet loss / reordering during replay (chaos test) — **No**. Replay is
      faithful: realtime-paced or as-fast-as-possible, never lossy. No chaos knobs.
- [ ] Fuzz mode: mutate frames during proxy forward for robustness testing — **No**. Explicit
      non-goal at `PRODUCT_1_CAPTURE.md:94`: "Modifying traffic. The capture tool is a passive
      proxy."

## 9. Integration and Interop

- [x] Command-line invocation suitable for scripting — **Yes**. `Sources/SwiftXCapture/main.swift`
      dispatches `dump / summary / diff / replay / <proxy flags>` subcommands. `--no-gui` forces
      CLI. Stdin/stdout-friendly: chrono dump and summary write to stdout, info to stderr.
- [~] Exit codes meaningful for CI use — **Partial**. `main.swift` uses `exit(0)` for success,
      `exit(1)` for runtime errors, `exit(2)` for usage errors — that distinction is implemented and
      consistent. But it's not documented as a public contract, and `dump`/`summary` parse errors
      leak Swift `\(error)` text rather than structured codes.
- [ ] Export to Wireshark `.pcap` (with X dissector compatibility) for cross-tool workflows —
      **No**. Not implemented anywhere.
- [ ] Import from existing `xtruss` / `xscope` output (if feasible) — **No**. Not implemented; would
      be of dubious value (those tools emit text, not bytes).
- [ ] JSON export of decoded frames for downstream analysis tools — **No**. Only the per-capture
      `.xtap.json` sidecar (`Recorder.swift:137` `Metadata`) is JSON; it has session-level stats,
      not per-frame data.
- [x] Library form of the decoder usable independently of the viewer — **Yes**. `Sources/Framer/`
      (wire codec) and `Sources/SwiftXCaptureCore/` (file format + dumper + diff + replay) are both
      Swift libraries exported by `Package.swift:10-13`. `SwiftXCaptureCore` depends only on
      `Framer` + Foundation/Darwin; no AppKit. `SwiftXServerCore` consumes them as a separate
      target.
- [~] Bindings or FFI for Python / Swift / C++ for custom analysis scripts — **Partial**. Swift
      bindings exist by virtue of the libraries being Swift packages — any Swift project can depend
      on them. No Python / C / C++ FFI. Swift-on-Linux not supported (platforms = `.macOS(.v14)` in
      `Package.swift:7`).
- [~] Stable on-disk format suitable for archival (multi-year `.xtap` files still readable) —
      **Partial**. Format is dead simple (8-byte header + length-prefixed frames), version field
      hardcoded to 1, no removals since v1 (per `PRODUCT_1_CAPTURE.md:49`). But no formal
      compatibility promise documented, and the JSON sidecar's keys could drift silently.

## 10. Platform and Distribution

- [~] macOS native build (code-signed, notarized binary) — **Partial**. Builds as a native SwiftPM
      executable + SwiftUI app (`Package.swift` target `macxcapture`). No `Info.plist` checked in;
      no signing/notarization infrastructure (no entitlements, no signing scripts, no GitHub
      Actions). Distribution today = "`swift build` and run."
- [~] Apple Silicon and Intel binaries — **Partial**. SwiftPM produces a native-arch binary; running
      `swift build` on either arch produces a working binary for that arch. No universal binary
      build step; no shipped binaries at all.
- [x] Runs against macXserver — **Yes**. PROJECT.md context: that's the primary use case
      (`PRODUCT_1_CAPTURE.md:24-30`). `swiftx-server --capture` does server-side tee via
      `SessionCapture`.
- [x] Runs against XQuartz — **Yes**. XQuartz is a normal X server on TCP/Unix socket; `--forward
      localhost:6000` works against XQuartz the same as anything else. The proxy is byte-faithful.
- [~] Runs against remote Linux Xorg over TCP — **Partial**. Should work as a black box (proxy is
      byte-faithful). Won't **decode** Tier-2 extensions a modern Linux session uses
      (RANDR/XFIXES/DAMAGE/XINPUT2/COMPOSITE/SYNC etc. — Section 4) — frames flow through but
      display as `<ExtName> opcode=N minor=M (undecoded)`. Per `PRODUCT_1_CAPTURE.md:920`.
- [~] Runs against Xwayland over Unix socket forwarded via SSH — **Partial**. The proxy is TCP-only
      (Section 1). Works if the user sets up TCP-on-the-Mac → SSH-tunnel → unix-socket-on-Linux
      themselves. Doesn't speak `.X11-unix` directly.
- [N/A] Linux build (so capture tooling isn't macOS-locked) — **N/A**. macOS-only is a deliberate
  stance per `PRODUCT_1_CAPTURE.md:16-20` ("Cross-platform tools are the least common denominator
  ... You do need a Mac. That part is unapologetic."). `Package.swift:7` declares `.macOS(.v14)`
  only.
- [ ] Homebrew formula or cask — **No**. No `Formula/` directory, no published tap.
- [~] Standalone `.app` for the viewer — **Partial**. The GUI runs as a SwiftUI app
      (`SwiftXCaptureApp.main()` in `Sources/SwiftXCapture/main.swift:35`), but it's bundled into
      the same binary as the CLI. No separate `.app` artifact, no `.xtap` file association
      registered with Launch Services.
- [x] CLI-only mode for headless capture (server-side recording) — **Yes**. `macxcapture --no-gui`
      forces CLI. Also `swiftx-server --capture` records per-client `.xtap` files server-side via
      `SessionCapture.swift` (no GUI required) — see `PRODUCT_1_CAPTURE.md:388`.

## 11. Documentation

- [~] `.xtap` format specification document — **Partial**. The format is documented at
      `PRODUCT_1_CAPTURE.md:190` ("Capture file format" section). It's a couple of paragraphs inside
      the product doc — not a freestanding spec file. To reach Yes, lift it into a standalone
      `XTAP_FORMAT.md` (or similar) with versioning policy.
- [ ] User guide for the viewer — **No**. The Record screen has in-line wizard copy
      (`RecordView.swift` step text), but no separate user guide. No "open / browse / save"
      walkthrough.
- [ ] Cookbook of common debugging recipes — **No**. Not implemented.
- [~] Worked examples (real bugs, captured and diagnosed via macXcapture) — **Partial**. The blog
      under `blog/` has several articles that show wire-trace debugging in narrative form (e.g.
      `blog/0002-capture-first.md`, `blog/0009-the-motif-gauntlet.md`). Not organized as cookbook
      recipes.
- [ ] API documentation for the decoder library — **No**. Source is well-commented (every type has a
      doc comment) but there's no generated DocC, no public API surface map for downstream
      consumers.
- [ ] Comparison page against `xtruss`, `xscope`, Wireshark X dissector — **No**. The mission
      section of `PRODUCT_1_CAPTURE.md` mentions them briefly; no detailed feature comparison.
      `XQUARTZ_COMPARISON.md` exists but is server-side.
- [ ] Tutorial: "Your first capture in five minutes" — **No**. Closest is the wizard inside the
      Record screen itself (`RecordView.swift`); no external getting-started doc.

## 12. Security and Privacy

- [ ] Captures clearly marked as potentially containing sensitive content (keystrokes, clipboard,
      screen content) — **No**. No banner / warning / metadata flag. The viewer just renders bytes.
- [ ] Redaction mode (strip property values, keystroke contents, image data) for sharing captures —
      **No**. Not implemented. The `Recorder` does not modify bytes; there's no post-process
      redaction tool.
- [ ] Cookie / auth data redaction by default in saved files — **No**. MIT-MAGIC-COOKIE-1 auth data
      lands in the saved `.xtap` verbatim as part of the SetupRequest frame. Searched
      `Sources/SwiftXCaptureCore/*.swift` — no redaction codepath.
- [ ] Documentation calling out the dual-use nature of capture tools — **No**. README.md and
      PRODUCT_1_CAPTURE.md don't mention privacy risk. The capture audience-targeting copy treats
      this as a debugging tool only.

---

## Summary

**Counts (127 items total, last updated 2026-05-31 after the keysym + modifier
symbolic decode wedge landed):**

- **Yes**: 26
- **Partial**: 35
- **No**: 65
- **N/A**: 1 (Linux build — explicit non-goal)

_Changes since the morning audit: protocol-error highlighting moved Partial → Yes (landmark
correlation), Resource IDs tracked moved No → Partial (LandmarkDetector window hierarchy),
Jump to next/previous matching filter moved No → Partial (Cmd-]/Cmd-[ landmark navigation),
and one new row added for inline narrative landmarks in §6._

The Yes column is concentrated where you'd expect from the project history: the wire codec (core
requests + events + errors, SHAPE/BIG-REQUESTS/MIT-SHM/RENDER/XInputV1, atom resolution), the file
format basics (magic, frame header, per-frame timestamps, direction tag), the
proxy/recorder/replay/diff backbone, and the syntax-highlighted viewer. That is genuinely a lot —
macXcapture today already covers more X11 wire surface than xscope or xmon and is at parity with
Wireshark's X dissector on the extensions it does cover. But the Yes count is misleadingly small as
a measure of value-delivered because most of the "no" rows are scope-extensions on top of working
machinery, not foundational gaps. The decoder library is real. The viewer is real. They're just
missing the analytic and interop layers above them.

**Highest-leverage gaps (the items most likely to convert "useful tool" into "infrastructure people
standardize on"):**

1. **Tier-2 extensions for modern Linux audiences (§4: RANDR / XFIXES / DAMAGE / XINPUT2 / COMPOSITE
   / SYNC / Present / GLX / XTEST)**. The current decoder lights up vintage-Sun-era X plus the
   Tier-1 modern extensions. A capture of any modern GTK/Qt session today emits dozens of `<ExtName>
   opcode=N minor=M (undecoded)` lines. This is the gap between "tool for vintage-X workflows" and
   "tool the whole X community uses." `OPCODE_STATUS.md:275` already flags this as a ship/no-ship
   decision.
2. **Resource tracking (§3 + §6: ID lineage, leak detection, use-after-free, follow-this-resource
   navigation)**. The 2026-05-30 LandmarkDetector now keeps a session-wide window hierarchy
   (parent map, top-level table, mapped state, transient-for) — but it's internal to the detector
   and only windows are covered. Pixmaps / GCs / fonts / cursors / colormaps remain untracked, and
   §6's leak / use-after-free / follow-this-resource items still need a proper exposed registry.
   Promoting the LandmarkDetector's window state to a first-class `ResourceRegistry` accessible to
   other passes would unblock all of these.
3. **Structured navigation in the viewer (§5: jump to frame N, filter by
   opcode/direction/resource, search by atom name)**. The 2026-05-30 landmark + Cmd-]/Cmd-[
   work closed the worst part of this (you can now jump between named events and see them as an
   outline), but generic filters and "follow this resource" still don't exist. NSTextView's
   find-and-Cmd-F is the only generic-search tool. For captures larger than a few thousand frames
   this remains a real gap; Wireshark gets used over `tcpdump` mostly because of structured
   filtering.
4. **Cookie / auth-data redaction by default (§12)**. The "share a .xtap as a bug report" workflow
   is one of the stated mission goals (`PRODUCT_1_CAPTURE.md:88`), and right now every shared .xtap
   leaks the user's MIT-MAGIC-COOKIE-1 verbatim. This is small to fix (mask the SetupRequest's
   authProtocolData field at finalize time, with a sidecar flag) and high-impact for safety.
5. **`.pcap` export with X dissector compatibility (§9)**. A `.xtap → .pcap` converter is the
   cheapest possible interop story; .pcap is the lingua franca of network debugging, and giving
   users a path into Wireshark is more valuable than building a second filter UI from scratch. The
   framer-decoded bytes are already known; serializing them as Ethernet/TCP-framed pcap with X
   dissector hints is mostly bookkeeping.

**Things I noticed that aren't in the checklist but probably should be:**

- **Visual byte-order conversion of MSB captures.** macXcapture transparently handles either byte
  order in the X protocol, but the viewer always shows the wire-order bytes. A "normalize to host
  byte order" view would help anyone reading a capture taken from an MSB Sun talking to an LSB Linux
  server.
- **Per-client demux when multiple connections share a capture file.** The current `.xtap` format
  can technically interleave multiple sessions' frames in one file (the direction tag plus
  length-prefix are enough), but there's no client identifier per frame. Multi-client capture (§1)
  and the .xtap format (§2) both bottleneck on this; adding a `clientId: UInt8` to the frame header
  would unlock both.
- **xtruss/xtrace text-output emission mode.** Independent of `.pcap` export, an "emit xtruss-style
  text" mode would make existing xtruss users feel at home and lower the switching cost.
- **Capture file annotation / comments.** Letting the user paste a comment into a `.xtap` (or add
  per-frame notes) makes the format more useful for "here's what I was doing when this fired."
- **Bundled corpus.** The `captures/` directory in this repo is a real asset (real Sun-recorded
  sessions). Shipping a curated subset with the .app as "example captures" would give new users
  something to open before they wire up their own proxy.
- **A regression-test harness on top of CaptureDiff.** The diff machinery is there, but there's no
  "given two captures of the same scenario, fail the build if they diverge by more than N rows"
  tool. The 2026-05-13/14 audit was hand-driven; structural diff tests would let regressions surface
  automatically.

## Summary (vintage X11 lens)

The framing above scores against the "infrastructure the whole X community uses" outcome.
Re-scoring against the audience this project actually serves day to day (people running real
vintage Sun, SGI, DEC, and HP workstations and replaying their X clients against macXserver, or
debugging vintage Motif / CDE / Athena widget code) doesn't change the score by much, but it
reshuffles the priority list substantially.

**Items that are scope-irrelevant under this lens (treat as N/A, not No):**

- §1: Unix socket proxy, IPv6. Vintage X over the wire is TCP-IPv4 because the workstation is
  always on a different machine than the Mac.
- §4 extensions: RANDR, XINPUT2, COMPOSITE, DAMAGE, XFIXES, Present, DRI3, GLX modern, SYNC modern
  usage. None of these existed in the X11R5/R6 era, none of the clients in `captures/` use them,
  and a Sun ss2 with a 1280x1024 1995 frame buffer has no compositor, no display hotplug, no
  double-buffered swap chain.
- §9: .pcap export with X dissector compatibility. Wireshark's X dissector is itself thin on XKB
  / XInput v1 / RENDER (the exact extensions vintage clients use most), so the conversion delivers
  less value here than for a modern audience.

That moves about a dozen items from No to N/A; the in-scope universe shrinks from 126 to ~113,
and the Yes / Partial / No mix is roughly unchanged at 22 / 34 / 57. The headline percent-covered
moves from ~31% to ~35% at half-credit-for-Partial. What the lens changes meaningfully isn't the
score, it's which No rows actually matter.

**Highest-leverage gaps under the vintage lens:**

1. ~~**Keysym and modifier symbolic decode (§3).**~~ **Closed 2026-05-31.** 1224-entry table
   imported from `reference/X11R6/xc/include/keysymdef.h` (regen script at
   `Tools/regen_keysyms.sh`). KeyPress events now resolve keycode → keysym via the session
   keymap harvested from GetKeyboardMapping replies / ChangeKeyboardMapping requests; modifier
   masks render as `Shift|Ctrl|Mod1...`. Live xterm trace from the corpus now reads as
   `KeyPress L (keycode=92) state=none` and `KeyPress X (keycode=108) state=Ctrl` instead of
   the prior raw-integer form.
2. **WM-property type-aware decoding (§3).** WM_NORMAL_HINTS, WM_HINTS, WM_STATE, WM_CLASS, and
   WM_PROTOCOLS are the lingua franca of vintage WM debugging, and right now ChangeProperty /
   GetProperty body bytes print as a byte count. Decoding them inline surfaces the flags,
   supplied-fields, and aspect ratios that matter when a vintage app isn't behaving (the "why
   won't this Motif dialog place itself correctly?" workflow).
3. **Visual catalog lookup (§3).** Vintage X is dominated by 8-bit PseudoColor (Sun ss2, SGI Indy,
   most CDE installs). Every CreateWindow / CreateColormap / CreatePixmap references a visualId
   and depth that currently print as raw integers. Resolving against the SetupReply's
   `screen.allowedDepths` catalog gives the reader "visual 0x21 is the 8-bit PseudoColor of screen
   0" without manual translation.
4. **XTEST + RECORD + XC-MISC decoders (§4).** These are the genuinely vintage gaps in §4 (the
   actually-era-correct extensions, as distinct from the modern Tier-2 list). XTEST is what every
   input-injection test rig for vintage X uses, and a capture taken during automated UI tests is
   undecodable without it. XC-MISC is a tiny 4-request extension; the cost is low. RECORD is what
   `xmacrorec` and similar tools use; relevant for anyone debugging macro replay.
5. **Resource lineage (§3 + §6).** Same point as the modern lens, but the sharpest vintage use
   case is "follow this Motif widget across the session": a MotifPushButton creates a window,
   attaches Pixmap shadows, paints labels, gets ButtonPress events. A session-wide resource
   registry plus a "follow window 0x..." filter turns widget-level investigations from
   grep-on-text into a single-click drill-down.

**Things the vintage lens highlights that the modern synopsis didn't:**

- **MSB byte-order normalization is closer to mandatory.** The modern synopsis lists it as a
  nice-to-have. For the vintage audience it's higher priority because every Sun, DEC, and SGI
  capture is msb-first; the dumper currently shows raw wire bytes and that's harder to read for
  byte-by-byte audit work. A "normalize to host order" view should ship before launch.
- **The `captures/` corpus is itself the deliverable.** Bundled corpus is on the modern list.
  Under the vintage lens the corpus is the project's most distinctive asset: a Sun ss2 with CDE
  1.0 + Motif 1.2 + full xclock / xterm / xcalc / xfontsel / quickplot sessions is genuinely rare
  to capture today, and there are 50+ such sessions in the repo. Curating, labeling, and bundling
  these as "vintage X reference traces" is a community-value move modern audiences wouldn't
  surface.
- **Replay-vs-macXserver regression CI.** macXserver is the project's own server, the `captures/`
  folder is its primary test fuel, and a nightly "replay each capture, diff against last
  known-good pixel output" loop is a vintage-first feedback loop. The modern synopsis framed
  CaptureDiff as a bug-report aid; the vintage frame promotes it to the project's primary
  correctness signal.
