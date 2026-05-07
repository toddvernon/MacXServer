# Opcode implementation status

Per-opcode status and confidence for the Swift X server. Updated every time an opcode gets implemented, changed, or reviewed. The point is to know — at a glance — which parts of the protocol we trust and which we don't.

For the Mac graphics primitive each opcode resolves to, see `RENDERING_DESIGN.md` (per-opcode mapping table). This file tracks *implementation status*; that file is the *design intent*.

## Convention

Whenever you implement, change, or stub an opcode in the server:

1. Update this file. Set Status, Confidence, Last reviewed, and Notes if there's anything non-obvious.
2. Confidence reflects "if a real client uses this in any normal way, will it behave correctly?" Be honest — low confidence is fine, hidden low confidence is not.

When new R6-spec edge cases get verified, ratchet Confidence up. When a client misbehaves and we trace it to an opcode, ratchet Confidence down and add a Note.

## Confidence levels

- **High** — implemented, tests cover the common and tricky cases, matches spec to our reading, no known caveats.
- **Medium** — implemented, basic tests pass, but specific aspects (edge cases, unusual flag combinations, subtle byte-order or padding details) haven't been verified against a real corpus or live client.
- **Low** — implemented, works for the cases we've seen, but we know there are aspects we punted on. Notes column says what.
- **Stub** — returns enough to keep clients happy (replies have correct shape and sequence numbers) but doesn't do the actual work the opcode names. See `SHORTCUTS.md`.
- **Not implemented** — opcode is not handled yet. Either errors out, gets ignored, or the server doesn't survive seeing it.

## Status

Pre-populated with the opcodes xclock will hit during M1. Other opcodes get rows as they're encountered.

| Opcode | Name | Status | Confidence | Last reviewed | Notes |
| --- | --- | --- | --- | --- | --- |
| (setup) | SetupRequest / SetupAccepted | impl | medium | 2026-05-07 | Hardcoded SetupAccepted (see SHORTCUTS); accepts both byte orders; partial buffering tested |
| 1  | CreateWindow | impl (M2: NSWindow on top-level) | medium | 2026-05-07 | parent==root → bridge.registerTopLevel; descendants stored in WindowTable only. |
| 2  | ChangeWindowAttributes | impl (M1 track-only) | medium | 2026-05-07 | Updates eventMask only; other attrs ignored. BackingStore bit silently dropped. |
| 8  | MapWindow | impl (M2) | medium | 2026-05-07 | Top-level: bridge brings up NSWindow, emits ReparentNotify+ConfigureNotify+MapNotify+Expose. Descendant: bridge emits MapNotify only. |
| 9  | MapSubwindows | impl (M2) | medium | 2026-05-07 | Marks every direct child mapped + bridge.mapDescendant for each. |
| 10 | UnmapWindow | impl (M2) | low | 2026-05-07 | Top-level: bridge orderOut + UnmapNotify. Descendant: tracking only. Not exercised by xclock. |
| 12 | ConfigureWindow | impl (M2 track-only) | low | 2026-05-07 | Width/height/x/y honoured in tracking. NSWindow user-resize → ConfigureNotify+Expose still TODO (M3). |
| 16 | InternAtom | impl | high | 2026-05-07 | Monotonic ID assignment, name-stable across calls. Tested. |
| 18 | ChangeProperty | impl | medium | 2026-05-07 | Replace/prepend/append all supported. Per-window dictionary. |
| 20 | GetProperty | impl (stub-ish) | low | 2026-05-07 | Returns stored prop if present, otherwise empty. xclock's RESOURCE_MANAGER hits empty path. |
| 43 | GetInputFocus | impl | medium | 2026-05-07 | Always reports focus=None, revertTo=None. |
| 45 | OpenFont | impl (M1 track-only) | medium | 2026-05-07 | Accepts any name, no real Core Text mapping yet. |
| 47 | QueryFont | impl (stub) | low | 2026-05-07 | Stub reply with ascent=11 descent=2 char-range 32..126, zero properties/charinfos. xclock doesn't render text so passes. |
| 53 | CreatePixmap | impl (M1 track-only) | medium | 2026-05-07 | Records id/depth/dimensions. No backing pixels (M3). |
| 54 | FreePixmap | impl | medium | 2026-05-07 | Removes from table. |
| 55 | CreateGC | impl (M1 track-only) | medium | 2026-05-07 | Stores valueMask+valueList. No CG state translation yet (M3). |
| 56 | ChangeGC | impl (M1 track-only) | low | 2026-05-07 | Coarse merge of valueMask+valueList. Will need finer state model in M3. |
| 60 | FreeGC | impl | medium | 2026-05-07 | Removes from table. |
| 72 | PutImage | accepted, no-op | low | 2026-05-07 | Bytes are decoded by framer but pixels are dropped. xclock writes icon bitmaps; we don't surface them anywhere yet. |
| 84 | AllocColor | impl | medium | 2026-05-07 | Monotonic pixel (start=16), pixel→RGB cached. No real palette. |
| 98 | QueryExtension | impl (stub) | medium | 2026-05-07 | Reports `present=false` for everything. |
| 65 | PolyLine | impl (M3) | medium | 2026-05-07 | Strokes a connected line strip via CGContext. Origin and Previous coordinate-modes both supported. Line-width from GC (0 → 1px). |
| 66 | PolySegment | impl (M3) | medium | 2026-05-07 | Strokes independent line segments via CGContext.move+addLine+strokePath. |
| 69 | FillPoly | impl (M3) | low | 2026-05-07 | Fills with foreground; uses GC fill-rule (default EvenOdd). Convex/Nonconvex/Complex shape attribute not yet specialised. |
| 61 | ClearArea | impl (M3) | low | 2026-05-07 | Fills rect with window's BackPixel. width=0/height=0 fill-to-edge supported. exposures bit ignored. |

(Add rows as opcodes get encountered.)

## Per-opcode notes

(Populated when an opcode has more to say than fits in the Notes column.)
