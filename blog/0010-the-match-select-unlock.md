# Post 10: The MATCH_SELECT unlock

**Date range**: May 10, 2026 **One-line elevator**: Five CDE Motif apps that wouldn't even render, plus a
quickplot dead-end I'd already parked. All three blocked by a single bug hiding in Xt's selection-event
handler in the X11R6 source. The fix is three lines. Finding it took reading the source.

## What this post covers

The dt-app saga. Building a fake CDE customization daemon. The discovery of the time-field bug in Xt's
selection handling. The cascading unlock: dt-apps boot, then quickplot turns out to work too. Reflection on
the moment, on AI-assisted debugging, and on what a week of focused work looks like.

## Setting

End of day 2026-05-09: quickplot wedges on widget callbacks, every observable opcode-level bug fixed, parked
as an internal-libXm issue. The handoff doc says "no signal to follow, would need symbol-rich Motif
debugging."

Same machine, same setup, the user (me) asks: how about the dt-apps from a CDE session on u5? dtcalc, dtterm,
dthelpview, dticon, dtmail, dtfile. Some had been tried; all either failed to render or rendered partially.

## Thread anchor: protocol vs implementation

This is the post where the protocol-vs-implementation framing pays its biggest dividend. The MATCH_SELECT bug
isn't a swift-x bug in any normal sense. It's a misimplementation of a protocol contract that Xt's
HandleSelectionReplies has assumed since 1989. The contract: SelectionNotify's time field echoes the
ConvertSelection request's time verbatim. Xt has been depending on that contract for thirty-six years. We were
violating it because the source file `reference/X11R6/xc/lib/Xt/Selection.c` is the only place the contract is
written down, and we hadn't read it. The protocol's stability cuts both ways: stable contracts you didn't know
about will bite you exactly as hard as stable contracts you knew about.

## The dt-app investigation

dtcalc was the first target. Launched from a CDE session on u5 with `DISPLAY=mac:0`. Result: silence. Nothing
rendered. Server log showed dtcalc reaching request 86 (ConvertSelection) then nothing. No errors. No further
client requests.

Capture trace showed the chain: dtcalc interns "Customize Data:0", calls GetSelectionOwner (gets None. we
don't have a CDE customization daemon), creates its main window, sets WM properties, calls ConvertSelection on
the unowned selection, receives SelectionNotify(property=None) from our server. Then silence for two minutes.
Then I killed it.

The **gold trace** (a term worth defining the first time it appears: the capture tool can record either
Sun-to-Sun traffic, where a real Sun client talks to a real Xsun server, or Sun-to-swiftx traffic, where it
talks to ours. The Sun-to-Sun capture is "gold" because it's the authoritative reference for what the
protocol should look like end-to-end. Every diagnostic in this series boils down to "what does gold do here
that we don't?" and the corpus has paired captures for every app we've tested.) The gold trace for dtcalc
showed a different path. The customization daemon (dtsession or similar) owns Customize Data:0 in a real CDE
session. dtcalc reads the property directly from the daemon's window, gets the SDT Pixel Set palette
manifest, proceeds.

So in gold, dtcalc takes the direct-property-read path. In our case, it falls to the formal ConvertSelection
fallback. We answer with property=None per spec. Then dtcalc hangs.

## Building a fake customization daemon

First fix: impersonate the daemon. Register a server-internal stub window (`0xFFFE_0003`) as the owner of
Customize Data:0. Pre-publish the SDT Pixel Set property on that window with the exact 94-byte ASCII string
captured from u5's real daemon
(`2_4_8_6_7_5_9_d_b_c_a_e_12_10_11_f_13_17_15_16_14_9_d_b_c_a_9_d_b_c_a_e_12_10_11_f_9_d_b_c_a_1`).

Short-circuit ConvertSelection: if the selection is owned by a window in our internal range, write empty bytes
to the requestor's property and emit SelectionNotify(property=success).

Tried it. dtcalc still hung.

## The trace dive

dtcalc's behavior after my fix: GetSelectionOwner returned our daemon, dtcalc interned "SDT Pixel Set" with
only-if-exists which returned None (we hadn't pre-interned the atom), dtcalc skipped the direct-property-read
path and fell through to the formal ConvertSelection. We short-circuited with
SelectionNotify(property=_XT_SELECTION_0). dtcalc... did nothing.

The SelectionNotify went out correctly per a binary check of the capture: seq=87, time=337ms,
requestor=0x4400001, selection=Customize Data:0, target=Pixel Sets, property=_XT_SELECTION_0. Byte-perfect.

So dtcalc/Xt received our SelectionNotify and did nothing. The followup GetProperty that Xt's `HandleNormal`
should do after SelectionNotify(success) never fired.

Time to read the X11R6 source.

## The bug

`reference/X11R6/xc/lib/Xt/Selection.c:1357` `HandleSelectionReplies` uses `MATCH_SELECT` to decide whether a
SelectionNotify is "for us." `MATCH_SELECT` is in `SelectionI.h:165`:

```c
#define MATCH_SELECT(event, info) ((event->time == info->time) && \
    (event->requestor == XtWindow(info->widget)) && \
    (event->selection == info->ctx->selection) && \
    (event->target == *info->target))
```

All four fields must match. Three are obvious (requestor, selection, target). The fourth is the gotcha:
`event->time == info->time`.

Xt's `info->time` is the value it put in the ConvertSelection request, which is typically `CurrentTime` (which
is 0). The X spec says the server should echo this time back verbatim on SelectionNotify. We were substituting
`serverTime` (a non-zero millisecond value) when `r.time == 0`, because there's a separate code path that
needed that substitution for *server-generated* events like ButtonPress (where time=0 confuses some clients
into thinking events are duplicates).

So when dtcalc fired ConvertSelection with time=0:
- Xt stored `info->time = 0`
- We replied with `event->time = serverTime` (some non-zero ms value)
- `0 == 337` is false
- MATCH_SELECT returned false
- Xt silently dropped the event with "not really for us" comment in the source
- dtcalc waited forever for a reply that already arrived but had been thrown away

The fix: three lines. Remove the `r.time == 0 ? serverTime : r.time` substitution on the selection-event
paths. Use `r.time` verbatim.

Build, test, ship.

## The cascade

After the MATCH_SELECT fix:
- dtcalc renders (panels in CDE grey, LCD shows "0.00", mouse hover registers)
- dtterm renders
- dthelpview renders
- dticon renders

The CDE palette I'd guessed at (pixels 1-23 with approximations of the CDE Default scheme) was the missing
piece. without it, the dt-apps had their windows rendering all-black (the pixel-to-RGB lookup fell back to
black for unknown pixels in the SDT Pixel Set manifest).

Then I tried quickplot. The widget that I'd parked the previous day as a Motif-internal dead-end. It worked.
Menus posted, dialogs opened, buttons responded, plotting rendered.

The MATCH_SELECT bug had been silently dropping every Xt selection roundtrip in any toolkit. quickplot's
widget callbacks were waiting on a selection conversion they never got. The same bug.

## Reflection

Five days of work. Two real foundation bugs found this week (the ChangeGC merge-vs-concat bug in xterm color,
and MATCH_SELECT). Five CDE apps that wouldn't even render now boot and accept input. Quickplot, which I'd
parked as "internal libXm bug," fully functional.

The "rule out everything observable, conclude it must be internal" framing on 2026-05-09 turned out to be
wrong. The bug WAS observable. I just hadn't read the right source file.

Reading `reference/X11R6/xc/lib/Xt/Selection.c` was what found the bug. Not theorizing about what Motif might
want. Not adding speculative protocol features. Reading the source code of the actual client-side library that
the dtcalc binary was linked against.

The bug had probably been latent in our server since M1. Every Xt-based selection roundtrip using
`CurrentTime` was silently failing. We just didn't notice because the simple clients we'd been testing don't
do much selection work at init.

## Where the project is

A working X server. Five days of code. xterm, xcalc, xclock, xeyes, xfontsel, quickplot, dtcalc, dtterm,
dthelpview, dticon all functional from a real Sun workstation. Cosmetic issues remain (button widget chrome on
dt-apps not redrawing, menu placement, text widget spacing, the idle 6-request poll loop in quickplot).
Substantial gaps remain (real visibility tracking, XErrors emission, more extensions). The foundation is
sound.

The next week I'm away from the vintage workstation collection so live testing isn't an option. The plan:
foundation work (visibility tracking, backing-store advertise), tooling (capture-diff tool, regression test
coverage), tech debt (XErrors, the selection-mediator refactor). All unit-testable without hardware. The
post-week live session arrives with a stronger foundation.

## What Todd should add

- The detective-story arc. The trace, the discovery, the source-read.

TODD: trace is important, there just isn't enough docs to do this without watching real apps interact with real servers.

- The "I parked it" → "it actually works" moment for quickplot. That's a real emotional beat.

TODD: i thought, fuck we aren't going to get there

- AI-assistance reflection. The pattern of working with Claude across this week: where I had to push back,
  where it had to push back, where the partnership found things neither side would have alone.

TODD: it was real.  We disagreed on direction and would shift back and forth.  In fact i brought in parts
to the CHARGPT and generated docs for claude to consider (this was on the font and scaling)

- The "it had been there since M1" realization. Every Xt selection roundtrip with CurrentTime had been
  silently failing the whole week, on every client that exercised one. The three-line fix unblocked dt-apps
  and quickplot at the same time, plus whatever future Xt-based selections we hadn't encountered yet.

TODD: kind of maddning as its time based, the time field is there for a reason, why did we miss this. An honest
problem of working with ai is its so fast you can't grok every iteration you might make, you are working at
a higher management level.

- The honest scorecard. What's still wrong. What I'm proud of. What I'd do differently.

TODD: quickplot mostly works, on the downside the problems that remain are Xm problems.  We have no source on
that so no fallback when we get stuck.  On the plus side they are pretty small relative to NOT TAKING INPUT.

- The closing reflection: five days, working X server, with a Sun on one end and a Mac on the other. The thing
  that motivated the whole project actually works.

This can work.  its going to be more work and we will likely never be done.  Shoud capture be part of
the xserver itself?  If we release this to the world the world needs to provide captures back?

## Anchors for fact-check pass

- Files: `INVESTIGATION_MOTIF_INPUT.md` (current state, retest scorecard), `DECISIONS.md` 2026-05-10 entries
  (customization daemon impersonation, dt-button chrome park), `SHORTCUTS.md` (new entries for hardcoded
  palette, hardcoded SDT Pixel Set, fake daemon), `.claude-memory/reference_match_select_time.md`,
  `.claude-memory/project_dt_apps_status.md`, `.claude-memory/project_motif_quickplot_status.md`
- Commits: `36d82d2` 2026-05-10 "Fake CDE customization daemon + SelectionNotify time fix" (the unlock)
- The MATCH_SELECT macro: `reference/X11R6/xc/lib/Xt/SelectionI.h:165`
- Xt's HandleSelectionReplies: `reference/X11R6/xc/lib/Xt/Selection.c:1357`
- The captured gold daemon's SDT Pixel Set bytes: extracted from `captures/dtcalc-sun.xtap` seq=29 reply via
  Python parser
- Forward look: `WHAT_TO_DO_THIS_WEEK.md` for the no-hardware week plan

## Working title alternatives

- "The bug that had been there all along"
- "Five days, one source file"
- "Reading the source"
- "MATCH_SELECT"
