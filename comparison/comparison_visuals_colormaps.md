# Visuals + colormaps: spec / R6 / xorg+XQuartz / swift-x

Three-way narrative for the visual-class + colormap-opcode family. Authority
order: spec > X11R6 > xorg+XQuartz > swift-x. Era target: X11R6. xorg ≈ XQuartz
collapsed into one column with XQuartz overrides called out.

The driving question: real Sun u5/SS2 clients (and CDE's dt-apps in particular)
were written for an 8-bit PseudoColor world. They want to allocate private
colormap cells, store new RGB values into them, and watch the screen update.
swift-x runs on a 24-bit TrueColor Mac. xorg+XQuartz also runs on a 24-bit Mac.
What does each implementation do about it?

---

## Spec (`reference/x11-protocol-spec/x11protocol.html`)

Six visual classes (line 1089-1090): `StaticGray`, `GrayScale`, `StaticColor`,
`PseudoColor`, `TrueColor`, `DirectColor`. Static classes have read-only
colormaps with server-defined values; Dynamic classes (GrayScale, PseudoColor,
DirectColor) allow client allocation and `StoreColors` (line 1284-1320).
TrueColor and StaticColor decompose pixels into separate RGB subfields per the
visual's red/green/blue masks; the masks are only defined for those two classes
(line 1321-1326). `bitsPerRgbValue` is log2 of the per-primary intensity
quantization (line 1328), unrelated to colormap entry count.

A screen can advertise any number of depths, each with any number of visuals. A
server picks one as the screen's `rootVisual` (returned in the setup reply's
Screen block).

The colormap requests, in dispatch-table order with their authoritative errors:

| Opcode | Request | Errors |
|---|---|---|
| 78 | CreateColormap | Alloc, IDChoice, Match, Value, Window |
| 79 | FreeColormap | Colormap |
| 80 | CopyColormapAndFree | Alloc, IDChoice, Colormap |
| 81 | InstallColormap | Colormap |
| 82 | UninstallColormap | Colormap |
| 83 | ListInstalledColormaps | Window |
| 84 | AllocColor | Alloc, Colormap, Value |
| 85 | AllocNamedColor | Alloc, Colormap, Name |
| 86 | AllocColorCells | Alloc, Colormap, Value |
| 87 | AllocColorPlanes | Alloc, Colormap, Value |
| 88 | FreeColors | Access, Colormap, Value |
| 89 | StoreColors | Access, Colormap, Value |
| 90 | StoreNamedColor | Access, Colormap, Name, Value |
| 91 | QueryColors | Colormap, Value |
| 92 | LookupColor | Colormap, Name |

Notable spec subtleties:

- `CreateColormap(alloc=All)` on a Dynamic class pre-allocates every cell
  writable (line 6072-6094); on a Static class it requires `alloc=None` or
  returns `Match`.
- `AllocColorCells` (line 6333-6383) returns C pixels + P masks. With C=1 and
  P=0 it returns one writable cell — a common idiom in Motif for "give me a
  single writable color." On a Static class it's `Alloc`.
- `StoreColors` (line 6497 onward) on a Static class is `Access`. On a Dynamic
  class with cells the client allocated read-only (via AllocColor) it's also
  `Access` — only AllocColorCells/Planes cells are writable.
- `FreeColors` decrements a per-client refcount; only freeing the last reference
  actually returns the cell to the pool. Cells freed are still legal to use as
  pixel values until the next AllocColor reuses them.
- `ColormapNotify` (events, line 9072) fires on two distinct triggers:
  CWColormap change (new=True) and Install/Uninstall (new=False). Both require
  `ColormapChangeMask` selected on the affected window.

---

## X11R6 (`reference/X11R6/xc/programs/Xserver/`)

The era target. Real Sun u5 with cgsix at 8-bit runs this. Default-install
behaviour:

`cfb/cfbcmap.c:399 cfbInitVisuals` is the visual factory. With pixmap formats
including 8bpp (`screenInfo.formats[*].depth == 8`) and no explicit
`cfbSetVisualTypes` call, it falls through to `vtype = ALL_VISUALS` at line 434
(`cfbcmap.c:342` defines `ALL_VISUALS = StaticGrayMask | GrayScaleMask |
StaticColorMask | PseudoColorMask | TrueColorMask | DirectColorMask`). **Six
visuals at depth 8**. The priority list (`cfbcmap.c:361`) picks PseudoColor as
the default.

`dix/colormap.c` is where the protocol semantics live, 2650 lines of it. Notable
entry points:

- `colormap.c:258 CreateColormap` — allocates the per-cell `Entry` table, the
  per-client `clientPixelsRed[MAXCLIENTS]` allocation lists, and (for
  DirectColor) the parallel green/blue tables. Calls the screen's
  `CreateColormap` proc (typically `miInitializeColormap` via cfb) to fill in
  initial RGB for static classes. The `BeingCreated` flag bypasses the
  static-class write protection so the device can seed the table.
- `colormap.c:788 AllocColor` — branches on visual class. For TrueColor it
  separately closest-matches each component in its own subtable; for
  PseudoColor/GrayScale it walks the colormap with `FindColor` looking for an
  existing shared-RGB cell (refcount bump) or grabs a free cell.
  StaticColor/StaticGray return closest-match only. The client-allocation list
  (`pmap->clientPixelsRed[client]`) is what makes FreeColors and client-death
  cleanup work.
- `colormap.c:1497 AllocColorCells` — returns BadAlloc if the class isn't
  DynamicClass (line 1512-1513). Otherwise delegates to `AllocPseudo` (line
  1789) for GrayScale/PseudoColor or `AllocDirect` (line 1669) for DirectColor.
  Each returns C pixels and packs P masks of contiguous-or- scattered bits.
- `colormap.c:2356 StoreColors` — gates on DynamicClass at line 2372 (BadAccess
  if static), then walks the def list. For DirectColor it decomposes the pixel
  into R/G/B subfields and updates each subtable separately. For PseudoColor it
  updates the unified table and walks for shared-cell propagation (line 2575
  onward — if the cell is shared with another cell tracking the same SHAREDCOLOR
  struct, all sharers get a follow-up `StoreColors` call to keep the hardware in
  sync).
- `colormap.c:720 UpdateColors` — used after CopyColormapAndFree to push the
  freshly-copied palette into the device.

The Sun-specific layer (`hw/sun/sunCfb24.c:104 CG24ScreenInit`) wraps cfb,
overriding `pScreen->StoreColors = CG24StoreColors` (line 120) so that
StoreColors writes through the cgsix hardware palette register. The
`InstallColormap` slot points at `sunInstallColormap` (line 117), which
poke-pokes the hardware. **The hardware palette is real on u5** — it's a
DAC-driven 256-entry table inside the cgsix chip.

So on R6/u5, when a Motif client does `XAllocColorCells; XStoreColors; redraw`,
the cells get a real hardware DAC register, StoreColors writes to that register,
and the screen instantly shows the new color without any client-side redraw.
This is the model Motif/Xt expects.

---

## xorg + XQuartz (`reference/xquartz-xserver/`)

The dix-side semantics in `dix/colormap.c` are textually almost identical to R6
— same K&R-vs-ANSI difference but the same logic. The interesting divergence is
the **screen-level visual list**, controlled by the DDX (the "hardware" layer):

`hw/xquartz/xpr/xprScreen.c:357-400` is the switch table. At depth 24 (today's
Macs): **TrueColor only**.

```
dfb->visuals      = TrueColorMask;     // line 391 — bitmask, NOT a list
dfb->preferredCVC = TrueColor;
dfb->depth        = 24;
dfb->bitsPerRGB   = 8;
dfb->redMask      = 0x00FF0000;
dfb->greenMask    = 0x0000FF00;
dfb->blueMask     = 0x000000FF;
```

At depth 8 it would be PseudoColor only (line 357-367), but Mountain Lion killed
8-bit backing stores and the case is now functionally dead.

`hw/xquartz/darwin.c:209` plumbs that single bitmask into
`miSetVisualTypesAndMasks`, which in `mi/micmap.c:319-350` builds the visual
table for the screen. With `visuals = TrueColorMask`, the HAKMEM popcount at
line 343-345 yields `count = 1`, so the screen advertises **exactly one visual**
at depth 24.

There's a telling comment at `darwin.c:215`:

```c
// TODO: Make PseudoColor visuals not suck in TrueColor mode
// if(dfb->depth > 8)
//    miSetVisualTypesAndMasks(8, PseudoColorMask, 8, PseudoColor, 0, 0, 0);
```

That commented-out block is the unwritten emulation layer. XQuartz wanted to
advertise an 8-bit PseudoColor visual alongside the 24-bit TrueColor one (which
would let Motif use writable cells), but never solved how to emulate hardware
palette switching on a TrueColor framebuffer. The honest answer needs
StoreColors to walk every drawable using that colormap, look up every pixel in
software, find pixels referencing the changed cell, and rewrite the
backing-store pixels with the new RGB — a full virtual cell emulation. Nobody
has shipped this in xorg/XQuartz for at least 15 years; the comment goes back to
roughly 2010.

So in practice, what XQuartz does when a Motif app asks for writable cells:

1. App calls `XGetVisualInfo` looking for `class == PseudoColor`. Gets nothing
   back. Falls back to whatever's available (TrueColor).
2. App calls `XAllocColorCells` on the default (TrueColor) colormap.
   `dix/colormap.c:1494` returns `BadAlloc` because TrueColor lacks the
   DynamicClass bit (`include/X11/X.h:359` defines `DynamicClass = 1;
   StaticColor = 2; PseudoColor = 3; TrueColor = 4; DirectColor = 5; StaticGray
   = 0; GrayScale = 1` — Dynamic == odd value).
3. The Xt color converter (`reference/X11R6/xc/lib/Xt/Convert.c
   CvtStringToPixel`) catches BadAlloc and falls back to `XAllocColor`
   (read-only closest-match).
4. The app draws using read-only pixels, no animation, no palette flash.

That's the entire emulation: **emit BadAlloc, let the client fall back.** It
works because Xt has the fallback path. Motif apps that animate by StoreColors
fail silently (the animation just doesn't happen). Apps that need
StoreColors-style animation use double-buffering or PutImage as a workaround.

XQuartz's `InstallColormap` / `UninstallColormap` go through `mi/micmap.c:54-83
miInstallColormap` / `miUninstallColormap` — these just update a per-screen
"currently installed" pointer and emit `ColormapNotify(new=False,
state=Installed)` to selecting clients via `WalkTree(TellGainedMap)`. **Zero
hardware effect** — there's no hardware palette on a TrueColor framebuffer to
flip. The whole install/uninstall concept is vestigial on modern displays but
the events still fire, and clients (notably quartz-wm at `x-window.m:2642`)
still rely on them.

`fb/fbcmap_mi.c` is even more vestigial: every function is a one-line wrapper
around `mi*` (`fbInstallColormap` → `miInstallColormap`, etc.). No actual
framebuffer work. `mi/micmap.c:236 miCreateDefColormap` is the factory: at
server startup it creates one Colormap resource at the screen's `defColormap`
mid using `CreateColormap` with `alloc=AllocNone` on a Dynamic visual or
`alloc=AllocAll` on a Static visual (lines 250-253), then pre-allocates the
screen's white/black pixels via `AllocColor` to populate `pScreen->whitePixel`
and `pScreen->blackPixel` (lines 260-267). That's why XQuartz's whitePixel and
blackPixel are always consistent with the colormap: they come straight out of
AllocColor.

---

## swift-x (`Sources/`)

The single visual story is in `SwiftXServerCore/ServerConfig.swift:97-126
makeSetupAccepted`. One visual at depth 8:

```swift
let pseudoColor8 = VisualType(
    visualId: rootVisualId,
    visualClass: .pseudoColor,
    bitsPerRgbValue: 8,
    colormapEntries: 256,
    redMask: 0, greenMask: 0, blueMask: 0
)
let depth8 = Depth(depth: 8, visuals: [pseudoColor8])
```

Set as `rootVisual` and the only entry in `allowedDepths`. The screen also
publishes `whitePixel: 0xFFFFFF, blackPixel: 0x000000` (line 112-113), which is
**incoherent with a 256-entry PseudoColor visual** — 0xFFFFFF isn't a valid
index into a 256-entry table. R6 / xorg would have populated these via
AllocColor at default-colormap creation, getting back small integer indices like
0 and 1. swift-x's `ColorTable` (`ColorTable.swift:25-28`) papers over this by
pinning entries for both `pixel=0` and `pixel=0xFFFFFF`, so resolveColor at draw
time finds them. The colormap is emulated entirely in software and never touches
a real hardware palette.

The colormap-opcode dispatch is in `SwiftXServerCore/ServerSession.swift`. Only
four colormap-family opcodes are handled:

- `case .allocColor` at line 3080 — appends to a per-session `ColorTable`,
  returning a monotonically-increasing pixel value starting at 16.
- `case .allocNamedColor` at line 3091 — resolves the name against the embedded
  X11R6 rgb.txt database (`XColorDatabase`) and delegates to AllocColor.
- `case .lookupColor` at line 3114 — same name resolution, no allocation.
- `case .queryColors` at line 3587 — looks up each requested pixel in the
  ColorTable, returns black for unknowns.

Every other colormap opcode — CreateColormap (78), FreeColormap (79),
CopyColormapAndFree (80), InstallColormap (81), UninstallColormap (82),
ListInstalledColormaps (83), AllocColorCells (86), AllocColorPlanes (87),
FreeColors (88), StoreColors (89), StoreNamedColor (90) — falls through the
framer's `default:` arm at `Sources/Framer/Requests/Request.swift:329` into
`.unknown(opcode:, bytes:)`, which `ServerSession.swift:3918` dispatches to
`emitError(.request, majorOpcode: op)`. That's a BadRequest error on the wire.
The comment at line 3922 frames this as "per XError-honesty policy, don't
silently drop" — better than silent-drop, but BadRequest is semantically wrong
for "the opcode is valid, the server just hasn't implemented it." The right
errors are `BadAlloc` (AllocColorCells on a static visual), `Success`
(CreateColormap, InstallColormap), or a synthetic reply
(ListInstalledColormaps).

The `ColorTable` itself (`SwiftXServerCore/ColorTable.swift:20-101`) is a single
Swift dictionary `pixelToRGB: [UInt32: RGB16]` per session, not keyed by
colormap mid. There's no resource record for the default colormap; the
`defaultColormapId = 0x21` advertised in the setup is purely a wire token. The
table pre-seeds 23 entries (lines 58-82) with a hardcoded approximation of the
CDE "Default" colour scheme — necessary because dt-apps reference those pixels
by index (via the SDT Pixel Set property we impersonate at session init) without
ever calling AllocColor. Without the pre-seed, resolveColor returns black for
every dt-app widget and the whole calculator paints black-on-black.

`nextPixel` is unbounded (line 22) — it starts at 16 and increments forever with
no cap and no recycling. After ~16M AllocColor calls the counter rolls into the
resource-ID space and collisions become possible. For today's workloads (xclock
allocates 4 colors, xterm 6, dtcalc draws from the pre-seeded set) this is a
theoretical problem, but a long-running Motif session with palette animation
hits it.

Resource side: there's no `colormaps` table in
`SwiftXServerCore/ResourceTables.swift`. The grep is empty (only mention is a
comment in a different context, line 339). So `CreateColormap` couldn't record a
new mid even if the dispatch existed.

`GetWindowAttributes` (`ServerSession.swift:3700`) hardcodes the reply's
colormap field to `config.defaultColormapId` regardless of any CWColormap the
client set. Same hardcode in the conceptual `ChangeWindowAttributes` flow —
CWColormap is decoded but the change isn't persisted to the WindowEntry (would
need to verify by reading `ValueListReader.swift` and the CreateWindow /
ChangeWindowAttributes dispatch, but the absence of any ColorTable lookup keyed
by window confirms this isn't actually wired through).

---

## Surprises and divergences

**1. xorg/XQuartz ship far fewer visuals than R6.** Real cgsix on u5 at 8-bit
advertises six (ALL_VISUALS); XQuartz at 24-bit advertises one (TrueColor only).
The xorg DDX makes this choice deliberately — modern Mac displays are TrueColor
framebuffers and emulating the others usefully would require the virtual-cell
layer XQuartz never shipped. swift-x splits the difference accidentally: it
advertises one visual (matching XQuartz's discipline) but it's PseudoColor
(matching R6 era) — and the result is incoherent, because we render on a
TrueColor Mac but tell clients we have a hardware palette.

**2. The `// TODO: Make PseudoColor visuals not suck in TrueColor mode` comment
at `hw/xquartz/darwin.c:215` is the single most quoted line in any "why doesn't
X-on-Mac just work" discussion.** It's the unsolved problem at the intersection
of every Motif-on-TrueColor story. XQuartz's answer is to not pretend; swift-x's
answer is to pretend and hope nobody calls AllocColorCells. So far nobody has —
dt-apps get pre-seeded pixels through the CDE protocol, xterm/xclock/xcalc
allocate handfuls of read-only colors, and our test corpus doesn't include
anything that animates a palette.

**3. The whitePixel inconsistency in our setup is a real bug.** R6 / xorg both
populate whitePixel/blackPixel by calling AllocColor on (0xFFFF, 0xFFFF, 0xFFFF)
and (0, 0, 0) at default-colormap creation time, getting back colormap indices.
They're guaranteed in-range. swift-x hardcodes 0xFFFFFF and 0
(`ServerConfig.swift:112-113`), and the value 0xFFFFFF is out of range for the
256-entry PseudoColor visual we advertise. We get away with it because no client
today does `pixel & 0xFF` to extract a colormap slot from whitePixel. The day
one does, it'll get slot 255 (which is nothing in our table) and paint black.

**4. `ColormapNotify` is the spec event nobody emits and quartz-wm depends on.**
quartz-wm calls `XInstallColormap` on every focus change (`x-window.m:2642`).
With swift-x as the server and quartz-wm as the WM, every focus switch would
BadRequest because we don't decode InstallColormap. Today we're rootless-self-WM
so we never call quartz-wm, but the moment someone tries to use a real WM (mwm
forwarded from the Sun, which is the obvious endpoint for Product 4) we're
broken.

**5. The dispatch returns BadRequest instead of BadAlloc/BadAccess/Match.** This
is a subtle correctness bug: BadAlloc on AllocColorCells signals to Xt's color
converter to fall back to read-only closest-match; BadRequest signals "your code
is broken." Most Xlib clients log BadRequest loudly to stderr but recover; some
(older Motif gadget libraries) treat it as fatal and abort. The fix shape isn't
"decode all opcodes" — it's "at minimum, emit the spec-correct error for opcodes
we choose not to implement."

**6. Era-correct R6 cfb had real CG24StoreColors hardware paths.** The
`hw/sun/sunCfb24.c:120` slot points at a function that writes through the cgsix
DAC. On modern Macs we have nothing equivalent — Core Graphics doesn't expose a
palette register because there isn't one. To make PseudoColor actually animate
on Mac, we'd have to do what XQuartz never did: maintain a virtual cell table,
store each drawable's pixel allocation as 8-bit indices (not the resolved RGB),
and reblit every affected drawable on every StoreColors. Expensive, but doable
for the small windows typical of R6 apps. This is the third option for
risk-register item #5.

---

## Blog hooks

**1. "How a 24-bit-only Mac pretends to be an 8-bit Sun for old apps."** The
XQuartz `// TODO: Make PseudoColor visuals not suck in TrueColor mode` comment
is the perfect anchor. Walk through what writable cells were for (palette flash
animation, smooth gradients, dithering on 8-bit hardware), what spec says
StoreColors must do, what XQuartz does in practice (returns BadAlloc on
AllocColorCells, never advertises PseudoColor on a TrueColor display, lets Xt
fall back to read-only), and what an honest emulation would look like (the
virtual-cell-redraw scheme — store indices not RGB per drawable, walk every
drawable on StoreColors). Mention the ~15-year-old comment that's still in the
source. The conclusion: the problem isn't technically hard, it's just that
nobody who cares about modern Mac performance also cares about R6-era Motif
palette animation.

**2. "Six visuals, one visual, no visual: how three X servers decode the
colorspace question."** R6 on cgsix advertises six visuals at depth 8
(closest-match for every kind of client). XQuartz at depth 24 advertises one
(TrueColor, the modern reality). swift-x today advertises one PseudoColor — the
worst of both worlds, since we render TrueColor but claim PseudoColor. Walk
through the picking logic in `mi/micmap.c:miInitVisuals` (priority list at line
300), why R6 lists ALL_VISUALS for cfb 8-bit, what changes at 24-bit, and what
swift-x should do (advertise both PseudoColor at 8 for compat AND TrueColor at
24 as the preferred root, like a hybrid u5 + Mac).

**3. "BadAlloc vs BadRequest: why the right wrong error matters."** The swift-x
dispatch returning BadRequest for AllocColorCells looks fine — we emit *some*
error, the client knows not to expect a reply. But spec says BadAlloc (because
the visual lacks DynamicClass), and Xt's color converter catches BadAlloc as
"fall back to read-only" while it logs BadRequest as "the server is broken."
Show how a one-line decision in dispatch dictates whether Motif animations
gracefully degrade or visibly fail. Same pattern applies across the whole opcode
family. Tie back to the CLAUDE.md "no silent lies" principle — these aren't
lies, but they're the *wrong* truth.
