# risk_input.md — input dimension

Risk register for the **Input** dimension of swift-x: keyboard/modifier/pointer
mapping, grabs, focus, crossings, motion, bell, auto-repeat. Three buckets:
actively bleeding now, will bleed when X happens, theoretical/spec-only.

Authority: spec > X11R6 > xorg+XQuartz > swift-x. Era target: X11R6 (no XKB, no
XInput2, no XFIXES barriers). Single client per session.

References used for fix-shape suggestions:
- `reference/X11R6/xc/programs/Xserver/dix/devices.c` (mapping + control procs)
- `reference/X11R6/xc/programs/Xserver/dix/events.c` (focus / grab / crossing)
- `reference/x11-protocol-spec/x11protocol.html`

---

## Actively bleeding now

### 1. Five core mapping/control opcodes return `BadRequest` instead of working.

**Severity: actively bleeding** for any captured-from-Sun corpus replay or live
fixture that touches keyboard control or pointer remapping. Specifically:
opcodes **100 (ChangeKeyboardMapping)**, **102 (ChangeKeyboardControl)**, **103
(GetKeyboardControl)**, **105 (ChangePointerControl)**, **106
(GetPointerControl)**, **39 (GetMotionEvents)**, **116 (SetPointerMapping)**,
**118 (SetModifierMapping)**, **29 (UngrabButton)**, **34 (UngrabKey)** all lack
framer decoders (`Sources/Framer/Requests/Request.swift:329` falls through to
`.unknown`, `ServerSession.swift:3928` emits `BadRequest`). For request-with-
reply ones (39, 103, 106) the client now gets a BadRequest in the reply slot.
For request-only ones (100, 102, 105, 116, 118, 29, 34) the client gets an
unexpected BadRequest event which Xlib logs as `error 1` on the console.

**Trigger today**: xterm's `*c8` mode-setting paths, Motif's
`XmInitializeVirtualBindings` (it may issue ChangeKeyboardMapping when it
patches in virtual keysyms), CDE's `dtsession` and `dtcm` (clipboard/calendar
issue ChangeKeyboardControl to disable autorepeat on their text widgets), and
any Xlib `XAutoRepeatOff/On` call. Quickplot is known to issue ~5 `GrabKey`
calls and at least one `UngrabKey` on shutdown; the shutdown path will now emit
a BadRequest event right before the connection closes (cosmetic, but visible in
client stderr).

**Fix shape**: add framer decoders for all ten opcodes (most are small —
SetPointerMapping is one byte-array, SetModifierMapping is keycodes × 8,
ChangeKeyboardControl is a value-list like ChangeWindowAttributes). Server side:
SetModifierMapping returns `Success(0)` and emits MappingNotify;
SetPointerMapping likewise; Get*Control returns a synthesized reply with
sensible idle values (`autoRepeat=1`, `bell=50`, all-zero LED mask, autoRepeats
all-ones); GetMotionEvents returns `nEvents=0` (we don't keep a history buffer).
ChangeKeyboardMapping can update an in-memory clone of USKeymap and emit
MappingNotify. UngrabButton/UngrabKey just walk passiveButtonGrabs /
passiveKeyGrabs and remove matching entries.

### 2. No MappingNotify event is ever sent.

**Severity: actively bleeding latently.** Even if SetModifierMapping etc. were
implemented, swift-x never emits MappingNotify (event code 34). R6's
`SendMappingNotify` (`devices.c:755`) fires on every Modifier / Pointer /
Keyboard change. Xt's `_XtRefreshMapping` and Xlib's `_XRefreshKeyboardMapping`
both rely on this event to invalidate their cached keysym tables.

**Trigger today**: nothing breaks right now because we never *change* a mapping.
The moment the fix for risk #1 lands, every Set*/Change* path needs to fan out a
MappingNotify or Xlib's keysym cache will stay stale.

**Fix shape**: factor a `sendMappingNotify(request: 0|1|2, firstKeycode, count)`
helper in `ServerSession` and call it from each of the three mapping handlers.
MappingNotify is `CantBeFiltered` (broadcast to all clients), and event format
is trivial — 32 bytes, see `reference/X11R6/xc/include/Xproto.h` xMappingNotify.

### 3. FocusIn/FocusOut detail is hard-coded to `Nonlinear`, missing the seven
other valid detail values.

**Severity: actively bleeding** on quartz-wm-style focus management and on the
NSWindow becoming-key path. `handleFocusChange` (`ServerSession.swift:548`),
`emitFocusEventPair` (line 1400), and the `GrabKeyboard`/`UngrabKeyboard` paths
all unconditionally set `detail: .nonlinear`. The spec (and R6's `DoFocusEvents`
in `events.c:2513`) demands the full
Ancestor/Virtual/Inferior/Nonlinear/NonlinearVirtual/Pointer/PointerRoot/None
machinery depending on the from/to relationship. Plus, the spec says when focus
moves into a window that's an ancestor or descendant of the pointer window,
intermediate windows receive `NotifyPointer` chain events.

**Trigger today**: xterm renders correctly because it just toggles cursor shape
on any FocusIn/Out regardless of detail. Motif Text widgets (XmText,
XmTextField), and the dt-apps' input fields, **do** check the detail field: if a
`FocusIn(detail=Nonlinear)` arrives but the widget's `XmNtraversalOn` expected a
`FocusIn(detail=Pointer)` for focus-follows-mouse, the widget silently refuses
to render its cursor. Likely cause of "click in dtterm's input field, no cursor,
but typing still works" symptoms; testable.

**Fix shape**: port R6's `DoFocusEvents` algorithm. ~80 lines of code; the
ancestor/descendant/LCA logic is already done correctly for crossing events in
`emitCrossings` so a generic helper is feasible. Detail values 5/6/7
(`Pointer`/`PointerRoot`/`None`) only fire when focus is set to root or
PointerRoot — quartz-wm does this (`main.m:396` —
`XSetInputFocus(PointerRoot)`).

### 4. SetInputFocus ignores `revertTo` and `time`; passive grabs ignore the
"grab while frozen" semantics.

**Severity: actively bleeding** in two specific spots. (a) `revertTo` is parsed
but never stored (`ServerSession.swift:3217-3228`), so GetInputFocus always
returns `revertTo=Parent` (line 3146) regardless of what the last SetInputFocus
requested. Quartz-wm-style WMs read this back. (b) The X spec says `time`
enforces "if InvalidTime (request time is earlier than the current focus-change
time), the request is ignored." We don't track focus- change time, so a sequence
of `SetInputFocus(focus=A, time=100); SetInputFocus (focus=B, time=50)` ends up
at B when spec says it must stay at A.

**Trigger today**: any well-behaved Motif app that round-trips focus via
SetInputFocus(... RevertTo*); xmcd, xfontsel, dtterm Edit menu paths all do
this. Quickplot does this too during its menu post.

**Fix shape**: store `revertToValue` and `focusChangeTime` on the session; echo
on GetInputFocus; reject SetInputFocus where `time < focusChangeTime` per spec
(silently — it's a "request is ignored" not a BadValue).

### 5. Passive button grabs ignore `keyboardMode` and `pointerMode` (sync vs.
async).

**Severity: actively bleeding latently** for any client that wants "synchronous"
pointer grabs to queue events behind AllowEvents. Today `AllowEvents` is a no-op
(`ServerSession.swift:3476-3481`). GrabButton stores
`pointerMode`/`keyboardMode` per the decoder, but `ServerSession.swift:3443`
drops them on the floor when building the `PassiveButtonGrab`. Once a grab
activates we always deliver immediately as if `GrabModeAsync`. Real X servers
(R6 `events.c:746` `ActivatePointerGrab` + `971` `ProcAllowEvents`) queue events
on a sync grab and release them only when the grabbing client issues
AllowEvents.

**Trigger today**: Motif's drag-drop initiation (XmDragStart issues a
GrabPointer with `pointerMode=Synchronous` so the source widget can preview the
drag before letting events flow), and Xt's `XtGrabPointer` for tear-off menus.
Neither is a feature we use day-to-day, but quickplot's about-dialog animation
**may** depend on the implicit drag-grab queueing. Note:
INVESTIGATION_MOTIF_INPUT.md mentioned this; once we attempt drag-source apps
this will surface.

**Fix shape**: track a per-session `frozenEvents` queue, a `pointerFrozen` bit,
a `keyboardFrozen` bit. On a grab with `Sync` mode, set the bit. While set,
queue ButtonPress/Release/MotionNotify into `frozenEvents` instead of emitting.
`AllowEvents` with `AsyncPointer` / `ReplayPointer` / etc. drains or replays per
spec § 12.6. Mid-complexity; needs care on event ordering with keyboard grab.

---

## Will bleed when X happens

### 6. QueryKeymap returns all-zeros — no held-key tracking.

`ServerSession.swift:3904-3916` returns 32 zero bytes. Real servers (R6
`devices.c:1572`) snapshot the current `keyboard->key->down` bitmap.
**Trigger**: Xt's `_XtMatchAtom` debounce, Motif's keyboard repeat detection
during keyboard-only menu navigation. The dt-apps and quickplot we've shipped
don't seem to read it during init, but any keyboard-driven menu interaction in
dtterm could care. Documented honest-low confidence; recorded in OPCODE_STATUS.

**Fix**: per-keycode `Set<UInt8>` updated in `handleKeyEvent`, serialized in the
reply.

### 7. PointerMotionHintMask is not honored — motion always carries `detail=0`.

`ServerSession.swift:880` always sets `detail: 0` (no-hint) and emits every move
as a full MotionNotify. The spec says clients that set PointerMotionHintMask are
willing to receive *hint* events with `detail=1` and must call QueryPointer to
get the current coords. Apps that opt into hinting expect a sparser stream.
**Trigger**: any high-frequency motion consumer that turned on hinting for
bandwidth reasons. xterm doesn't use it; Motif XmScale sliders don't; xeyes
turns on PointerMotionMask without hint. So today this is latent.

**Fix**: when the target window's eventMask includes PointerMotionHintMask (bit
1<<7) and we just emitted a non-hint motion, defer further motion until a
QueryPointer arrives or some other event flushes.

### 8. KeymapNotify is never emitted after FocusIn.

R6's `FocusEvent` (`events.c:2456`) emits a KeymapNotify whenever a window with
`KeymapStateMask` in its event mask gets a FocusIn. swift-x's `FocusEvent`
encoder exists (`InputEvents.swift:257`) but no call site emits one.
**Trigger**: Athena `XawTextSink` and Motif XmText both expect to read the
current keymap bitmap on focus-in to know which modifiers were pressed when they
weren't the focus window — without it, modifier-modified initial keystrokes can
be missed. Rare but real, and easy to add once held-key tracking (risk #6)
lands.

**Fix**: in `handleFocusChange(gained: true)`, if the target window's event mask
has `KeymapStateMask` (bit 1<<14), encode and append a KeymapNotify right after
FocusIn, sharing the same packet boundary.

### 9. ChangeActivePointerGrab ignores `time`.

`ServerSession.swift:3242-3266` updates cursor + eventMask but never compares
`r.time` against the grab's installation time. Spec § 12.8 says "if the time is
earlier than the last-grab-time or later than the current server time, the
request has no effect." **Trigger**: race conditions during menu post (a delayed
ChangeActivePointerGrab from a stale Xt timer could override the real grab); we
haven't observed this, but quickplot's menu cascade is the most likely place.

**Fix**: store grab installation time on `PointerGrab`, gate the update.

### 10. GrabPointer never returns `AlreadyGrabbed`, `NotViewable`, or `Frozen`.

`ServerSession.swift:1307-1340` always returns `Success` even when there's
already an active grab. R6 returns `AlreadyGrabbed` when a different client
holds the grab (`events.c:2738`). Single-client comment ("we don't have a
different client") justifies skipping AlreadyGrabbed, but a client grabbing
twice in a row before ungrabbing is spec-legal and we should still handle the
"second grab replaces first" path correctly, plus we silently wedge any client
that explicitly checks for `Frozen` (some Motif xmDragContext paths).

**Fix**: cheap — leave Success in place but log a warning when we observe
double-grab; revisit if a client trips on it.

### 11. WarpPointer doesn't actually move the macOS cursor.

`ServerSession.swift:3483-3494` updates internal last-known pointer position but
doesn't call `CGWarpMouseCursorPosition`. The comment explicitly says this is a
deliberate choice for rootless. **Trigger**: xeyes follows the real pointer so
warping it pointless-but-not-broken; xscreensaver-demo would notice (it warps to
center on lock-screen activation); quickplot's "jump-to-origin" command warps
and *does* want the visual cursor to track.

**Fix**: optional flip. Spec is ambiguous on whether the cursor *must* visibly
move; XQuartz's `quartz.c` honors warp via `CursorWarpedTo` callback. Could gate
behind a preference.

### 12. Crossing events emitted on subwindow transitions ignore `state` field.

`ServerSession.swift:1063, 1081` always set `state: 0` on the CrossingEvent.
Spec says crossing events carry the current modifier+button state in the same
encoding as InputEvent.state. **Trigger**: Xaw SmeBSB menu items use the
crossing event's state to decide whether to invert (button held = "drag- through
highlight"); Motif menu cascades may use it for keyboard-modifier- sensitive
highlight. We've seen Athena menu highlighting work on xfontsel — that's only
because the button-down crossing path goes through grab mode which the widget
handles separately. The non-grab path is incomplete.

**Fix**: replace `state: 0` with `currentModifierState | heldButtonsMask` in
both emit loops.

---

## Theoretical / spec-only

### 13. No focus-change time tracking → can't reject stale focus changes.

Spec § 9.5 SetInputFocus enforces "time later than last-focus-change-time." No
real client of ours races focus changes within milliseconds. Tracked under risk
#4 as the deeper version of "ignores time."

### 14. Bell pitch / duration / percent scaling ignored.

`ServerSession.swift:3548-3554` calls `NSBeep` if percent > 0, no scaling. macOS
NSSound.beep has no volume/pitch knobs. Spec lets us advertise no volume
control. Real Sun clients do `XBell(display, 100)` once on errors; nobody cares
about pitch except `xkbbell -p` (Xkb, out of era).

### 15. No LED state — KBLed / KBLedMode silently irrelevant.

There are no LEDs on a Mac keyboard for us to drive (CapsLock indicator is
macOS's, not ours to set), and clients that issue `KBLed` requests during init
don't fail when the change is invisible. R6 maintained LED state but the
bell-rings-on-CapsLock semantics are gone post-Sun.

### 16. GrabKey `key` field validation against the keymap is missing.

Spec says BadValue if `key` isn't within `min_keycode..max_keycode`. Our keymap
advertises `8..255`, which any keycode the client sends fits inside. So in
practice never triggered; would be wrong if we ever shrink keycode range.

### 17. No "freeze" semantics on keyboard grab for synchronous mode.

Same shape as risk #5 but on the keyboard side. Quickplot's GrabKey calls all
use `GrabModeAsync`, and Motif's accelerator path is Async too. Latent until a
client uses `GrabModeSync` on the keyboard.

### 18. AnyKey / AnyModifier expansion edge cases on passive grabs.

`findActivatablePassiveKeyGrab` (`ServerSession.swift:1226-1246`) handles
AnyKey=0 and AnyModifier=0x8000 correctly but doesn't expand AnyModifier into
the cross-product of {with-CapsLock, with-NumLock, with-ScrollLock} that R6 does
in `grabs.c:DeliverGrabbedEvent`. This matters when a client registers
`GrabKey(F1, mod=ShiftMask)` and the user presses F1 with CapsLock on: real X
would still match; we wouldn't. Theoretical for Mac since we don't surface
NumLock/ScrollLock at all.
