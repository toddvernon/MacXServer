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

Edit `connection.json` in the project root:

```json
{
  "listen": ":6000",
  "forward": "ss2:6000",
  "output": "captures/<app>-running-on-<client>-display-on-ss2.xtap"
}
```

Then `./run-all.sh` from the project root. Since `forward` is non-local,
the script skips starting `swiftx-server` and just runs the capture proxy
between the client and the target server.

From the client host (set `DISPLAY=<mac>:0.0` where `<mac>` is your Mac's
hostname or IP), launch the app, exercise it briefly, quit. Stop the
proxy with Ctrl-C. Move to the next app.

## Archive

`archive/` holds pre-2026-05-17 captures of mixed and now-unknown
provenance (variously captured against u5 or SS2 in different sessions
with the older `-sun.xtap` naming). Kept for historical reference only;
not used by tests.

## Current gold set

| App | Capture | Notes |
|-----|---------|-------|
| xeyes | `xeyes-running-on-ss2-display-on-ss2.xtap` | basic, short |
| xclock | `xclock-running-on-ss2-display-on-ss2.xtap` | basic, short |
| xterm | `xterm-running-on-ss2-display-on-ss2.xtap` | basic, short |
| xcalc | `xcalc-running-on-ss2-display-on-ss2.xtap` | Athena widget set |
| xfontsel | `xfontsel-running-on-ss2-display-on-ss2.xtap` | font list + ListFonts coverage |
| dtcalc | `dtcalc-running-on-u5-display-on-ss2.xtap` | CDE app, Motif |
| dtterm | `dtterm-running-on-u5-display-on-ss2.xtap` | CDE app, Motif text widget |
| dtfile | `dtfile-running-on-u5-display-on-ss2.xtap` | CDE app, file browser |
| dthelpview | `dthelpview-running-on-u5-display-on-ss2.xtap` | CDE app, help viewer |
| dticon | `dticon-running-on-u5-display-on-ss2.xtap` | PARTIAL — ToolTalk timeout through proxy |
| dtmail | `dtmail-running-on-u5-display-on-ss2.xtap` | PARTIAL — same |
| dtpad | `dtpad-running-on-u5-display-on-ss2.xtap` | PARTIAL — same |
| quickplot | `quickplot-running-on-u5-display-on-ss2.xtap` | Motif, plotting |

The PARTIAL captures stop short of clean app exit (apps hung on ToolTalk
and were terminated). Their initial-setup bytes are valid X11 and serve
as replay test fixtures for the boot sequence.
