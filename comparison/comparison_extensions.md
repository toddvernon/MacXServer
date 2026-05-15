# Extensions survey: swift-x vs xorg/XQuartz

Survey fork. swift-x advertises zero extensions today (every `QueryExtension`
reply returns `present=false` — see `ServerSession.swift` around line 3151), so
a per-extension implementation deep-dive would be empty. Instead: enumerate what
xorg/XQuartz expose, label era, judge whether we'd want each given our target
client mix (Sun u5/SS2 X11R6 apps, CDE dt-apps, Motif).

Authority: spec > X11R6 > xorg/XQuartz. Era column reflects when the wire
protocol for the extension was published, not when its current implementation
landed. xorg ≈ XQuartz unless noted; XQuartz disables some at startup.

## Extensions advertised by xorg/XQuartz

| # | Name | Wire-level summary | Era | Want? | Who needs it |
|---|------|--------------------|-----|-------|--------------|
| 1 | BIG-REQUESTS | Lets a single request exceed the 256KB core-protocol cap by inserting a 32-bit length word after the opcode. Negotiated once at startup; thereafter long requests just work. | R6 | **Y** | Any client that sends a large `PutImage`, a long `ChangeProperty`, or a fat `PolyText`. Modern Xlib calls `XExtendedMaxRequestSize` on connect; without us advertising it the limit is 262140 bytes. |
| 2 | XC-MISC | Two requests: `GetVersion` and `GetXIDRange` / `GetXIDList`, so Xlib can recover when the client-side XID pool runs dry on long-lived connections. | R6 | **Maybe** | Long-lived clients that allocate millions of XIDs (xterm chewing through pixmaps, a session-long Motif app). Without it a long-running client eventually can't create new resources. |
| 3 | SHAPE | Lets a client attach a non-rectangular bounding/clip region to a window. Sets the visible silhouette and the input-hit region independently. | R6 | **Y** | xeyes (the round eye), xclock (round face when run with `-shape`), oclock, every "shaped" toy app from the R6 era. dtwm and Motif gadgets are rectangular so this isn't strictly required for CDE, but R6-era demo apps will look square without it. |
| 4 | MIT-SHM | Hands off a System V shared-memory segment ID so the client can write pixels directly into a server-readable pixmap, skipping the socket. Local-only — both ends must share the same kernel. | R6 | **N** | Local clients doing video / X imaging. Our target clients are *remote* Sun u5/SS2 boxes — they can't share memory with macOS, so this is meaningless for the through-line use case. |
| 5 | MIT-SUNDRY-PROTOCOL (MIT-MISC) | One toggle: turn off the bug-compat behavior in R3/R4 clients. Two requests, `SetBugMode` and `GetBugMode`. | R6 | **N** | Nothing modern. R3/R4 clients are out of scope and we'd just no-op. |
| 6 | XTEST | Synthetic input injection plus screen-cursor compare. Lets a test harness drive the server without a human. | R6 | **Maybe** | `xdotool`, automated test rigs, `Xnee` recorders. We could use this ourselves for test fixtures driving our own server. Real apps don't need it at runtime. |
| 7 | SYNC | Counters and alarms keyed off X server time. Clients can wait on counters, schedule alarms, drive smooth animation. The XSync system depends on it. | R6 | **Maybe** | Motif's animation paths *can* use it (drag/drop, smooth scroll), modern Xlib uses `_NET_WM_SYNC_REQUEST` for tear-free resize. None of our R6-era clients require it. |
| 8 | XKEYBOARD (XKB) | A full keyboard model overlay on top of the legacy `GetKeyboardMapping` — groups, levels, virtual modifiers, geometry, indicators, compose. Half a hundred requests. | R6 | **Maybe** | Modern Linux clients assume XKB is present and silently degrade if absent. R6 Sun clients use the core keymap requests we already serve, so XKB is not on the critical path for the CDE/Motif workload. |
| 9 | XInputExtension (XI 1.x) | Secondary input devices — graphics tablets, multi-mouse, valuators. Original 1989 design, the "old XI". | R6 | **N** | Wacom drivers, tablet apps. None of our R6 Sun workloads use it. |
| 10 | XInputExtension v2 (XI2) | A redesign of XI: master/slave device hierarchy, raw events, per-device focus, touch events, smooth scroll, barriers. Wire-incompatible event delivery from core. | post-R6 | **N** | Modern GTK/Qt apps that want multitouch or raw motion. Our era predates this entirely. |
| 11 | RECORD | Lets a client tap the wire and receive copies of other clients' requests/replies/events. Built for `xnee` and similar recording tools. | post-R6 | **N** | `xnee`, debuggers. We have our own capture tool (Product 1) that does the same thing one layer down. |
| 12 | RENDER (Xrender) | Server-side compositing primitives: pictures, glyph sets, trapezoids, image filters, ARGB visuals. The basis for every antialiased font in modern X. | post-R6 | **Maybe** | GTK, Qt, modern xterm, anything drawing antialiased text via Xft. R6 Motif/CDE clients use core PolyText/ImageText so they don't need RENDER, but the moment a 2026 modern client connects, no RENDER means no glyphs. |
| 13 | RANDR | Resize and rotate. Lets clients query connected monitors, change resolution, set rotation, query EDID. v1.0 was simple, v1.2+ exposes per-CRTC/output info. | post-R6 | **Maybe** | Window managers, fullscreen apps, anything that wants to know the geometry of multi-monitor setups. We have a single virtual screen and our scaling is fixed at startup, so 1.0-level RANDR (a `GetScreenInfo` reply) would be cheap and stop a class of "what's my display?" probes. |
| 14 | XFIXES | Grab-bag of small fixes: server-side regions (`XFixesRegion`), cursor-image queries, selection-ownership change notifications, region operations for clipping. | post-R6 | **Maybe** | Composite and Damage both depend on it. Selection-change notifications would actually be useful for clipboard work. |
| 15 | DAMAGE | Server tells the client which rectangles of a drawable have changed. Lets compositors avoid re-reading whole windows. | post-R6 | **N** | Compositors (`compton`, `picom`). Not in our world. |
| 16 | Composite | Redirects child windows to off-screen pixmaps so a compositor can do its own blending. Plus name-window-pixmap for window-to-texture mapping. | post-R6 | **N** | Compositing window managers. XQuartz disables this at startup (`noCompositeExtension = TRUE` in `bundle-main.c:644`); we'd do the same. |
| 17 | DPMS | Display Power Management. Set/get the timeouts that put the monitor to sleep. | post-R6 | **N** | Power-management tools. macOS handles its own monitor sleep. |
| 18 | MIT-SCREEN-SAVER | Lets a screensaver register as the server-blanking client and get notified when the timeout fires. | post-R6 | **N** | `xscreensaver`. We aren't a screensaver platform. |
| 19 | SCREEN-SAVER (newer) | Same idea, slightly richer events. Often confused with above. | post-R6 | **N** | Ditto. |
| 20 | X-Resource | `XResQueryClients`, `XResQueryClientResources`. Lets a tool ask the server who owns which resources, for leak hunting. | post-R6 | **N** | `xrestop`. Diagnostic only. |
| 21 | XVideo (Xv) | YUV/RGB image port for hardware-overlay video playback. Bypasses the regular drawing pipeline. | post-R6 | **N** | mplayer/mpv on X. Modern apps moved on; we have no hardware overlay path on macOS anyway. |
| 22 | XVideo-MotionCompensation (XvMC) | Hardware-accelerated MPEG decode, layered on Xv. | post-R6 | **N** | Same as above, even less relevant. |
| 23 | DOUBLE-BUFFER (DBE) | Back-buffer per window, server-side swap. Pre-Composite tear-free animation. | post-R6 | **N** | Old animation toys. CoreAnimation gives us the same result for free. |
| 24 | Generic Event Extension (GenericEvent / GE) | Plumbing only — defines opcode 35 as the generic event envelope so extensions like XI2 can carry events bigger than the legacy 32-byte struct. | post-R6 | **Maybe** | Required if we ever add XI2. Nothing R6 needs it. |
| 25 | XFree86-Bigfont | Lets a client query a font's metrics via a shared-memory segment instead of a 256KB-cap-busting wire transfer. Now redundant since BIG-REQUESTS exists. | post-R6 | **N** | Legacy XFree86 clients. We already plan a saner font path. |
| 26 | XFree86-VidModeExtension | Read/write VESA modelines. | post-R6 | **N** | xvidtune-class hardware-poking tools. Useless on macOS. |
| 27 | XINERAMA / PanoramiX | Pre-RANDR multi-monitor — present multiple physical screens as one logical screen with `XineramaQueryScreens` enumerating their rectangles. XQuartz uses a derivative called PseudoramiX (`hw/xquartz/pseudoramiX/`) that just fakes the geometry from the Mac displays. | post-R6 | **Maybe** | Anything that lays out a window across two monitors. XQuartz disables real PanoramiX (`noPanoramiXExtension = TRUE` in `bundle-main.c:640`) and uses its faked variant. If we ever support multiple Mac displays we'd want PseudoramiX-style stub. |
| 28 | SECURITY | Untrusted-client tokens. Clients connecting with a "untrusted" cookie get reduced wire access. | post-R6 | **N** | Old `xauth -untrusted` flows. Modern stacks use namespaces / wayland for this. |
| 29 | XSELinux | SELinux MAC labels on X resources. Linux-only ideology, totally inert on macOS. | post-R6 | **N** | Never. |
| 30 | XACE | X Access Control Extension — internal hook framework SECURITY and XSELinux plug into. Not advertised on the wire by name. | post-R6 | **N** | Internal only. |
| 31 | GLX | OpenGL-over-X. Wraps GL calls into X requests, gives clients GLX contexts and drawables. The reason `glxgears` works. | post-R6 (R6 had GL bindings but GLX wire stabilised after) | **N** | Modern GL clients. None of our R6 Sun workloads use it. |
| 32 | DRI / DRI2 / DRI3 | Direct Rendering Infrastructure — hands a GPU-backed buffer to the client so it can render directly with hardware. XQuartz has an `Apple-DRI` variant in `hw/xquartz/xpr/appledri.c`. | post-R6 | **N** | Hardware-accelerated GL clients. macOS won't let us hand out raw GPU buffers cross-process anyway. |
| 33 | Present | Modern "show this buffer at this vblank" primitive. Replaces DBE for tear-free flips, used by Wayland-on-X bridges and modern GL apps. | post-R6 | **N** | Modern compositors. Not our world. |
| 34 | Apple-WM | XQuartz-specific. Lets `quartz-wm` ask the X server for window-manager events tied to Aqua window operations (zoom, miniaturize, close from the title bar). Defined in `hw/xquartz/applewm.c` and `hw/xquartz/xpr/xprAppleWM.c`. | XQuartz-specific (post-R6) | **N** today, **Maybe** future | Only quartz-wm. We're rootless and don't have a separate WM process; if we ever spawn a quartz-wm-style helper we'd want this. |
| 35 | Apple-DRI | XQuartz-specific. Direct-render path for GL on macOS, bypassing the X drawing pipeline. | XQuartz-specific (post-R6) | **N** | GL apps under XQuartz. Not on our roadmap. |

## Extensions XQuartz disables at startup

Worth calling out — even xorg's Mac port turns these off:

- **Composite** — `noCompositeExtension = TRUE`
  (`hw/xquartz/mach-startup/bundle-main.c:644`). XQuartz uses Aqua compositing
  instead.
- **PanoramiX** — `noPanoramiXExtension = TRUE` (`bundle-main.c:640`).
  PseudoramiX takes over.
- **RENDER** and **XTEST** — gated behind XQuartz prefs
  (`XQuartzPrefKeyRENDERExtension`, `XQuartzPrefKeyTESTExtension`) in
  `X11Application.m:550-551`. Off by default.

That's a useful signal: even Apple's port concluded that a rootless Mac-hosted X
server is better off *not* speaking some of these. We can use that as our
"reasonable Mac-X-server baseline" reference.

## What swift-x looks like to a 1995 R6 client

We're a server that says "no" to every `QueryExtension`. For a 1995 R6 client
that's actually pretty close to spec-correct — Xt and Motif are written to fall
back to core protocol when extensions aren't present. CDE dt-apps, xterm, xcalc,
xclock-without-`-shape`, xfontsel: all of these survive on plain core, which is
why our current setup boots them at all. The visible gaps in the R6 world are
exactly two: (a) any client that uses **SHAPE** (xeyes, oclock, xclock with
`-shape`, the round-eye Motif demos) will render as an opaque rectangle —
protocol-legal, just ugly. (b) Clients that issue large requests will be capped
at 262140 bytes per request without **BIG-REQUESTS**; for our captured workloads
we haven't hit this yet but xterm with a very wide font set or a pixmap-heavy
Motif app will eventually. Everything else in the R6 extension set (MIT-SHM,
MIT-MISC, XTEST, SYNC, XKB, XInput, XIE) is either local-only, era-irrelevant,
or unused-in-practice by our target apps. **The honest answer is: for the
R6/CDE/Motif crowd, we'd want SHAPE first and BIG-REQUESTS second, and after
that it's diminishing returns.**

## What swift-x looks like to a 2026 modern client

Bleak. A Linux user pointing 2026 `xterm` or `xclock` at us — let alone a GTK or
Qt app — assumes a deep stack: XKB for keymaps, RENDER for antialiased glyphs
via Xft, BIG-REQUESTS for large image uploads, SYNC for `_NET_WM_SYNC_REQUEST`
resize handshakes, XFIXES for selection notifications, RANDR for monitor
geometry. Modern Xlib/xcb negotiates all of these on connect. Without XKB,
modifier handling is brittle and dead keys / compose sequences don't work.
Without RENDER, every glyph falls back to bitmap fonts the client may not even
ship anymore — modern xterm with Xft enabled simply won't draw text. Without
BIG-REQUESTS, large `PutImage` calls (screenshots, image viewers) fail
mid-stream. Without SYNC, resize tears. So: connection succeeds, basic
core-protocol apps mostly work, anything modern degrades hard. **For future
product framing, the short-list to add for "swift-x as a real server a modern
user might use" is BIG-REQUESTS, XKB, RENDER, RANDR 1.0, XFIXES — in roughly
that priority order based on what modern toolkits actually call.**

## Blog hooks

- **"The shortest extension survey in 30 years: swift-x advertises zero, and the
  R6 world barely notices."** Lead with the surprising fact that R6/CDE/Motif
  clients are extension-tolerant by design, and only SHAPE and BIG-REQUESTS show
  up as actual gaps.
- **"Why XQuartz turns off Composite, PanoramiX, RENDER, and XTEST."** Read
  Apple's defaults and decode what they learned about hosting X on a non-X
  compositor. Useful framing for our own "what to skip" list.
- **"The 1995 extension stack vs the 2026 extension stack."** Side-by-side: R6
  shipped 11 extensions, 2026 xorg ships 35-ish. Which ones got added because
  clients demanded them, which ones got added because hardware demanded them,
  and which ones are dead code nobody noticed.
