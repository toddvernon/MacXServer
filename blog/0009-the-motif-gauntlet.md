# Post 9: The Motif gauntlet

**Date range**: May 9, 2026
**One-line elevator**: Athena was easy. Motif is harder. quickplot from a real SS2 brought every Motif-specific corner-case the simpler apps didn't exercise: implicit pointer grabs, override-redirect popup windows, GrabPointer, ChangeActivePointerGrab, the _MOTIF_DRAG_WINDOW init crash, the keymap that has to handle Sun L-keys for VirtualBindings, and a dead end on widget click dispatch that I parked at end of day.

## What this post covers

The first sustained encounter with Motif from a real Sun workstation. quickplot init unblocked through a sweep of opcode and event fixes. xfontsel menus working via cross-NSWindow drag tracking. The dead-end on quickplot widget callbacks. The investigation handoff doc.

## Setting

xterm works. xcalc works (Athena). xclock and xeyes work. The first real Motif client to throw at the server is quickplot, a custom Motif app on the SS2. (My own custom Motif app from years ago.)

## Thread anchor: protocol vs implementation

Motif is the test of "did we get the protocol right" at its hardest. Sun-era libXm makes a lot of assumptions about server behavior that are perfectly valid protocol-wise but rarely tickled by simpler clients. ChangeActivePointerGrab. Override-redirect popup windows. The _MOTIF_DRAG_WINDOW property pre-set. Every gap we find here is a gap in our protocol-contract coverage, not a Motif bug. The protocol surface is fixed; we're discovering its corners.

quickplot is the right test case because:
- It's running on SS2 (SunOS 4.1.4, OpenWindow libXm, ~1995). Older Motif is more strict than later versions.
- I wrote it, so I know what's supposed to happen.
- It exercises buttons, menus, mouse interaction, text rendering, plot rendering. Motif's full widget set.

## quickplot init through to clicks

Commit `8a5b3d9` 2026-05-09: "Motif/quickplot init unblocked: GrabPointer + QueryBestSize + sequence-order fix + idempotent MapWindow." Then `8640402`: "Implicit pointer grab + override_redirect + SetInputFocus + real event time/state. quickplot init through to working clicks."

The opcode list that landed:
- `GrabPointer` (active grab, returns pixel mask)
- `QueryBestSize` (cursor / pixmap dimensions client-driven)
- `SetInputFocus`
- `XDefineCursor` + NSCursor substitution (I-beam over xterm text area, commit `c6ea015`)
- `ChangeActivePointerGrab` (commit `8a5b3d9`)
- Override-redirect popup window handling (NSPanel at popup-menu level for menus and tooltips)
- Passive button grab activation (matching ButtonPress installs an active pointer grab on the grab window)
- Implicit pointer grab no crossing emit → emits with mode=Grab
- mode=Grab/Ungrab on Enter/Leave + Focus
- Real event time/state on ButtonPress (was previously time=0, state=0)
- Sequence-order fix (replies were arriving before the events that should have preceded them)
- Idempotent MapWindow (xclock was fine but Motif sometimes maps twice)

## The _MOTIF_DRAG_WINDOW crash

Commit `6f9a8ac` 2026-05-09: "Pre-set _MOTIF_DRAG_WINDOW on root to dodge SS2 Motif crash." SS2-era libXm reads `_MOTIF_DRAG_WINDOW` on the root window during `XmDisplay` init. If we return None, Motif tries to BECOME the drag coordinator itself, and the older code path SIGSEGVs.

On a real Sun X server, some other Motif app would have already created a drag-coordinator window and set this property. Subsequent apps just read it. We pre-set the root window itself as the coordinator (pretend it's already there). Motif reads it, doesn't try to become coordinator, doesn't crash.

This is the first "real bandaid" entry in `SHORTCUTS.md` for this round. Working around a Motif client-side bug by lying about server state.

## Keymap expansion

Commits `cbf2f52` and `41973bd` 2026-05-09: keypad function-key keysyms + F13–F35 + Insert/Select/Help/Menu + Sun L-keys for Motif VirtualBindings.

Motif's translation manager parses translation strings like `<Btn1Down>: ManagerGadgetArm()` at startup. If any keysym referenced in a translation table is missing from the server's keymap, Motif logs `Cannot convert string <Key>... to type VirtualBinding` to stderr and silently drops the translation. Without those translations, Motif menus don't post, buttons don't arm.

Sun-era apps assume the full Sun keyboard layout, including the L-keys (L1-L10 on the left side of a Sun keyboard for cut/copy/paste/undo). The keysym mapping had to include them even though no modern keyboard has those keys.

## Cross-NSWindow drag tracking

Athena and Motif menus rely on the X server delivering drag events to the popup-menu window even when the user pressed the button on the menu title (in a different NSWindow). AppKit's `mouseDragged` is sticky to the origin view, so the popup never sees pointer motion natively.

XQuartz solves this with kernel-private `xp_*` APIs that AppKit apps don't have. Commit `29bc237` 2026-05-10: when an X-protocol pointer grab is active, `CocoaWindowBridge` installs a local `NSEvent.addLocalMonitorForEvents` for `[.mouseDragged, .leftMouseUp]`. The monitor looks up which managed NSWindow contains the global pointer position (popup-level NSPanels first per z-order), translates to that window's logical X coords, and routes via the bridge.

This is the public-API approximation of the kernel-private XQuartz approach. Validated against xfontsel (Athena MenuButton + SimpleMenu) drag-and-select on a real SS2 over the LAN.

## ConvertSelection routing

Commit `b9f2b25` 2026-05-09: "ConvertSelection: route to owner or reply None. unblocks dtcalc init." Two paths:
- If selection has an owner, forward as SelectionRequest event to the owner (standard ICCCM)
- If no owner, reply directly with SelectionNotify(property=None) per spec. otherwise the client hangs forever

dtcalc tripped this at request 85 (its init-time `Customize Data:0` probe). Before the fix, we silent-dropped opcode 24 and dtcalc hung waiting for a reply that never came.

This fix unblocked dtcalc enough to reach further into init. It didn't fix the deeper bug that wedged dt-apps (that came the next day, see Post 10).

## Capture proxy improvements

Commit `5dc809f` 2026-05-09: "Capture proxy: buffer in memory, single disk write at finalize." During the Motif debugging arc the proxy was suspect. recorder I/O might have been corrupting captures. Switching to in-memory buffering with a single disk write at session-end removed it as a confounder.

## Single protocol thread

Commit `29bc237` 2026-05-10: "Single-thread protocol model + Xt menu support." Replaced the prior two-thread (read + write) model with one GCD serial queue per session that owns all session state, the client socket, and event synthesis. AppKit bridge callbacks now hop onto this queue instead of touching session state on the main thread.

Reason: Xlib "sequence lost" warnings from quickplot proved real wire-order corruption from the writeLock race. Cross-thread reads of sequenceNumber, pointerGrab, focusWindow, etc. were structurally racy regardless. One thread per session eliminates both classes of bug.

Mirrors X.org's `Dispatch()` loop and XQuartz's pthread-based server thread.

## The dead end

By end of day 2026-05-09 (and into 2026-05-10), quickplot was reaching the click-dispatch path but Motif wasn't firing widget callbacks. The X protocol path was verified clean (xev showed correct ButtonPress wire bytes; same bytes Motif sees). The failure was somewhere inside Motif's translation manager.

Every observable opcode-level bug got fixed in this sweep. Motif was just silently choosing not to dispatch widget actions on Btn1Down/Btn1Up. No stderr signal. Couldn't make progress without symbol-rich Motif debugging.

I wrote `INVESTIGATION_MOTIF_INPUT.md` as a handoff document for the next session and parked it.

That handoff turned out to be wrong about something. (See Post 10.)

## What Todd should add

- The "this is harder than xterm" moment.
- The keymap expansion as an example of how Sun-era apps demand things modern keyboards don't have. The L-keys backstory if you have one.
- The cross-NSWindow drag-tracking workaround as a concrete example of XQuartz using private kernel APIs we don't have. The "doable with public APIs" framing.
- The dead-end parking decision. Why park rather than push further? The "no signal to follow" framing.
- The capture proxy as a debugging tool getting suspect mid-session. Removing it as a confounder.

## Anchors for fact-check pass

- Files: `INVESTIGATION_MOTIF_INPUT.md` (the handoff doc), `Sources/SwiftXServerCore/CocoaWindowBridge.swift` (cross-NSWindow drag tracking), `Sources/SwiftXServerCore/USKeymap.swift` (keymap expansion), `Sources/SwiftXServerCore/ServerSession.swift` (_MOTIF_DRAG_WINDOW pre-set in init)
- Commits in order: `b9f2b25` ConvertSelection, `8a5b3d9` quickplot init, `8640402` implicit grab + override-redirect, `c6ea015` XDefineCursor, `bee1010` EnterNotify/LeaveNotify + PolyRectangle, `cbf2f52` keypad keysyms, `41973bd` F13-F35 + L-keys, `6f9a8ac` _MOTIF_DRAG_WINDOW pre-set, `5dc809f` capture buffer change, `496209a` investigation handoff doc, `29bc237` single-thread + Xt menu support
- Reference: `reference/X11R6/xc/lib/Xt/Selection.c` (Xt selection implementation, important for the next post)

## Working title alternatives

- "Motif is its own kind of difficult"
- "Day four: the Motif sweep"
- "Every bug except the one that mattered"
