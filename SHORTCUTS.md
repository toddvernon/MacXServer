# Shortcuts and stubs

Running list of places we hardcoded, stubbed, or otherwise corner-cut to make something work. Each entry should die eventually; the point of the file is to make sure none of them is forgotten.

## Convention

- **When you hardcode** something to make a bigger thing work, add an entry here in the same change.
- **When you replace** a hardcode with a real implementation, delete the entry (or move it to the Closed section at the bottom).
- Periodically review the open list. If it's growing and not shrinking, that's a signal to stop adding features and clean up.
- Each entry: file or component, what's stubbed, why, what "real" would look like.

## Open

- **SetupAccepted is hardcoded.** Lives in `Sources/SwiftXServerCore/ServerConfig.swift` as `ServerConfig.default`. One screen 1280×1024, one PseudoColor 8-bit visual (id 0x22), one pixmap format (depth=8 bpp=8 pad=32), vendor "swift-x", root=0x28, defaultColormap=0x21, resourceIdBase=0x4400000. The matched-Sun values are used so unit tests can replay the captured Sun C2S byte stream against our server. Real version: derive from actual macOS display geometry, expose both PseudoColor 8-bit and TrueColor 24-bit per `DECISIONS.md`.
- **GetProperty returns empty for unknown properties.** `Sources/SwiftXServerCore/ServerSession.swift` `case .getProperty`: serves stored props from `PropertyTable` when present, returns `GetPropertyReply.empty` otherwise. xclock's `GetProperty(RESOURCE_MANAGER)` hits the empty path and falls back to compiled-in defaults. Real version: maintain a server-side Xrm database (loaded from `xrdb`-equivalent or `~/.Xdefaults`).
- **AllocColor returns synthetic monotonic pixel values.** `Sources/SwiftXServerCore/ColorTable.swift` allocates from `nextPixel = 16` and caches `pixel → RGB` for M3's draw-time lookup. Real version: a proper PseudoColor colormap implementation with shared cells, freelist, and StoreColors.
- **QueryFont returns a stub.** `Sources/SwiftXServerCore/ServerSession.swift` `case .queryFont`: hardcoded ascent=11 descent=2, char-range 32..126, no properties or charinfos. Works because xclock doesn't render text. Real version: open the requested font via Core Text, fabricate metrics consistent with what we'll actually render — see `DECISIONS.md` 2026-05-05 (font handling).
- **OpenFont accepts any name and returns success without doing anything.** `case .openFont` records the fid and the bytes of the name; no Core Text matching. Real version: name → Core Text font matching, with the "lie" approach for X core fonts.
- **CreatePixmap depth=1 / PutImage just track and drop pixels.** `case .createPixmap` records geometry; `case .putImage` is a silent no-op. xclock's icon bitmap and mask never get used in rootless mode (the NSWindow gets its icon from the app bundle). Real version: when we care about iconified state, bridge depth=1 pixmaps to NSWindow icon.
- **ChangeWindowAttributes only honors CWEventMask.** `case .changeWindowAttributes` extracts the event mask if set; everything else (BackPixel, BorderPixel, Colormap, BitGravity, BackingStore) is dropped. Real version: M3+ honors the rest; BackingStore stays ignored permanently.
- **GC state is stored as raw mask+valueList, not parsed.** `Sources/SwiftXServerCore/ResourceTables.swift` GCEntry just records the bytes. M3 will need to translate to a `GCState` struct that maps to CGContext attributes per `RENDERING_DESIGN.md`.
- **No events emitted for non-mapping flows.** M2 emits ReparentNotify / ConfigureNotify / MapNotify / Expose / UnmapNotify / DestroyNotify on top-level lifecycle, plus MapNotify on descendants of a mapped top-level. EnterNotify / LeaveNotify / FocusIn / FocusOut / KeyPress / ButtonPress are not emitted. xclock doesn't care; xterm and others will.
- **Expose on map walks the descendant tree.** `MockWindowBridge.emitMapSequence` (shared between Mock and Cocoa bridges) emits Expose on the top-level if its event mask has ExposureMask, then on each already-mapped descendant whose event mask has ExposureMask. This matches X11's "newly viewable" rule for the simple case (no border + no obscured regions). xclock's inner window registers ExposureMask, so it gets the Expose and starts drawing.
- **Synthesized ReparentNotify uses a constant fake parent ID.** `MockWindowBridge.syntheticParentId = 0xC0FFEE00`. xclock and most apps don't care what this value is, just that the event arrives. If a client tries to manipulate the synthesized parent, they'll get an unknown-window response.
- **NSWindow opens at fixed (100, 100) on screen.** `CocoaWindowBridge.mapTopLevel` ignores the X CreateWindow geometry's x/y for the screen position. Real WMs honour `WM_NORMAL_HINTS` and various positional hints. For now the X coords just decide window size.
- **Window background is white if BackPixel is unset.** `windowBackground()` falls back when CWBackPixel isn't in the CreateWindow valueList. xclock sets it explicitly, so this is rare in practice.
- **Color resolution falls back to black for unknown pixels.** `ServerSession.resolveColor` returns black when `ColorTable.rgb(for:)` is nil. Replayed captures hit this constantly because the captured CreateGC bytes reference pixels that the *original* Sun server allocated, not ours. For live clients this is fine because they see our AllocColor reply and use our pixel values.
- **No XErrors emitted, ever.** Decode failures and unknown opcodes are logged but don't synthesize a real X protocol error to the client. Real version: emit BadRequest / BadValue / etc. with proper sequence numbers.
- **Drawing happens on main thread, but read thread doesn't wait.** The session calls bridge.draw* from the read thread; bridge does `DispatchQueue.main.async`. So drawing closures queue up. They run in the order issued because the main queue is serial. But if main is busy/blocked, drawings pile up and don't appear. Fine for xclock-paced workloads; xterm will need a different model.
- **NSWindow user-resize doesn't propagate.** No `windowDidResize` delegate yet. The X client never sees a ConfigureNotify when the user drags the corner, so it doesn't redraw. M3 polish.
- **Single-client only.** `Listener.runOne()` accepts one connection and the listener stops when the client disconnects. Multi-client is post-PoC; needs per-connection resource ID isolation.

## Closed

(Empty. Items move here from Open when fixed.)
