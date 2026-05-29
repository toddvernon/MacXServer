# Captures

Wire-byte recordings of real X clients talking to real X servers, used as
gold reference fixtures for `swiftx-server` development and regression
testing.

## File naming

```
<app>-running-on-<client-host>-display-on-<server-host>.xtap
```

Verbose but unambiguous — at a glance you know exactly which binary was
run, where it ran, and which X server it was talking to. The `.xtap.json`
sidecar holds capture metadata (tool version, timestamp, byte counts).

Examples:
- `dtcalc-running-on-u5-display-on-ss2.xtap` — u5's `/usr/dt/bin/dtcalc`
  binary, running on u5, with `DISPLAY=mac:0` going through our capture
  proxy to SS2's X server.
- `xterm-running-on-ss2-display-on-ss2.xtap` — SS2's xterm binary,
  running on SS2, talking to the local SS2 X server (still going through
  the capture proxy so we get the recording).

## Hosts

- **ss2** = SS2 vintage Sun workstation running SunOS 4.1.4 + the
  X Consortium R6 sample X server + Motif Window Manager (MWM, 3rd-party
  Open Software Foundation addon). No CDE. No xrdb-loaded RESOURCE_MANAGER
  (zero bytes). No ToolTalk session daemon. MWM does pre-set a few atoms
  on root: `_MOTIF_WM_INFO`, `_MOTIF_DRAG_WINDOW`, `_MOTIF_DEFAULT_BINDINGS`.
- **u5** = u5 vintage Sun workstation running Solaris 2.6 + CDE (Common
  Desktop Environment) + Sun's branded Xsun. `dtsession` populates a 3910-
  byte RESOURCE_MANAGER on root. `ttsession` (ToolTalk) running. CDE owns
  the `Customize Data:0` selection. Full CDE environment.
- **swiftx** = our Swift X server (`./run-server.sh`). For `dtcalc-swiftx-*.xtap`
  files, see directly the v1/v2 generation tags — those are ad-hoc
  comparison fixtures, not part of the gold baseline.

## Why SS2 is the gold reference (not u5)

The reason for the 2026-05-17 re-baseline: u5 captures conflate "what
the X server does" with "what CDE adds on top." Our server isn't
CDE-aware (and shouldn't be — CDE is a vendor-specific desktop env,
not a property of the X11 protocol). Testing against u5 led us to bake
CDE-specific compatibility into the server (RESOURCE_MANAGER fixture,
SelectionMediator daemon impersonation, `SDT Pixel Set` hardcoded bytes)
to match behaviors that aren't actually X protocol requirements.

SS2+MWM is the simplest spec-compliant baseline we have access to —
X Consortium R6 sample server, MWM as the only environment, no CDE.
A capture against SS2 shows what dt-apps and classic X apps actually
need from an X server, separately from what they need from a full
desktop environment.

What we learned from the re-baseline:
- Dt-apps boot fine against SS2 with empty RESOURCE_MANAGER — they have
  hard-coded Motif defaults (light blue background, white text) and use
  those when no resources are loaded.
- Dt-apps DO issue `ConvertSelection(Customize Data:0)` against SS2, but
  SS2 just replies `SelectionNotify(property=None)` in spec-correct
  fashion and the apps continue. The wedge we worked around with the
  daemon impersonation was specific to our server's handling, not a
  generic dt-app requirement.
- Some dt-apps (`dticon`, `dtmail`, `dtpad`) hang on ToolTalk timeout
  (~5min) when run through our `swiftx-capture` proxy — but they run
  fine direct u5→ss2 without the proxy. That's a proxy-layer bug, not
  a server-layer bug.

  The Motif dialog these apps pop up reads `/usr/dt/bin/ttsession is
  not running`. SS2 has no `ttsession` either way, and the same apps
  tolerate that direct — so the proxy is doing something specifically
  bad to ToolTalk-using sessions. Hypothesis: the framer has a partial
  decoder for some opcode (the summary line "1 with no typed decoder"
  we saw in early captures) and the proxy either drops, mangles, or
  stalls on it; or proxy buffering breaks TT's timing-sensitive
  selection roundtrips. Diagnostic: enable per-byte forwarding traces
  in `swiftx-capture` and watch for the byte position where forwarding
  diverges from a `tcpdump`-baselined direct run. Bug lives in
  `Sources/SwiftXCaptureCore/Proxy.swift`, not in the server.

## Recapturing

Use **macXcapture** (the GUI wizard) — point the client's `DISPLAY` at this
Mac on port 6000/6001, forward to the real X server, name the capture, hit
Start. Files land in `/tmp/swift-x-captures/` with the wizard's naming;
move them into this directory with the convention above.

For `display-on-swiftx` captures we let **macXserver** itself record each
session it serves — it writes a `.xtap` per X client connection with an
autoname (the app name from `WM_CLASS`, or `unidentified-<N>` when we
can't tell). Rename those to the `<app>-running-on-<src>-display-on-swiftx.xtap`
form when promoting to gold.

## Current gold set

The ss2→ss2 batch (2026-05-29) covers every X client we've found on the SS2
disk that exposes a useful surface. Per-app working/broken status is in the
**App status** section below; each app has one or both of:

- `<app>-running-on-ss2-display-on-ss2.xtap` — macXcapture proxy between ss2
  client and ss2's real X server (the gold reference).
- `<app>-running-on-ss2-display-on-swiftx.xtap` — macXserver's own recording
  of the same client running against our server (the comparison baseline).

The u5/CDE apps (`dtcalc`, `dtterm`, `dtfile`, `dthelpview`, `dticon`,
`dtmail`, `dtpad`) and `quickplot` are **pending u5 recapture** — their
captures were wiped in this rebaseline and need to be re-recorded from u5
before the replay tests that depended on them can come back.

## App status (2026-05-29 batch)

Direct from `/tmp/swift-x-captures/notes` at capture time. "ss2" means
ss2→ss2 (gold), "swiftx" means ss2→macXserver.

| App | ss2 | swiftx | Notes |
|-----|-----|--------|-------|
| auto_box   | works | (no capture) | phigs not in framer, proxy can't capture |
| beach_ball | works | (no capture) | phigs not in framer, proxy can't capture |
| bitmap     | works | works | menus turn white on drag (minor) |
| dogs       | works | works | |
| editres    | works | LOCKS UP | hangs on macXserver when clicking a widget for its tree |
| fileview   | works | works | |
| ico        | works | works | |
| maze       | works | works | |
| motifanim  | works | partial | can't see dog bitmap on macXserver, likely bitmap-loading issue |
| motifbur   | works | works | |
| motifshell | works | works | |
| periodic   | works | works | |
| puzzle     | works | BROKEN | fails on opcode 57 (X_CopyGC) — recurring missing-op signature |
| textedit   | works | BROKEN | "BaseFrom not passed parent window in environment, unable to create window" at startup |
| viewres    | works | works | |
| xev        | works | works | |
| xfontsel   | works | works | |
| xgas       | works | works | |
| xgc        | works | works | |
| xlogo      | works | works | |
| xlsatoms   | works | works | |
| xlsclients | works | SILENT | silent on macXserver — likely missing opcode dropped silently |
| xmag       | works | BROKEN | no mag window on macXserver — likely missing opcode |
| xmeditor   | works | works | |
| xmforc     | works | works | |
| xmmap      | works | partial | scroll smears all the redraws on macXserver |
| xmpiano    | works | BROKEN | fails on opcode 103 (X_GetKeyboardControl) |
| xmtr       | works | partial | on ss2 no menu bar (we show one); on macXserver just a round window, no animations |
| xprop      | works | HANGS | hangs on macXserver |
| xterm      | works | works* | *rogue popup that survives reparent — black window persists after xterm exits |
| xwininfo   | works | works | |

The `xterm-running-on-ss2-display-on-swiftx.xtap` capture in this batch is
intentionally the **later** of two runs because it contains the rogue
reparent-survivor popup.

There are also `unidentified-N-running-on-ss2-display-on-swiftx.xtap`
captures from the macXserver side where the connection's `WM_CLASS` didn't
resolve to a known app. They're kept as-is; figure out which app each one
is when chasing the bug it documents (or just recapture with a known
client).
