# Post 4: First NSWindow

**Date range**: May 7, 2026 **One-line elevator**: A real macOS window appears on the Mac when an X client
maps its top-level. Rootless from day one, native chrome, no XQuartz-style faux-X11 title bar. Short post.
One architectural decision, one event sequence, one moment.

## What this post covers

M2 of Product 2. The architectural decision that defines what swift-x feels like as a Mac app: every
top-level X window becomes a real NSWindow with real Mac chrome. The post-Map event sequence Xlib expects
in return. The first time a window appeared on the Mac because a Sun told it to.

## Setting

M1 shipped earlier the same day. xclock connects, stays connected, all protocol-level stubs fire correctly.
From the client's vantage everything looks normal: it thinks it's mapped a window. From mine, the Mac
screen is empty. M2 closes that gap.

## Rootless, deliberately

`DECISIONS.md` 2026-05-05: rootless window mode is the primary mode. Each top-level X window becomes a
native NSWindow with native macOS chrome. No big "X11 desktop" surface hosting borderless X windows. No
faux title bars drawn by the X server. Real `NSWindow`s with the macOS traffic-light buttons, integrated
into Spaces, addressable from Cmd-Tab, draggable to other monitors via the standard Mac mechanism.

TODD: I want the X windows to coexist with Mac apps. I don't want a different environment for X. I have
that already, ten feet away, with my Sun monitors, keyboards, and mice. When I'm on the Mac I want one
desktop, one Cmd-Tab list, one set of Mission Control spaces. xclock and Safari side by side, not xclock
in a separate "X11 world."

This is where swift-x differs from XQuartz the most visibly. XQuartz can run rootless, but its rootless
mode still draws its own X11-style title bars instead of using AppKit chrome. The result looks 1996 next
to a 2026 Safari window, and the X-titled windows don't pick up Mac shortcuts the way you'd expect. We
use real `NSWindow`s from the first byte of M2.

The escape hatch for retro authenticity is to run `mwm` on the Sun. The X server sees mwm's reparenting
and decoration windows as just more X windows and displays them correctly inside our NSWindow. Someday
we may ship a native Mac-side "mwm look" wrapper for NSWindow chrome (title bar pattern, corner grips,
the right shade of Motif grey), but that's chrome theming, not hosting a real client-side mwm. Real
client-side mwm rendered on a Mac is too clunky.

## The WindowBridge protocol

The Mac side has to mediate between "the X protocol just got a `MapWindow`" and "make an NSWindow appear
on screen." That mediation lives behind a `WindowBridge` protocol so the server core doesn't import
AppKit directly.

`CocoaWindowBridge` is the production implementation. It owns one NSWindow per top-level X window,
positioned per the client's requested geometry. `MockWindowBridge` is the test implementation. It records
every bridge call as a structured event so unit tests can assert "did we emit the right sequence" without
spinning up a Cocoa runloop. Same protocol, same `emitMapSequence` helper, two backends.

The bridge protocol surface is small: `mapTopLevel`, `unmapTopLevel`, `paintWindowRects`,
`setTopLevelWindowTitle`. The dispatcher calls those methods. Cocoa or Mock decide what they mean.

## The post-Map event sequence

When the client maps a top-level window, Xlib expects a specific sequence of events back. Wrong order
and the client doesn't always disconnect, but the drawing path goes wrong in subtle ways:

1. `ReparentNotify` — the window has been reparented. We synthesize a parent ID since there's no real
   window manager on the Mac side.
2. `ConfigureNotify` — final geometry confirmation. The NSWindow positions its content area at the
   requested coords.
3. `MapNotify` — the window is now mapped.
4. `Expose` — content needs drawing.

All four emit in that order from `emitMapSequence` in `MockWindowBridge.swift:92`, shared by both
bridges so the order stays in one place. If the top-level had already-mapped descendants (xclock's
pattern is to `CreateWindow` outer + inner, `MapSubwindows`, then `MapWindow` on outer), each descendant
with `ExposureMask` also gets an Expose. Without that, xclock's inner drawing window never gets the
signal to redraw and the clock stays blank in M3.

## Pivotal moment

The first time xclock came up on the Mac as a native NSWindow, with the macOS traffic-light buttons and
the title from `WM_NAME`, sized correctly per the client's geometry. The clock face was blank because M3
wasn't done. But the window was real. Move it. Close it. Cmd-Tab past it. The X client did the right
thing on close. The Mac responded the way it should to a Mac window.

The visible payoff is in Post 5 (pixels). The architectural payoff is here.

## What Todd should add

- The "first window appears" moment in voice. This is the visible counterpart to Post 3's "fuck, wow"
  about the protocol staying connected. M1 was invisible; M2 is the first time the project produced
  something you could point at on a screen.
- Any "Spaces / Mission Control / Cmd-Tab" memories. Mac users who came up through XQuartz will recognize
  the small daily friction of X windows being almost-integrated. Concrete examples land.

## Anchors for fact-check pass

- Files: `Sources/SwiftXServerCore/CocoaWindowBridge.swift`, `Sources/SwiftXServerCore/MockWindowBridge.swift`,
  `Tests/SwiftXServerCoreTests/WindowBridgeTests.swift`
- M2 commit: `4a0dd24` 2026-05-07 "Ship Product 2 M1-M3: xclock renders on swift-x server"
  (M1+M2+M3 all in one day)
- `emitMapSequence`: `Sources/SwiftXServerCore/MockWindowBridge.swift:92`
- Decision: rootless window mode as primary (`DECISIONS.md` 2026-05-05)
- Decision: no Motif implementation on the Mac side (`DECISIONS.md` 2026-05-05); relevant because mwm
  is preserved as the escape hatch

(`WM_NAME` → NSWindow title and the per-session log-renaming on `WM_CLASS` are mentioned in Post 8
where multi-client makes them concrete. Not duplicated here.)

## Working title alternatives

- "M2: a window on the Mac"
- "Rootless from day one"
- "First window"
