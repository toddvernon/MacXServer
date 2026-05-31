# Status 2026-05-31 — seven capture wedges (keysym, WM-property, visual catalog, Tier-4 extensions, resource registry, Motif properties, type-fallback) + console quieted

Two small landings on a Sun-less day. Both pure capture-side, no live
verification needed.

**`macxserver` console quieted.** Per-session and bridge traces are now
disk-only at `/tmp/macxserver/<instance>-<ts>.log` by default. New
`--verbose` / `-v` flag restores stderr mirroring when debugging. Listener
events (accept errors, shutdown) keep their stderr sink — those are rare
and worth seeing. `09bf07e`.

**Keysym + modifier symbolic decode for the capture viewer.** First wedge
out of the macXcapture decoder push's Phase 4-5 work, picked as the
highest-payoff Sun-independent gap from the checklist's vintage-lens top 5.

Three pieces:

- 1224-entry keysym name table generated from
  `reference/X11R6/xc/include/keysymdef.h` into
  `Sources/SwiftXCaptureCore/Keysyms.generated.swift`. Regen script at
  `Tools/regen_keysyms.sh`. Public API `keysymName(_:)` +
  `modifierMaskString(_:)` + `grabModifierString(_:)` in `Keysyms.swift`.
- `ChronoContext` now tracks a session keymap, populated from
  `GetKeyboardMapping` replies and `ChangeKeyboardMapping` requests.
  `KeyPress`/`KeyRelease` events translate keycode → keysym for output;
  before the keymap is populated, falls back to bare keycode.
- 7 dumper call sites rewritten: `GrabButton`, `GrabKey`, `UngrabButton`,
  `UngrabKey`, the four input-event types (state field), and
  `ChangeKeyboardMapping` payload (now prints rows as
  `kc7=[Tab,ISO_Left_Tab] kc8=[Return]`, capped to 8 keycodes + ellipsis).

Verified against `captures/xterm-running-on-ss2-display-on-ss2.xtap` —
live key trace now reads as `KeyPress L (keycode=92) state=none` and
`KeyPress X (keycode=108) state=Ctrl` instead of the prior
`keycode/btn=92 state=0x0` / `keycode/btn=108 state=0x4`. 12 new unit
tests; 1083/1083 total tests pass.

Checklist (`macXcapture-feature-checklist.md`): two §3 rows moved No → Yes
(keysym decode, modifier mask decode). Counts: 24/35/67/1 → 26/35/65/1.
Vintage-lens gap #1 closed.

**WM-property type-aware decode (vintage-lens gap #2).** Second wedge of
the day, same pattern. The five ICCCM WM_* properties plus WM_TRANSIENT_FOR
now decode inline on both the `ChangeProperty` request and `GetProperty`
reply paths:

- WM_NORMAL_HINTS — flags list + populated size/min/max/inc/aspect/base/
  gravity fields (gravity rendered by name).
- WM_HINTS — flag list, input bool, initialState name, icon refs, urgency.
- WM_STATE — state name, icon window.
- WM_CLASS — instance/class strings split from the NUL-terminated pair.
- WM_PROTOCOLS — atom-name list resolved through `ctx.atomToName`.
- WM_TRANSIENT_FOR — single window id.
- Fallback: generic `ATOM`-typed properties get the atom-list renderer
  even when the property name isn't in the WM_* set.

Layouts in `Sources/SwiftXCaptureCore/WMProperties.swift`, ported from
`reference/libX11/src/Xatomtype.h` and ICCCM §4. `ChronoContext` gained
`seqToGetPropertyAtom` for request → reply pairing. New
`previewBytesRaw(_:format:)` overload lets the reply path call the
generic preview without an enum round-trip.

Verified against the corpus: `xterm` capture shows
`prop=WM_NORMAL_HINTS ... flags=PSize|PWinGravity PSize=484x316
gravity=NorthWest` and `prop=WM_HINTS ... flags=Input|State input=true
initialState=Normal`; `xedit` shows `prop=WM_PROTOCOLS ... type=ATOM
... atoms=[WM_DELETE_WINDOW]`. 15 new unit tests; 1098/1098 total tests
pass.

Checklist §3 "Property values decoded with type awareness" row stays
Partial (WM_* done; CARDINAL and non-WM_* STRING decoding still
fall through to `previewBytes`). Vintage-lens gap #2 marked Closed.

**Visual catalog lookup (vintage-lens gap #3).** Third wedge of the day,
same pattern again. `ChronoContext.visualCatalog` is populated at the
SetupAccepted landing by walking every screen → allowedDepths → visuals
tuple; entries record depth + class + bitsPerRgbValue + screen index.
`visualDisplay(_:ctx:)` renders a visualId as `0x22(PseudoColor d8)`,
falling back to bare hex when the catalog hasn't been populated. The
spec sentinels for `CreateWindow.visual=0` and `CreateWindow.depth=0`
render as `CopyFromParent` by name.

Two dumper sites rewired: CreateWindow gained explicit `depth=` and
`visual=` fields (previously only the class field was printed);
CreateColormap's visual now resolves through the new helper instead of
the old `windowDisplay` shorthand.

Verified against the corpus: ico, auto-box, and xmag captures now show
`visual=0x22(PseudoColor d8)` where before they showed bare hex; xterm
still reads `visual=CopyFromParent` because xterm inherits its parent's
visual rather than picking one explicitly. 5 new unit tests; 1103/1103
total tests pass.

Checklist row §3 "Visual and depth references resolved" moved No → Yes
(27/35/64/1). Vintage-lens gap #3 marked Closed.

**XC-MISC / XTEST / RECORD extension decoders (vintage-lens gap #4).**
Fourth wedge of the day. Three new `ExtensionDumper` implementations
registered in `ExtensionDumperRegistry.builtins`:

- `XcMiscDumper` — three requests (GetVersion, GetXIDRange, GetXIDList).
  Layouts from `reference/X11R6/xc/include/extensions/xcmiscstr.h`.
- `XTestDumper` — four requests (GetVersion, CompareCursor, FakeInput,
  GrabControl). FakeInput is the meaty one — synthesized input event:
  the `detail` field is labeled per `type` (keycode for Key*,
  button for Button*, absolute/relative for MotionNotify). Layouts from
  `reference/xproto/include/X11/extensions/xtestproto.h`.
- `RecordDumper` — all eight context-management requests. Trailing
  variable-length CLIENTSPEC and RECORDRANGE lists surface as counts
  only; per-element walks deferred. Layouts from
  `/opt/X11/include/X11/extensions/recordproto.h`.

No corpus capture exercises any of these (they're for external
captures: input-injection rigs, macro-recording tools, long-running
sessions that exhaust the resource-id pool). Verified via 15 new unit
tests in `Tier4ExtensionTests.swift` — both byte orders, every minor
opcode shape covered. 1118/1118 total tests pass.

Checklist §4: XC-MISC + XTEST + RECORD all No → Yes. Counts:
27/35/64/1 → 30/35/61/1. Vintage-lens gap #4 marked Closed.

**Resource registry / lineage (vintage-lens gap #5).** Fifth wedge of
the day. The architectural one. `ResourceRegistry` is a public
session-wide registry keyed by resource id, tracking creation +
free-time for all six X11 resource kinds (window, pixmap, GC, font,
cursor, colormap). Populated in `dump()`'s request-dispatch loop via
`trackResourceLifecycle(_:seq:registry:)` — every Create* / Free* shape
maps cleanly. ID reuse honored: new creation overwrites the slot but
separate monotonic counters keep session-end stats honest.

Two consumer features ship in the same wedge:

1. **Session-end resource summary landmark.** After the existing
   `# Session ends after Xs (N requests, M events)` line, a new
   `# resources: 2 windows (0 freed, 2 leaked), 7 GCs (1 freed, 6 leaked),
   4 fonts (0 freed, 4 leaked), 8 cursors (0 freed, 8 leaked)` line
   surfaces every kind with non-zero activity. Vintage clients commonly
   "leak" all resources at shutdown (server cleans up on disconnect),
   so the leak counts are diagnostic, not accusatory.

2. **Use-after-free / lineage annotation on XError landmarks.**
   `LandmarkDetector.errorLandmark` now consults the registry. When the
   bad resource id was created earlier in the session, the landmark
   gets a `(created at seq=X)` suffix. When it was created AND freed
   before the failing request, the suffix becomes
   `(freed at seq=Y, created at seq=X)` — the textbook use-after-free
   signal, surfaced automatically.

LandmarkDetector keeps its window-specific state (top-level identity,
transient-for, click resolution) since that's a different concern than
raw lineage; the two are complementary now.

Verified against the xterm and xedit corpus captures — both produce a
clean `# resources:` line at end-of-session. Use-after-free path
covered by synthetic unit tests (no corpus capture happens to trigger
it). 12 new tests in `ResourceRegistryTests.swift`; 1130/1130 total
tests pass.

Checklist §3 "Resource IDs tracked" Partial → Yes; §3 "Resource
creation lineage shown" No → Yes; §3 "Resource lifetime tracked" No →
Yes; §6 "Resource leak detection" No → Partial (session-end count
lands, per-resource detail still missing); §6 "Use-after-free detection"
No → Yes. Counts: 30/35/61/1 → 34/35/57/1. Vintage-lens gap #5 Closed.

**All five top-5 vintage-lens readability gaps closed in one Sun-less
day.** Plus the console-quiet server wedge from this morning.

**Bonus: `_MOTIF_*` property decoders.** With the top-5 closed, picked
the highest-leverage *purely vintage* follow-up: four Motif-specific
property decoders that no modern audience cares about but every vintage
CDE/Motif client sets at realize time. Wired into the existing
`decodeKnownWMProperty` dispatcher in `WMProperties.swift`:

- `_MOTIF_WM_HINTS` — flags + functions + decorations + inputMode +
  status. Layout from `reference/motif/lib/Xm/MwmUtil.h`
  `PropMotifWmHints`. The mwm/dtwm communication channel; every Motif
  top-level uses it.
- `_MOTIF_WM_INFO` — mwm-startup flags + wmWindow id. Layout same
  header. Published by the running window manager on the root.
- `_MOTIF_DRAG_WINDOW` — single WINDOW id, the DnD root-window proxy.
  Reuses the existing `decodeSingleWindow` path.
- `_MOTIF_DRAG_RECEIVER_INFO` — 16-byte header for a drop target.
  Layout from `reference/motif/lib/Xm/DragICCI.h`
  `xmDragReceiverInfoStruct`. Has an embedded `byte_order` byte ('l'/
  'B') that overrides the X11 connection's endianness — Motif's DnD
  properties are self-describing so any client can read them
  regardless of its own byte order. Decoder honors this.

Plus the `_MWM_*` alias variants (`_MWM_HINTS`, `_MWM_INFO`) — the
Motif source uses both spellings interchangeably.

Verified against the corpus: dogs/motifanim/fileview etc. now render
`prop=_MOTIF_DRAG_WINDOW ... window=0x2400001` (proxy resolution),
`prop=_MOTIF_WM_HINTS ... flags=INPUT_MODE inputMode=MODELESS`
(non-modal dialog), `prop=_MOTIF_DRAG_RECEIVER_INFO ... endian=msb
protocol=0 style=PREFER_PREREGISTER proxy=None sites=2 heap=72`
(fileview as a 2-site drop target). 11 new unit tests; 1141/1141 total
tests pass. No checklist count shifts — the type-aware row was already
Partial and this extends its coverage without flipping it.

**Type-driven property decode fallback.** Seventh wedge — closes the
§3 "type-aware decoding" row from Partial → Yes. The dispatcher in
`WMProperties.swift` gained a `decodePropertyByType` fallback that
fires whenever the property name didn't match a WM_* / _MOTIF_* case:

- **CARDINAL** / **INTEGER**: render as decimal lists (unsigned /
  signed). Format-width-aware: 8/16/32 bits. Truncated to 8 elements
  with `…(+N)` tail.
- **STRING** / **UTF8_STRING** / **COMPOUND_TEXT**: render as quoted
  text up to 200 chars (Latin-1 for STRING/COMPOUND_TEXT, UTF-8 for
  UTF8_STRING). Newlines/CR/tab escaped; control bytes → `?`; longer
  bodies show `…" (N bytes)` suffix.
- **WINDOW** / **PIXMAP** / **COLORMAP** / **CURSOR** / **FONT** /
  **DRAWABLE**: render as resource-id lists with `None` for id=0.
- **ATOM**: already covered by `decodeAtomList`.

Verified against the corpus: `RESOURCE_MANAGER` now reads as
`value="! Reserved for resources that should apply...\n"` (truncated
preview of the actual Xrm text) instead of `data=30567b`;
`_MOTIF_DEFAULT_BINDINGS` shows its osfKey binding list inline;
`WM_CLIENT_MACHINE` resolves to the hostname string.

One stale test in WMPropertyTests had to be updated — its
"unknown-property returns nil" assumption no longer holds when the
type is recognized. Replaced with a positive test for the new path.
15 new unit tests; 1157/1157 total tests pass. Checklist §3 row
Partial → Yes: 34/35/57/1 → 35/34/57/1.

Eight commits, 54 new unit tests, no regressions, no Sun required.

# Status 2026-05-30 — three-day rollup (SHAPE; capture v2 GUI; macXcapture decoder push)

Three days of major work landed since the 2026-05-27 entry below. Writing
this as a single rollup because no end-of-day STATUS pass got made on
05-28, 05-29, or 05-30 -- the work was real, the doc just slipped. A new
Stop hook landed today to nag when this happens again.

## 2026-05-28 -- SHAPE extension

oclock comes up round and xeyes as a bare oval. SHAPE shipped as major
opcode 128, event base 64, no extension-specific errors. All 9 requests
implemented and the region state is stored/queryable; visual application
covers the bounding shape on a top-level (the demoable win). Clip shape
and descendant-window shape are stored but not yet applied to rendering
-- ledgered in SHORTCUTS with the exit plan. See DECISIONS 2026-05-28
for the scope decision and `reference_xeyes_round_without_shape` memory
for the corrected note (the earlier memory claiming xeyes never used
SHAPE was wrong; Xmu calls `XShapeCombineMask`).

Three commits trace the arc:

- `5be5334` -- core: protocol + region engine + storage. Region algebra
  is a faithful port of `Xext/shape.c:RegionOperate` onto our existing
  `Region`. ShapeMask's bitmap-to-region reuses the depth-1 fully-black
  convention from the FillStippled reader. Real xcalc and xeyes SS2
  captures now replay their SHAPE traffic with zero XErrors.
- `6a03159` -- render path: bounding-shaped top-levels actually appear
  shaped on screen. Three things had to align: map-time re-apply (oclock
  shapes before mapping, but our NSWindow/view is created lazily at
  map, so the original ShapeMask landed against a nil view and was
  dropped); transparency (FlippedXView clears its backing + the layer
  background to clear, NSWindow goes non-opaque); and edge quality (the
  protocol region is 1-logical-pixel banded, which our display scale
  magnifies into visible stair-steps -- ShapeMask now also captures a
  device-resolution mask from the source pixmap while it's still alive,
  and the clip follows that at full backing resolution).
- `6496b6f` -- Motif-frame integration: when the local mwm-look frame
  is on, a shaped client renders mwm-style (rectangular title bar OR'ed
  with the client shape, per mwm's `SetFrameShape`). `MotifFrameView`
  gains a `clientIsShaped` flag that reports `isOpaque=false` and draws
  only the title-bar strip while transparent everywhere else.

Also that day: remote launcher learned TERM=xterm telnet negotiation
(`2db4596`) so `.cshrc` prompt setup runs on the remote, and
`LaunchProgressWindowController` got Xcode-target-registered
(`7b4c01c`).

## 2026-05-29 -- Capture v2 largely lands + ss2 rebaseline

Capture v2 (the library + GUI app + decoded-text export from
`DECISIONS.md` 2026-05-23) shipped most of its scope in a single push.
macXcapture is now a real Mac app, not a CLI:

- `1294bc0` -- optional decoded `.txt` log alongside each `.xtap`,
  written as the capture runs.
- `6485f7d` -- capture viewer window with standardized chrono dump
  formatting. Opens any `.xtap` file in a syntax-highlighted code-editor
  view.
- `66f6b4d` -- moved `.txt` generation out of the capture path and into
  the viewer as Save As / Export as Text. Captures stay binary; the
  viewer renders to text on demand.
- `d95a66b` -- extracted shared `SwiftXCaptureUI`. The capture app and
  the server's debug viewer now use the same code path.
- `550a8aa` -- Record screen redesigned as a stacked 6-step wizard:
  source / target / proxy / output / launcher / go.
- `ce28a32` -- launcher gained an optional plaintext password field
  with keychain fallback.
- `f5e2301` -- red XTAP app icon, distinct from the blue X server icon
  (`Icons/CaptureAppIcon.appiconset/`). Render script lives in
  `Icons/source/`.

Then the ss2 rebaseline (`c3f1572`): fresh `ss2 -> swiftx` capture pairs
for the dt-apps and quickplot, plus refreshed ss2-only golds. This
moots the "STALE pending u5 recapture" notes on
`project_motif_quickplot_status`, `project_dt_apps_status`, and
`project_dt_apps_theme_pass_open` -- the captures are now in tree.

End of day, the macXcapture mission doc landed (`40dea83`): mission
statement, decoder coverage plan, Phase 0 audit. Establishes the OSS
launch bar (decode any capture with zero `opcode=N (untyped)` lines for
documented opcodes) and the phased plan to get there. PRODUCT_1_CAPTURE
and PROJECT folded the mission in.

## 2026-05-30 -- Decoder coverage Phases 1-3, inline landmark detector, Phase 5 polish

The biggest single-day decoder push since the framer was first written.
Roughly five threads of work:

**Phase 1 -- framer core gaps closed (`672f01d`)**: 16 requests + 6
replies + 5 events that the framer had been silently treating as
untyped. CopyGC, FontPath ops, HostAccess ops, Keyboard ops, Pointer
ops, PropertyList ops, ListProperties/GetFontPath/GetKeyboardControl/
GetPointerControl/ListHosts/SetMapping replies. Round-trip tested.

**Phase 2 -- extension dumper registry (`d95e957`)**: ChronoDumper now
dispatches by negotiated major opcode to per-extension dumpers
registered at startup. Replaces the hardcoded shape-dumper bolt-on.
`ShapeDumper` lifts to the new registry.

**Phase 3 -- extension decoders, three sessions per extension**:

- BIG-REQUESTS + MIT-SHM (`37a2c8d`).
- XKB Sessions 1-3 (`df89a00`, `5cfeb72`, `72c878a`) -- Tier A
  requests + all 11 events; `GetMap`/`SetMap` nested-list trailer;
  Tier B/C bulk.
- XInput v1 Sessions 1-2 (`71739e4`, `a31b5e9`) -- Tier A + class
  trailer + events; Tier B/C bulk + three union types.
- RENDER Sessions 1-3 (`e3721bf`, `ea82093`, `820c11b`) -- Tier A +
  PictFormats walker; glyph stack + filter/index queries; Tier B/C
  bulk.

OPCODE_STATUS was updated in lockstep on every commit.

**Phase 5 polish**: visual request/reply pairing via a `↳` glyph
(`9664a68`) and a `↙` glyph for replies (`9417165`); field-level
semantic diff in CaptureDiff (`f6c19ef`); proxy read/write paths
harmonized with the listener (`218dc53` -- EINTR/EAGAIN retry +
errno logging).

**Inline narrative landmark detector** -- new sub-feature that landed
in four phases:

- `9111f86` -- core: LandmarkDetector + syntax-colored `# ...` callouts
  inline in the dump. Server-side parity in `ServerSession`.
- `af25b2f` / `230b4d2` -- rewrote landmarks as story-form narration,
  left-justified `# ...` comments. Fixed the first-top-level
  detection bug.
- `9417165` -- verbose identify landmarks (which app each window came
  from).
- `b5a233d` / `de4160d` / `16fd018` / `7796097` -- Phases A through D:
  window hierarchy + click contextualization; hidden / closed /
  dialog-dismissed landmarks; error correlation + session-end summary;
  viewer-side landmark navigation (sidebar + Cmd-]/Cmd-[).

**Docs + ledger**:

- `201c52c` / `d3d43ec` -- macXcapture feature checklist created and
  filled (22 Yes / 34 Partial / 69 No / 1 N/A).
- `2f912fc` -- checklist rewrapped + vintage-X11-lens synopsis added.
- `532e786` -- end-of-day audit against the day's landmark + diff
  work. Four row moves; checklist now 24/35/67/1 (127 items, +2 Yes,
  +1 Partial, -3 No net).
- `60568bb` -- xcodegen regen to pick up Phase 1-3 source files.
- `ff7dd8c` -- server: drop the session-end console summary that the
  capture-side landmark sweep made redundant.
- `ac2614c` -- server: close landmark parity with the capture side.
- `9eacc8a` -- new memory: don't filter protocol truth from output
  (`feedback_dont_filter_protocol_truth`). Rephrase quirky-but-real
  wire acts (empty WM_NAME, hidden helper windows) so they read
  cleanly instead of hiding them.

## What's open

Carrying over from prior status entries, no progress since 2026-05-27
on:

- Framer-shared bug investigation (carried since 05-19).
- dtpad Gap B: text-area paint loss on resize (DECISIONS 2026-05-25
  flagged as separate from the preservation work).
- dtpad menu-bar erase on dialog popup (DECISIONS 2026-05-25).
- Horizontal scrollbar reverse-image rendering (DECISIONS 2026-05-25).

New since the SHAPE work:

- Clip-shape and descendant-window shape: stored but not rendered. No
  hosted client needs them today. See SHORTCUTS for the exit plan.
- ShapeNotify is per-session, not cross-session (SHORTCUTS).
- `ShapeRectangles` ordering claim not enforced (SHORTCUTS, low value).

New since the macXcapture push:

- The 67 `No` rows in `macXcapture-feature-checklist.md`. Phase 4-5
  of the decoder coverage plan is the next focused push if we want
  to keep moving on OSS-launch quality.

Previous status entries (2026-05-27 onward) preserved below.

---

# Status 2026-05-27 — remote launcher; Motif clipboard; root properties; configurable frame; doc audit

Started as cleanup, turned into the biggest feature day of the project.

**Remote app launcher.** New Launchers submenu in the app menu. Each
entry telnets to a vintage Sun, logs in, sets DISPLAY, launches the
X app in background, disconnects. Config file `~/.swiftx-launchers`
(INI format, same editor pattern as fonts/resources). Passwords in
macOS Keychain. Configurable prompt patterns for non-standard shells
(`login_prompt`, `password_prompt`, `shell_prompt`). Optional verbose
flag shows a progress window with the telnet session log -- typed text
in bold, echo suppressed at the byte level, ANSI escapes stripped.
Telnet IAC negotiation handles SunOS 4.1.4 through Solaris 2.6.
Tested live against u5. Nine new files, ~1100 lines.

**Motif frame chrome now configurable.** `MotifTheme` converted from
static constants to a loaded struct driven by `[motif-frame]` section
in `~/.swiftx-resources`. Colors (hex or X11 named), bevel width,
frame width, title bar height, button style all editable. Existing
installs get the section auto-appended on first startup.

**Root-window properties moved to ServerCoordinator.** The oldest
architectural bug in the server: root-window properties were per-session
(PropertyTable on ServerSession), so anything one client wrote to root
was invisible to another client. Fixed by adding a server-global
PropertyTable on ServerCoordinator with NSLock guarding, a
RootPropertyObserver protocol for PropertyNotify fan-out across
sessions, and routing all ChangeProperty/GetProperty/DeleteProperty
on root through the coordinator. Session-init properties
(_MOTIF_DRAG_WINDOW, _MOTIF_WM_INFO, RESOURCE_MANAGER) also moved.

**Motif clipboard copy/paste between apps now works.** The unlock.
Motif's CutPaste.c stores all clipboard state as root-window properties
(_MOTIF_CLIP_HEADER, _MOTIF_CLIP_LOCK, _MOTIF_CLIP_ITEM_*, etc.) and
uses a PropertyNotify-on-root timestamp probe (ClipboardGetCurrentTime)
that blocked forever because we never emitted PropertyNotify for root.
Two fixes: (1) emitPropertyNotify now checks rootEventMask for root
windows (was only checking WindowEntry, which doesn't exist for root);
(2) the root property migration above makes clipboard data visible
across sessions. Verified: two dtpads from u5, Copy in one, Paste in
the other transfers text correctly.

**Pixmap-writer y-flip verified live.** quickplot button-bar icons
right-side-up, horizontal scrollbar thumb shadow correct orientation.
Closes the 2026-05-27 morning investigation.

**Doc audit sweep.** Went through all docs and compiled a 26-item open
bug list. Todd verified 4 items are already fixed (resize repaint gap,
small gray rectangles, dtpad menu-bar erase, window placement). Agent
audit of the remaining 22 found 2 more already fixed in code (NoExpose
gating on graphicsExposures, SetupAccepted display-adaptive) and one
stale count (cursor glyph mapping is 22 values not ~10). All docs
updated.

Previous status entry (morning) preserved below.

---

# Status 2026-05-27 (morning) — dt-app theme dead-rule sweep; pixmap-writer y-flip closed

Cleanup session. Two commits, both pushed.

**Retired dead dt-app dialog-button foreground rules (`9aa90c3`).** Spent
the afternoon debugging dtpad's `save_warn` dialog buttons — none of our
`Dtpad*save_warn*…foreground` rules took, no matter the binding
tightness. Kitchen-sink diagnostic at every level from `*OK.foreground`
up to the fully-tight `Dtpad.save_warn_popup.save_warn.OK.foreground`
all failed to land. A paired `background:MidnightBlue` test also didn't
move. But shape rules (`shadowThickness:8`, `marginWidth:20`,
`marginHeight:15`) DID land and visibly bloomed the buttons. That's the
mechanism evidence: Motif sets dialog-button fg/bg programmatically via
`XmGetColors()` at widget-create time (`XtSetArg` under the hood),
which beats every Xrm rule we can write. Shape rules flow through Xrm
normally because they're not in the auto-color path.

So I pulled every never-firing dialog-button fg rule from both the
seed (`DefaultMotifResources.swift`) and the running config
(`~/.swiftx-resources`): `*XmDialogShell*XmPushButton(Gadget).foreground`,
`Dtpad*save_warn*…foreground`, `Dthelpview*XmPushButton(Gadget).foreground`,
the per-instance Dthelpview close/back/print triple, plus all the
`*fontList` Helvetica-italic companions for those rules. Kept the
font/shape rules that actually work. Dialog buttons now render
Black-on-Gray Motif-fallback, which is SS2 visual parity anyway —
this isn't a regression, it's accurate documentation of what we can
and can't control.

**Sealed off SDT Pixel Set impersonation with a giant banner.**
`installCDECustomizationDaemonImpersonation` in
`SelectionMediator.swift` is dormant (retired 2026-05-18, never
called) but kept reading like current architecture across sessions
and dragging diagnoses back toward SDT-Pixel-Set fixes that don't
apply. Now commented out under a `RETIRED` ASCII banner with an
explicit "ask Todd before considering this" gate. Original doc-block
preserved verbatim as historical citation. New memory
`feedback_sdt_pixel_set_retired.md` plus a CLAUDE.md edit so the
trap can't keep firing.

**y-flip saga: reverted then fixed at the writer.** Morning: backed
out `be8fdce` (2532ba6) because the blit-side y-flip introduced for
horizontal scrollbar thumb shadows regressed quickplot's button-bar
bitmaps. Afternoon: diagnosed the asymmetry and fixed it at the
writer instead of the blit.

The asymmetry: `PixelBuffer`'s CGBitmapContext has a y-flipped CTM
(`translateBy(0, h); scaleBy(1, -1)`) so X-protocol coords pass
through. `ctx.draw(image:in:)` into a y-flipped context paints the
image rows upside-down in memory unless you locally counter-flip —
the well-known macOS gotcha. Fill-based writers (`FillRectangle`,
`PolySegment`) have no orientation so they wrote pixmap memory
correctly top-down. Image-based writers (`drawPutImage`) didn't
counter-flip and wrote pixmap memory upside-down. `blitCroppedImage`
(pixmap → window) used the same y-flipped context with no counter-
flip on the destination side either, so it ALSO drew upside-down.
Net effect chain:

- Scrollbar thumb shadow (FillRect pixmap → window): 1 flip → bug.
- Button-bar icon (PutImage pixmap → window): 2 flips → accidental
  right-side-up.

`be8fdce` added a counter-flip on the blit side only, fixing the
shadow (0 flips) but breaking the button bar (1 flip).

The fix: counter-flip BOTH writers. `drawPutImage` now saves GState,
applies the same `translateBy(0, 2y+h); scaleBy(1,-1)` as `be8fdce`,
draws the image, restores. Pixmap memory is now consistently
top-down. Re-landed the matching counter-flip in `blitCroppedImage`.
Net: every chain is one flip in the writer + one flip in the blit =
right-side-up everywhere. All 771 tests still pass.

Need live visual verification on the two clients that motivated each
half: quickplot's button bar (button-bar regression closed) and a
Motif horizontal scrollbar — xfontsel font list, dtpad font picker,
or quickplot's plot scrollbars (be8fdce bug closed).

## What's still open

1. ~~**Visual verification of the pixmap-writer fix.**~~ **Closed
   2026-05-27.** Verified live from u5: quickplot button-bar icons
   right-side-up, horizontal scrollbar thumb shadow correct (top+left
   highlight, bottom+right shadow, SS2 parity). Fix is shipped.

2. **Carry-overs from prior status entries** -- ~~resize-uncover
   repaint gap~~ (closed 2026-05-27, verified fixed); framer-shared
   bug investigation (still open); ~~dt-apps smoke tests post-clipping~~
   (closed 2026-05-27, all look good).

# Status 2026-05-24 — Optional Motif frame; SIGPIPE fix; parked-bug closures

Three things landed today.

**Optional Motif window-manager frame for X top-levels.** Opt-in via
Preferences → Display. Vendored from a separate WindowText prototype
into `Sources/SwiftXServerCore/MotifFrame/` (MotifTheme, MotifFrameView,
MotifWindow + a small Preferences provider). NSWindow content rect grows
by the frame insets so the inner X-client area still equals the
client-requested geometry (ICCCM §4.2.1 reparenting model). Title text
follows real mwm policy (center when it fits, left-align + visual clip
mid-glyph when it doesn't — verified against `motif/clients/mwm/
WmGraphics.c::WmDrawXmString`). Per-window button style toggle between
Motif raised glyphs and Mac traffic lights. FlippedXView grew
`layer?.masksToBounds = true` to fix a latent shrink-overshoot bug that
was hidden by AppKit's native title-bar compositing layer.

**SIGPIPE fix.** `signal(SIGPIPE, SIG_IGN)` at the top of
`ServerEntry.run()`. Latent bug since the listener was written —
`writeAllToSocket` calls plain `Darwin.write()`, so a post-EOF write
returned EPIPE *and* the kernel killed the process by signal. Symptom:
"I quit my X client and the server vanished." Recent timing changes
(GUI redesign + my new Motif close-button → WM_DELETE handshake) made
the race more likely. One-line fix in `Sources/SwiftXServer/
ServerEntry.swift`.

**OSF/Motif source pulled into `reference/motif/`.** Community-
maintained Motif 2.3.x (`https://git.code.sf.net/p/motif/code`,
LGPL 2.1) cloned via `reference/fetch.sh`. ~73MB. `clients/mwm/` is
the canonical standalone mwm (direct ancestor of CDE's `dtwm`); `lib/Xm/`
is the widget library. For the first time we can read what Motif
widgets actually expect from the server. README + SOURCE.md updated.

**Two agent-driven closures**:

- **2026-05-10 "park dt-Motif widget chrome redraw"** — formally closed
  in `DECISIONS.md` 2026-05-24. Symptom ("buttons don't render at all")
  was actually fixed during the 05-13 → 05-18 sweep (VisibilityNotify
  state derived from `borderClip ∩ interiorBox`, QueryTextExtents,
  PolySegment pixmap path, PutImage Bitmap + CopyArea cross-window/
  pixmap, CDE-impersonation retirement). Both background agents found
  explicit closure evidence — no live re-investigation needed.

- **Expose-architecture flooding** — also closed in the same DECISIONS
  entry. Survey of 21 Motif widget classes via `reference/motif/lib/Xm/*`
  showed every Motif widget declares `visible_interest = FALSE`, so
  VisibilityNotify gates nothing on the Motif side. The dominant Motif
  gates are `XtIsRealized` and `MenuShell.popped_up`, both purely
  client-side. Xt's `XtExposeCompressMaximal` (default for every
  manager — BulletinB.c:372, RowColumn.c:837, …) already coalesces our
  per-clip-rect Expose events client-side. Recommendation: keep the
  current model; the visibility-tracking work envisioned in the parking
  decision would have been wasted effort.

**Status of in-flight bugs**: see "What's still open" near the bottom
of this file (updated today). The big remaining real one is the
resize-uncover repaint gap in `ServerSession.handleConfigureWindow`'s
descendant-uncover branch (dthelpview buttons thinner after resize;
dtpad text-area paint loss). Distinct from the now-closed chrome
parking.

# Status 2026-05-22 — x11perf clean sweep + error-path test suite

x11perf survey from the SS2 is 254/254. Every test in the build runs to
completion and reports a number. The three-day push that got us here
was a chain of unblocks: ScreenSaver-trio stubs (107/108/115), GetImage
with ARGB→pixel reverse-mapping, PolyText16+ImageText16 CHAR2B variants,
CopyPlane via a 1-bpp bitmap synthesized from the src ARGB and routed
through the existing PutImage path. Plus a bookkeeping pass that
brought OPCODE_STATUS in sync with the Request enum (14 catch-up rows).

Today's other landing: an error-path test sweep delegated to a worktree
agent, then merged back cleanly. `Tests/SwiftXServerCoreTests/ErrorPathSweepTests.swift`
adds 69 new tests on top of the existing 49 in `XErrorEmissionTests.swift`,
table-driven and grouped by argument type (window, GC, drawable,
colormap, font, cursor, atom). The sweep caught six silent-drop bugs:
ReparentWindow.parent, WarpPointer.srcWindow + dstWindow, GrabButton.confineTo,
AllocNamedColor/LookupColor/QueryColors cmap, and SetSelectionOwner/
GetSelectionOwner/ConvertSelection selection-atom. ReparentWindow was
the worst — it was emitting a ReparentNotify event with the bogus
parent ID embedded in it, a lie on the wire. All fixed with small
validation guards.

The worktree pattern worked well — the sweep ran in parallel with the
user's SS2 x11perf survey without contention. One quirk: the agent
branched from the last committed state, which predated three days of
uncommitted GetImage/CopyPlane/text16 work on main. The merge required
dropping four stale `_RoutesToBadRequest` tests that assumed those
opcodes were still routed through `case .unknown` → BadRequest. The
six dispatcher fixes themselves landed cleanly because they touched
sites that the recent work didn't overlap with.

All 631 tests pass (4 unrelated skipped).

# Status 2026-05-19 — End of day

The X server's bg-paint contract is now honored end-to-end. Three big
visible fixes plus a tooling boost that paid for itself the day it
landed. dthelpview, xterm, and most of quickplot's open plot-window
artifacts all unstuck by a single architectural correction.

## Headline

**Three closes:**

1. **dthelpview renders with proper white DisplayArea and blue form
   border, no leftover blue rectangles after expand.** Root cause was
   two-part: (a) draw ops weren't clipped to the window's visible region
   (`clipList`) so a parent's bg paint or Motif's `ClearArea` on the
   form bled right through descendant windows; (b) `handleConfigureWindow`
   updated geometry + emitted Expose but never painted the descendant's
   bg into newly-claimed pixels, so the form's L-shape of new pixels
   after expand stayed as fresh-bitmap-white.

2. **xterm `-bg black -fg cyan` renders correctly black with cyan text
   on black cells.** `GCState.background` default was `0xFFFFFF`, which
   resolved to whitePixel after the 2026-05-19 (earlier today) ColorTable
   canonicalization. xterm relies on the spec default for GC bg
   (background=1 = blackPixel per X11 spec); we were handing it white.
   One-line fix to GCState; verified live.

3. **Quickplot's plot-window drawing artifacts mostly resolved as a
   bonus.** Todd reports today's bg-paint-contract fixes closed "a lot
   if not all" of quickplot's open plot-window issues. Most likely the
   blue-line-at-y=50 artifact on selected pages (open issue #5 in
   `project_motif_quickplot_status`) — textbook "parent's bg paints into
   descendant area" which is exactly what the new clipList composite-clip
   prevents. Re-verify and formally close next session.

**One architectural unlock:** Todd's "Athena widgets just *were* a
color" observation. Once stated, it became the lens for both fixes
(server owns bg paint on every visibility transition; widgets just
declare bg via CWBackPixel). Memorized as `reference_x11_server_owns_bg_paint`
so future "white where bg should be" bugs route to "find the missing
paint, not the wrong color."

## What landed (with file pointers)

### Bridge-layer visible-region clipping (the dthelpview-content fix)

- `Sources/SwiftXServerCore/DrawTarget.swift` — `.window` case now
  carries `id` alongside `topLevel`/`offsetX`/`offsetY` so the bridge
  can look up per-window clipList.
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` —
  `windowClipLookup` closure (set by session, mirrors `pixmapBufferLookup`);
  `withDrawContext` for `.window` targets calls the lookup and sets
  `CGContext.clip` to the clipList rects BEFORE the GC user-clip, per
  X.org `mi/migc.c:miComputeCompositeClip`. New `withClip` overload
  takes both window- and GC-clip args. `clearArea` bridge signature
  changed from single-rect to `rects: [Rectangle]` (session does the
  intersection now).
- `Sources/SwiftXServerCore/ServerSession.swift` — `handleClearArea`
  intersects request rect with `entry.clipList`, passes surviving
  rects to bridge. `paintRectsForWindow` clips inner bg rect to the
  window's clipList. Session registers `windowClipLookup` on the
  bridge at init.
- `Sources/SwiftXServerCore/WindowBridge.swift` — protocol updates for
  new `clearArea` shape + `setWindowClipLookup`. MockWindowBridge
  default-impls updated.

### Paint-on-grow for descendant ConfigureWindow (the dthelpview-form fix)

- `Sources/SwiftXServerCore/ServerSession.swift` `handleConfigureWindow`
  — when descendant grows or moves, calls `paintRectsForWindow` on the
  descendant and emits via `paintWindowRects`, so its bg lands in its
  new visible region before the Expose. Mirrors the X server's
  contract per `reference_x11_server_owns_bg_paint`.
- `handleTopLevelResize` reordered: `recomputeClips` now runs BEFORE
  `mappedBackgroundPaints` (correctness no-op so the top-level's paint
  sees its fresh clipList).
- New `descendantBgPaints(of:byteOrder:)` helper — mirrors the 2026-05-19
  Expose cascade for the non-top-level MapWindow path so the dthelpview
  "children mapped before wrapper shell" pattern paints each descendant's
  bg as the subtree becomes viewable.

### GCState bg default (the xterm fix)

- `Sources/SwiftXServerCore/GCState.swift` — `background: UInt32 = 1`
  (was `0xFFFFFF`). Spec default per X11 protocol §7. The 0xFFFFFF
  sentinel was harmless until the 2026-05-19 ColorTable change pinned
  it to whitePixel.

### ChronoDumper value-list decoders (the tooling that made today fast)

- `Sources/SwiftXCaptureCore/ChronoDumper.swift` — three new inline
  decoders:
  - `decodeWindowAttrs(mask:values:)` for `CreateWindow` +
    `ChangeWindowAttributes` value-lists. Surfaces `bg-pixmap`,
    `bg-px`, `border-px`, `bit-grav`, `win-grav`, `override`,
    `save-under`. The smoking gun decoder — killed three wrong
    hypotheses for the DisplayArea bg in five minutes.
  - `decodeConfigureWindow(mask:values:)` for `ConfigureWindow`'s
    `x`/`y`/`w`/`h`/`bw`/`sibling`/`stack-mode` value-list.
  - `AllocColor` / `AllocNamedColor` reply pixel value formatting
    (`→ pixel=0x10 rgb=(...)`) so we never have to mentally count
    allocations to figure out what pixel `0x13` is.

### Docs / ledgers

- `SHORTCUTS.md` — three new Closed entries (clipping, paint-on-grow,
  GCState bg default). dthelpview cosmetic open entry rewritten —
  bg+aspect-ratio gaps separated; bg now closed, aspect-ratio remains.
  Two new Open entries: `subWindowMode=IncludeInferiors` untracked;
  border-ring rect not clipped to borderClip.
- New memory `reference_x11_server_owns_bg_paint.md` — the
  architectural principle behind both fixes. Linked from MEMORY.md.
- `project_motif_quickplot_status` — 2026-05-19 stamp noting today's
  fixes likely closed open issue #5 (and possibly #4); re-verify next
  session before formally closing.

### Tests

- New `DrawingDispatchTests.testClearAreaClippedByMappedChildren`
  locks in parent-ClearArea-clipped-by-children invariant. Existing
  `testClearAreaUsesWindowBackground` updated (post-fix, unmapped
  windows have empty clipList so the test now maps the window first).
- `CapturedAppReplayTests.testReplayDthelpview` baseline rebased to
  843 requests for the fresh `-manPage`-mode capture taken today
  (previous was 414 pre-`-manPage`; intermediate was 875 from an
  earlier capture).
- 542 total tests pass (294 server + 248 capture/framer), 4 skipped, 0 failures.

## What's still open (next session's queue)

1. **Verify quickplot fixes formally.** Open issues #4 (about-dialog
   animations) and #5 (blue-line-at-y=50 plot artifact) likely closed
   by today's clipping + paint-on-grow work, but unverified
   end-to-end. Should be the first thing — quick visual check on the
   live app, formally close the memory entries if confirmed.

2. ~~**dthelpview aspect ratio wider than SS2.**~~ **Closed 2026-05-20**
   via mean-not-max AVERAGE_WIDTH + Monaco-Bold fallback. See memory
   `project_dthelpview_cosmetic_open` for the FONTPROP spec audit lesson.

3. **Smoke other dt-apps and Motif clients post-clipping.** dtcalc,
   dtterm, dticon — quickplot got bonus fixes, others probably did too.
   Walk through each, note what's improved, what's still off.

4. **Resize-uncover repaint gap.** The 2026-05-10 "park Motif button
   chrome" parking decision is closed (DECISIONS 2026-05-24 — chrome
   renders fine post the 05-13/05-14/05-17 VisibilityNotify +
   QueryTextExtents + PolySegment-pixmap + PutImage/CopyArea fixes,
   and post the 05-18 CDE-impersonation retirement). The residual
   distinct bug is: dthelpview button-bar buttons look thinner after
   resize than before; dtpad's text-area drops content on resize.
   Root is in `ServerSession.handleConfigureWindow`'s descendant-
   uncover branch — not Expose architecture, not PushButton internals.
   Capture u5→swiftx during a dtpad resize and diff Expose against
   gold.

5. **Framer-shared bug investigation.** Deferred again. Still open.

## Working tree at end of day

Two commits today on `main`:

- `ef0d6eb` — Honor X server bg-paint contract: clip draws + paint on
  grow + fix GC bg default (the big one — clipping + paint-on-grow +
  GCState + ChronoDumper value-list decoders + 1 new regression test)
- `44f30ea` — quickplot memory: note that bg-paint-contract fixes
  resolved plot-window artifacts

Six commits ahead of `origin/main` total.

## Reflection

Three lessons from the day worth keeping:

**Tooling pays back disproportionately when it surfaces "what's
actually on the wire?".** The `CreateWindow` value-list decode was 50
lines added to ChronoDumper and immediately killed three hours of
hypothesis-spinning. Yesterday's GC fg/bg decode did the same for the
dtcalc LCD bug. Pattern: when a draw-related bug class shows up,
spend 30 minutes adding the relevant decoder before going deeper —
the diagnosis time saved is huge. Added two more decoders proactively
today (ConfigureWindow value-list, AllocColor/AllocNamedColor reply
pixel) on the same theory. Stopping there per "add when we hit the
same bug shape twice."

**Capture-first / screenshot-diff-first beats speculation every
time.** I went down two wrong paths today (ParentRelative hypothesis;
"the remaining blue strips are correct-by-spec"). Both got killed by
data Todd produced — the swiftx capture for the first, the
SS2/swiftx side-by-side for the second. `feedback_wire_matches_gold`
keeps being right. When I can't explain a pixel, ask for a comparison
shot or a capture before guessing.

**One architectural lens can unify N seemingly-unrelated bugs.**
Todd's "Athena widgets just *were* a color" observation didn't just
explain dthelpview — it instantly told me where the xterm
white-text-bg bug had to be (broken GC bg default; not a paint path
issue). And it predicted quickplot's plot-window artifacts would
close as a side effect. The right lens is force-multiplying; the
memory entry preserves it for the next session that hits a
"wrong-color-where-bg-should-be" symptom.
