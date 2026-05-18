# Comparison: pixmaps + drawables

Three-way: spec / X11R6 / xorg+XQuartz / swift-x. Scope is CreatePixmap,
FreePixmap, the four CopyArea variants, CopyPlane, GetImage, PutImage, the
GraphicsExposure / NoExposure event pair, and the chunk of connection-setup info
that governs all of it (imageByteOrder, bitmapBitOrder, bitmapFormatScanlineUnit
/ Pad, pixmapFormats).

## Spec (authoritative)

`reference/x11-protocol-spec/x11protocol.html`

- **CreatePixmap** (anchor `requests:CreatePixmap`, line 4279): allocate a
  pixmap of given (depth, width, height) on a drawable's screen. Errors:
  Drawable, IDChoice, Value, Alloc. Depth must appear in the screen's
  `allowed-depths` (else BadValue).
- **CopyArea** (`requests:CopyArea`, line 5089): combine src rect with dst rect.
  Both drawables must share the same root and same depth (`BadMatch` otherwise —
  that's *both* roots and depths). GC components used: function, plane-mask,
  subwindow-mode, graphics-exposures, clip-x-origin, clip-y-origin, clip-mask.
  Obscured-source-region rule: not copied, BUT if the dst is a window with bg !=
  None, the corresponding dst region gets tiled with the bg. If
  `graphics-exposures` is True: GraphicsExposure events for those corresponding
  dst regions. If `graphics-exposures` is True but no GraphicsExposure events
  fire, then exactly one NoExposure event.
- **CopyPlane** (`requests:CopyPlane`, line 5151): src and dst must share root.
  **Do NOT have to share depth.** `bit-plane` is exactly-one-bit-set, value <
  2^src.depth, else BadValue. Semantics: form a virtual pixmap at dst's depth
  where every bit-1 cell in that plane becomes gc.foreground, every bit-0 cell
  becomes gc.background, then CopyArea that virtual pixmap. GC components used:
  function, plane-mask, foreground, background, subwindow-mode,
  graphics-exposures, clip-x-origin, clip-y-origin, clip-mask.
- **PutImage** (`requests:PutImage`, line 5664): format ∈ {Bitmap, XYPixmap,
  ZPixmap}. Bitmap requires depth==1 and is gc.fg/gc.bg substituted into the dst
  at dst.depth. XYPixmap/ZPixmap require depth == drawable.depth. ZPixmap
  requires leftPad==0. Bitmap/XYPixmap require leftPad < bitmap-scanline-pad.
  left-pad bits are dropped from the front of every scanline.
- **GetImage** (`requests:GetImage`, line 5745): format ∈ {XYPixmap, ZPixmap},
  returned in server's image-byte-order and bitmap-bit-order. Plane-mask says
  which bit-planes to include. For ZPixmap, planes excluded by plane-mask are
  transmitted as zero. For window source: BadMatch if not viewable, or if the
  rect isn't fully on screen, or not fully inside the border. Backing-store may
  fill obscured regions; otherwise obscured contents are "undefined."
- **GraphicsExposure event** (`events:GraphicsExposure`, line 8514): only fires
  for clients using a GC with graphics-exposures=True. Multi-rect events come
  with a contiguous-count chain; final event has `count=0`.
- **NoExposure event** (`events:NoExposure`, line 8556): fires only "when a
  graphics request that *might* produce GraphicsExposure events does not produce
  any" — i.e., only when graphics-exposures=True AND zero GraphicsExpose events
  were generated.
- **SetupAccepted server info** (line 9955+): the server announces a global
  `image-byte-order` ({LSBFirst, MSBFirst}), `bitmap-format-bit-order`,
  `bitmap-format-scanline-unit` ∈ {8,16,32}, `bitmap-format-scanline-pad` ∈
  {8,16,32}, and a `LISTofFORMAT` (one FORMAT triple `{depth, bits-per-pixel,
  scanline-pad}` per supported depth). Per spec (line 1131-1136): "images are
  always transmitted and received in formats (including byte order) specified by
  the server." This is the only thing the X protocol does NOT byte-swap to the
  client's preference — image data goes raw in the server's order, the client
  adapts.

## X11R6 (era-correct intent)

`reference/X11R6/xc/programs/Xserver/`

- `dix/dispatch.c:ProcCreatePixmap:1305`: validate the new ID is fresh + free,
  `VERIFY_GEOMETRABLE(pDraw, stuff->drawable, ...)`, depth must be 1 OR in
  `pDraw->pScreen->allowedDepths`, dispatch to
  `(*pDraw->pScreen->CreatePixmap)(pScreen, w, h, depth)`. Lower-level pixmap
  allocation lives in the cfb / mfb back-ends — for an 8-bit cfb screen,
  `cfb/cfbpixmap.c:cfbCreatePixmap` allocates a plain raster of
  `BitmapBytePad(width)` per scanline times height bytes.
- `dix/dispatch.c:ProcFreePixmap:1347`: simple `LookupIDByType` +
  `FreeResource`. No ref-count games on the dispatch path; pixmaps stay alive as
  long as a GC references them or the X resource ID is live.
- `dix/dispatch.c:ProcCopyArea:1541`: `VALIDATE_DRAWABLE_AND_GC` on dst; if src
  != dst then `VERIFY_DRAWABLE` on src AND **check (pDst->pScreen ==
  pSrc->pScreen) && (pDst->depth == pSrc->depth)** — BadMatch otherwise. Then
  `(*pGC->ops->CopyArea)(...)`. Critical detail: the returned `RegionPtr pRgn`
  is the set of dst regions where the src was obscured / out-of-bounds. If
  `pGC->graphicsExposures` is True, call
  `(*pDst->pScreen->SendGraphicsExpose)(client, pRgn, dstDrawable, X_CopyArea,
  0)` — which is `mi/miexpose.c:miSendGraphicsExpose:343`. That function either
  emits one GraphicsExpose event per rect (with proper count chaining) OR a
  single NoExpose when `pRgn` is nil/empty.
- `dix/dispatch.c:ProcCopyPlane:1579`: same validation but only requires same
  root (`pdstDraw->pScreen != psrcDraw->pScreen` → BadMatch); explicitly does
  NOT check depth equality. Validates `bit-plane` is exactly-one-bit-set:
  `(stuff->bitPlane == 0) || (stuff->bitPlane & (stuff->bitPlane - 1)) ||
  (stuff->bitPlane > (1L << (psrcDraw->depth - 1)))` → BadValue. Same
  SendGraphicsExpose tail.
- `mi/miexpose.c:miHandleExposures:96`: the heart of the matter. Builds a region
  of obscured source pixels relative to the dst, translates back to source
  coords, intersects with dst's clipList, and returns it as `RegionPtr` for
  `SendGraphicsExpose` to emit. Important behaviors: (a) if both src and dst are
  pixmaps and pSrc has no backStorage, returns NULL (no expose possible); (b) if
  there are more than RECTLIMIT=25 rects, collapse to the bounding extents (spec
  calls this "spontaneous combustion" and explicitly allows it); (c) walks any
  window with a backStorage and uses the backing-store ExposeCopy as a recovery
  path; (d) handles the "dst is a window with bg != None" case by calling
  `PaintWindowBackground` on the exposed region.
- `mi/miexpose.c:miSendGraphicsExpose:343`: one xEvent per rect,
  type=GraphicsExpose, fields drawable/x/y/w/h/count/majorEvent/minorEvent.
  Count counts *down*: rect i (1-indexed) gets `count = numRects - i`, so the
  last event always has count=0. Empty / nil region → single NoExpose event.
- `dix/dispatch.c:ProcPutImage:1817`: format check, then for Bitmap requires
  depth==1 + leftPad < bitmapScanlinePad; for XYPixmap requires drawable depth
  match + same leftPad rule; for ZPixmap requires drawable depth match +
  leftPad==0. Computes server-padded scanline length and dispatches
  `(*pGC->ops->PutImage)(pDraw, pGC, depth, dx, dy, w, h, leftPad, format,
  tmpImage)`. The bridging from protocol scanline padding to internal server
  scanline padding (for 32-bit hosts vs 64-bit hosts) lives behind
  `INTERNAL_VS_EXTERNAL_PADDING`. R6 cfb implements all three formats in
  `cfb/cfbimage.c`.
- `dix/dispatch.c:ProcGetImage:1929`: format check (only XYPixmap or ZPixmap,
  not Bitmap), `VERIFY_DRAWABLE`, then a full geometry check (window must be
  viewable, rect must be fully on screen, etc.) — see the chain at line
  1956-1970. Emits xGetImageReply header then chunked scanline reads via
  `(*pDraw->pScreen->GetImage)(...)`, broken up by `IMAGE_BUFSIZE` so the reply
  length doesn't overflow.
- Server-info encoding
  (`reference/X11R6/xc/programs/Xserver/include/servermd.h`): `IMAGE_BYTE_ORDER`
  is hardcoded per platform — sparc-bigendian/sun-3 get MSBFirst, VAX gets
  LSBFirst, RS/6000 gets MSBFirst. The macro flows through `dix/main.c:389` into
  `setup.imageByteOrder`.

## xorg / XQuartz (collapsed; XQuartz overrides called out)

Core paths live in `reference/xquartz-xserver/`; both X.org and XQuartz share
the dix / mi / fb tree, with XQuartz substituting DDX bits.

- **`dix/dispatch.c:ProcCopyArea` / `ProcCopyPlane` / `ProcCreatePixmap` /
  `ProcFreePixmap` / `ProcPutImage` / `ProcGetImage`** are structurally
  identical to R6: spec validation in `dix`, real work in the GC ops dispatch.
  xorg's variants have minor additions for XINERAMA, RandR, DRI cross-process
  pixmaps, and PolyEdge antialiased fills (none of which apply to swift-x's R6
  target).
- **`mi/micopy.c:miDoCopy:131`** is the modern replacement for R6's
  `mi/mibitblt.c:miCopyArea`. Generic clip-rect calculator that calls a back-end
  `miCopyProc` for each individual box. Source clip handling: for pixmap source,
  fast path (`fastSrc = TRUE`); for window source with `IncludeInferiors`, walks
  `NotClippedByChildren`; for root window in IncludeInferiors mode, special-case
  fast path matching pixmap.
- **`fb/fbcopy.c:fbCopyArea:239`** — calls `miDoCopy` with `fbCopyNtoN`
  (`fb/fbcopy.c:32`) as the box-copier. `fbCopyNtoN` is the workhorse: walks
  each box, optimizes the common case (plane-mask all ones, alu=GXcopy, no
  reverse, no upside-down) into a `pixman_blt`, else falls back to the generic
  `fbBlt`. Critically: works across pixmap and window drawables uniformly
  because they share the `fbGetDrawable` accessor — the back-end doesn't care if
  it's blitting to a window's framebuffer slice or a pixmap's malloc'd raster.
- **`fb/fbcopy.c:fbCopyPlane:249`** — three branches: if src bpp > 1, use
  `fbCopyNto1` (extract one plane from a multi-bit src); else if src bpp==1 and
  bitplane==1, use `fbCopy1toN` (substitute fg/bg into N-bit dst). For
  bitplane==0 (no plane requested) it still calls `miHandleExposures` to send
  any required GraphicsExpose events — preserving spec behavior even on the null
  case.
- **`mi/miexpose.c`** is unchanged from R6 in structure — `miHandleExposures`
  and `miSendGraphicsExpose` are the same code, just modernized.
- **XQuartz-specific layer (`hw/xquartz/`)**:
  - `darwin.c:InitOutput:631` advertises:
    - `imageByteOrder = IMAGE_BYTE_ORDER` from `include/servermd.h:55-65` —
      derived from host byte order. On Apple Silicon and Intel Macs (both
      little-endian), this is **LSBFirst**.
    - `bitmapBitOrder = BITMAP_BIT_ORDER` — same derivation, so LSBFirst on Mac.
    - `bitmapScanlineUnit = bitmapScanlinePad = 32` (servermd.h:80-87).
    - 7 pixmap formats: `{1, 1, 32}`, `{4, 8, 32}`, `{8, 8, 32}`, `{15, 16,
      32}`, `{16, 16, 32}`, `{24, 32, 32}`, `{32, 32, 32}` (`darwin.c:155-163`).
  - `xpr/xprScreen.c` adds the rootless surfacing on top of `fbScreenInit`, but
    does NOT override CopyArea / CopyPlane / GetImage / PutImage / CreatePixmap.
    Those flow through the standard fb back-end. The only override is in
    `xpr/driWrap.c:DRICopyArea:191` / `DRICopyPlane:214` / `DRIPutImage:173`,
    and that's just a DRI synchronization shim that calls through to
    `pGC->ops->CopyArea` after acquiring a DRI lock — same semantics, different
    timing.
  - **XQuartz pixmap storage is plain CPU malloc** (delegated to
    `fbCreatePixmap` in `fb/fbpixmap.c`). The IOSurface / Quartz-side
    compositing happens at the *window* layer, not the pixmap layer. Pixmaps
    live in process memory the whole time.

## swift-x (current implementation)

Read-only inspection of `Sources/`.

- **Protocol decode** in `Sources/Framer/Requests/`:
  - `CreatePixmap` ✓, `FreePixmap` ✓ (`SimpleResourceRequests.swift:125`),
    `CopyArea` ✓, `PutImage` ✓ (`PutImage.swift`).
  - **`CopyPlane`: no decoder**. Opcode 63 listed in
    `Sources/Framer/OpcodeNames.swift:65` for logging but no struct; falls into
    `Request.unknown` (`Sources/Framer/Requests/Request.swift:329`). grep
    confirms — only mention of `CopyPlane` in `Sources/` is the OpcodeNames map.
  - **`GetImage`: no decoder**. Same story; OpcodeNames-only.
- **State storage**:
  - `Sources/SwiftXServerCore/ResourceTables.swift:PixmapEntry:289` is metadata
    only: id, drawable, depth, width, height. No pixel storage of any kind.
  - `PixmapTable:302-311` is a tiny `[UInt32: PixmapEntry]` dictionary.
  - `Sources/SwiftXServerCore/GCState.swift:GCState:32` materializes most GC
    components from a CreateGC / ChangeGC value bag, but **does not read
    `graphicsExposures`** even though the bit constant exists
    (`GCBits.graphicsExposures = 1 << 16`).
- **Dispatch**:
  - `Sources/SwiftXServerCore/ServerSession.swift:case .createPixmap:3059`
    inserts the metadata stub. **No depth validation** against `allowedDepths`,
    no width==0 / height==0 check (spec violations).
  - `case .freePixmap:3062` checks the resource exists and removes; emits
    `BadPixmap` correctly.
  - `case .putImage:3303` validates drawable + GC and then logs "silent-drop,
    see SHORTCUTS". Pixels never reach a canvas.
  - `case .copyArea:3182` → `handleCopyArea:2124`. The handler validates
    drawables (BadDrawable on unknown id), validates GC, then short-circuits to
    `BadImplementation` whenever the src and dst aren't the same top-level
    window (`srcTop != dstTop`), AND whenever either is a pixmap (since
    `topLevelAndOffset` only resolves windows). The same-window path calls
    `bridge.copyArea(...)` and then always appends NoExposureEvent.
- **Bridge**:
  - `Sources/SwiftXServerCore/WindowBridge.swift:copyArea:247` interface allows
    only the same-window case (one `topLevel` argument). The default-impl
    extension (`WindowBridge.swift:365`) is a no-op so mock bridges in tests
    don't fail.
  - `Sources/SwiftXServerCore/CocoaWindowBridge.swift:copyArea:612` is a direct
    `memmove`-per-row of the underlying CGBitmapContext data buffer, accounting
    for the scale factor (logical-to-device). Handles overlapping src/dst
    correctly by iterating top-down or bottom-up per direction. **GC clip is
    ignored on this path** (logged at line 626); xterm doesn't set clip on its
    scroll GC so this works for the one client we care about.
- **Connection-info advertised**
  (`Sources/SwiftXServerCore/ServerConfig.swift:97-148`):
  - `imageByteOrder: .msbFirst` (line 138). Matches Sun Xsun's advertised order,
    mismatches Mac host byte order.
  - `bitmapFormatBitOrder: .mostSignificant`, `bitmapFormatScanlineUnit: 32`,
    `bitmapFormatScanlinePad: 32`.
  - `pixmapFormats: [PixmapFormat(depth: 8, bitsPerPixel: 8, scanlinePad: 32)]`
    — just one entry. No depth-1 bitmap format, no depth-24/32 format.
    `allowedDepths` only contains depth-8 PseudoColor.

## Surprises and divergences

1. **swift-x advertises MSBFirst image byte order on a little-endian host.**
   xorg's universal rule is host byte order. The deliberate mismatch is a "match
   Sun Xsun for capture/replay convenience" call (the Sun is the reference).
   It's currently invisible because we don't actually interpret image bytes
   (PutImage drops, GetImage is unimplemented). The moment we land either of
   those, we either start swapping bytes per pixel or flip the advertised order.
   This is a one-paragraph blog post in itself: why "host byte order" is the
   rule and what happens when you break it.

2. **Cross-window CopyArea isn't a depth check or a region computation, it's a
   CGContext-isolation problem.** In xorg/XQuartz, all windows on a single
   screen share one framebuffer raster — `fbCopyNtoN` just blits between byte
   offsets in the same backing array. In swift-x's rootless model, each
   top-level X window has its own NSWindow with its own CGBitmapContext
   (`CocoaWindowBridge`). There is no shared screen raster. Cross-window
   CopyArea becomes a copy between two CGContexts, which is fine in principle
   (`CGContextDrawImage` from a `CGImage` snapshot of src into dst), but it's a
   different code path from same-window memmove and crosses NSWindow / AppKit
   threading boundaries. The xorg implementation cost-comparison is misleading
   here; ours is genuinely a different problem because we picked rootless.
   Adopting xorg's approach (one shared raster) would defeat the rootless
   premise. Practical fix: same-NSWindow becomes the current memmove path;
   cross-NSWindow becomes `CGContext.draw(CGImage)` from a snapshot of the
   source bitmap into the dst bitmap, run on `DispatchQueue.main` after locking
   both backing buffers. The cost is one CGImage construction per cross-window
   CopyArea, which is fine for the rates real clients use.

3. **CopyPlane is harder than CopyArea by an interesting amount.** CopyPlane is
   the *only* CopyArea-family request that allows different source and
   destination depths. R6 / xorg handle this by virtualizing the source as a
   1-bit pixmap on the fly, substituting gc.foreground/background per bit, then
   doing a CopyArea. Implementing CopyPlane correctly means implementing the
   1-bit-source-to-N-bit-dst substitution kernel — which is the same kernel as
   PutImage with Bitmap format. The two should be implemented together. Once we
   have it, every Athena widget bevel and Motif shadow renders for free, which
   according to the project notes is a parked dt-app problem.

4. **NoExposure unconditional emit is a tiny wire-protocol lie.** swift-x emits
   NoExposure on every CopyArea regardless of GC.graphicsExposures. This is a
   "lying on the wire" failure mode per CLAUDE.md, currently uncaught because
   the existing client (xterm) sets graphics-exposures=True and our same-window
   path generates no real obscured regions. Cost to fix: ~10 LOC (materialise
   the bit, gate the emit). Highest ratio of compliance-improvement to LOC of
   anything in this dimension.

5. **PutImage's drawable validation succeeds but the drawing silently fails.**
   This is the single biggest CLAUDE.md "ledgered exception" hotspot in the
   dimension. The drawable check passes, the GC check passes, the request enters
   the dispatch, the log says "silent-drop." A client reasonably believes the
   bits landed. There's no XError to signal "I can't do this." A reasonable fix
   order, given the project context: (a) wire PutImage to window drawables
   (depth=8, ZPixmap format) using the existing top-level bitmap context — this
   is straightforward, the byte unpacker is two loops; (b) defer pixmap-target
   PutImage until A1 (pixmap storage) lands; (c) emit BadImplementation when
   targeting a pixmap, with a SHORTCUTS entry stating the exit plan.

6. **The capture/replay corpus probably doesn't exercise
   PutImage/CopyPlane/GetImage extensively** —
   `Sources/SwiftXCaptureCore/Dumper.swift:359` only dumps PutImage among the
   image opcodes. xterm doesn't issue any of the three on the working session.
   xcalc doesn't. CDE dt-apps almost certainly do (button chrome, dialog icons,
   drag previews) — and we already know dt-apps' button chrome doesn't render.
   The captures we have are a poor fixture for this dimension; the parked Motif
   investigation is the validation surface.

## Blog hooks

1. **"Image byte order is the one thing X doesn't swap for you."** Two-paragraph
   riff on why the X protocol is otherwise the chattiest byte-swapping system
   imaginable (every CARD32 in a reply gets endian-flipped if the client says it
   wants the other order), but image data is the one exception — server's order,
   client adapts. Then the kicker: swift-x runs on a little-endian Mac, talks to
   big-endian Sun clients, and advertises MSBFirst to match the Sun rather than
   the Mac. Discuss xorg's "host byte order" choice and why it's wrong for our
   use case (and why it's right for theirs). Reference: spec line 1131-1136,
   `xquartz-xserver/include/servermd.h:55-65`,
   `swift-x/Sources/SwiftXServerCore/ServerConfig.swift:138`. Headline: "The one
   place the X protocol won't lie for you about endianness."

2. **"Cross-window CopyArea is not a rendering problem. It's an architecture
   problem."** Walks through xorg's "single screen raster, blit by byte offset"
   model vs swift-x's "every top-level NSWindow owns its own CGBitmapContext"
   rootless model. Show that fbCopyNtoN is ~30 lines and works for all four
   CopyArea variants because everything's in one buffer. Then show that in
   rootless, the same operation needs to bridge two CGContexts owned by
   different NSWindows on different `DispatchQueue.main` invocations, which is
   the architectural cost of the rootless promise. References:
   `xquartz-xserver/fb/fbcopy.c:32-85` (fbCopyNtoN),
   `Sources/SwiftXServerCore/CocoaWindowBridge.swift:612-688` (swift-x
   same-window path), and the contrast. Punchline: rootless is the right call
   for the project (native macOS look, real NSWindows, AppKit-native chrome),
   but every X operation that was "blit between two byte offsets" in the server
   becomes "marshal two CGContexts" in our world.

3. **"The X server isn't allowed to lie, but PutImage is the easiest one to lie
   about."** Frame around the CLAUDE.md "no fake successes" rule. PutImage
   validates drawable and GC and then drops the bits — and the project's own
   SHORTCUTS ledger acknowledges this as a known lie. Show what "real PutImage"
   looks like (the R6 unpacker, the depth/format dispatch, the
   ZPixmap-vs-XYPixmap-vs-Bitmap branching, the leftPad detail), and what we'd
   need to land before we could un-lie: a pixel store on PixmapEntry, depth-1 in
   pixmapFormats, byte-order coherence with B2. Reference:
   `reference/X11R6/xc/programs/Xserver/dix/dispatch.c:ProcPutImage:1817` (the
   era-correct unpacker),
   `Sources/SwiftXServerCore/ServerSession.swift:3303-3318` (the lie). Closer:
   every dt-app button shadow not rendering on screen is the cost we pay for the
   lie, and now we can name it.
