# xclock session walkthrough

Source: `captures/xclock.xtap`. xclock running on u5 (SunOS / SPARCstation 2 — the WM_CLIENT_MACHINE says "ss2"), connecting to a real Xsun on u5 itself. 71 client requests, 89.3 seconds, 4356 C2S bytes, 8596 S2C bytes.

This is the reference trace for the Product 2 proof of concept. The goal is that an xclock running on a Sun against the Swift X server produces the same visible result as this session.

## Conventions

- `→` = client to server (xclock to the X server)
- `←` = server to client
- **VISIBLE** notes describe what the user sees on screen at that point
- **INVISIBLE** notes describe protocol activity with no on-screen consequence yet
- Resource IDs in `0x44xxxxx` are xclock's (allocated from the resource-id-base 0x4400000); IDs in `0x21`, `0x28`, `0x130`, etc. are server-owned (root window, default colormap, atoms)

## Phase 1: Connection setup (0–17ms)

### t=0.0ms → SetupRequest
xclock opens TCP to `:6000` and sends "I want X11 11.0, MSB byte order, no auth."

**INVISIBLE.** The server must reply with a believable SetupAccepted: at least one screen, at least one visual xclock can use (an 8-bit PseudoColor visual), a pixmap format, a vendor string, a resource-id-base for the client, and a default colormap. xclock will pick the first depth-8 PseudoColor visual it sees. For the Swift server, hard-coding one screen with one pixmap format and one PseudoColor visual is enough.

### t=4.7ms ← SetupAccepted
Sun's reply: vendor "Sun Microsystems, Inc.", release 3600, 1280×1024, depth 8, 4 visuals. The values the Swift server needs to fabricate that xclock will use: root window ID (Sun used `0x28`), default colormap (`0x21`), resource-id-base (xclock used `0x4400000`).

### t=13ms → CreateGC `cid=0x4400000` drawable=root mask=0xc
mask=0xc is `GCForeground|GCBackground`. xclock is making a generic GC against the root window for early protocol use (likely just to have one — it's freed before the window dies, see seq=70).

**INVISIBLE.** GC creation has no display effect. Swift server: just record the GC and its attributes.

### t=13ms → GetProperty window=root prop=RESOURCE_MANAGER
xclock asks the root window for the Xrm resource database (font names, colors, X resources set by `xrdb`).

### t=17.8ms ← Reply (GetProperty)
Server returns the X resources. For the PoC, returning an empty/no-value reply is fine — xclock will fall back to its compiled-in defaults.

**INVISIBLE.** Look on the Swift server side for: did we send a syntactically valid GetProperty reply with the right sequence number?

## Phase 2: Color and atom priming (67–95ms)

### t=67ms → AllocColor cmap=0x21 rgb=(51200, 51200, 51200)
A grayish color (about 80% white). xclock uses this for the dial highlight or shadow.

### t=74.4ms ← Reply (AllocColor)
Server picks a pixel value in the colormap and returns it (plus the actual RGB it allocated, which may differ from requested). For the PoC: return any unique pixel value; cache server-side `pixel → RGB` so drawing requests using that pixel render correctly.

### t=80–94ms → InternAtom × 2
"WM_CONFIGURE_DENIED" and "WM_MOVED" — Sun-specific WM protocol atoms that xclock pre-interns. Server returns atoms `0x130` and `0x131`. The Swift server can hand out atom IDs from any monotonic source as long as identical names always map to the same ID for the lifetime of the server.

**INVISIBLE.** Look for: server returns an InternAtom reply with the right sequence number and any non-zero atom ID. Same name asked twice should return the same ID.

## Phase 3: WM icon pixmap and icon mask (109ms)

### t=109ms → CreatePixmap, CreateGC, PutImage(48×48 depth=1), FreeGC × 2
Two 48×48 1-bit pixmaps. These are the **WM icon pixmap and icon mask**, set on the top-level via WM_HINTS so the window manager can show a clock icon when xclock is iconified. Source: `reference/X11R6/xc/programs/xclock/xclock.c:143-159`, which calls `XCreateBitmapFromData` for both `clock_bits` (the icon shape) and `clock_mask_bits` (the alpha mask). The bitmap data is hard-coded in `clock.bit` and `clmask.bit`.

**INVISIBLE** for the PoC. We're rootless on macOS and the NSWindow's icon comes from the application bundle, not from WM_HINTS. The Swift server should accept the pixmaps (so xclock doesn't error), store them, and ignore them. The WM_HINTS property that references them can also be ignored for the PoC.

## Phase 4: Black, font, drawing GCs (114–147ms)

### t=114ms ← AllocColor reply (the (51200, 51200, 51200) color)
### t=121ms → AllocColor cmap=0x21 rgb=(0,0,0)
### t=121ms → OpenFont fid=0x4400005 name="-dt-interface user-medium-r-normal-s..."
xclock asks for a CDE font. The font is used for nothing visible in xclock — there are no labels on the analog dial. xclock will QueryFont to get metrics, then never actually draws text. For the PoC, return *any* QueryFont reply with non-zero ascent/descent and a `min_bounds`/`max_bounds` that matches `font_ascent + font_descent` for the height. xclock won't crash even if metrics are absurd, because it doesn't render text.

### t=126.4ms ← Reply (QueryFont) ascent/descent=11/2 chars=224 properties=21
Big reply (3944 bytes in the original). For the PoC: return a minimal valid QueryFont reply. Don't bother with real font properties. Stub it.

**INVISIBLE.** xclock holds the font ID and might query it again later (it doesn't, in this trace, but could in another).

### t=147ms → CreateGC × 4 (cid=0x4400006, 0x4400007, 0x4400008, 0x4400009)
Four drawing GCs with different masks. `0x4400006` mask=0x400c is foreground+background+font (the GC that "knows about" the font we just opened, even though we won't draw text). The other three have mask=0x4 = GCForeground only. These are the four colors xclock will draw with: tick marks, hour-hand outline, minute-hand outline, fill colors.

**INVISIBLE.** GC creation has no display effect.

## Phase 5: Window creation and mapping (147ms)

### t=147ms → CreateWindow wid=0x440000A parent=root 164×164 at (0,0) class=inputOutput mask=0x281a
The xclock outer window. mask=0x281a = `CWBackPixel | CWBorderPixel | CWBitGravity | CWEventMask | CWColormap` (bits 1,3,4,11,13 per `reference/xproto/include/X11/X.h`). xclock specifies its background and border pixels, a bit-gravity hint, an event mask, and the colormap to use. The window is 164×164 — xclock's default size.

**INVISIBLE.** CreateWindow alone does not show the window. The window exists in the server's tree but is unmapped.

### t=147ms → ChangeProperty × 7 (WM_NAME, WM_ICON_NAME, WM_COMMAND, WM_CLIENT_MACHINE, WM_NORMAL_HINTS, WM_HINTS, WM_CLASS)
WM hints. The window manager will read these when the window maps and use them for window chrome (title, decorations, sizing constraints).

**INVISIBLE** to xclock; **INVISIBLE** to user until the WM uses them. For the PoC, the Swift server should accept these and store them as window properties. Whether anything reads them later is a separate question (in rootless mode, the macOS NSWindow chrome is set from WM_NAME).

### t=147ms → CreateWindow wid=0x440000B parent=0x440000A 164×164 at (0,0)
The clock face child window, same size as parent. mask=0x280a = `CWBackPixel | CWBorderPixel | CWEventMask | CWColormap` (no bit-gravity this time). xclock's analog dial will be drawn into this child.

### t=147ms → MapSubwindows window=0x440000A
"Map all my children." This will produce a MapNotify for the child window once the parent is mapped.

### t=147ms → MapWindow window=0x440000A
"Show the parent window." This is what triggers the WM to reparent the window into a frame and show it.

### t=147ms → InternAtom "WM_DELETE_WINDOW"

## Phase 6: WM reparenting and the first Expose (152–162ms)

### t=152ms ← MapNotify window=0x440000B
Server confirms: child window is now mapped (it became viewable when parent mapped).

### t=156.8ms ← ConfigureNotify window=0x440000A 164×164 at (0,0)
Server tells xclock: "your outer window is at (0,0) size 164×164." This is the position before the WM has moved it.

### t=157.7ms ← ReparentNotify window=0x440000A parent=0x38000E8 at (0,0)
The WM (dtwm/CDE on the Sun) has reparented xclock's outer window into a frame window the WM owns (`0x38000E8`). xclock now lives inside the WM's decoration frame.

**For the Swift server in rootless mode**, the macOS NSWindow IS the frame. There's no "WM" inside the X server — Cocoa is the WM. So this step doesn't happen for us; instead, the Swift server creates an NSWindow when the X window is mapped and the X window's content becomes the NSView's drawable. ReparentNotify probably should still be sent to xclock so it knows it's been reparented (for behavioral consistency), but the parent ID will be a synthesized server-side window ID.

### t=157.7ms ← [SendEvent] ConfigureNotify window=0x440000A 164×164 at (175,175)
A *synthetic* ConfigureNotify (note `[SendEvent]`) sent by the WM telling xclock "you are now at root coordinates (175,175)." This is dtwm's "I'm a window manager and I'm telling you where I put you."

**For the Swift server**: synthesize a ConfigureNotify after the NSWindow is on screen, with the X coordinates that correspond to the NSWindow's position.

### t=162.4ms ← MapNotify window=0x440000A
The outer window is now visible.

### t=162.4ms ← Expose window=0x440000B (0,0) 164×164 count=0
"Please draw the contents of your child window. The whole 164×164 region needs painting." This is the trigger xclock has been waiting for. From this point xclock will start sending drawing requests.

**VISIBLE** at this point on a working server: an empty 164×164 window with the macOS chrome. Inside the window: blank (whatever the BackPixel is — probably the colormap's pixel 0 or 1, often shows up as gray or white).

## Phase 7: Initial draw (239ms)

xclock is now responding to the Expose. The drawing burst here paints the dial.

### t=239.3ms → ChangeProperty window=0x440000A prop=WM_PROTOCOLS type=ATOM data=4b
Tells the WM "I support the WM_DELETE_WINDOW protocol." The 4-byte data is the atom ID `0x90` (WM_DELETE_WINDOW).

### t=239.3ms → ChangeWindowAttributes window=0x440000B mask=0x800
mask=0x800 = `CWEventMask` (bit 11, per `reference/xproto/include/X11/X.h`). xclock is updating the event mask on the inner clock-face child — almost certainly to subscribe to ExposureMask and StructureNotifyMask now that the window is mapped, so it'll get redraw triggers when the window manager resizes the parent.

For the PoC: store the new event mask on the window. When we send Expose / ConfigureNotify later, only deliver them to windows whose event mask includes the corresponding bit.

### t=239.3ms → PolySegment drawable=0x440000B gc=0x4400006 segments=60
**The 60 minute ticks around the dial.** Each segment is a short line. Drawn with the foreground GC (probably black). After this request, you should see 60 little tick marks around the perimeter of the clock face on screen.

**VISIBLE.** This is the first thing the user sees inside the window.

### t=239.3ms → FillPoly drawable=0x440000B gc=0x4400009 points=6 shape=convex
**Minute hand body.** A 6-point convex polygon. Color is whatever GC `0x4400009` was created with — one of the dial colors.

### t=239.3ms → PolyLine drawable=0x440000B gc=0x4400008 points=6
**Minute hand outline.** Same shape, drawn as an outline with a different GC.

### t=239.3ms → FillPoly drawable=0x440000B gc=0x4400009 points=6 shape=convex
**Hour hand body.**

### t=239.3ms → PolyLine drawable=0x440000B gc=0x4400008 points=6
**Hour hand outline.**

**VISIBLE.** The full clock is now drawn: 60 ticks, hour hand, minute hand. No second hand (xclock by default has no second hand; you'd see it if `-update 1` were passed).

## Phase 8: Idle period with mouse motion (239ms – 45.5s)

For 45 seconds, nothing happens visually. The user is moving the mouse around but not interacting with xclock. The server sends EnterNotify/LeaveNotify events to xclock as the mouse pointer crosses the window boundary. xclock ignores them (it didn't ask for ButtonPress in a way that needs them).

**For the Swift server**: track mouse pointer position globally and send EnterNotify/LeaveNotify when it crosses an X window boundary. For the PoC, you can skip this entirely — xclock doesn't care, and there's no visible consequence.

## Phase 9: First user resize (45.5s)

### t=45505ms ← ConfigureNotify window=0x440000A 361×405 at (0,0)
The user dragged the corner of the window. The WM tells xclock "your outer window is now 361×405." Note: the dimensions changed, the position is still (0,0) relative to the WM frame. The aspect ratio became 361×405 — an awkward shape because the user dragged it, and dtwm doesn't enforce square.

### t=45522ms → ConfigureWindow window=0x440000B mask=0xc
xclock is propagating the resize down: it's resizing its child window to match. mask=0xc is `Width|Height` — it's setting new W/H on the child.

### t=45526ms ← Expose window=0x440000B (0,0) 361×405 count=0
"Please redraw the whole 361×405 region of the child."

### t=45539ms → PolyLine × 2, FillPoly × 2 (seq=42-45)
**These erase the old hour and minute hand positions.** Note these are PolyLine and FillPoly using GC `0x4400007` (a different GC) — that GC's foreground is the background color of the window. Drawing with the background color = erasing.

### t=45539ms → PolySegment seq=46 (the ticks again, now scaled to the new window size)
**Redraws the 60 ticks.**

### t=45539ms → FillPoly + PolyLine + FillPoly + PolyLine seq=47-50
**Redraws the minute and hour hands at the new size.**

**VISIBLE.** The clock is now drawn at 361×405. The dial is stretched — the ticks are now arranged on an ellipse-shaped boundary because xclock didn't get a square aspect ratio.

> ### Note for the PoC
> 
> Today's replay artifact lives here. xclock's drawing math is based on the window dimensions reported via ConfigureNotify. In a replayed session, the WM doesn't resize, but xclock had already calculated coordinates for 361×405. So in replay, drawings for "stretched 361×405 dimensions" land in a 164×164 window. For the PoC against a *live* xclock on a Sun, this isn't a concern — the live xclock will react to whatever ConfigureNotify the Swift server sends.

## Phase 10: WM-driven moves (47–55s)

Several `[SendEvent] ConfigureNotify` events arrive: at (87,92), then (75,195). These are the WM telling xclock its window has been moved. xclock doesn't redraw because position changes don't dirty the contents.

**INVISIBLE** to the dial; **VISIBLE** as window position on screen.

## Phase 11: Minute tick redraw (60.3s)

### t=60253ms → PolyLine × 2, FillPoly × 3, PolyLine × 2 (seq=51-58)
**xclock's internal one-minute timer fired.** No preceding Expose — xclock decided on its own to redraw because the minute hand position needs updating.

This is the *only* drawing burst in the whole session that's not in response to an Expose. This matters for the PoC: xclock will keep redrawing every minute on its own, regardless of server events. The Swift server doesn't need to do anything special — just process the drawing requests and update the NSView.

**VISIBLE.** The minute hand snaps to the new position.

## Phase 12: Second user resize (61.6s)

### t=61614ms ← ConfigureNotify window=0x440000A 276×173 at (0,0)
User resized again, now to 276×173.

### t=61620ms → ConfigureWindow window=0x440000B mask=0xc
xclock resizes its child.

### t=61625ms ← Expose window=0x440000B (0,0) 276×173 count=0

### t=61633ms → PolyLine × 2, FillPoly × 2, PolySegment, FillPoly, PolyLine, FillPoly, PolyLine (seq=60-68)
Same pattern: erase old, redraw ticks, redraw hands at new size.

**VISIBLE.** Clock at the new dimensions.

## Phase 13: Quiet with mouse activity (62–89s)

Just EnterNotify/LeaveNotify events. No drawing.

## Phase 14: Close (89.3s)

### t=89290ms ← [SendEvent] ClientMessage window=0x440000A type=WM_PROTOCOLS format=32
The user clicked the WM's close button (or pressed Cmd-Q, or similar). The WM sent a synthetic ClientMessage with `WM_DELETE_WINDOW` (the data is the atom ID we cached as `0x90` earlier). xclock had previously declared via WM_PROTOCOLS that it supports this; it's the WM's polite way of saying "please close yourself."

### t=89297ms → InternAtom "WM_PROTOCOLS"
xclock re-interns WM_PROTOCOLS (probably to confirm what the message type means; it had this earlier as `0x91`).

### t=89301ms ← Reply (InternAtom) atom=0x91
Same atom ID as before.

### t=89309ms → FreeGC gc=0x4400000
xclock cleans up its initial GC.

### t=89309ms → GetInputFocus
A "barrier" request — xclock waits for the reply before doing anything destructive, which guarantees all prior requests have been fully processed by the server. Standard Xlib pattern before disconnect.

### t=89313ms ← Reply (GetInputFocus)

After this, xclock closes the TCP connection. The server (default close-down mode = DestroyAll) destroys all of xclock's resources: the two windows, the four drawing GCs, the two stipple pixmaps, the two stipple GCs (already freed), the font, the two allocated colors. The two atoms and the WM_DELETE_WINDOW protocol property remain (atoms persist for the server's lifetime; properties are owned by the destroyed windows so they go away with them).

## What the Swift server needs to handle for this proof of concept

Listed in roughly increasing order of "actually has visible consequences":

1. **Connection setup**: SetupRequest in, SetupAccepted out. Hard-code a screen, one PseudoColor depth-8 visual, one pixmap format. (M1)
2. **Resource ID allocation**: hand out a resource-id-base. Track which IDs the client is using.
3. **GetProperty**: return empty for unknown properties. xclock asks for RESOURCE_MANAGER and gets nothing useful even on real Xsun. (M1)
4. **AllocColor**: return a pixel value. Cache it for later drawing. (M1, but only "visible" once we render in M3)
5. **InternAtom**: return monotonic atom IDs. Same name → same ID. (M1)
6. **OpenFont + QueryFont**: stub. xclock doesn't draw text. (M1)
7. **CreateGC, ChangeGC, FreeGC**: track GC state per ID. (M1)
8. **CreatePixmap + PutImage**: track pixmap state per ID. xclock's stipples are never drawn from. (M1)
9. **CreateWindow**: build internal window state. For the outer window (parent=root), create an NSWindow on the Mac. (M2)
10. **ChangeProperty**: store properties on the window. WM_NAME should set the NSWindow title. (M2)
11. **MapSubwindows + MapWindow**: make the NSWindow visible. Send back MapNotify, ConfigureNotify, ReparentNotify (synthesized, with NSWindow's frame as parent), and Expose. (M2)
12. **PolySegment, PolyLine, FillPoly**: render to the NSView's drawable via Core Graphics. (M3 — this is the headline.)
13. **ChangeWindowAttributes**: store. The BackingStore attribute can be ignored.
14. **ConfigureWindow**: resize the NSView/NSWindow. Server should follow up with Expose to the appropriate region. (M3 to handle live resize from the user; not needed if xclock doesn't resize.)
15. **WM_DELETE_WINDOW protocol**: when the NSWindow gets a close request from macOS, send the synthetic ClientMessage to xclock so it disconnects cleanly. (M3 polish)

What can be skipped entirely:
- EnterNotify/LeaveNotify (xclock ignores them)
- Real font handling (xclock doesn't draw text)
- Real colormap allocation (synthetic pixels are fine)
- Stipple rendering (xclock's stipples are unused)
- BackingStore (modern servers ignore it)
- All the Selection / cursor / keymap / extension queries (xclock doesn't make them)
