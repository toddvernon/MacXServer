# Status 2026-05-31 -- capture-decoder marathon, Sun-less

Couldn't reach the vintage Suns today, so leaned all the way into
capture-side decoder work. Fifteen commits, all pushed. Tests:
1083 -> 1225 (+142 new). Zero regressions. macXcapture checklist:
24/35/67/1 -> 36/33/57/1 -- six rows moved Yes, two moved Partial,
six closed from No.

All five top-5 readability gaps from the checklist's vintage-X lens
section closed in this one day: keysym/modifier symbolic decode,
WM-property type-aware decode, visual catalog lookup,
XC-MISC/XTEST/RECORD extension decoders, and the resource registry
with lineage. Plus several follow-ups beyond the top-5, a final
landmark-text enrichment pass that surfaces today's data inside the
existing landmark vocabulary, and a late wedge that lifts today's
capture-side ResourceRegistry into the live server so macxserver's
own XError landmarks pick up the same use-after-free annotation.

## The fifteen commits

In order:

- `09bf07e` server: quiet stderr by default, add `--verbose`.
  Per-session and bridge traces moved to
  `/tmp/macxserver/<inst>-<ts>.log`; only the startup banner +
  listener events (accept errors, shutdown) hit stderr now. `-v`
  restores the live mirror when debugging.
- `44ce275` keysym + modifier symbolic decode. 1224-entry table
  generated from `reference/X11R6/xc/include/keysymdef.h` via
  `Tools/regen_keysyms.sh`. ChronoContext now tracks a session
  keymap populated from `GetKeyboardMapping` replies and
  `ChangeKeyboardMapping` requests; KeyPress/Release translate
  keycode to keysym. Modifier masks render as `Shift|Ctrl|Mod1`.
- `6a4b1ab` ICCCM WM_* type-aware property decode. WM_NORMAL_HINTS,
  WM_HINTS, WM_STATE, WM_CLASS, WM_PROTOCOLS, WM_TRANSIENT_FOR.
  Wires into both ChangeProperty and GetProperty reply paths.
- `9d1a567` visual catalog lookup. `ChronoContext.visualCatalog`
  harvested from SetupAccepted. visualIds render as
  `0x22(PseudoColor d8)`. CreateWindow gained inline depth + visual
  fields.
- `6af1270` XC-MISC + XTEST + RECORD extension decoders. Three new
  ExtensionDumpers registered. XTEST's FakeInput surfaces the
  synthesized event-type and detail (keycode/button/absolute-vs-
  relative).
- `b1adba7` session-wide resource registry + lineage.
  `ResourceRegistry` tracks Create*/Free* for all 6 X11 resource
  kinds. Powers two consumer features: session-end summary line
  (`# resources: 47 pixmaps (3 freed, 44 leaked)`) and
  use-after-free annotation on XError landmarks
  (`(freed at seq=Y, created at seq=X)`).
- `b916974` _MOTIF_* property decoders. `_MOTIF_WM_HINTS`,
  `_MOTIF_WM_INFO`, `_MOTIF_DRAG_WINDOW`, `_MOTIF_DRAG_RECEIVER_INFO`.
  Includes the embedded `byte_order` tag on DnD properties.
- `f4548b2` property type-driven fallback. CARDINAL / INTEGER /
  STRING / UTF8_STRING / COMPOUND_TEXT / WINDOW / PIXMAP / etc.
  decode by type atom when the property name isn't in the WM_* set.
  Closes §3 type-aware-decoding from Partial to Yes.
  RESOURCE_MANAGER now reads as inline text instead of `data=30567b`.
- `a353eac` ClientMessage payload decode. WM_PROTOCOLS messages
  render `protocol=WM_DELETE_WINDOW time=12345`;
  `_MOTIF_WM_MESSAGES` map message codes to named MWM_F_FUNCTION_*
  values; everything else gets the format-aware generic dump.
- `02643bb` WM_COMMAND argv decode. Splits NUL-terminated argv into
  a quoted list.
- `2ed2d0a` reply-body decode batch 1 (top 10 by corpus frequency).
  GetInputFocus, GetAtomName (also populates `atomToName` in
  reverse), GetGeometry, QueryTree, GetWindowAttributes,
  QueryColors, GetModifierMapping, GrabPointer/GrabKeyboard,
  GetSelectionOwner, QueryPointer, TranslateCoordinates,
  QueryBestSize. ~3300 reply lines across the corpus affected.
- `3e328a5` reply-tail (final 16). ListProperties, ListFonts,
  ListFontsWithInfo, GetFontPath, ListExtensions,
  ListInstalledColormaps, ListHosts, GetImage, GetKeyboardControl,
  GetPointerControl, GetPointerMapping, GetScreenSaver,
  QueryKeymap, QueryTextExtents, LookupColor, SetModifierMapping,
  SetPointerMapping. Closes §3 "All core replies decoded" Partial
  to Yes.
- `7562efd` SM_CLIENT_ID + WM_CLIENT_LEADER + WM_COLORMAP_WINDOWS
  naming polish. Slight relabeling on top of the type-fallback.
- `fb48a93` landmark enrichment using today's data: provenance
  suffix on the map landmark (class + host + argv); symbolic
  modifier prefix on click landmark (`Shift-clicks`, `Ctrl-clicks`);
  modal vs non-modal dialog distinction via
  `_MOTIF_WM_HINTS.inputMode`; per-window text cache feeding button
  labels on click landmarks (`clicks on "OK" in "Save?"`).
- `bdc393b` server-side ResourceRegistry.
  `ServerSession` now owns a `ResourceRegistry`, calls
  `trackResourceLifecycle` after each request decode, and threads
  the registry into both `LandmarkDetector.afterServerMessage` call
  sites (the event-emit path and the `emitError` path). Live
  macxserver XError landmarks now read the same way the capture
  viewer's do, e.g. `# BadGC at seq=100 from CopyArea on "xterm"
  (freed at seq=88, created at seq=42)` instead of the bare
  resource line. Three new tests in
  `Tests/SwiftXServerCoreTests/ResourceLineageLandmarkTests.swift`
  cover the freed-then-used, still-live, and registry-never-saw-it
  cases. `trackResourceLifecycle` promoted from internal to public
  in `ChronoDumper.swift` so `SwiftXServerCore` can call it. Zero
  behavior change on the capture side.

## What's reading better now

All taken from real corpus dumps:

```
KeyPress event:
  before: KeyPress ... keycode/btn=108 state=0x4
  after:  KeyPress ... X (keycode=108) state=Ctrl

WM_NORMAL_HINTS ChangeProperty:
  before: prop=WM_NORMAL_HINTS ... data=72b
  after:  prop=WM_NORMAL_HINTS ... flags=PSize|PWinGravity
          PSize=484x316 gravity=NorthWest

CreateWindow:
  before: CreateWindow ... class=inputOutput ... mask=0x80A
  after:  CreateWindow ... class=inputOutput depth=8
          visual=0x22(PseudoColor d8) mask=0x80A

RESOURCE_MANAGER GetProperty reply:
  before: Reply (GetProperty) prop=RESOURCE_MANAGER ... data=30567b
  after:  Reply (GetProperty) prop=RESOURCE_MANAGER type=STRING
          format=8 value="! Reserved for resources that should..."
          (30567 bytes)

GetGeometry reply:
  before: Reply (GetGeometry)
  after:  Reply (GetGeometry) root=0x2B at (0,0) 484x316 border=0 depth=8

GetModifierMapping reply:
  before: Reply (GetModifierMapping)
  after:  Reply (GetModifierMapping) perMod=3 Shift=[106,117]
          Lock=[126] Ctrl=[83] Mod1=[127,129] Mod2=[20] Mod3=[26]
          Mod4=[105] Mod5=[32,80,104]

XError landmark (when registry has seen the resource):
  before: # BadGC at seq=100 from CopyArea (bad resource 0x300)
  after:  # BadGC at seq=100 from CopyArea (bad resource 0x300)
          (freed at seq=88, created at seq=42)

Map landmark for a top-level:
  before: # The "dogs" window appears on screen (0x5200057, 614x353)
  after:  # The "dogs" window appears on screen (0x5200057, 614x353,
          ApplicationShell class, host "ss2")

Click landmark on a button:
  before: # The user clicks inside "bitmap" on a 60x26 child 0x... at (31,10)
  after:  # The user clicks on "File" in "bitmap" at (31,10)

Click landmark with modifier state:
  before: # The user clicks inside "xterm" on a 484x316 child at (64,204)
  after:  # The user Ctrl-clicks inside "xterm" on a 484x316 child at (64,204)

Session-end summary:
  before: # Session ends after 11.43s (297 requests, 22 events)
  after:  # Session ends after 11.43s (297 requests, 22 events)
          # resources: 2 windows (0 freed, 2 leaked), 1 pixmap
          (0 freed, 1 leaked), 7 GCs (1 freed, 6 leaked), ...
```

## Checklist progress (macXcapture-feature-checklist.md)

Started: 24 Yes / 35 Partial / 67 No / 1 N/A.
Ended:   36 Yes / 33 Partial / 57 No / 1 N/A.

Row-level closures:

- §3 Keysym values decoded to symbolic names: No -> Yes.
- §3 Modifier masks decoded symbolically: No -> Yes.
- §3 Resource IDs tracked across the session: Partial -> Yes.
- §3 Resource creation lineage shown: No -> Yes.
- §3 Resource lifetime tracked: No -> Yes.
- §3 Visual and depth references resolved: No -> Yes.
- §3 Property values decoded with type awareness: Partial -> Yes.
- §3 All core replies decoded: Partial -> Yes.
- §4 XC-MISC: No -> Yes.
- §4 XTEST: No -> Yes.
- §4 RECORD: No -> Yes.
- §6 Use-after-free detection: No -> Yes.
- §6 Resource leak detection: No -> Partial (session-end summary
  lands the data; per-resource detail still missing).

The vintage-X-lens section's top-5 readability gaps are all now
marked Closed.

## What's still open

Carrying over from prior status entries, no progress today on:

- Framer-shared bug investigation (open since 05-19).
- dtpad Gap B: text-area paint loss on resize (05-25).
- dtpad menu-bar erase on dialog popup (05-25).
- Horizontal scrollbar reverse-image rendering (05-25).
- Clip-shape and descendant-window shape rendering (stored but
  not yet rendered; no hosted client needs them today).
- ShapeNotify per-session, not cross-session (low priority).

New noise since today's push:

- The 57 remaining No rows on the macXcapture checklist. Most are
  not vintage-specific: modern Tier-2 extensions (RANDR, COMPOSITE,
  DAMAGE, XFIXES, XINPUT2, Present, GLX, SYNC), viewer UI features
  (structured navigation, follow-this-resource, bookmarks), `.pcap`
  export, cookie redaction.
- `AllocColorCells` and `AllocColorPlanes` replies don't have
  framer decoders. Not blocking anything; both are rarely-used
  8-bit-colormap allocation patterns.
- ~~Server-side ResourceRegistry population.~~ Done in the late
  wedge above. macxserver's live XError landmarks now carry the
  `(freed at seq=Y, created at seq=X)` annotation the capture
  viewer gets. Took ~30 minutes as forecast.

## Note for next session

One reasonable continuation if vintage Suns are still offline:

- **Curate `captures/` into `CORPUS.md`** as the launch deliverable
  with per-capture metadata (which Sun, which app, what's
  interesting about it). Half-day docs work, lower technical
  density, but it's the project's most distinctive deliverable for
  the OSS launch (the checklist's vintage synopsis explicitly names
  the corpus as the project's most valuable asset).

Or start with whatever's actually on the Sun-availability front.

## Tooling notes for this session and next

- `tail -F /tmp/macxserver/<instance>-*.log` is the right way to
  watch a server session now that stderr is quiet by default.
  `--verbose` mirrors the disk log to stderr if you want both.
- Both capture viewer windows (the macXcapture app and macxserver's
  "Open .xtap..." in the debug menu) feed off the same
  `ChronoDumper.dump(path:)` call, so every decoder enrichment from
  today applies to both viewers automatically. Run with `--capture`
  and open the resulting `.xtap` to get the rich-decoded server
  trace; that's the right "I want server-side wire visibility"
  workflow.

Previous status entries below.

---

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
