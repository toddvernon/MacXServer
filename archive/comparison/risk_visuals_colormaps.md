# risk_visuals_colormaps.md — visuals + colormaps dimension

Risk register for the **Visuals + colormaps** dimension of swift-x: visual
classes advertised on the wire, default visual, RGB masks, and the full
CreateColormap / FreeColormap / CopyColormapAndFree / InstallColormap /
UninstallColormap / ListInstalledColormaps / AllocColor / AllocNamedColor /
AllocColorCells / AllocColorPlanes / StoreColors / StoreNamedColor / FreeColors
/ QueryColors / LookupColor opcode family. Three buckets: actively bleeding now,
will bleed when X happens, theoretical/spec-only.

Authority: spec > X11R6 > xorg+XQuartz > swift-x. Era target: X11R6 (single
client, no Render/ARGB, no Composite). Reference paths used in fix-shape
suggestions:

- `reference/X11R6/xc/programs/Xserver/dix/colormap.c` (era-correct semantics)
- `reference/xquartz-xserver/dix/colormap.c` (current xorg/XQuartz core)
- `reference/xquartz-xserver/mi/micmap.c` (default-colormap factory + visual
  table)
- `reference/x11-protocol-spec/x11protocol.html` sections "Visual Information"
  (line 1279) and the per-request entries from line 6017 (CreateColormap)
  through 6700 (LookupColor).

---

## Actively bleeding now

### 1. Eleven core colormap opcodes return `BadRequest` instead of doing their job.

**Severity: actively bleeding** for any client that touches a colormap beyond
the default the connection setup hands it. The framer doesn't decode opcodes
**78 (CreateColormap)**, **79 (FreeColormap)**, **80 (CopyColormapAndFree)**,
**81 (InstallColormap)**, **82 (UninstallColormap)**, **83
(ListInstalledColormaps)**, **86 (AllocColorCells)**, **87 (AllocColorPlanes)**,
**88 (FreeColors)**, **89 (StoreColors)**, or **90 (StoreNamedColor)**. Grep
evidence: `Sources/Framer/Requests/Request.swift` lines 63-66 only enumerate
`.allocColor`, `.allocNamedColor`, `.queryColors`, `.lookupColor`; the
`default:` arm at line 329 wraps everything else into `.unknown`, and
`Sources/SwiftXServerCore/ServerSession.swift:3918` calls `emitError(.request,
...)`. The dispatch comment at line 3922 calls this "spec-correct" but it isn't:
BadRequest is the right reply for "this opcode isn't recognized at all," while
these are perfectly valid core opcodes the server is choosing not to serve.
Clients that issue any of them get an `error 1` (BadRequest) instead of the
protocol-specified behaviour (`Success`, a real reply, or one of `BadAlloc` /
`BadColormap` / `BadMatch` / `BadAccess`).

**Triggers today**: every CDE dt-app's startup path calls `CreateColormap`
indirectly via Xt's `Visual` resource conversion (Xt opens the default colormap,
but a chunk of Motif gadgets call `XCopyColormapAndFree` to fork a private map
for animation transitions). quartz-wm calls `XInstallColormap` on every focus
change (`reference/quartz-wm/src/x-window.m:2642`), so if we ever switch from
rootless-self-WM to running quartz-wm we BadRequest every focus switch. xclock
from u5 doesn't trigger this. xterm doesn't. xcalc doesn't. **But** any client
that wants per-window animation, fades, or palette flashing (older Motif demos,
Solaris "screen blank" effects) does.

**Fix shape**: add framer decoders for all eleven. For CreateColormap on our
advertised PseudoColor visual, record the colormap mid → empty-allocation record
in a per-session table; if the client passes `alloc=All`, pre-fill pixels 0..N-1
(per spec, line 6076 onward). FreeColormap drops the table entry (defaults are
no-op per spec line 6094-ish — actually line 6470 area, xorg `dispatch.c:2469`).
CopyColormapAndFree is a memcpy-and-detach. Install/Uninstall return Success and
emit `ColormapNotify(state=Installed)` if any client selects
`ColormapChangeMask`. ListInstalledColormaps returns `[defaultColormap]` plus
whatever's been Install'd. AllocColorCells on our advertised PseudoColor visual
is the interesting one (entry 3 below). FreeColors just removes pixels from the
per-client allocation list. StoreColors / StoreNamedColor on a DynamicClass
colormap update the pixel→RGB table and trigger a redraw of every drawable using
that colormap.

### 2. Single visual advertised on the wire (`PseudoColor`), incoherent with the visible white pixel.

**Severity: actively bleeding latently.** `ServerConfig.swift:97-126` advertises
exactly one visual: PseudoColor at depth 8 with `colormapEntries = 256`, but
then publishes `whitePixel = 0xFFFFFF` and `blackPixel = 0`. A PseudoColor
visual with 256 entries can address pixels 0..255 only; 0xFFFFFF isn't a valid
colormap index. R6's `cfbInitVisuals` for an 8-bit pixmap format advertises six
visuals (StaticGray, GrayScale, StaticColor, PseudoColor, TrueColor, DirectColor
— `ALL_VISUALS` in `X11R6/xc/programs/Xserver/cfb/cfbcmap.c:342`); a real u5
cgsix at 8-bit exposes all six and clients pick. XQuartz advertises one visual
but it's *consistent* — at 24-bit it's TrueColor with whitePixel=`0x00FFFFFF`
(matches the OR'd red/green/blue masks) and blackPixel=0; at 8-bit it's
PseudoColor with whitePixel/blackPixel populated by AllocColor at
default-colormap creation, so they're in-range (`mi/micmap.c:260-267`).

What this costs today: most R6 clients use the screen's whitePixel/blackPixel as
opaque tokens — they pass them straight to CreateGC and CreateWindow. Since
swift-x's ColorTable pre-pins `0 → black` and `0xFFFFFF → white`
(`ColorTable.swift:27-28`) the drawing happens to work out. But a client that
does `pixel & 0xFF` to extract a colormap index (legitimate on PseudoColor) gets
`0xFF` (= 255) for white, which collides with whatever's at slot 255 in the
colormap. Clients that walk the visual list looking for TrueColor (modern
Motif's `XmGetVisualDefaults`, every Xft-aware client) find nothing and either
fall back to PseudoColor or hard-fail.

**Trigger today**: any modern Xlib client connecting to us looks for a TrueColor
visual to use Xft / Render and finds none — they fall back to core PolyText
which the current rendering pipeline handles, so it's invisible. **Will bite the
moment** we want a modern Linux client (your "vintage Sun + occasional debugging
Linux app" mix) or a Sun-side app that checks visual list for "must be TrueColor
or DirectColor for color image display" (Sun-era `xv`, `xli`, `xloadimage` all
do this).

**Fix shape**: advertise both a PseudoColor visual at depth 8 (the one we have,
plus consistent whitePixel/blackPixel = colormap indices 0 and 1 with ColorTable
seeded accordingly) AND a TrueColor visual at depth 24 with masks 0xFF0000 /
0x00FF00 / 0x0000FF. Pick TrueColor as the root visual. Migrate the rendering
pipeline to read TrueColor pixel values directly (pixel IS the RGB encoding) and
only fall back to the ColorTable lookup when the client explicitly picked
PseudoColor. This is also the natural shape for the macOS framebuffer
underneath, which is 32-bit RGBA.

### 3. AllocColor pretends every request gets a unique pixel; no upper bound, no shared cells, no FreeColors.

**Severity: actively bleeding latently.** `ColorTable.swift:88-94` hands out
monotonically-increasing pixel values starting at 16 with no cap and no
recovery. After ~16M AllocColor calls (Motif animation, a long-running xeyes, an
xterm with heavy 256-color use) the counter rolls past 32 bits and starts
colliding with the advertised resource-id space. R6's `AllocColor` for
PseudoColor (`dix/colormap.c:877` onward, `FindColor` helper at line 1128) walks
the colormap looking for an existing shared cell with the same RGB; only if no
match returns BadAlloc. xorg's same function at `dix/colormap.c:1012-1100` does
the same. Shared-cell semantics matter because they're what `FreeColors` plus
reference counting relies on — clients call FreeColors expecting the cell back
when refcount hits 0.

**Trigger today**: a Motif app that allocates colors in a tight loop. The
ColorTable comment at line 5-6 admits this: "This isn't a real palette (no
shared cells, no freelist, no cap)." We're not hitting it yet because the
clients we've tested allocate handfuls of colors at startup. xclock: 4 colors.
xterm: 6. xcalc: 8. quickplot: 12. dtcalc: pre-seeded from our hardcoded CDE
palette plus maybe 4 more.

**Fix shape**: bound `nextPixel` at `colormapEntries - 1` and emit `BadAlloc`
when full. Hash-bucket the (red, green, blue) tuple so identical allocs share a
cell. Refcount each cell so FreeColors works. The current "infinite unique
pixels" approach lets clients quietly leak the colormap until the counter wraps.

### 4. The default colormap (`0x21`) is referenced in setup but has no resource record.

**Severity: actively bleeding latently.** `ServerConfig.swift:75` hardcodes
`defaultColormapId: UInt32 = 0x21` and `makeSetupAccepted` puts it in the Screen
struct (line 111), but no entry is created in any per-session resource table.
`GetWindowAttributes` (`ServerSession.swift:3700`) always returns `0x21` as the
window's colormap regardless of any `ChangeWindowAttributes(CWColormap=...)` the
client did. If a client does `XGetWindowAttributes()` then `XInstallColormap()`
on the returned colormap field, both calls today silent-succeed (one is faked,
the other BadRequests). xorg's `miCreateDefColormap`
(`reference/xquartz-xserver/mi/micmap.c:236-272`) goes through the full
`CreateColormap` path including `AddResource(mid, RT_COLORMAP, ...)`, so
`dixLookupResourceByType` finds it from any later
Install/Uninstall/AllocColor/QueryColors.

**Trigger today**: nothing yet, because we never let the default colormap mid
escape our control. But the first client that does CreateColormap to clone the
default, or any colormap operation, hits issue #1.

**Fix shape**: model colormaps as a real resource table keyed by mid. Default
cmap gets `0x21` and a ColorTable instance. CreateColormap adds new mids.
Window's effective colormap is the one in CWColormap or default if unset, and
that's what GetWindowAttributes returns.

---

## Will bleed when X happens

### 5. AllocColorCells / AllocColorPlanes will BadRequest the first Motif app that wants writable cells.

**Severity: will bleed.** Era-correct Motif on a real Sun PseudoColor display
does `XAllocColorCells` to grab a block of writable slots for animation (button
click flash, drag highlight), and `XStoreColors` to rewrite their RGB while a
window is mapped — XQuartz's whole `// TODO: Make PseudoColor visuals not suck
in TrueColor mode` comment (`hw/xquartz/darwin.c:215`) is exactly the unresolved
version of this problem. Today swift-x BadRequests both. The spec says
(`x11protocol.html:6356-6383`) that on a DynamicClass visual
(GrayScale/PseudoColor/DirectColor) these requests must succeed with C pixels
and P masks returned; on a static class (StaticGray / StaticColor / TrueColor)
the request returns `BadAlloc`. R6's `AllocColorCells` at `colormap.c:1497` and
xorg's at `dix/colormap.c:1484` both return BadAlloc on a non-Dynamic visual —
which is what the client expects when it sees a TrueColor-only server, and is
what makes Xt/Motif fall back gracefully to read-only `XAllocColor`.
**BadRequest is the wrong wrong:** clients catch BadAlloc as "no writable cells,
fall back to closest-match," but BadRequest is a "your code is broken" signal
that some clients log loudly and bail on.

**Trigger when**: any Motif app whose theme uses palette-flash animation
(M-motif's drag-and-drop autoscroll arrow, certain dtwm window-frame flashes),
or any app that does `XAllocColorCells(... 8, 0, ...)` to grab a private
256-entry workspace. None of the dt-apps tested so far do this because they get
a pre-seeded SDT pixel set instead, but anything outside the dt umbrella (a real
Motif port that doesn't know about CDE's out-of-band palette) will hit it.

**Fix shape**: now that we advertise PseudoColor with 256 entries, the honest
move is to actually allocate writable cells from a real freelist and return
their pixel values and bit masks per spec. Then `StoreColors` updates pixel→RGB
and triggers a redraw of every drawable using that colormap (R6's
`colormap.c:720-782 UpdateColors` shows the per-screen redraw walk; xorg's at
line 698-756 is identical structure). Alternatively, flip the root visual to
TrueColor (item #2), at which point both opcodes return BadAlloc per spec and
Motif falls back to AllocColor. The latter is less work and matches what XQuartz
actually does on a 24-bit Mac.

### 6. StoreColors / StoreNamedColor on the default (PseudoColor) colormap will silently break palette animation.

**Severity: will bleed.** If we keep advertising PseudoColor (the current
posture), spec says `StoreColors` must update the cells named in the request
(`x11protocol.html:6500-6580`). R6 / xorg gate this on the DynamicClass bit
(`dix/colormap.c:2356`, xorg `dix/colormap.c:2240`) — returning BadAccess on a
static class is correct, but on PseudoColor (which is what we advertise) the
right answer is `Success` and a redraw. swift-x today BadRequests. A client that
does `XAllocColorCells; XStoreColors; redraw` to do palette animation today gets
BadRequest on the first XStoreColors and never animates, but worse, it doesn't
get the spec-correct BadAlloc signal that would tell it to abandon the animation
strategy and use slower per-frame redraws instead.

**Trigger when**: any palette-cycling demo from the R6 era. None of our current
corpus does this — it's a "we'll find out the day someone tries to run XCycle"
failure.

**Fix shape**: tied to #5. If we keep PseudoColor, implement StoreColors
properly: update ColorTable, walk windows, generate Expose on every drawable
that uses the affected colormap. If we move to TrueColor as the root visual,
return BadAccess per spec and call it done.

### 7. No `ColormapNotify` event ever gets sent.

**Severity: will bleed.** Spec (`x11protocol.html:9072`) says `ColormapNotify`
fires on two triggers: (a) a window's colormap attribute changes (new=True), or
(b) a colormap is installed or uninstalled (new=False), reported to clients with
`ColormapChangeMask` in their event mask. swift-x never emits this event in any
code path. quartz-wm uses it (`reference/quartz-wm/src/x-input.m:710
x_event_colormap_notify`) to re-install the focus-window's colormap; without it
the WM races against the server. dtwm and mwm both select ColormapChangeMask on
their managed frame windows for the same reason.

**Trigger when**: we ever swap rootless-self-WM for an external WM (quartz-wm or
a real mwm forwarded from the Sun), or any client that explicitly selects
ColormapChangeMask.

**Fix shape**: in the InstallColormap / UninstallColormap dispatch (item #1),
walk windows with that colormap and emit ColormapNotify to clients selecting it.
In the ChangeWindowAttributes path when CWColormap is in the mask, also emit
ColormapNotify(new=True) on that window.

---

## Theoretical / spec-only

### 8. The visual ID (`0x22`) and the default colormap ID (`0x21`) both fall outside the advertised resource-id range.

The setup advertises `resourceIdBase = 0x4400000` and `resourceIdMask =
0x1FFFFF` (`ServerConfig.swift:76-77`) — the client's pool of legal IDs is
`0x4400000 | (allocated & 0x1FFFFF)`. The server-side defaults at `0x21` and
`0x22` (lines 73-75) are in the server's own ID space, which is fine per spec,
but the choice is a bit nonsensical: the X protocol convention is server IDs
above any client base. R6 servers use IDs like `0xFFFE_0000`+ for their built-in
resources. Currently harmless because no client tries to overlap these.

**Trigger**: a misbehaving client passing the literal `0x21` colormap ID to a
no-op operation. Spec compliance only.

**Fix shape**: cosmetic. Move server-built resources to the top of the 32-bit ID
space (`0xFFFE_0000`+) to match R6.

### 9. `bitsPerRgbValue = 8` on a PseudoColor visual is consistent but constrained.

`ServerConfig.swift:101` sets `bitsPerRgbValue: 8`. Spec
(`x11protocol.html:1328`) says this is log2 of the number of distinct intensity
values per primary, not related to colormap entry count. 8 means clients can
pass 0..255-quantised intensities and expect quantised colors back. R6
`miResolveColor` (`reference/xquartz-xserver/mi/micmap.c:87`) rounds incoming
protocol intensities (0..65535) to the bits-per-RGB precision, so 8 means our
rounding granularity is 256 levels per channel per cell. Fine; matches real
cgsix.

**Trigger**: nothing — observation only.

### 10. No `minInstalledMaps` / `maxInstalledMaps` story beyond hardcoded 1/1.

`ServerConfig.swift:119-120` hardcodes both to 1. Real Sun cgsix advertises 2/4
(overlay + main). Spec (`x11protocol.html` connection setup, the Screen block)
says these are how many colormaps can be simultaneously installed by the
server's hardware. With virtual cells on TrueColor (which is what we'd be
implementing if we filled out #5), we effectively have infinite installed
colormaps — the meaningful value would be `maxInstalled = 1` to discourage
clients from trying to install many. Today's 1/1 is fine for single-client.

**Trigger**: only matters if a client checks this and adapts its strategy (e.g.
a colormap-flipping demo from R5 era). Theoretical.
