# Plan: pixmap pixel storage + real CopyArea

Status: drafted 2026-05-17, pre-implementation. Stage 0 settled the same day from existing `captures/*-sun.xtap` files (see Stage 0 Findings below); the CopyPlane caveat and depth-mismatch concerns are resolved.

Context: we have direct evidence from a quickplot run (log `/tmp/swiftx-server/qp-2026-05-17-13-03-03.log`) that one missing piece — pixmap pixel storage + real CopyArea — is the root cause of multiple shipped-broken behaviors: Motif button chrome doesn't render across every dt-app (the parked issue in `INVESTIGATION_MOTIF_INPUT.md`), dtterm and friends spam BadImplementation on opcode 62, quickplot's plot window shows blue NSWindow background bleeding through after every Expose.

The shortcut in place is a deliberate ledgered lie pair (`SHORTCUTS.md` entries 41+42+43): we silent-drop draws into pixmaps because emitting the spec-correct BadImplementation would also break clients, and we BadImplementation CopyArea-from-pixmap. Both ends of the lie retire together.

## Framing

The actual problem isn't "implement two opcodes." It's "introduce a second class of render target into a server whose entire draw pipeline assumes the target is one of N top-level NSWindows, each backed by a single CGBitmapContext." Once a pixmap can be a renderable target, every draw handler grows a second case and CopyArea grows from one matrix cell (window→window same NSWindow) to five. Neither is hard on its own. Doing both in one commit is.

## Stage 0 Findings (settled 2026-05-17)

Three real-Sun `*-sun.xtap` captures already in `captures/` resolved every open question Stage 0 was supposed to ask:

| | rootDepth | CopyArea | CopyPlane | PutImage | PolyFillRect | PolySegment |
|---|---|---|---|---|---|---|
| dtcalc-sun | 8 PseudoColor | 75 | 0 | 8 | 311 | 367 |
| dtterm-sun | 8 PseudoColor | 19 | 0 | 2 | 310 | 77 |
| quickplot-sun | 8 PseudoColor | 484 | 0 | 36 | 1224 | 913 |

What this tells us:

1. **CopyPlane is dead.** Zero traffic across every dt-app and quickplot. Real Sun's Motif uses plain CopyArea. The whole "CopyPlane may be the real unlock" caveat goes away.
2. **PutImage is not the load-bearing piece.** Motif's button chrome flow is `CreatePixmap → many PolyFillRectangle + PolySegment → one CopyArea pixmap→window`. PutImage shows up 2–36 times vs hundreds-to-thousands of Poly ops. The visual unlock for dt-Motif is the DrawTarget refactor (Poly ops rendering into pixmap contexts), not the PutImage decoder.
3. **No depth-mismatch problem.** Real Sun is 8-bit PseudoColor; we advertise 24-bit TrueColor. Motif always creates pixmaps at root-depth, so pixmap-depth = window-depth in both worlds. The BadMatch worry from the original plan is moot — pixmap depth will match window depth on every server we host.
4. **PutImage byte-format mix still informs decoder priorities.** From swiftx-server logs (which see what clients send us when they think they're talking to a TrueColor depth-24 server): 157× Bitmap d=1, 5× ZPixmap d=1, 1× ZPixmap d=8, zero XYPixmap, zero ZPixmap d=24. So when we do ship the decoder, those three formats are the whole story.

## 1. PixelBuffer design

Add a `PixelBuffer` value attached to each `PixmapEntry`:

```swift
public struct PixelBuffer {
    let context: CGContext   // CGBitmapContext, always 32-bit ARGB on the Mac side
    let logicalW: Int
    let logicalH: Int
    let depth: UInt8         // X-side depth: 1, 8, or 24/32. Bridge converts on write.
}
```

A `CGBitmapContext` per pixmap, sized at the pixmap's logical pixels (no scale-up to device; pixmaps live at logical resolution per `RENDERING_DESIGN.md` item 11). Rationale: pixmaps are small (16×16 to 48×48 dominate; even quickplot's biggest is well under 200×200), reads need to be cheap for CopyArea, and we already have one of these per top-level. The `depth` field is the X-side depth; the Mac-side bitmap is always 32-bit ARGB. We translate at the write boundary (PutImage decode, draw-into-pixmap GC color resolve) and at the read boundary (GetImage encode, CopyPlane src extraction).

**Eager vs lazy allocation.** Eager at CreatePixmap. Reasons: (a) we already know the width/height/depth at create time, deferring buys nothing; (b) eager keeps the ownership and lifetime model dead obvious — alloc on CreatePixmap, free on FreePixmap, no double-init guards in draw handlers; (c) bytes used per pixmap is small (16×16×4 = 1 KB, 48×48×4 = 9 KB, even 256×256×4 = 256 KB).

Quickplot session creates 73 pixmaps in the worst log; even if everything were 256×256 that's 18 MB which is nothing. Realistic upper bound for a sane app set: under 5 MB. If a pathological client allocs giant pixmaps, we'll learn about it then; no need to design for it now.

**Y-flip on the pixmap context.** Apply the same y-flip + top-left origin transform we apply to `FlippedXView.backing` (`FlippedXView.swift:288-310`). One coordinate convention everywhere, no per-target arithmetic in draw handlers.

**Depth-1 vs depth-8 vs depth-24 backing.** All three use the same 32-bit ARGB CGBitmapContext on the Mac side. The X-side depth only affects (a) how PutImage bytes decode into ARGB, (b) how GetImage encodes ARGB back out, (c) what value-mask bits CopyPlane reads. Storing depth on the entry, not in the bitmap layout, keeps the format matrix simple.

Files: `ResourceTables.swift` (extend `PixmapEntry`), new `Sources/SwiftXServerCore/PixelBuffer.swift`. Lifecycle owned by a small `PixmapTable.allocate(...)` / `deallocate(...)` helper so the alloc bytes live in one auditable place, not scattered through handlers.

## 2. PutImage byte-format matrix

From the captured logs, the matrix we actually face:

| Format | Depth | Source | Action |
|---|---|---|---|
| Bitmap (0) | 1 | Motif button chrome (16×16, 30×30) | **must work** |
| ZPixmap (2) | 1 | xeyes/xclock icon mask (48×48) | should work; same decode |
| ZPixmap (2) | 8 | dtcalc icon (48×48), one shot | should work; trivial |
| ZPixmap (2) | 24/32 | nobody (yet) | implement when seen |
| XYPixmap (1) | anything | nobody | BadImplementation |

The Motif chrome case is the load-bearing one. Bitmap-format-1 at depth-1: bytes are packed 8 pixels/byte, row-padded to `bitmapScanlinePadUnit` (32 bits per our `ServerConfig`), MSB-first within byte per the *bitmap-bit-order* we advertise in SetupAccepted. The `foreground` and `background` from the GC expand the bits into ARGB: 1-bit = GC foreground, 0-bit = GC background. Honor the `leftPad` field (skip leftPad bits at the start of each row before the first pixel).

ZPixmap depth=1: same bit-packing as Bitmap but interpreted as a "real depth-1 pixmap" rather than a 1-bit-deep glyph-into-window expansion. For our purposes the decode is identical because we always expand to 32-bit ARGB; the difference matters only for GC-foreground/background expansion semantics on the write target (depth-1-into-window vs depth-1-into-depth-1-pixmap), which we'll address in stage 2.

ZPixmap depth=8: one byte per pixel, scanline-padded to 32 bits. Resolve each byte through `ColorTable.rgb(for:)` (same path as `resolveColor`) to get ARGB.

XYPixmap: each plane is sent as a separate Bitmap-format-1 block, planes concatenated. Nobody in our captures uses it. Stub with BadImplementation.

Image-byte-order pitfall: our `ServerConfig` (advertised in SetupAccepted) tells the client what byte order to use. Whatever we advertise is what we receive. The decoder doesn't have to flip; it has to know which bit is the leftmost pixel in a byte. Pick once, document it, write the decoder to match. The reference algorithm is in X11R6's `mi/miputimage.c`.

Files: new `Sources/SwiftXServerCore/PutImageDecoder.swift` with `decode(bytes:format:depth:width:height:leftPad:byteOrder:fg:bg:colorTable:) -> [UInt32]`. Pure function, easy to unit test.

## 3. Pixmap draw routing — the `DrawTarget` refactor

This is the bigger refactor and it sets up everything downstream. Current shape: every `handleXxx(...)` in `ServerSession.swift:2080-2340` calls `validateDrawTarget(r.drawable, ...) -> (topLevel, dx, dy)?` and then a bridge method that takes `topLevel: UInt32`. The bridge's draw methods all reach for `slot(topLevel)?.view.backing` (a window CGContext). When the target is a pixmap, there's no slot, so the whole pattern bails.

Cleanest fix: introduce a `DrawTarget` enum that resolves a drawable to either a window-CGContext-with-clip or a pixmap-CGContext, and route every draw through a unified `withDrawContext(_ target: DrawTarget, body: (CGContext) -> Void)` helper that already knows about the y-flip, AA-off, and clip stack:

```swift
enum DrawTarget {
    case window(topLevel: UInt32, xOffset: Int16, yOffset: Int16)
    case pixmap(id: UInt32, depth: UInt8)
}
```

`ServerSession.validateDrawTarget` returns `DrawTarget?` instead of `(UInt32, Int16, Int16)?`. Each handler passes the `DrawTarget` straight through to the bridge. The bridge has one method per draw op as today, but the body opens a `withDrawContext` that hides which kind of target we're hitting. Inside, applyFill / applyForeground / applyStrokePlane / `clip(to:)` work unchanged — they're CGContext operations.

This is the change that earns its keep three times over: it makes every draw op pixmap-capable in one go, it gives us a single place to do GC `clip-mask` (depth-1 pixmap → CGImage as a clipping mask), and it makes the GC `tile`/`stipple` work later a single-site change instead of a sweep.

**On GC `function`:** only GXcopy (3) and GXxor (6) appear in our captures (xor for Athena menu highlights, see `OPCODE_STATUS.md` row 70). GXcopy is the default; GXxor maps to `.difference`. The other 14 raster-ops are correct-but-rare. Leave them mapping to GXcopy with a one-line warn log, log a SHORTCUTS entry, fix when something complains.

**On GC `clip-mask` (a depth-1 pixmap mask):** today we only support `SetClipRectangles`. The pixmap-mask variant of clip ships *with* pixmap pixel storage — same infra. Implement after Stage 2 lands so we have something to mask against.

**On GC `tile` / `stipple`:** pixmap-backed, same infra. Realistically nothing in our captures uses these (xterm's stippled cursor maybe but it's invisible because the cursor is implicit). Leave as known-stub, document, ship when needed.

Files: `WindowBridge.swift` (DrawTarget enum + every draw method's signature), `CocoaWindowBridge.swift` (collapse `slot(topLevel).view.backing` into a `resolveContext(_ target:)` helper, route `withClip` through it), `MockWindowBridge.swift` (mirror), every `handleXxx` in `ServerSession.swift:2080-2340`.

## 4. CopyArea matrix

| src → dst | What it is | Implementation | Notes |
|---|---|---|---|
| window → window same NSWindow | xterm scroll | already works (`CocoaWindowBridge.copyArea:672-748`) | bitmap memmove path; preserve it |
| window → window cross NSWindow | rare; mostly happens during drag/drop preview | `CGContext.draw(image:in:)` from src view's backing | source as `CGImage` via `CGBitmapContextCreateImage(srcCtx)` |
| pixmap → window | **dt-Motif button chrome — the load-bearing case** | `CGContext.draw(image:in:)` into window backing | source pixmap context → `CGImage`; subrect via `CGImageCreateWithImageInRect` |
| window → pixmap | not seen in captures | symmetric, same draw call | implement for completeness |
| pixmap → pixmap | not seen in captures but trivial once others work | same draw call | nothing special |

For all cases that route through CGContext: honor GC clip rectangles via `clip(to:)`. The current same-window memmove path *can't* honor clip without doing per-row scissor math, and the only client we have that exercises same-window CopyArea (xterm scrolling) doesn't set clip. Keep the memmove fast path for that one case; everything else goes through `CGContext.draw(image:)` which is clip-aware for free.

**Depth-mismatch handling.** X spec says CopyArea requires `src.depth == dst.depth`, BadMatch otherwise. Stage 0 captures confirmed Motif always creates pixmaps at root-depth, so pixmap-depth = window-depth in practice. Still, the handler should emit BadMatch on actual mismatches per spec — cheap to check, defends against pathological clients.

**graphics-exposures.** Already plumbed (closed entry in SHORTCUTS as of 2026-05-15). NoExposure emission gates on the bit; nothing new needed.

**Pixmap → window: does it honor GC clip?** Yes, because it now goes through CGContext. Free with the refactor.

## 5. CopyPlane (opcode 63)

**Parked.** Stage 0 captures show zero CopyPlane traffic across every dt-app and quickplot. Real Sun's Motif uses plain CopyArea exclusively. Leave CopyPlane as undecoded / BadImplementation; ship when a client actually exercises it. The 90% infrastructure overlap with CopyArea means it'll be cheap to add later — no reason to gold-plate now.

## 6. GetImage (opcode 73)

Once pixmaps have backing, GetImage from a pixmap is just `CGBitmapContextCreateImage(pixmap.context)` → encode to the requested format/depth. From a window: `CGBitmapContextCreateImage(view.backing)` → encode. The encoder is the inverse of the PutImage decoder; same byte-format matrix, smaller surface (only handle what we know how to decode, BadImplementation for the rest).

Status today: not implemented at all (not in `OPCODE_STATUS.md`, no decoder). Cheap win once Stages 1+2 ship — maybe 100 lines including the encoder. Ship as Stage 4. Mostly used by screenshot tools, screencap apps, image-pasting in editors. Not load-bearing for any client we host but high "completeness" value.

## 7. Test plan

Pure unit tests in `Tests/SwiftXServerCoreTests/`:

- `PutImageDecoderTests` — feed a known bit pattern in, assert the ARGB pixels match. Cover: Bitmap depth=1 with leftPad=0/1/7, ZPixmap depth=1, ZPixmap depth=8 with a stub ColorTable. The Motif chrome bit-pattern (a 30×30 button face — top-shadow line, bottom-shadow line, fg label area) is the natural fixture; eyeball-construct it.
- `PixmapDrawTargetTests` — create a pixmap, draw a PolyFillRectangle into it, GetImage back out, assert the pixel grid is right. End-to-end test of the DrawTarget refactor without needing AppKit.
- `CopyAreaPixmapTests` — pixmap→pixmap, pixmap→window (via MockWindowBridge), assert blit lands at right offset with right pixels. window→window same is regression-only.
- `CopyAreaDepthMismatchTests` — verify BadMatch (or acceptance) for depth-1 → depth-24, depending on what Solaris does. Capture+diff a small Motif app from u5 first to lock the answer.

Integration: Todd has live u5 access. Visual inspection of dtcalc / dtterm after Stage 2 lands. The buttons either show shadows + labels, or they don't. Either way, capture a fresh quickplot and dtcalc trace and diff against gold via `swiftx-capture diff`. Image-hash regression is overkill at this stage; visual + traffic diff is enough.

## 8. Stage ordering — four commits

**Stage 0: settled.** Existing `captures/*-sun.xtap` already answered the open questions. See Stage 0 Findings near the top. No code changes; the reordering below is the consequence.

**Stage 1: PixelBuffer + DrawTarget refactor (the foundation).** New `PixelBuffer` type, attached to `PixmapEntry`, allocated eager at CreatePixmap via a small `PixmapTable.allocate(...)` helper, freed at FreePixmap. Introduce `DrawTarget` enum (`.window(topLevel, dx, dy)` / `.pixmap(id, depth)`). Refactor `validateDrawTarget` to return `DrawTarget?`. Every `handleXxx` poly draw and every bridge `drawXxx` learns the pixmap path via a unified `withDrawContext(_ target:)` helper that resolves to either the window's CGContext or the pixmap's CGBitmapContext, applies y-flip + AA-off + clip stack. Draws into pixmaps now actually write pixels. **Retires SHORTCUTS entry 42** (draws-to-pixmaps silent-drop) fully. OPCODE_STATUS rows touched: 65, 66, 67, 68, 69, 70, 71, 74, 76, 61, 64. All move from "impl (window-only)" → "impl (window + pixmap)." **Nothing visual changes yet** — Motif draws into the pixmap correctly but the CopyArea blit to the window still BadImplementations. Tests: PixmapDrawTargetTests, PixelBuffer alloc/free tests.

**Stage 2: CopyArea — the visual unlock.** Drop the BadImplementation from `handleCopyArea`. Pixmap→window, window→pixmap, pixmap→pixmap, cross-window all route through `CGContext.draw(image:in:)`. Same-window memmove path stays (xterm scroll fast path). Honor GC clip on every path except same-window memmove. Emit BadMatch on actual depth mismatches (defensive; doesn't fire on Motif's flow). **Retires SHORTCUTS entry 43** fully. **OPCODE_STATUS row 62** moves from "impl (Phase 1)" → "impl (all 5 cases)". Tests: CopyAreaPixmapTests, CopyAreaDepthMismatchTests. **This is the commit that visually unblocks dt-Motif button chrome and kills the quickplot blue-bleed.** Visual check on u5 + diff `dtcalc-swiftx.xtap` against `dtcalc-sun.xtap` after.

**Stage 3: PutImage decoder.** New `PutImageDecoder` (pure function). Bitmap-depth-1 + ZPixmap-depth-1 + ZPixmap-depth-8 decode into the pixmap's CGContext. Everything else: BadImplementation. **Retires SHORTCUTS entry 41** (PutImage silent-drop) fully. OPCODE_STATUS row 72 moves up. Visual: icon glyphs (xeyes pupil pixmaps, dtcalc icon, etc.) start rendering. Lower priority than Stage 2 since the dominant captures use Poly-into-pixmap, not PutImage-into-pixmap.

**Stage 4: GetImage + GC clip-mask.** GetImage decoder + handler (round-trip with the PutImage decoder). GC clip-mask via pixmap-as-CGImage. Both small once Stages 1–3 are in. OPCODE_STATUS row 73 (GetImage) gains its row; GC rows get a note about clip-mask. Tests: GetImageRoundTripTests.

Four commits, each independently buildable + test-passing. Each unlocks something concrete: Stage 1 builds the foundation and lets Motif's pre-paint draws actually land; Stage 2 lights up dt-Motif chrome and quickplot's plot panel; Stage 3 lights up icon glyphs; Stage 4 closes the protocol-completeness gap.

## 9. Risks and confidence targets

**Risks ranked (post-Stage-0):**

1. **Y-flip and origin alignment for the pixmap context.** Three coordinate spaces (X11 logical y-down, CG default y-up, FlippedXView's already-flipped y-down) plus a new fourth (pixmap context). High probability of getting this wrong on first try and seeing upside-down chrome. **Mitigation:** apply *exactly* the same transform we apply to the window backing context (`FlippedXView.swift:308-310`); one helper function shared, no copy-paste.
2. **DrawTarget refactor touches every draw handler.** Wide change, easy to miss one. **Mitigation:** the type system catches it. Once `validateDrawTarget` returns `DrawTarget?`, every caller has to update or the build breaks.
3. **PutImage byte-format details — bit-order MSB vs LSB.** Easy to get wrong, hard to debug visually because depth-1 glyphs are small. Less load-bearing post-Stage-0 (Motif chrome doesn't depend on PutImage). **Mitigation:** unit tests with hand-constructed bytes are dirt cheap; write them *before* trying to render real icon glyphs.
4. **Memory growth.** Pathological client allocates 100MB of pixmaps. **Mitigation:** not a real risk for our target apps; if it happens later we add a budget/LRU eviction.

**Confidence targets after the work:**

- PutImage Bitmap depth=1: **high** (covers 95%+ of captures, well-defined format)
- PutImage ZPixmap depth=1/8: **medium** (covers the rest of what's seen, less unit-tested)
- PutImage everything else: **stub** (BadImplementation)
- CopyArea window→window same: **high** (preserves existing behavior)
- CopyArea pixmap→window: **medium** (load-bearing for dt-Motif, will be visually-tested)
- CopyArea window→pixmap, pixmap→pixmap: **medium** (symmetric, less tested by real clients)
- CopyPlane: **medium** if shipped confidently, **stub** if Stage 0 shows dt-Motif doesn't use it
- GetImage: **medium** (round-trip tests cover the cases shipped; depth conversion has corners)
- Draws into pixmaps via every poly op: **medium** (same code path as window draws, but pixmap-target is a new code path)

## 10. Resolved framing questions

- ~~CopyPlane may be the actual dt-Motif unlock.~~ Resolved by Stage 0: zero CopyPlane traffic in any capture. Plain CopyArea is what Motif uses.
- ~~Depth-mismatch BadMatch may break dt-Motif.~~ Resolved by Stage 0: Motif always creates pixmaps at root-depth, so depth always matches. Defensive BadMatch in the handler is correct but won't fire on the load-bearing flow.
