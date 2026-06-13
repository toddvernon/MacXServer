# Modal-dialog behavior investigation — open (2026-06-13)

Symptom Todd observed: quickplot opened a file-picker dialog (modal),
then he clicked the command window and opened a second dialog. When
he dismissed the second dialog, BOTH the second dialog AND the file
picker dismissed. Expected on real Sun mwm: clicking the command window
while the modal file picker was up should have been BLOCKED — the user
couldn't have opened the second dialog at all.

Capture: `/tmp/macxserver/qp-2026-06-13-17-15-27.log`.

## What the log shows

- Quickplot IS using `XtAddGrab` under the hood → we receive
  `XGrabKeyboard` + `XGrabPointer` on the dialog's X window. Confirmed
  at req[3826]/[3827] (first modal), req[3839]/[3840] (second modal
  nested), req[3875]/[3890] (ungrab pair on dismiss).
- The grabs nest correctly on the wire (two GrabPointer calls without
  an intervening UngrabPointer).
- `WM_TRANSIENT_FOR` is set on the dialog windows (0x4400159,
  0x440016d, 0x44001b0) pointing at their parents.
- `_MOTIF_WM_HINTS.inputMode` is NOT set on any of these — modal
  signaling is via the X grab path, NOT via the MWM hint.

## What's likely going wrong (hypotheses, unverified)

1. **Mac focus changes during X grabs aren't blocked.** Our cross-
   NSWindow drag tracker uses `NSEvent.addLocalMonitorForEvents` to
   intercept pointer events during a grab — but a mouseDown on a
   different NSWindow that AppKit treats as a "click to focus" may
   still fire `windowDidBecomeKey` on that other window, transferring
   key focus even though the X grab is active. The X client thinks
   it owns input; AppKit has moved on. Result: user CAN click the
   command window during a modal, and from there open a second
   dialog.

2. **Grab-stack accounting bug.** Once two grabs are nested and a
   single Ungrab arrives, our state tracking may be releasing the
   bottom grab too (or vice versa). The "both dismissed" symptom
   smells like a stack confusion, not just a single missing block.

3. **WM_TRANSIENT_FOR isn't being honored at the NSWindow level.**
   On macOS, transient dialogs should attach to their parent via
   `NSWindow.addChildWindow(_:ordered:)` so they follow the parent
   in Spaces, minimize together, and stack correctly. We don't do
   this today (it's on the punch list from earlier — #11
   "TRANSIENT_FOR → NSPanel"). The "both dismiss" might be a
   consequence of the transient relationship not being honored;
   when one X-window destroys, AppKit doesn't keep the other in
   the right state.

## What to read before writing code

Authoritative sources in the project tree:

- `reference/motif/lib/Xt/Shell.c` — XtAddGrab / XtRemoveGrab impl.
  Look for how grab stacking is supposed to work.
- `reference/X11R6/xc/lib/X11/Grab.c` — the Xlib grab path.
- `reference/X11R6/xc/programs/mwm/` — mwm's window-manager-side
  handling of grab events and modal dialogs (e.g. WmFunction.c,
  WmWinList.c).
- ICCCM §4.1.2.6 (WM_TRANSIENT_FOR) — what the WM is supposed to do
  with the property.
- Memory `reference_implicit_grab_replaced_by_explicit.md` for the
  XGrabPointer / implicit-grab interaction we already fixed.

## What Todd can check against the Sun

1. Run quickplot on u5 (or any Sun-mwm setup) and confirm: when the
   file-picker is up, clicking the command window does nothing.
2. Try to make a click reach the command window via Ctrl-clicks, etc.
   — confirm mwm really does block all input from other windows of
   the same app.
3. If clicking IS allowed (i.e. modal isn't enforced on Sun either),
   the bug shape changes — it's just "two grabs nested, one ungrab
   shouldn't drop both."

## What to do next

1. Read mwm / Xt grab handling in `reference/`. Pin down the
   semantics in a few sentences before touching code.
2. Verify Todd's expected behavior on real Sun if practical.
3. Pick the fix shape based on what mwm actually does:
   - If mwm strictly blocks foreign-window clicks during a grab → we
     need an NSEvent monitor that prevents `makeKeyAndOrderFront` on
     other NSWindows of the same app while an X grab is active.
   - If mwm allows the click but our grab-stack code is broken →
     audit the GrabPointer/UngrabPointer handler in ServerSession.
   - If WM_TRANSIENT_FOR + child-window relationship is missing →
     wire `addChildWindow` and the "both dismiss" symptom may
     resolve itself naturally.
4. Write tests against whichever fix lands. Geometry test was easy;
   grab-stack tests will need a session-driving scaffolding.

## Why this isn't a quick fix

Three things converge:
- Modal semantics in X11 (XtAddGrab → XGrabPointer/Keyboard)
- Mac native focus model (NSWindow click-to-focus)
- WM_TRANSIENT_FOR child-window relationships

Each has its own subtleties; together they need a coherent approach
or we risk papering over one symptom and creating two more (see also
`CHROME_NOTES_2026-06-13.md` for an example of that exact failure mode
on chrome sizing).
