# Post 9: The Motif gauntlet

**Date range**: May 9, 2026 **One-line elevator**: Athena was easy. Motif is harder. quickplot from a real SS2
brought every Motif-specific corner-case the simpler apps didn't exercise: implicit pointer grabs,
override-redirect popup windows, GrabPointer, ChangeActivePointerGrab, the _MOTIF_DRAG_WINDOW init crash, the
keymap that has to handle Sun L-keys for VirtualBindings, and a dead end on widget click dispatch that I
parked at end of day.

## What this post covers

The first sustained encounter with Motif from a real Sun workstation. quickplot init unblocked through a sweep
of opcode and event fixes. xfontsel menus working via cross-NSWindow drag tracking. The dead-end on quickplot
widget callbacks. The investigation handoff doc.

## Setting

xterm works. xcalc works (Athena). xclock and xeyes work. The first real Motif client to throw at the server
is quickplot, a custom Motif app on the SS2. (My own custom Motif app from years ago.)

## Thread anchor: protocol vs implementation

Motif is the test of "did we get the protocol right" at its hardest. Sun-era libXm makes a lot of assumptions
about server behavior that are perfectly valid protocol-wise but rarely tickled by simpler clients.
ChangeActivePointerGrab. Override-redirect popup windows. The _MOTIF_DRAG_WINDOW property pre-set. Every gap
we find here is a gap in our protocol-contract coverage, not a Motif bug. The protocol surface is fixed; we're
discovering its corners.

TODD: [CLAUDE: worth mentioning that we had source available to everything except Motif.  So what started
as we can figure it out based on traces, when we get stuck try to goto the source, turned into just the 
traces, and that is not easy becuase you are basically guessing at that point]

quickplot is the right test case because:
- It's running on SS2 (SunOS 4.1.4, OpenWindow libXm, ~1995). Older Motif is more strict than later versions.
- I wrote it, so I know what's supposed to happen.

TODD: and i do have the source to the app, not Xm but at least the app

- It exercises buttons, menus, mouse interaction, text rendering, plot rendering. Motif's full widget set.

TODD: and a lot of intristic mouse and server grabs emitted from motif but also in app grabs that enable
rubber banding areas of graphics, and cross hairs to determin values.  A lot of forced focus changes between
the grphics window with xlib non-widget images and motif text entry fields.

## quickplot init through to clicks

Commit `8a5b3d9` 2026-05-09: "Motif/quickplot init unblocked: GrabPointer + QueryBestSize + sequence-order fix
+ idempotent MapWindow." Then `8640402`: "Implicit pointer grab + override_redirect + SetInputFocus + real
event time/state. quickplot init through to working clicks."

The opcode list that landed:
- `GrabPointer` (active grab, returns pixel mask)
- `QueryBestSize` (cursor / pixmap dimensions client-driven)
- `SetInputFocus`
- `XDefineCursor` + NSCursor substitution (I-beam over xterm text area, commit `c6ea015`)
- `ChangeActivePointerGrab` (commit `8a5b3d9`)
- Override-redirect popup window handling (NSPanel at popup-menu level for menus and tooltips)

TODD: we largely unlocked this with xfontsel

- Passive button grab activation (matching ButtonPress installs an active pointer grab on the grab window)
- Implicit pointer grab no crossing emit → emits with mode=Grab
- mode=Grab/Ungrab on Enter/Leave + Focus
- Real event time/state on ButtonPress (was previously time=0, state=0)

TODD: i think this was the unlock on both dt apps, sfontsel menus, and ultimately motif input stall

- Sequence-order fix: `CocoaWindowBridge.mapTopLevel` was emitting the ReparentNotify / ConfigureNotify /
  MapNotify / Expose sequence from inside its main-async block. Inline replies on the read thread raced
  ahead, and Xlib saw the wire go backwards: `sequence lost (0xXXXXX > 0xYYY) in reply type 0x15`. Hoist
  `emitMapSequence` out of the async block so it fires synchronously on the read thread. The actual
  NSWindow creation still happens on main, but the outbound bytes now match the sequence-number order the
  read thread allocated.
- Idempotent MapWindow: real and verified, not speculation. Per X11 spec section 10.5, MapWindow on an
  already-mapped window has no effect. quickplot issues MapWindow twice for each top-level during init
  (a Motif/Xt pattern, probably realize-then-shell-map). We were processing both, creating a second
  NSWindow per X window and producing duplicate-window-on-screen artifacts. Fix is one line: early return
  in MapWindow when `windows.get(id)?.mapped` is already true. (Commit `8a5b3d9` message confirms exactly
  this; xclock didn't trigger it because xclock maps once.)
- GrabPointer / GrabKeyboard always reply `GrabSuccess` (single-client per session means there's nothing
  to compete for the grab). While a pointer grab is active and `ownerEvents=false`, redirect Button /
  Motion events to the grab window, filtered by `grab.eventMask`. `ownerEvents=true` keeps natural routing.
  Rootless caveat: macOS owns the pointer outside the NSWindow, so X grabs that span the root can't see
  clicks on other apps. Sufficient for Motif menus posted as children of the parent NSWindow.
- QueryBestSize: was previously logging "reply not implemented yet" without actually replying, so the
  client hung at request 81 of init. Reply 16×16 for cursor class (canonical X cursor size; doesn't matter
  much because we substitute NSCursor), echo dimensions back for Tile / Stipple.

## The _MOTIF_DRAG_WINDOW crash

Commit `6f9a8ac` 2026-05-09: "Pre-set _MOTIF_DRAG_WINDOW on root to dodge SS2 Motif crash." SS2-era libXm
reads `_MOTIF_DRAG_WINDOW` on the root window during `XmDisplay` init. If we return None, Motif tries to
BECOME the drag coordinator itself, and the older code path SIGSEGVs.

On a real Sun X server, some other Motif app would have already created a drag-coordinator window and set this
property. Subsequent apps just read it. We pre-set the root window itself as the coordinator (pretend it's
already there). Motif reads it, doesn't try to become coordinator, doesn't crash.

This is the first "real bandaid" entry in `SHORTCUTS.md` for this round. Working around a Motif client-side
bug by lying about server state.

TODD: forshadown SHORTCUTS getting a little out of control, where we are now

## Keymap expansion

Commits `cbf2f52` and `41973bd` 2026-05-09: keypad function-key keysyms + F13–F35 + Insert/Select/Help/Menu +
Sun L-keys for Motif VirtualBindings.

Motif's translation manager parses translation strings like `<Btn1Down>: ManagerGadgetArm()` at startup. As
part of that init, libXm registers a long table of "virtual bindings": named actions like `osfClear`,
`osfUndo`, `osfPaste` that map to keysyms. For every keysym in the table, libXm calls `XKeysymToKeycode` to
find a real keycode on the server's keymap. If any lookup fails, the binding-registration loop aborts,
`XmDisplay` can't initialize, and the application SIGSEGVs on the next access.

The mechanism is unforgiving and doesn't degrade gracefully. One missing keysym anywhere in the table and
the whole Motif app is dead before its first widget realizes.

### What L-keys are and why they bit us

Sun's Type 4 and Type 5 keyboards (the ones on every SPARCstation from the late 1980s through the late
1990s) had a dedicated column of ten keys on the left side, labeled L1 through L10. They were Stop, Again,
Props, Undo, Front, Copy, Open, Paste, Find, and Cut. Workstation-class keyboards from the era often had
these dedicated keys; they pre-date Mac and PC keyboards adopting standard Cmd/Ctrl shortcuts. Motif on Sun
binds them as the canonical undo/copy/paste/etc. actions via the OSF virtual binding scheme. They're
defined in `/usr/openwin/include/X11/Sunkeysym.h` on a Sun, outside the standard X `keysymdef.h`. So they're
not just "missing from modern keyboards." They're Sun-specific keysyms not in the cross-vendor keysym set.

Then there are F13 through F35. Standard PC and Mac keyboards have F1–F12. Sun-era Motif assumes up to F35.
Insert/Select/Help/Menu are also missing from a Mac keyboard. ISO_Left_Tab (Shift-Tab) is referenced too.

The fix: add every missing keysym at synthetic Mac keycodes 0x80 and above (X keycodes 0x88+). No Mac
keyboard can physically produce these keycodes, but Motif's keysym table only needs the LOOKUP to succeed.
It doesn't actually need the user to be able to press them. Once each keysym exists somewhere in the
keymap, `XKeysymToKeycode` returns a valid keycode, `XmDisplay` init completes, and the app is alive.

A side fix: the wire encoder for `GetKeyboardMapping` had a `> 127` clamp that would have hidden these
synthetic keycodes from the client. Lifted that so the client sees them too.

This is the kind of bug where the symptom (SIGSEGV deep inside libXm with no useful stderr output) gives
you almost no information about the cause (one missing keysym in a registration loop you have no source
for). Working it out required reading the X11R6 Xt source (we have that) and comparing the SS2 gold trace
to the swiftx trace to see which keysyms got requested. Then a bulk add covered everything.

## Cross-NSWindow drag tracking

Athena and Motif menus rely on the X server delivering drag events to the popup-menu window even when the user
pressed the button on the menu title (in a different NSWindow). AppKit's `mouseDragged` is sticky to the
origin view, so the popup never sees pointer motion natively.

XQuartz solves this with kernel-private `xp_*` APIs that AppKit apps don't have. Commit `29bc237` 2026-05-10:
when an X-protocol pointer grab is active, `CocoaWindowBridge` installs a local
`NSEvent.addLocalMonitorForEvents` for `[.mouseDragged, .leftMouseUp]`. The monitor looks up which managed
NSWindow contains the global pointer position (popup-level NSPanels first per z-order), translates to that
window's logical X coords, and routes via the bridge.

This is the public-API approximation of the kernel-private XQuartz approach. Validated against xfontsel
(Athena MenuButton + SimpleMenu) drag-and-select on a real SS2 over the LAN.

TODD: good tecnical part and good to reference XQuartz and the kernal hack

## ConvertSelection routing

Commit `b9f2b25` 2026-05-09: "ConvertSelection: route to owner or reply None. unblocks dtcalc init." Two
paths:
- If selection has an owner, forward as SelectionRequest event to the owner (standard ICCCM)
- If no owner, reply directly with SelectionNotify(property=None) per spec. otherwise the client hangs forever

dtcalc tripped this at request 85 (its init-time `Customize Data:0` probe). Before the fix, we silent-dropped
opcode 24 and dtcalc hung waiting for a reply that never came.

This fix unblocked dtcalc enough to reach further into init. It didn't fix the deeper bug that wedged dt-apps
(that came the next day, see Post 10).

## Capture proxy improvements

Commit `5dc809f` 2026-05-09: "Capture proxy: buffer in memory, single disk write at finalize." During the
Motif debugging arc the proxy was suspect. recorder I/O might have been corrupting captures. Switching to
in-memory buffering with a single disk write at session-end removed it as a confounder.


## Single protocol thread

TODD: I was admiment we not use a lot of sync features in swift.  Claude was trained on a lot of concurent code
bases and always goes heavy into concurancy.  Consurancy isn't bad but its important to understand we are 
reinterpreting a server that did not have any concurrancy.  there are likely bugs in the orginal code that would
surface if it was in the system. in my mind to get this correct with a of concurrancy, we would a lot of locks
and frankly a better understanding of the orginal code then we or the auther might have.  my desicions was lock down rendering
and io so they behave as much like the OG server did. In the end we are running out server on a bot literally 100 time
faster than the orginal xserver so keep it simple and we will be rewarded.


Commit `29bc237` 2026-05-10: "Single-thread protocol model + Xt menu support." Replaced the prior two-thread
(read + write) model with one GCD serial queue per session that owns all session state, the client socket, and
event synthesis. AppKit bridge callbacks now hop onto this queue instead of touching session state on the main
thread.

Reason: Xlib "sequence lost" warnings from quickplot proved real wire-order corruption from the writeLock
race. Cross-thread reads of sequenceNumber, pointerGrab, focusWindow, etc. were structurally racy regardless.
One thread per session eliminates both classes of bug.

Mirrors X.org's `Dispatch()` loop and XQuartz's pthread-based server thread.




## The dead end

By end of day 2026-05-09 (and into 2026-05-10), quickplot was reaching the click-dispatch path but Motif
wasn't firing widget callbacks. The X protocol path was verified clean (xev showed correct ButtonPress wire
bytes; same bytes Motif sees). The failure was somewhere inside Motif's translation manager.

Every observable opcode-level bug got fixed in this sweep. Motif was just silently choosing not to dispatch
widget actions on Btn1Down/Btn1Up. No stderr signal. Couldn't make progress without symbol-rich Motif
debugging.

I wrote `INVESTIGATION_MOTIF_INPUT.md` as a handoff document for the next session and parked it.

That handoff turned out to be wrong about something. (See Post 10.)

## What Todd should add

- The "this is harder than xterm" moment.

TODD: much harder because we had no reference motif source to look at.  We had xt which a lot of motif
inherits from but that onluy goes so far.

- The keymap expansion as an example of how Sun-era apps demand things modern keyboards don't have. The L-keys
  backstory if you have one.

TODD: [CLAUDE: i still don't really understand what we did here]

[CLAUDE: rewrote the "Keymap expansion" section above with the actual mechanism. Short version: Motif at
init scans a table of named actions like osfPaste/osfUndo and calls XKeysymToKeycode on each keysym it
mentions. If ANY lookup fails (and many do, because Sun's L1-L10 keys, F13-F35, Insert/Select/Help/Menu
aren't on a Mac keyboard), the whole Motif init aborts and the app SIGSEGVs. We added the missing keysyms
at synthetic mac keycodes 0x80+ so the lookups succeed. The user can never press these keys (they don't
exist on a Mac keyboard) but Motif doesn't care — it just needs the keysyms to be defined SOMEWHERE in the
keymap so the registration loop doesn't fail. If you have memories of the Sun Type 4/5 keyboard with the
L1–L10 column on the left side (Stop, Again, Props, Undo, Front, Copy, Open, Paste, Find, Cut), this is a
good place to tell that story in voice.]


- The cross-NSWindow drag-tracking workaround as a concrete example of XQuartz using private kernel APIs we
  don't have. The "doable with public APIs" framing.

TODD: using the solaris 2.6 CDE window manager and xfontsel, it seemed to me like we didn't need the kernal
hack.  maybe we do but it seems to work with our own in window compositing.

- The dead-end parking decision. Why park rather than push further? The "no signal to follow" framing.

TODD: tired, so much capture iternation was burning me out. I was becoming another tool to claude.

- The capture proxy as a debugging tool getting suspect mid-session. Removing it as a confounder.

TODD: capture tool was in the end changing timing enough to either expose a problem in our code (suspected) or 
break some part of X.  Record to memory idea was a huge unlock to keep timing fast.  We probably still have
and issue with debug terminal output we should fix as well now that i think about it.


## Anchors for fact-check pass

- Files: `INVESTIGATION_MOTIF_INPUT.md` (the handoff doc), `Sources/SwiftXServerCore/CocoaWindowBridge.swift`
  (cross-NSWindow drag tracking), `Sources/SwiftXServerCore/USKeymap.swift` (keymap expansion),
  `Sources/SwiftXServerCore/ServerSession.swift` (_MOTIF_DRAG_WINDOW pre-set in init)
- Commits in order: `b9f2b25` ConvertSelection, `8a5b3d9` quickplot init, `8640402` implicit grab +
  override-redirect, `c6ea015` XDefineCursor, `bee1010` EnterNotify/LeaveNotify + PolyRectangle, `cbf2f52`
  keypad keysyms, `41973bd` F13-F35 + L-keys, `6f9a8ac` _MOTIF_DRAG_WINDOW pre-set, `5dc809f` capture buffer
  change, `496209a` investigation handoff doc, `29bc237` single-thread + Xt menu support
- Reference: `reference/X11R6/xc/lib/Xt/Selection.c` (Xt selection implementation, important for the next
  post)

## Working title alternatives

- "Motif is its own kind of difficult"
- "Day four: the Motif sweep"
- "Every bug except the one that mattered"
