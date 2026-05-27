# Graphics primer: the y-flip and how not to break it

This doc exists because we lost a day to a y-orientation bug in May 2026
that should have been a 10-minute fix. The bug came back in different
shapes across multiple sessions because the convention wasn't documented
in one place and the test suite couldn't see orientation regressions.
Read this before adding any graphics op or touching any code that draws
into a `PixelBuffer` or `FlippedXView` backing.

## The convention

X11 protocol coordinates are y-DOWN: (0, 0) is the top-left of a
drawable, increasing y goes down the screen. macOS Quartz (CGContext)
is y-UP by default: (0, 0) is bottom-left, increasing y goes up.

We render X11 traffic by reconciling the two: every backing context we
write into gets a y-flipped CTM applied at creation so X coords pass
through unchanged. There are three such backings:

1. **`PixelBuffer.context`** — every X pixmap is one of these. The
   y-flip CTM lives in `PixelBuffer.init` (see `PixelBuffer.swift`).
2. **`FlippedXView.backing`** — the CGBitmapContext that holds a
   top-level window's pixels. Same y-flip CTM, plus a logical→device
   scale factor.
3. **`FlippedXView` itself** — `isFlipped = true` so AppKit's layout
   and event coordinates also match X11. (Different mechanism: AppKit
   flag, not a CTM. Same intent.)

Net effect: a draw at user-space `(x, y)` lands at memory row `y` from
the top (no math required at the call site). Fill, stroke, and text
ops all just work.

## Where it breaks: image-source draws

`CGContext.draw(image:in:)` does **not** "just work" in a y-flipped
context. Apple's canonical gotcha: when the CTM is y-flipped, image
rows land upside-down in memory unless the caller applies a local
counter-flip. CGImage data has an internal orientation (row 0 = top of
image); the y-up vs y-down mismatch shows up here and nowhere else.

This affects:

- `CGContext.draw(_ image: CGImage, in: CGRect)`
- `CGContext.draw(_ pdf: CGPDFPage)` (we don't use it today; would
  have the same issue).
- Pattern fills derived from images.

It does NOT affect:

- `CGContext.fill(_ rect: CGRect)` (no orientation)
- `CGContext.stroke(...)`, `CGContext.addPath / drawPath`
- `CTFontDrawGlyphs` (already counter-flipped per-call inside our
  text ops; see the `[Y-FLIP #3 of 3]` comment in `drawImageText8`).

## How we protect against the gotcha

**Rule: never call `ctx.draw(image, in:)` against a `PixelBuffer` or
window backing directly.** Use the helper:

```swift
ctx.drawImageRespectingYFlip(cgImage, in: dstRect)
```

The helper lives in `PixelBuffer.swift` as an extension on `CGContext`.
It saves GState, applies a local `translateBy + scaleBy(1, -1)`
matched to the destination rect, draws, restores. Compose-friendly:
your other CTM manipulations are not affected.

Today the only two callers are `drawPutImage` and `blitCroppedImage`
in `CocoaWindowBridge.swift`. If you add a third, it goes through the
helper.

## Required test for any new image-source graphics op

If you add or modify code that calls `ctx.draw(image:in:)` (or any
other image-source op), you MUST add a test in
`Tests/SwiftXServerCoreTests/YFlipOrientationTests.swift` (or a new
file with the same shape) that:

1. Builds an **asymmetric** source (top row distinct from bottom row).
   Symmetric blocks of one color can pass even when rows are flipped
   in memory — that's how the May 2026 bug stayed alive.
2. Exercises the new path end-to-end against the real
   `CocoaWindowBridge` and `PixelBuffer` (no mocks).
3. Reads pixmap memory directly via `buf.context.data` and asserts
   that memory row 0 corresponds to the top of the source.

Existing tests are the reference shape:

- `testDrawPutImageWritesRowZeroAsTopOfSource` — single-op write test.
- `testCopyAreaPixmapToPixmapPreservesRowOrder` — fill-source blit test.
- `testPutImageThenCopyAreaPreservesOrientation` — full chain test.

Symmetric-color tests like the old `CopyAreaPixmapTests` paths are
**not sufficient**. They pass when rows are upside-down. Don't lean
on them for orientation coverage.

## The five-flip composition (advanced, for reference)

There are five places in the codebase where a y-flip happens. Knowing
them helps when something visually wrong shows up:

1. **`PixelBuffer.init` CTM** — `translateBy(0, h); scaleBy(1, -1)`.
   Bakes the y-down convention into every pixmap's context.
2. **`FlippedXView.resizeBacking` CTM** — same shape as #1, plus the
   device-scale factor. Bakes y-down into the window backing.
3. **`FlippedXView.draw` blit** — copies the y-flipped backing into
   AppKit's natively y-up draw context. The CGImage from the backing
   is drawn at full bounds and AppKit's automatic flip on a flipped
   view inverts it back to the right orientation on screen.
4. **`drawImageText8` / `drawPolyText8` glyph local flip** — every
   text op does a local `saveGState / translateBy / scaleBy(1, -1) /
   restoreGState` around `CTFontDrawGlyphs` because glyph art is in
   CG's y-up convention. Look for `[Y-FLIP #3 of 3]` and similar tags.
5. **`drawImageRespectingYFlip` helper** — the counter-flip for
   image-source draws. The reason this doc exists.

If you're touching any of these and find yourself confused, walk the
chain end-to-end with a single asymmetric pixel: where does memory
row 0 of the source end up in screen coords?

## The history that motivated this doc

- **2026-05-26 (be8fdce):** Motif horizontal scrollbar thumb shadows
  rendered upside-down. Counter-flip added to `blitCroppedImage` only.
- **2026-05-27 morning (2532ba6):** That fix regressed quickplot's
  button-bar bitmaps (they now rendered upside-down). Reverted.
- **2026-05-27 afternoon (7880fa6):** Diagnosed the asymmetry —
  `drawPutImage` was the inconsistent writer. Counter-flip added in
  BOTH writer sites. Both visual bugs closed. This doc + the helper +
  the regression tests landed in the follow-up commit.

The thing that kept us out of the fix for a week was that
`CGContext.draw(image:in:)` produces the same memory-orientation bug
across two different writers, and our test suite couldn't see it —
asymmetric sources hadn't entered our orientation testing vocabulary.
This doc and `YFlipOrientationTests.swift` are the fence against
that mistake happening again.
