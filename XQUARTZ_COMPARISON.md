# XQuartz vs swift-x: feature comparison

Why we don't need Xplugin / the CGS private APIs that XQuartz depends on.

This doc exists because the question keeps coming up: how does swift-x deliver an X11 server on macOS using only public AppKit when XQuartz ships a large body of code (`libXplugin`, CGS/SkyLight bindings, historically a kernel extension) to do the same thing? Short answer: we made a fundamentally different scope decision, and that decision pays us back by letting us use only public AppKit.

## The table

| Capability | XQuartz (Xplugin/CGS) | swift-x (public AppKit) | Matters for our scope? |
|---|---|---|---|
| X popup menus over other Mac windows | ✓ (CGS levels) | ✓ (`NSWindow.Level.popUpMenu`) | **Yes — both deliver** |
| X over TCP from another machine | ✓ | ✓ | **Yes — both deliver** |
| Mac-style window chrome + WM | ✓ | ✓ | **Yes — both choose this** |
| QueryPointer live position while cursor is over any X window | ✓ | ✓ (via AppKit motion events) | **Yes — both deliver** |
| X windows above macOS menu bar / Dock | ✓ | ✗ | No |
| QueryPointer / motion events while cursor is over OTHER Mac apps | ✓ (global via `xp_*`) | ✗ (lastPointerXY freezes) | No — xeyes, menus only care about inside-X tracking |
| Exclusive input grab (block Cmd-Tab during X grab) | ✓ | ✗ | No — Cmd-Tab still working is actually nicer on Mac |
| Custom X cursor across the whole desktop | ✓ | ✗ (inside X windows only) | No |
| SHAPE — transparent pixels outside bounding shape | ✓ | ✗ (deferred; reachable via `NSWindow.isOpaque = false` + `CALayer.mask`) | Low — xeyes is rectangular anyway; `oclock` would benefit |
| Rootful mode (one big virtual X root) | ✓ | ✗ (rootless only by design) | No — Mac integration is the point |
| Multiple X visuals (8-bit PseudoColor, etc.) | ✓ | ✗ (24-bit TrueColor only) | Low — modern toolkits prefer TrueColor |
| Direct framebuffer blits | ✓ (`xp_*` to shared memory) | ✗ (CGContext per window) | No — throughput is fine for our app set |
| Backing store / save-under | ✓ (limited) | ✗ (re-paint on Expose; correct via cascade) | No |
| Drag tracking across to non-X apps | ✓ | ✗ (within-app via `NSEvent.addLocalMonitorForEvents`) | Low — Sun apps don't drag to Safari |
| X extensions (XKB, SHAPE, MIT-SHM, RENDER, ...) | Wide | None | Varies; our apps don't request them |
| Local UNIX-socket DISPLAY | ✓ | ✗ (TCP only currently) | Low — TCP suffices for vintage Sun + local clients |

## What this means

Every capability where the answer is "✓ XQuartz, ✗ us" lives in the "No" or "Low" matters column. The capabilities that actually matter to our use case (popup z-order, network listen, Mac-native chrome, cursor tracking inside X windows) we deliver from **public AppKit only**.

The reframing: XQuartz needs Xplugin not because the macOS public API stack can't host an X server. They need it because they're trying to deliver behaviors that macOS users would actively dislike — X apps that can't be Cmd-Tabbed away from, override-redirect popups over the menu bar, exclusive input grabs that block other apps. They're fighting the OS to deliver Linux X11 semantics. We embrace the OS and accept the trade.

## Where we'd reach if scope ever expanded

These are the deferred items in the table that we COULD do with reasonable effort from public AppKit, if the use case ever justified it:

- **SHAPE**: ~2 focused days. Port `Xext/shape.c` faithfully; top-level windows get `NSWindow.isOpaque = false` + a `CALayer.mask` keyed to the bounding region; sub-windows already work via the existing `clipList` intersection. See the end-of-2026-05-25 chat for the full scope analysis.
- **UNIX-socket DISPLAY**: ~1 day. Add a second listener on `/tmp/.X11-unix/X0` with the same `runConnection` plumbing. Useful if we ever ship to people running X clients on the same Mac.
- **Global pointer position in QueryPointer**: ~5 lines. Replace `lastPointerXY` read with `NSEvent.mouseLocation` translated to X-root coords. Makes xeyes track across the whole desktop. Filed as task but low priority since cursor-inside-X behavior is what real X clients care about.

The items NOT in this list (rootful mode, exclusive grabs, X windows over menu bar, custom cursor across desktop, framebuffer blits) are out of scope by design, not deferred. We won't add them.

## See also

- `PROJECT.md` — overall scope and non-goals
- `DECISIONS.md` 2026-05-05 entry — why Swift X server vs other approaches
- `DECISIONS.md` 2026-05-14 backing-store decision — closely related (we chose re-paint over save-under for the same reason: public AppKit suffices)
- `.claude-memory/reference_xquartz_drag_routing.md` — the one place we approximate XQuartz's xp_* behavior, using `NSEvent.addLocalMonitorForEvents`
