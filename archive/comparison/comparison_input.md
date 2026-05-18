# comparison_input.md — input dimension

Three-way narrative: X11 protocol spec, X11R6 era-correct implementation,
xorg+XQuartz today, swift-x. Each section is concrete (files, functions, lines)
so the reader can grep along.

Scope: keyboard mapping (`GetKeyboardMapping`, `ChangeKeyboardMapping`,
`MappingNotify`), modifier mapping, pointer mapping, pointer warping, grabs
(active + passive + server), focus (`SetInputFocus`/`GetInputFocus`/RevertTo/
PointerRoot/None), crossings (`EnterNotify`/`LeaveNotify` with full
Ancestor/Virtual/Inferior/Nonlinear/NonlinearVirtual detail semantics),
`KeymapNotify`, `MotionNotify` (including `PointerMotionHintMask`),
`GetMotionEvents`, button-mask state encoding, auto-repeat
(`ChangeKeyboardControl`, `GetKeyboardControl`), `Bell`.

---

## 1. Keyboard mapping (`GetKeyboardMapping`, `ChangeKeyboardMapping`, `MappingNotify`)

**Spec** (chapter 9, `requests:GetKeyboardMapping` / `events:MappingNotify`):
GetKeyboardMapping returns a `keysyms-per-keycode` byte followed by `(count ×
keysymsPerKeycode)` 32-bit keysym words covering keycodes `first_keycode ..
first_keycode + count - 1`. ChangeKeyboardMapping replaces that range and is
server-wide; the server **must** then emit `MappingNotify` (event code 34) to
**every** client with `request=Keyboard`. Per § 5 Keyboards, the server holds a
single global mapping shared across clients.

**X11R6**: `programs/Xserver/dix/devices.c:1078 ProcGetKeyboardMapping` walks
`inputInfo.keyboard->key->curKeySyms` and writes the run. `devices.c:995
ProcChangeKeyboardMapping` updates `curKeySyms`, calls `SetKeySymsMap`, then
`devices.c:1032 SendMappingNotify(MappingKeyboard, firstKeyCode, count)`.
SendMappingNotify (`devices.c:755`) walks the client list and queues an
`xMappingNotifyEvent` per client (filter `CantBeFiltered` — never masked off).

**xorg/XQuartz**: same Proc names, modernized signatures — `dix/devices.c:1900
ProcGetKeyboardMapping`, `1783 ProcChangeKeyboardMapping`. xorg adds XKB
awareness: when XKB is enabled (default), the core protocol's
ChangeKeyboardMapping is funneled through `Xi/exevents.c:ChangeMasterDeviceKeys`
which then synthesizes an XKB `XkbNewKeyboardNotify` *and* the core
MappingNotify. XQuartz overrides nothing in this path; it provides the *content*
of the keymap via `hw/xquartz/quartzKeyboard.c:747 QuartzReadSystemKeymap`,
which uses `TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` to walk
the live macOS layout into a 4-group-per-keycode table.

**swift-x**: `Sources/SwiftXServerCore/ServerSession.swift:3563 case
.getKeyboardMapping` delegates to `SynthesizedFonts.swift:134
DefaultKeyboardMap.keysyms`, which calls `USKeymap.swift:93 keymapPayload`. The
table is a hard-coded US-ASCII layout (`USKeymap.swift:155 mappings`), 2 keysyms
per keycode (lower/upper), with Sun-specific keysyms padded in at synthetic
slots `mac 0xA0+` to let `XmInitializeVirtualBindings` find
`osfCopy/osfPaste/osfFront`. **No ChangeKeyboardMapping decoder exists** —
`Request.swift:329` falls through to `.unknown`, `ServerSession.swift:3928`
emits `BadRequest`. **MappingNotify is never emitted** — grep `MappingNotify` in
`Sources/` returns zero callers; the event type isn't even defined in
`Sources/Framer/Events/`.

**Surprises / divergences**:
- swift-x picks 2 keysyms per keycode; XQuartz advertises 4 (groups: normal,
  shift, mode_switch, mode_switch+shift). Two is spec-legal and matches Sun's
  default; doubling later is mechanical but means recomputing
  `XmInitializeVirtualBindings`-sensitive padding.
- swift-x's table never updates. XQuartz refreshes on macOS keyboard layout
  switches via `QuartsResyncKeymap` (`quartzKeyboard.c:870`) — but XQuartz has
  to fire MappingNotify when it does, and swift-x has nowhere to surface that
  signal even if we added the resync.
- The minKeycode/maxKeycode range in our SetupAccepted (8..255 per
  `USKeymap.swift:6 comment`) is wider than xorg's typical 8..255 with most high
  slots unmapped — fine, but Motif's virtual-binding probe enumerates the full
  range; we should make sure all those queries get NoSymbol replies, not
  BadValue.

**Blog hooks**:
- "Why the Sun's L-key column made it into a Mac X server in 2026 (the
  XmInitializeVirtualBindings rabbit hole)"
- "MappingNotify is the X server event nobody talks about until you don't send
  it"

---

## 2. Modifier mapping (`Get/SetModifierMapping`)

**Spec**: 8 modifier slots in fixed order — Shift, Lock, Control, Mod1, Mod2,
Mod3, Mod4, Mod5 — each with N keycodes (N = `keycodes_per_modifier`). Slot
value 0 = unassigned. SetModifierMapping returns a 1-byte `status`: `Success`,
`Busy` (a keycode is currently down), or `Failed` (one of the keycodes isn't a
real modifier per the keymap). On Success the server broadcasts
`MappingNotify(request=Modifier)`.

**X11R6**: `devices.c:972 ProcGetModifierMapping` writes the 8 × N keycode
array. `devices.c:863 ProcSetModifierMapping` validates each keycode (must have
at least one non-NoSymbol keysym), checks no keycode is down, then updates
`inputInfo.keyboard->key->modifierMap` and fires
`SendMappingNotify(MappingModifier, 0, 0)`.

**xorg/XQuartz**: `dix/devices.c:1755 ProcGetModifierMapping`, `1723
ProcSetModifierMapping`. XKB-aware. XQuartz contributes the initial mapping via
`quartzKeyboard.c:DarwinBuildModifierMaps` (around line 864) which walks the
keymap looking for `XK_Shift_L`, `XK_Control_L`, `XK_Alt_L`, `XK_Meta_L`, and
assigns them to the standard slots. macOS-specific: Command always goes to Mod2
(vs. Linux convention of Mod4 for Super) so the "Command sends X11 Meta" feature
works.

**swift-x**: `ServerSession.swift:3572 case .getModifierMapping` returns
`DefaultModifierMap.keycodes` (from `SynthesizedFonts.swift:147`, which is
`USKeymap.swift:70 modifierKeycodes` — a fixed 16-byte table). Command goes to
**Mod4** (slots 0x3F/0x3E for keycodes), Option goes to **Mod1**, matching the
most common Linux convention. **No SetModifierMapping decoder** — `BadRequest`.

**Surprises / divergences**:
- swift-x puts Command on Mod4, XQuartz puts it on Mod2. Doesn't matter for most
  Sun clients (they probe by keysym, not slot), but Motif's translation table
  for `osfPaste` is `Ctrl<Key>v` — if a user remaps Cmd→Meta expecting "Cmd-V
  pastes," they may be surprised by an apparent modifier-slot mismatch. We
  probably want to validate Motif behavior with a captured trace before
  committing to Mod4.
- swift-x's slot count is 2 (left + right), XQuartz uses 4 to accommodate
  Mode_switch and similar. R6 was 2.

**Blog hooks**:
- "How macOS keyboards lie about modifiers and what an X server does about it"

---

## 3. Pointer mapping (`Get/SetPointerMapping`)

**Spec**: Pointer mapping is a byte-array where index N (1-based) is the logical
button that physical button N maps to. SetPointerMapping returns `status`
(Success / Busy). MappingNotify(Pointer) follows on success.

**X11R6**: `devices.c:1117 ProcGetPointerMapping`, `1038 ProcSetPointerMapping`.
The latter checks no buttons are currently held (`mouse->button->buttonsDown`),
updates `inputInfo.pointer->button->map`, and fires
`SendMappingNotify(MappingPointer, 0, 0)`.

**xorg/XQuartz**: `dix/devices.c:1951 ProcGetPointerMapping`, `1842
ProcSetPointerMapping`. Default mapping is `1, 2, 3` (5-button mice add `4, 5`
for scroll). XQuartz hands physical button events through
`hw/xquartz/darwinEvents.c:488 DarwinSendPointerEvents` using the post-map
button number.

**swift-x**: `ServerSession.swift:3580 case .getPointerMapping` returns
`DefaultPointerMap.map` = `[1, 2, 3]` (`SynthesizedFonts.swift:152`). **No
SetPointerMapping decoder** — BadRequest. `FlippedXView.swift:184-189` maps
NSEvent button types to X buttons 1/2/3 via the standard left/right/other
correspondence; there's no swap-buttons-for-left-handed-users wire.

**Surprises**:
- macOS has no notion of "physical button 2" (middle-click) on a magic trackpad;
  we synthesize it via `otherMouseDown`. swift-x relies on AppKit here, so a
  left-handed user setting macOS to "primary button = right" gets the swap
  applied **before** we see the event — meaning our X protocol map stays `[1, 2,
  3]` but physical reality matches. xorg/XQuartz have the same property.

---

## 4. Pointer warping (`WarpPointer`)

**Spec** (`requests:WarpPointer`): if srcWindow=None, move pointer to `(dst.x +
dstX, dst.y + dstY)` unconditionally. Else only move if the pointer is currently
in src + (srcX, srcY, srcWidth, srcHeight). On move, generate the appropriate
crossing events plus MotionNotify.

**X11R6**: `events.c:1570 ProcWarpPointer` does the src-rect check, clamps to
the screen, then calls the device's `SetCursorPosition` and feeds the synthetic
motion into the event pipeline.

**xorg/XQuartz**: `dix/events.c:3667 ProcWarpPointer`. XQuartz hooks
`SetCursorPosition` via `quartzCursor.c` (out-of-era code path uses
`CGWarpMouseCursorPosition`).

**swift-x**: `ServerSession.swift:3483-3494` updates `lastPointerXY` and
`lastPointerTopLevel` only — **does not move the macOS cursor**. The comment is
explicit: "warping the macOS pointer feels jarring (the user's physical pointer
would jump)."  No crossing events fire on warp, no MotionNotify is synthesized.
QueryPointer subsequently reports the warped position even though the visible
cursor hasn't moved.

**Surprises**:
- This is a Mac-shaped concession. xeyes still kinda works because we report the
  correct internal coords, but the eyes track an invisible cursor when the X
  client warps. xclock and dt-apps don't warp.
- If we ever want quickplot's "jump to origin" or xscreensaver-demo's recenter
  to look right, we'd flip it to `CGWarpMouseCursorPosition`. The blocker is
  rootless: warping into a coord that isn't inside our NSWindow is meaningless.

**Blog hooks**:
- "Why WarpPointer is a Mac-philosophy collision and we silently ignored it"

---

## 5. Grabs

### 5a. Active pointer grab (`GrabPointer` / `UngrabPointer`)

**Spec**: GrabPointer (opcode 26) replaces the implicit press-time grab. Returns
status (Success / AlreadyGrabbed / InvalidTime / NotViewable / Frozen). If
`pointerMode = Sync`, events freeze until AllowEvents. ChangeActivePointerGrab
updates cursor + eventMask without releasing.

**X11R6**: `events.c:2738 ProcGrabPointer`. `746 ActivatePointerGrab` emits a
Leave→Enter crossing chain with `mode=Grab`. `778 DeactivatePointerGrab` emits
the inverse `mode=Ungrab` chain.

**xorg/XQuartz**: `dix/events.c:5042 ProcGrabPointer`. Same model, plus XInput2
device-grab tracking. XQuartz adds `xp_grab_control` (kernel private) to
redirect Mac events around AppKit during the grab — we don't have those APIs.

**swift-x**: `ServerSession.swift:1307 handleGrabPointer` always returns
Success, stores cursor+mask+ownerEvents in `PointerGrab` struct, calls
`bridge.startCrossWindowDragTracking()` (which installs an
`NSEvent.addLocalMonitorForEvents` to route cross-NSWindow drag — see
`CocoaWindowBridge.swift:1197`), and emits a `mode=.grab` crossing chain via
`emitCrossings`. Sync/Async modes are ignored. `pointerMode` and `keyboardMode`
fields are read by the decoder (`MoreRequests.swift:126`) but unused at delivery
time. `ChangeActivePointerGrab` updates cursor + mask but ignores `time`
(`ServerSession.swift:3242-3266`).

### 5b. Passive button/key grab (`GrabButton`, `GrabKey`, `UngrabButton`, `UngrabKey`)

**Spec**: registers a future activation. On a matching press, server
auto-installs an active pointer/keyboard grab on the grab-window for the
duration of the press. AnyButton=0, AnyModifier=0x8000.

**X11R6**: `events.c:3297 ProcGrabButton`, `3244 ProcGrabKey`, `3370
ProcUngrabButton`, `3202 ProcUngrabKey`. Storage in `grabs.c`. Matching done in
`events.c:CheckPassiveGrabsOnWindow` on every press.

**xorg/XQuartz**: `dix/events.c:5720 ProcGrabButton`, `5669 ProcGrabKey`. Same
model.

**swift-x**: `ServerSession.swift:3442` (GrabButton) and `3462` (GrabKey) append
to `passiveButtonGrabs[]` / `passiveKeyGrabs[]`. Matching:
`findActivatablePassiveGrab` (`ServerSession.swift:1248`) and
`findActivatablePassiveKeyGrab` (`1226`). The button-grab path is wired into
`handleMouseEvent` (`ServerSession.swift:711-746`) and **does** auto-install an
active grab + emits the `mode=.grab` crossing chain. The key-grab path is wired
into `handleKeyEvent` (`566-605`). **UngrabButton (opcode 29) and UngrabKey
(opcode 34) have no framer decoders** — they become BadRequest.

### 5c. Server grab (`GrabServer` / `UngrabServer`)

**Spec**: while server-grabbed, other clients' requests queue. Single-
client-relevant only.

**X11R6 + xorg**: implemented faithfully.

**swift-x**: `ServerSession.swift:3531-3535` no-ops both, with comment
"Single-client server."

### 5d. AllowEvents

**Spec** (§ 12.6): `AsyncPointer` / `SyncPointer` / `ReplayPointer` /
`AsyncKeyboard` / `SyncKeyboard` / `ReplayKeyboard` / `AsyncBoth` / `SyncBoth`.
Releases events queued behind a sync grab.

**X11R6**: `events.c:971 ProcAllowEvents`.

**xorg**: `dix/events.c:1912 ProcAllowEvents`.

**swift-x**: `ServerSession.swift:3476-3481` no-ops with comment "We don't
implement frozen grabs (every grab we install is in GrabModeAsync state)." This
is consistent — no queue means nothing to drain.

**Surprises / divergences across all 5x**:
- The implicit press-time grab is handled correctly in swift-x
  (`ServerSession.swift:801-839`), including the `mode=.grab` / `mode=.ungrab`
  crossing chains — which is more thorough than the hard-coded
  `detail=Nonlinear` on focus events would suggest, so the attention spent here
  is uneven across the input dimension.
- The R6 + xorg crossing chains carry the `state` field reflecting current
  modifier + button mask. swift-x emits `state: 0` on all crossing events
  (`ServerSession.swift:1063, 1081`). See risk #12.

**Blog hooks**:
- "Passive button grabs were the difference between Motif menus working and
  Motif menus appearing-then-disappearing"
- "What a 'frozen grab' really means and why we got away with not having one for
  a year"

---

## 6. Focus (`SetInputFocus`, `GetInputFocus`, FocusIn / FocusOut)

**Spec** (§ 9.5 + `events:FocusIn`): RevertTo ∈ {None=0, PointerRoot=1,
Parent=2}. Focus ∈ {None=0, PointerRoot=1, or a window ID}. Detail field on
FocusIn/Out is one of 8 values: Ancestor / Virtual / Inferior / Nonlinear /
NonlinearVirtual / Pointer / PointerRoot / None. The exact detail depends on the
relationship between (oldFocus, newFocus, pointer).

**X11R6**: `events.c:2705 ProcSetInputFocus` validates, calls `SetInputFocus`
which calls `DoFocusEvents (events.c:2513)`. DoFocusEvents walks the
from/to/pointer relationship and recursively emits FocusOut and FocusIn events
with **the correct detail** at each level via `FocusOutEvents` / `FocusInEvents`
(lines 2497, 2471). The algorithm has ~50 lines of branching to get the detail
right.

**xorg/XQuartz**: `dix/events.c:4984 ProcSetInputFocus`, `5003
ProcGetInputFocus`. Same DoFocusEvents algorithm, refactored to take a
DeviceIntPtr. XQuartz doesn't override.

**swift-x**: `ServerSession.swift:3212 case .setInputFocus` stores `focusWindow`
but **ignores `revertTo` and `time`**. `case .getInputFocus` (3133) returns
`revertTo: .parent` always (a defensible default, but divergent from what was
set). FocusIn/Out emission happens in three places:
- `handleFocusChange` (`548`) — NSWindow became-key transitions, sets `detail:
  .nonlinear`, `mode: .normal`.
- `handleGrabKeyboard` (`1365`) and `handleUngrabKeyboard` (`1381`) — set `mode:
  .grab` / `.ungrab` via `emitFocusEventPair` (`1400`), all with `detail:
  .nonlinear`.

The detail field is **always Nonlinear** in swift-x. KeymapNotify (which R6's
`FocusEvent` emits after FocusIn when KeymapStateMask is set, see
`events.c:2456`) is **never** emitted.

**Surprises / divergences**:
- swift-x's `detail=Nonlinear` works for xterm because xterm only reads the
  event type, not the detail. Motif's text widgets do read detail; see risk #3.
- `focus=PointerRoot (1)` and `focus=None (0)` should drive DoFocusEvents down
  very different code paths in R6 (the `WindowTable[i]` walk that notifies all
  root windows). swift-x just stores `nil` and effectively reverts to
  keyTarget-based delivery — which works in practice because we don't have
  multiple screens or non-default root behavior.
- quartz-wm (`src/main.m:396, 661`) calls `XSetInputFocus(PointerRoot,
  RevertToPointerRoot)` on startup and `(None, RevertToNone)` on shutdown. Both
  should produce different GetInputFocus replies. We'd lose the distinction.

**Blog hooks**:
- "All eight values of the FocusIn detail field, and what breaks if you pick the
  wrong one"

---

## 7. Crossing events (`EnterNotify` / `LeaveNotify`)

**Spec**: `EnterNotify`/`LeaveNotify` carry detail ∈ {Ancestor, Virtual,
Inferior, Nonlinear, NonlinearVirtual} reflecting the spatial relationship of
(from, to). Plus mode ∈ {Normal, Grab, Ungrab, WhileGrabbed}.

**X11R6**: `events.c:2406 DoEnterLeaveEvents`. ~30 lines of branching:
IsParent(from, to) → Inferior/Virtual/Ancestor chain; IsParent(to, from) →
Ancestor/Virtual/Inferior chain; else Nonlinear/NonlinearVirtual chain.
`EnterLeaveEvent` (low-level emitter) + `EnterNotifies` / `LeaveNotifies`
(walkers).

**xorg/XQuartz**: refactored into `dix/enterleave.c:349 CoreEnterLeaveEvents`
(xorg-specific file) with `CommonAncestor` helper (line 216). XInput2 device
versions live in `DeviceEnterLeaveEvents`.

**swift-x**: `ServerSession.swift:964 emitCrossings`. **This is the most
thoroughly-implemented input feature** — the algorithm correctly handles all
four cases (from-is-ancestor, to-is-ancestor, nonlinear with LCA, nonlinear
without LCA = "outside the X subtree"). Uses `ancestorPathToTopLevel` (line
1151) to walk parents. Filters by event mask (EnterWindowMask/LeaveWindowMask)
per recipient. Shares `crossingTime` across the chain so paired Leave/Enter
carry the same timestamp. The mode parameter is plumbed through correctly —
`.normal` from `handlePointerMoved`, `.grab` from grab activation, `.ungrab`
from grab release.

**Surprises / divergences**:
- swift-x's crossing implementation is more sophisticated than its focus
  implementation. Different authors? Probably the same author, but the crossing
  path got the attention because the Athena+Motif menus break visibly without
  correct Virtual/NonlinearVirtual detail, whereas focus detail is silently
  wrong.
- swift-x emits `state: 0` on crossings (`1063, 1081`), where R6 emits the
  current modifier+button mask. See risk #12.
- The "pointer left the NSView's content area" path (`handlePointerExitedView`,
  line 909) treats outside-the-X-subtree as `from = nil` for the chain math —
  clever, and matches what R6 does for same-screen crossings.

**Blog hooks**:
- "The Nonlinear case of the X crossing algorithm is the only reason Athena
  menus highlight correctly"

---

## 8. KeymapNotify

**Spec**: event code 11. 31 bytes of bitmap (one bit per keycode 0..247
indicating "currently down"). Emitted after FocusIn / EnterNotify when the
destination window has `KeymapStateMask` in its event mask. Has **no sequence
number** — uniquely among X events.

**X11R6**: `events.c:2456` (inside FocusEvent) and analogous spot in the
crossing emitter — when the target window's mask has KeymapStateMask, an
xKeymapEvent is encoded from `dev->key->down[1..32]` and delivered immediately
after.

**xorg/XQuartz**: same shape.

**swift-x**: `KeymapNotifyEvent` is defined (`InputEvents.swift:257`) and
correctly encodes the 32-byte payload with code=11 and **no sequence number**.
**Zero call sites** emit one. See risk #8.

**Blog hooks**:
- "The one X event that doesn't have a sequence number"

---

## 9. MotionNotify, button-mask state, GetMotionEvents

**Spec**: MotionNotify has `detail = 0` (no hint) or `1` (hint, sent if client
opted into `PointerMotionHintMask` — server waits for QueryPointer before
sending more). State field encodes modifiers + held buttons: buttons occupy bits
8..12 (`Button1Mask=1<<8`). GetMotionEvents returns a server-buffered ring of
timestamped positions.

**X11R6**: `events.c:1304 DeliverDeviceEvents` runs the hint logic via
`MaybeStopHint` (`devices.c:1490`). GetMotionEvents in `devices.c:1504
ProcGetMotionEvents` walks the device's motion buffer.

**xorg/XQuartz**: `dix/devices.c:2405 ProcGetMotionEvents`. Hint state on the
master pointer's `valuator->motionHintWindow`.

**swift-x**: MotionNotify emitted in `handlePointerMoved` (line 880) and
`handleMouseDragged` (670) with **detail always 0** (no-hint) — see risk #7.
State field built correctly for drag (`670` includes `currentModifierState |
buttonStateBit`), correctly for press/release (`759-778` reflects "state before
this event" per spec), correctly for keys (`617` is `currentModifierState`). The
button bit math (`UInt16(1) << (7 + button)`) gives Button1=0x100 which matches
the spec. **GetMotionEvents has no framer decoder** — BadRequest.

**Surprises**:
- swift-x's state field encoding is correct except for the crossing-event
  state-zero divergence above.
- The "state reflects BEFORE this event" rule (press doesn't include the
  just-pressed button; release does include the about-to-release button) is
  implemented in `ServerSession.swift:763-777`. That's the kind of spec detail
  that's easy to miss — credit where due.

**Blog hooks**:
- "What 'state reflects the state BEFORE this event' means in practice"

---

## 10. Auto-repeat + bell (`ChangeKeyboardControl`, `GetKeyboardControl`, `Bell`)

**Spec**: ChangeKeyboardControl is a value-list. Mask bits 0..7:
KBKeyClickPercent, KBBellPercent, KBBellPitch, KBBellDuration, KBLed, KBLedMode,
KBKey, KBAutoRepeatMode. GetKeyboardControl returns the current state plus a
32-byte autoRepeats bitmap. Bell takes a -100..100 percent (negative = soft);
BadValue out of range.

**X11R6**: `devices.c:1159 ProcChangeKeyboardControl`, `1355
ProcGetKeyboardControl`, `1379 ProcBell`. R6 has real auto-repeat per-key plus
LED state.

**xorg/XQuartz**: `dix/devices.c:2166 ProcChangeKeyboardControl`, `2210
ProcGetKeyboardControl`, `2241 ProcBell`. XQuartz's `DDXRingBell`
(`hw/xquartz/quartz.c:548`) drives `NSBeep` on the main thread.

**swift-x**: **No ChangeKeyboardControl, GetKeyboardControl,
ChangePointerControl, GetPointerControl decoders.** Bell is handled
(`ServerSession.swift:3548-3554`) but ignores pitch/duration entirely and
silences anything with `percent <= 0`. `CocoaWindowBridge.swift:1170 bell` calls
`NSSound.beep` on the main queue. See risks #1 + #14.

**Blog hooks**:
- "NSBeep vs. the X11 bell-pitch curve"

---

## Cross-cutting surprises and divergences

1. **swift-x has the framer types for input requests, but not for the
   control/mapping requests**. Five mapping-control opcodes (100, 102, 103, 105,
   106) and two unmaps (29, 34) have no decoder — they all become BadRequest.
   This is consistent within itself (the team prioritized the request-with-reply
   path that Xt needs at startup), but inconsistent with the "we already shipped
   the framer types for GrabKey, GrabButton, AllowEvents" pattern. Cheap to add.

2. **Crossing detail is correct; focus detail is not**. Two algorithms of
   roughly identical complexity (ancestor/descendant/LCA walking), one ported
   with care, the other hard-coded to Nonlinear. Likely because crossing
   failures are visible (menus don't highlight) and focus failures are silent
   (Motif input field cursor stays hollow).

3. **swift-x emits `state: 0` on crossings.** R6 and xorg always pack the live
   modifier+button mask. The only place this would bite us today is Athena
   SmeBSB drag-through highlighting — which we don't ship.

4. **WarpPointer doesn't warp.** This is a deliberate, documented Mac-shaped
   concession. R6 and XQuartz both move the cursor.

5. **Server is single-client by construction.** GrabServer is a no-op, no
   MappingNotify needs to fan out to other clients, no "AlreadyGrabbed by
   different client" path. This simplification cuts a lot of complexity and is
   appropriate for the goal.

6. **The Cocoa side is the source of input truth.** AppKit's `mouseDragged` →
   NSView routing means we had to install a kernel- adjacent monitor
   (`NSEvent.addLocalMonitorForEvents`, `CocoaWindowBridge.swift:1206`) to route
   cross-NSWindow drags during X grabs. XQuartz uses private `xp_*` kernel APIs;
   we don't have those. This is a real architectural difference, not just a
   missing feature.

7. **No XKB, no XInput2**: swift-x targets R6 which means core protocol only.
   The post-R6 keyboard/input world (XKB groups, level3 shift, XInput2 device
   events, multi-pointer X) is out-of-era and correctly absent. xorg's input
   layer is **heavily** XKB-aware now — even `ProcGetKeyboardMapping` consults
   `xkb->core_curr` rather than a classic keymap table. swift-x's classic
   two-keysyms-per-keycode approach is the R6-correct shape; we just need to
   make sure ChangeKeyboardMapping doesn't have to think about XKB groups.

---

## Blog hooks (collected)

- **"Why MappingNotify is the event nobody talks about until it's missing"**:
  shows up as Xlib's keysym cache going stale after every Set*. Easy to forget;
  not in any tutorial.
- **"The Nonlinear-Virtual case of the X crossing algorithm, illustrated"**: the
  `else` branch in DoEnterLeaveEvents is where Athena menus live or die. Worth a
  diagram.
- **"WarpPointer in a rootless world"**: the only X11 request that asks the
  server to move the user's physical pointer. macOS says "really?" We say "no."
- **"How a Sun keyboard's L-key column survives in 2026"**: USKeymap.swift has
  explicit slots for `SunProps`, `SunCopy`, `SunPaste` so
  `XmInitializeVirtualBindings` doesn't SIGSEGV. Pure archaeology.
- **"All 8 values of the FocusIn detail field, and what they really mean"**:
  nobody documents this clearly. Spec implies, R6 implements, Xt reads.
