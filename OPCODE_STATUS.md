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
| (setup) | SetupRequest / SetupAccepted | not impl | — | — | M1 will hardcode SetupAccepted; see SHORTCUTS.md |
| 1  | CreateWindow | not impl | — | — | M1: track only. M2: create NSWindow for top-level. |
| 2  | ChangeWindowAttributes | not impl | — | — | M1: store mask+values; ignore BackingStore bit |
| 8  | MapWindow | not impl | — | — | M1: track only. M2: emit Map/Configure/Reparent/Expose. |
| 9  | MapSubwindows | not impl | — | — | M1: track only |
| 12 | ConfigureWindow | not impl | — | — | M3: needed for child resize on parent resize |
| 18 | ChangeProperty | not impl | — | — | M1: store. WM_NAME → NSWindow title in M2. |
| 20 | GetProperty | not impl | — | — | M1: stub returns empty for unknown props |
| 16 | InternAtom | not impl | — | — | M1: monotonic, same name → same ID |
| 33 | GetInputFocus | not impl | — | — | M1: stub reply |
| 43 | OpenFont | not impl | — | — | M1: accept any name, return success |
| 47 | QueryFont | not impl | — | — | M1: stub reply (xclock doesn't render text) |
| 53 | CreatePixmap | not impl | — | — | M1: track. xclock makes 2 unused 48×48 depth=1 |
| 55 | CreateGC | not impl | — | — | M1: store mask+values |
| 56 | ChangeGC | not impl | — | — | M1: update stored values |
| 60 | FreeGC | not impl | — | — | M1: remove from resource table |
| 61 | ClearArea | not impl | — | — | M3: render (used for erase-before-redraw) |
| 65 | PolySegment | not impl | — | — | M3: render (the 60 minute ticks) |
| 66 | PolyLine | not impl | — | — | M3: render (hand outlines, dial details) |
| 69 | FillPoly | not impl | — | — | M3: render (hand bodies, convex) |
| 72 | PutImage | not impl | — | — | M1: accept and store (xclock writes icon bitmaps) |
| 84 | AllocColor | not impl | — | — | M1: synthetic pixel, cached server-side |

(Add rows as opcodes get encountered.)

## Per-opcode notes

(Populated when an opcode has more to say than fits in the Notes column.)
