# Post 7: Live xterm

**Date range**: May 7 - May 8, 2026
**One-line elevator**: With the rendering and scaling design landed (Post 6), xterm becomes a daily-usable terminal: ANSI colors, scrollback via CopyArea, keyboard input, live resize, Cmd-C copy to Mac clipboard, FocusIn/Out driving the cursor state. A real xterm session from a real Sun, on a real Mac.

## What this post covers

The shift from "the scaling math is right (Post 6)" to "xterm is a daily-usable terminal." Implementation milestones: keyboard, scrollback, colors, copy-paste, live resize, focus-driven cursor state. The protocol opcodes that xterm needs and xclock doesn't.

## Setting

Post 6 closed the scaling-design battle: integer scale, three-plane decomposition, cell-fits-font, no bitmap fonts. xterm at 3x looks correct. Now the rest of xterm has to work: typing produces text on screen, scrolling moves content, resizing reflows, focus matters, copy/paste roundtrips with macOS.

## What xterm needs that xclock doesn't

- `OpenFont` + `QueryFont` with actual metrics, not stubs (handled in Post 6's font work)
- `ImageText8` (text with bg fill) for terminal glyphs
- `PolyFillRectangle` for cell backgrounds
- `CopyArea` (same-window) for scroll
- Font resolution: XLFD parsing + substitution (handled in Post 6)
- Keyboard input: NSEvent → X event with keysym mapping
- Color: ANSI escape sequences want pixels for the 16 ANSI colors; xterm allocates them via AllocColor
- Selection: PRIMARY ownership for "copy selection" semantics

## Keyboard and US-ASCII keymap

xterm needs every keypress translated from NSEvent virtual keyCode to an X keysym, then encoded as a KeyPress event with modifier state. `USKeymap.swift` is the lookup table: macOS NSEvent virtual keyCode + 8 = X keycode, then the X server returns keysyms for that keycode via `GetKeyboardMapping`.

US-ASCII layout covers letters, digits, punctuation, arrows, modifiers. International layouts deferred. The keymap got significant expansion later for Motif (Post 9), which needs more keysyms than xterm cares about.

## Scrollback via CopyArea + NoExpose

xterm scrolls by calling `CopyArea` on its own window: copy rows N through bottom up one row, then ImageText8 the new bottom row. The source area is the same window. Easy case.

The subtle part: the X spec says CopyArea emits `GraphicsExpose` for any source region that wasn't readable, and `NoExpose` if the whole source was readable. xterm has a `CopyWait` mechanism that blocks waiting for one of those two events after every CopyArea. Without it, xterm wedges after the first scroll.

We always emit `NoExpose` for now (no real visibility tracking, see SHORTCUTS.md). xterm sees NoExpose, unblocks, continues.

## ANSI color and the ChangeGC bug

Commit `b60ae9b` 2026-05-08: "Color xterm: ANSI colors render via parsed-per-bit GC state, plus Cmd-V paste."

xterm sets up 16 ANSI colors at startup via AllocColor, then uses them as GC foreground/background. Each color escape (`ESC[31m` for red, etc.) switches the GC's foreground pixel value via ChangeGC. The render path resolves the pixel back to RGB16 every draw call.

The bug we hit on the way (commit `2dec89f`): ChangeGC was previously concatenating raw bytes onto the existing valueList. The materialiser kept reading the original CreateGC foreground, so xterm's per-glyph color switches never landed. The first xterm sessions rendered everything in the initial foreground color regardless of ANSI escapes.

Fix: ChangeGC re-parses the partial valueList using the change's own mask and merges into the entry's per-bit dict, overwriting prior values. From then on, xterm color works correctly.

This bug is worth dwelling on as an example of a non-obvious correctness issue. The framer decoded ChangeGC correctly. The dispatcher accepted ChangeGC. But the storage model was wrong, and the symptom was "colors don't update" rather than any kind of protocol error. Took a real xterm-with-color session to surface it.

## FocusIn / FocusOut and the cursor

xterm renders a filled cursor when focused (block over the glyph) and an outlined cursor when unfocused (hollow rectangle). That means the server has to emit FocusIn / FocusOut at the right moments when the NSWindow becomes or loses key status.

Commit `b238e11` 2026-05-07: FocusIn / FocusOut wired through CocoaWindowBridge's NSWindowDelegate `windowDidBecomeKey` / `windowDidResignKey`. With it, xterm's cursor properly switches between filled and outlined as the user clicks between windows.

The X spec's focus events are more complex than "this window gained focus." They have a `detail` field (NotifyAncestor, NotifyVirtual, NotifyInferior, NotifyNonlinear, etc.) describing the focus traversal path. We emit `NotifyNonlinear` for the simple case and the toolkits seem happy.

## Live resize without white-flashing

Commit `d50ec81` 2026-05-08: "Live-resize stops white-flashing: defer bitmap realloc, layer-back the view, draw at native size."

The naive resize handler reallocated the FlippedXView's backing CGBitmapContext on every windowDidResize call. AppKit was firing windowDidResize many times per second during a live drag, so the bitmap was getting torn down and recreated continuously, briefly showing white each time.

Fix: defer the bitmap realloc until live-resize ends (NSWindowDelegate's `windowDidEndLiveResize`). During live-resize, the existing bitmap shows scaled to AppKit's current frame. Layer-back the view so AppKit composites at native resolution. Result: smooth resize with no flash.

## Cut and paste via PRIMARY selection

xterm uses the PRIMARY selection for its "select text → middle-click to paste" model. swift-x bridges PRIMARY ↔ NSPasteboard:

- **Outbound (X to Mac):** xterm calls SetSelectionOwner on PRIMARY when text is selected. On Cmd-C, the session SelectionRequests STRING into a server pseudo-window, intercepts the ChangeProperty containing the selected bytes, pushes them to NSPasteboard.
- **Inbound (Mac to X):** on Cmd-V, the server fakes a paste by reading NSPasteboard and synthesizing the SelectionRequest/SelectionNotify chain into the focused X window.

Limits: PRIMARY only (no CLIPBOARD atom yet), STRING only (no UTF8_STRING or COMPOUND_TEXT), no INCR for selections larger than the request-size limit.

Two trigger modes in the Mac-side Preferences window: Mac behavior (autocopy on selection, matches macOS convention) vs Xterm behavior (Cmd-C explicit, matches X convention). User picks which they want.

## Pivotal moment

The first usable xterm session: connect from u5, type at the prompt, see output, scroll backward and forward, resize the window with the macOS title-bar drag, copy text to the Mac clipboard with Cmd-C. A real terminal from a real Sun, on a real Mac, looking better than XQuartz could manage.

## What Todd should add

- The "this is a daily-usable terminal" feeling.
- The ChangeGC bug as a story. The frustration of "the protocol is right but the colors don't change."
- The cut/paste UX choice. Mac users vs Xterm users have different expectations. Why expose both modes.
- Live verification flow against u5. What does "test against the Sun" actually look like as a daily routine?
- The "looks better than XQuartz could manage" moment in voice.

## Thread anchor: protocol vs implementation

The scaling work in Post 6 was "protocol commands, modern rendering." This post is the corollary: even with the rendering right, getting the protocol behavior right takes per-opcode care. ChangeGC's storage model is a protocol-contract bug, not a rendering bug. CopyArea's NoExpose is a protocol-contract requirement, not a rendering requirement. The protocol surface has corners you only find when real clients exercise it.

## Anchors for fact-check pass

- Files: `Sources/SwiftXServerCore/USKeymap.swift`, `Sources/SwiftXServerCore/CocoaWindowBridge.swift` (FocusIn/Out, live resize), `Sources/SwiftXServerCore/GCState.swift`, `Sources/SwiftXServerCore/ClipboardPreferencesProvider.swift` (or similar)
- Commits: `b238e11` 2026-05-07 FocusIn/Out, `f730de0` 2026-05-07 CHATGPT_REVIEW cursor diagnosis correction, `65801b5` 2026-05-07 live xterm working (keyboard + scroll + resize), `3f9526c` 2026-05-07 ConfigureNotify on direct resize, `60cb353` 2026-05-07 xterm3 capture, `b60ae9b` 2026-05-08 color xterm + Cmd-V paste, `2dec89f` 2026-05-08 ChangeGC bg fix, `d50ec81` 2026-05-08 live-resize no flashing, `1c31714` 2026-05-08 cut to clipboard + Preferences
- 16 ANSI colors allocated at xterm startup via AllocColor
- PRIMARY-only selection wire path: SetSelectionOwner → ConvertSelection → SelectionRequest → ChangeProperty → SelectionNotify
- Open SHORTCUTS: CLIPBOARD atom not wired; UTF8_STRING not handled; INCR not implemented; GraphicsExpose always replaced with NoExpose

## Working title alternatives

- "Live xterm"
- "A usable terminal"
- "Day two, day three, day four: xterm gets real"
