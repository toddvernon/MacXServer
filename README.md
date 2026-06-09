# MacXServer

A modern X11 server in Swift for macOS, plus a capture toolchain for
recording and inspecting X11 wire traffic. Built so I can display X
applications from real vintage Sun workstations on my Mac with proper
modern rendering. The Swift package is internally called `swift-x`.

The project has two pieces: a Swift X server that real X clients
connect to as their display, and a capture utility that records X11
sessions to disk and can replay them. They share a typed Swift wire
decoder (the framer) and a common `.xtap` file format.

## What's here

- `Sources/Framer/` — typed Swift decoders for the X11 core protocol.
  Covers every opcode that any of the captured Sun apps emit, plus
  encoders for the replies the server has to produce.
- `Sources/SwiftXServer/` + `Sources/SwiftXServerCore/` — the X11
  server. Rootless mode: each top-level X window becomes a real
  `NSWindow` with native chrome. Core Text font rendering with
  scalable substitutes for the X11 bitmap fonts the Sun apps ask
  for. Runs xterm, xcalc, xclock, xeyes, twm/mwm, quickplot (a
  Motif graphing app), and CDE's dt-apps (dtcalc, dtterm,
  dthelpview, dtpad, dticon).
- `Sources/SwiftXCapture/` + `Sources/SwiftXCaptureCore/` — the
  capture utility. Single binary, two faces:
  - **CLI**: proxy capture, dump, summary, diff, replay
    subcommands. Backwards-compatible with the v1 tool.
  - **SwiftUI app**: three modes — Record (proxy a session
    interactively with live byte counters and a decoded-opcode
    feed), Open (pick a `.xtap` and browse packet by packet),
    Replay (pipe a `.xtap` into a target server with progress
    bar, cancel button, and hold-open).

  The server can also tee its own sessions to `.xtap` files via
  `--capture` — useful for "hit a bug and email me the file"
  workflows.
- `captures/` — `.xtap` files from real Sun workstations. xterm
  (multiple sessions), xeyes, xclock, xcalc, quickplot, and the
  full CDE dt-app suite.
- `Tests/` — over 1,200 tests across the framer, capture library,
  server core, file format, and end-to-end integration paths.

## Quick start

Build:

```
swift build -c release
```

### Running the server

Start it listening on the default X display port (6000 → display
`:0`):

```
.build/release/macxserver
```

Status menu appears in the menu bar with the listen address and a
Stop Server item. Preferences (⌘,) covers clipboard bridging, font
mappings, and the capture toggle.

Point an X client at it from a real Sun (or anywhere on the LAN):

```
xterm -display <mac-ip>:0
```

### Capture, GUI

```
.build/release/macxcapture
```

Launches a chooser with three modes (Record / Open / Replay).
Defaults to opening files from `/tmp/macxcapture/` so the
server's auto-captures are the obvious choice.

### Capture, CLI

The v1 CLI behavior is preserved. Any subcommand triggers the
CLI; no args launches the GUI. `--no-gui` is also recognised as
an explicit "headless mode" flag for scripts that want CLI
behaviour even with empty args.

```
# proxy two real X endpoints
# (./run.sh + connection.json also still works)
.build/release/macxcapture \
    --listen :6001 \
    --forward sun-b.lan:6000 \
    --output session.xtap

# decoded chronological dump
.build/release/macxcapture dump captures/xterm_long.xtap

# aggregate per-opcode summary
.build/release/macxcapture summary captures/quickplot.xtap

# byte-pump replay into a target server
.build/release/macxcapture replay captures/xterm_long.xtap \
    --target localhost:6000
```

`./run-capture.sh` is a build-and-run wrapper that reads
`connection.json` (`listen` / `forward` / `output`) for proxy
mode and passes any other args straight through to
`macxcapture`. `./run-server.sh` does the same for the
server. `./run-all.sh` starts macxserver + a proxy capture
forwarding into it — used for "capture what swiftx itself
produces" diffing against gold Sun captures.

### Server-side capture

```
.build/release/macxserver --capture
```

Every X client connecting to the server gets its own `.xtap` file
in `/tmp/macxcapture/`, named after the client's `WM_CLASS`
once it identifies itself. The toggle is also available in the
server's Preferences → Capture tab; the CLI flag overrides the
preference. `/tmp` wipes on reboot, so captures don't accumulate
forever.

For bug reports: turn capture on, reproduce the issue, drag the
freshest file out of `/tmp/macxcapture/` into an email.

## Tests

```
swift test
```

## Documentation

The full project context lives in markdown at the repo root:

- `PROJECT.md` — what we're building, the two-product plan,
  explicit non-goals
- `ARCHITECTURE.md` — how the components fit together
- `DECISIONS.md` — architectural choices with reasoning,
  append-only
- `PRODUCT_1_CAPTURE.md` — capture utility: v1 (CLI, done) and v2
  (library + GUI app + server-side capture, in flight)
- `PRODUCT_2_SERVER.md` — X server scope and milestones
- `OPCODE_STATUS.md` — per-opcode implementation status with
  honest confidence ratings
- `SHORTCUTS.md` — known stubs, fakes-on-the-wire, and other
  ledgered tech debt
- `CLAUDE.md` — instructions for collaborator agents

## Status

**Capture utility**: v1 (CLI proxy + framer + corpus + article)
done. v2 (library + SwiftUI app + server-side `--capture`) all
landed except for screenshots and a blog post. Single binary
hosts both faces.

**Swift X server**: M1–M3 green. xterm, xcalc, xeyes, xclock,
twm/mwm, quickplot (Motif), and the CDE dt-apps all run from a
real Ultra 5 against the Mac. Core Text font substitution with
cell-snapping is in. Server-side capture is wired so any client
session lands as a `.xtap` for inspection. See
`PRODUCT_2_SERVER.md` for milestone definitions and
`OPCODE_STATUS.md` / `SHORTCUTS.md` for what's shipped vs
stubbed.

## Requirements

macOS 14 or later and a recent Swift toolchain (Xcode 15+). No other
dependencies.

## Contributing

The most useful contributions are good bug reports with an `.xtap`
capture attached, and captures from X clients I don't have access to.
Code contributions are welcome too. See `CONTRIBUTING.md` for the build,
the capture-a-bug workflow, and the ledger conventions, and
`CODE_OF_CONDUCT.md` for the ground rules.

## License

Apache-2.0. See `LICENSE`. Portions are derived from the X11R6 reference
implementation; those files retain the original X Consortium / Digital
Equipment Corporation notices, summarized in `NOTICE`.
