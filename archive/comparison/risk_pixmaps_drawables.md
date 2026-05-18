# Risk register: pixmaps + drawables

Dimension scope: CreatePixmap / FreePixmap, all four CopyArea variants,
CopyPlane, GetImage, PutImage, GraphicsExposure / NoExposure, advertised image /
bitmap / pixmap-format info in the SetupAccepted reply.

Authority order applied: spec > X11R6 > xorg+XQuartz > swift-x.

## A. Actively bleeding now

### A1. PutImage is a silent no-op
**Severity: high.** **Missing: rendering, not protocol decode.** **Trigger: any
client that ever fills a region by uploading pixels.**

`Sources/SwiftXServerCore/ServerSession.swift:3303-3318` validates the drawable
+ GC and then logs "silent-drop, see SHORTCUTS" — pixels never make it to the
bitmap. The framer (`Sources/Framer/Requests/PutImage.swift`) decodes Bitmap /
XYPixmap / ZPixmap correctly, but `PixmapEntry`
(`Sources/SwiftXServerCore/ResourceTables.swift:289`) is metadata-only (id,
depth, w, h), so there's nowhere to put the bits even if the bridge could blit
them. This is acknowledged in `CLAUDE.md` ("draws to pixmaps silently drop"),
but the silent-drop also catches PutImage-to-window, which Athena
`Toggle`/`Command` shadow rendering, dt-app button chrome, dialog icons, and
anything that flat-uploads CDE bitmap backgrounds will hit. The
drawable-validates-but-paint-vanishes pattern is exactly the "lying on the wire"
failure mode CLAUDE.md flags as more expensive than emitting a real error. **Fix
shape:** add a pixel store to `PixmapEntry` (CGBitmapContext at the pixmap's
depth — for now 8 or 32, since that's all we advertise); route window-targeted
PutImage to the existing top-level backing context with a depth-aware byte
unpacker; emit `BadMatch` instead of silent-drop when format/depth/leftPad
violate the spec.

### A2. CopyPlane is silently ignored end-to-end
**Severity: high for any pre-anti-aliased X client.** **Missing: framer decoder
+ handler.** **Trigger: every Athena widget shadow, every Motif PushButton/Label
that draws its own border, every cursor mask, every xeyes pupil if SHAPE isn't
routed.**

Search proves it: `grep -n CopyPlane Sources/` returns only
`Sources/Framer/OpcodeNames.swift:65` (the logger map). There's no
`CopyPlane.swift` request type, no `case 63:` in `Request.decode`
(`Sources/Framer/Requests/Request.swift:329` — opcode 63 falls into the
`.unknown` default and is bytes-only). The dispatcher's `.unknown` arm at
`ServerSession.swift:3918-3928` emits `BadRequest`. That's spec-correct for an
opcode the server doesn't implement
(`Sources/SwiftXServerCore/ServerSession.swift:3923` comment matches the spec
text exactly), so this isn't a lie on the wire — it's an honest "no." But it
means **any toolkit code that renders bevel shadows via 1-bit stipple-style
CopyPlane sees its drawing fail and the parent widget sees BadRequest**. In
practice, Xt swallows BadRequest in `XSetErrorHandler` default and renders no
shadows; per `INVESTIGATION_MOTIF_INPUT.md` referenced in the project context,
that's exactly what we see. **Fix shape:** wire up `CopyPlane` decode
(xCopyPlaneReq adds a CARD32 `bit-plane` after the CopyArea fields), then in the
handler check `bitPlane` is exactly-one-bit-set per spec ("[CopyPlane]
Effectively, a pixmap of the same depth as dst-drawable... is formed using the
foreground/background pixels in gc") and rasterize the 1-bit source by
substituting gc.foreground for 1-bits and gc.background for 0-bits. xorg's
`miDoCopy` + `fbCopy1toN` (`reference/xquartz-xserver/fb/fbcopy.c:87-249`) is
the model.

### A3. GetImage is silently ignored end-to-end
**Severity: high for any client that introspects pixels.** **Missing: framer
decoder + handler.** **Trigger: rxvt-style "save screen on resize", dthelpview
"copy widget to scratch pixmap", xwd, Motif drag-source pixmap snapshot,
anything roundtripping image data.**

Same proof shape as CopyPlane: `grep -n GetImage Sources/Framer/Requests/`
returns nothing. Opcode 73 has no decoder, falls into `.unknown`, dispatcher
emits `BadRequest`. Real clients calling `XGetImage()` will see a request-error
and `XGetImage` returns NULL. Toolkits often try to handle it (Motif's
DragContext has a fallback path), but many app patterns just crash on the NULL
return. **Fix shape:** decode xGetImageReq (8 words: opcode/format/length,
drawable, x, y, width, height, plane-mask); reply with the xGetImageReply header
(depth, visual, etc.) followed by pixel data extracted from the bridge. For
window source, walk the backing CGBitmapContext within the requested rect. For
pixmap source, once A1 lands, walk the pixmap's backing context. Pack to ZPixmap
at the screen's bpp by default (XYPixmap is much rarer; can be a follow-on).
Spec is fine with returning all-zeros for obscured regions when there's no
backing-store, which is what we have.

### A4. Cross-window and pixmap-involved CopyArea returns BadImplementation
**Severity: medium-high.** **Missing: rendering across CGContexts that live in
different NSWindow backings.** **Trigger: drag-and-drop preview,
off-screen-pixmap-then-blit-to-window animation, hide-window-into-icon
thumbnails, xeyes' double-buffering pattern.**

`ServerSession.swift:2142-2148` short-circuits to `emitError(.implementation,
...)` whenever `srcTop != dstTop`, AND whenever either drawable is a pixmap
(since `topLevelAndOffset(for:)` only resolves windows). The error is honest
(per CLAUDE.md the right call vs silent-drop), but it cuts off a large class of
working X clients. xterm scrolling — the only case currently working — is a
degenerate same-window-to-same-window scroll, the *easiest* CopyArea variant.
**Fix shape:** see the dedicated section in `comparison_pixmaps_drawables.md`.
Spec-required prerequisites: equal depth + equal root between src and dst
(currently checked by `srcTop == dstTop` accidentally, since all our windows are
on one root). Once pixmaps have backing bitmaps (A1), the cross-drawable case
becomes a CGContext-to-CGContext blit through a temporary `CGImage`.
Cross-NSWindow window→window is the tricky one — see the comparison doc.

### A5. NoExposure is fired unconditionally after CopyArea
**Severity: low-but-noisy.** **Missing: GC.graphicsExposures tracking +
GraphicsExposure event generation.** **Trigger: any client that sets
`graphics_exposures = False` on a GC to avoid the event traffic — and any client
that *expects* GraphicsExpose (count>0) when the source actually was obscured.**

`ServerSession.swift:2166-2172` unconditionally appends a NoExposure event after
every same-window CopyArea, ignoring `pGC->graphicsExposures`. Per spec (8556+):
NoExposure is generated only "when a graphics request that *might* produce
GraphicsExposure events does not produce any." If the GC has
graphics-exposures=False, neither GraphicsExpose nor NoExpose should fire.
`GCState` (`Sources/SwiftXServerCore/GCState.swift:32-79`) doesn't even
materialise `graphicsExposures` — the bit constant exists
(`GCBits.graphicsExposures = 1 << 16`) but is never read. xterm's `CopyWait`
blocks waiting for either NoExpose or GraphicsExpose, so this
firing-on-every-call works for xterm, but Xt's default GC (created by
`XCreateGC` with no value mask) defaults graphics-exposures=True, and apps that
explicitly set it false (Xaw `Form` widget) get spurious events. **Also
missing**: real GraphicsExpose generation when CopyArea actually does encounter
obscured source regions (e.g., cross-window). Since we don't yet support
cross-window CopyArea (A4), the practical bug is only the false-positive
NoExposure. **Fix shape:** add `graphicsExposures: Bool = true` to `GCState`,
materialise from `entry.values[GCBits.graphicsExposures]`, and gate the
NoExposure emit on `state.graphicsExposures == true`. When A4 lands, also wire
real GraphicsExpose by computing the obscured-region as xorg's
`miHandleExposures` (`reference/X11R6/xc/programs/Xserver/mi/miexpose.c:96-340`)
does.

## B. Will bleed when X happens

### B1. Only one pixmap format is advertised (depth=8, bpp=8, pad=32)
**Severity: medium, conditional.** **Missing: pixmap format list breadth.**
**Trigger: client that creates a depth-1 pixmap (extremely common) or any
depth>8 pixmap.**

`Sources/SwiftXServerCore/ServerConfig.swift:128` builds `pixmapFormats:
[pixmapFormat]` containing only `PixmapFormat(depth: 8, bitsPerPixel: 8,
scanlinePad: 32)`. xorg/XQuartz advertise 7 formats
(`reference/xquartz-xserver/hw/xquartz/darwin.c:155-163`: depths 1, 4, 8, 15,
16, 24, 32). X11R6's spec requires "An entry for a depth is included if any
screen supports that depth." Per `dispatch.c:1322-1331` (`ProcCreatePixmap`),
any depth not present in `allowedDepths` returns `BadValue`. We only advertise
depth 8 in `allowedDepths` (`ServerConfig.swift:107,125`). **A spec-compliant
client doing `XCreatePixmap(dpy, root, w, h, 1)` to make a bitmap mask will get
BadValue.** Xt's stipple-pattern caching does this. dt-apps' cursor masks do
this. Motif's drag-feedback bitmap does this. This currently doesn't bleed
because A1 hides A2/A3 (no client gets far enough to need a CopyPlane source
pixmap). When A1 lands without B1, real clients will start failing CreatePixmap.
**Fix shape:** add depth=1 (bpp=1, pad=32) at minimum, then depth=32 (bpp=32,
pad=32) for ARGB pixmaps. Add the corresponding `Depth` entries to
`allowedDepths` even if the visual is shared (depth-1 bitmaps don't need a
visual). Per spec, depth-1 needs no visual — the FORMAT entry alone is
sufficient.

### B2. imageByteOrder=MSBFirst advertised on a little-endian Mac
**Severity: medium, latent.** **Missing: alignment between what we advertise and
how we'd actually store pixels.** **Trigger: PutImage from any client of the
*opposite* byte order to what we advertise; GetImage from any client at all once
it ships.**

`Sources/SwiftXServerCore/ServerConfig.swift:138` hardcodes `imageByteOrder:
.msbFirst`. This matches what Sun's Xsun advertises
(`reference/X11R6/xc/programs/Xserver/include/servermd.h:139-143` shows sparc is
MSBFirst), which is convenient if you only care about Sun clients. xorg's rule
(`reference/xquartz-xserver/include/servermd.h:55-65`) is to derive
`IMAGE_BYTE_ORDER` from `X_BYTE_ORDER` — so XQuartz on Apple Silicon advertises
LSBFirst, matching Mac host byte order. Per spec (line 1131-1136): "images are
always transmitted and received in formats (including byte order) specified by
the server"; the client must adapt to the server's image byte order, not the
other way around. The server does **not** byte-swap image data on the wire, only
swap-and-back the non-image fields when client byte order != server. So an
MSBFirst-server / LSBFirst-Mac mismatch is fine as long as PutImage/GetImage are
no-ops. As soon as A1 / A3 land and we start *interpreting* image bytes (writing
to a Mac CGBitmapContext that's host-LSB), we have to either (a) byte-swap each
pixel value on PutImage entry and GetImage exit, or (b) flip the advertised byte
order to LSBFirst and require Sun clients to do the swap on their side (which
Xlib does automatically). Option (b) is what xorg does. **Fix shape:** flip to
`.lsbFirst` when A1 ships, OR keep `.msbFirst` and byte-swap in the
PutImage/GetImage path; pick one before either bug fix to avoid a swap-bug
regress. Tests need round-trip coverage with a Sun (MSB) client. Same finding
applies to `bitmapFormatBitOrder: .mostSignificant` (`ServerConfig.swift:139`)
for 1-bit bitmap data.

### B3. CopyArea same-window honors no GC clip on the bitmap path
**Severity: low, mostly cosmetic.** **Missing: clip-rect honoring on the memmove
blit.** **Trigger: any client that issues `XSetClipRectangles` before CopyArea
(Xaw Form, Motif ScrolledList).**

`Sources/SwiftXServerCore/CocoaWindowBridge.swift:619-627` explicitly notes: "GC
clip on CopyArea isn't honored for the same-window pixel-blit path because we
copy pixels via direct bitmap memmove rather than through CGContext." Logged.
The xterm scroll case is currently the only caller, and xterm doesn't set clip
on its scroll GC, so this is latent. **Fix shape:** when clip rects are set,
fall back to a CGContext path that clips, accepting the per-pixel cost.
xterm-style direct memmove for the clip=nil hot path stays.

### B4. CreatePixmap accepts depth=0 and depth=255
**Severity: low.** **Missing: depth validation.** **Trigger: malformed or
fuzz-test client.**

`ServerSession.swift:3059-3060` inserts a `PixmapEntry` straight from the
request with no depth check at all. Spec (R6 dispatch.c:1318-1331) requires
depth match an entry in `pScreen->allowedDepths`, else `BadValue`. We also fail
to reject width=0 or height=0 (spec: BadValue). Low impact because we're
single-client and we don't actually allocate per-depth bitmap memory yet, but
should be cleaned up before A1 lands (otherwise a depth-32 pixmap on our
depth-8-only server creates a phantom entry the renderer would have to choke
on).

### B5. Pixmap drawable not in `topLevelAndOffset` lookup
**Severity: medium when A4 is addressed.** **Missing: pixmap path through
coordinate translation.** **Trigger: any draw op (PolyFillRectangle, PolyText8,
ImageText8, FillPoly, PolyArc) targeting a pixmap drawable.**

`ServerSession.swift:2142-2144`'s `topLevelAndOffset(for:)` resolves windows
only. Every draw handler (e.g. `handlePolyFillRectangle`, `handlePolyText8`)
goes through `validateDrawTarget` which presumably uses the same path. Need to
confirm — but a
CreatePixmap-then-PolyFillRectangle-on-pixmap-then-CopyArea-to-window pattern is
the canonical "render once, blit many times" Xt pattern. Currently the pixmap is
a metadata stub, so every draw to it is necessarily silent. This bleeds together
with A1: the pixmap-as-backing-store can't work without both pixel storage AND
draw-op routing.

## C. Theoretical / spec-only

### C1. CopyArea cross-screen returns BadMatch only because we have one screen
**Severity: theoretical.** Spec requires src and dst share the same root
(`BadMatch` if not). We have exactly one root, so `srcTop == dstTop` passes the
test by accident. If multi-screen is ever added, the validation needs explicit
`pSrc->pScreen == pDst->pScreen` (per R6 `dispatch.c:1556-1560`).

### C2. CopyArea same-depth check missing
**Severity: theoretical until we have multi-depth visuals.** Spec / R6
`dispatch.c:1556`: `pDst->depth != pSrc->depth` is `BadMatch`. We only have
depth-8 windows for now; once we allow depth-1 bitmaps (B1) and depth-32 ARGB
pixmaps, we need this check for CopyArea (but NOT for CopyPlane, which is
explicitly cross-depth).

### C3. CopyArea source-out-of-bounds doesn't fill destination from background
**Severity: theoretical until cross-drawable ships.** Spec: "If regions outside
the boundaries of the source drawable are specified... if the dst-drawable is a
window with a background other than None, these corresponding destination
regions are tiled (with plane-mask of all ones and function Copy) with that
background." The current same-window path bounds-checks and bails
(`CocoaWindowBridge.swift:654-657`). xterm doesn't out-of-bounds itself, so this
never trips. When A4 lands, the obscured-source region must paint the dst
window's bg (per `mi/miexpose.c:283-307`).

### C4. SetGC and ChangeGC don't preserve / change `graphicsExposures` correctly
**Severity: theoretical until A5 lands.** The bit constant exists in `GCBits`
but no read/write path materialises it. Currently invisible because A5 is wrong
upstream. Worth flagging so the A5 fix doesn't get bolted on without the GCState
refactor.

### C5. PutImage with leftPad>0 unhandled
**Severity: low.** Spec: for Bitmap/XYPixmap format, leftPad <
bitmap-scanline-pad (32 for us) — first N bits per scanline ignored. Once A1
lands, the unpacker must skip leftPad bits at scanline start. The framer carries
`leftPad` through (`PutImage.swift:17`).

### C6. GetImage range check incomplete for windows
**Severity: theoretical until A3 lands.** Spec: window must be viewable AND if
there were no overlapping windows or inferiors, the rectangle would be fully
visible on screen AND wholly inside outside-of-border. Will need to ride along
with A3.

### C7. Bitmap format (PutImage format=0) needs gc.foreground/background substitution
**Severity: theoretical until A1 lands.** Spec PutImage Bitmap mode: "depth must
be one... The foreground pixel in gc defines the source for bits set to 1 in the
image, and the background pixel defines the source for the bits set to 0." Same
logic as CopyPlane's 1-bit path. Implement once for both A1 and A2.
