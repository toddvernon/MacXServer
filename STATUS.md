# Status 2026-06-26 (session 5)

## Headline: the SPARCstation serial console is now a real interactive terminal

The whole session was one arc: turn the captive-VM serial console from a
read-only teletype into an interactive vt100 terminal, then iterate it to
genuinely usable. cm (Todd's editor) and vi work in it. Decision + scope live
in `CONSOLE_TERMINAL.md` and `DECISIONS.md` (2026-06-26).

## What's working

- **Interactive console terminal.** Vendored libvterm (`Sources/CVTerm`, MIT,
  built from source) + `TerminalEmulator` and `TerminalView` in
  SwiftXServerCore, hosted in `SparcPlugConsoleWindowController` where the old
  `AttributedString` teletype was. vt100, 16-color + bold/underline/reverse,
  block cursor, cursor-hide. Input both directions (keystrokes out, terminal
  query replies on feed so cm's `resize` doesn't hang). Dirty-rect + coalesced
  rendering (a `top` repaint was ~5s of full-grid rebuilds; now one rebuild per
  runloop turn).
- **Console speed: `ttya-mode=115200`** (was the 9600 default). The ~5s `ls`/
  `top` was the console baud, not our rendering (proven by Todd's
  `/usr/bin/time` test: 0 CPU, 5s wall, `ls` blocking = baud-limited tty). The
  emulated escc does no real bit-timing, so 115200 runs clean even though it's
  above the real zs 38400 max.
- **Resizable.** Grid follows the window (`reflowToFit` + `vterm_set_size`).
  Guest tty winsize synced **manually** via the **Resize TTY** button (auto-
  injecting `stty` corrupts editors). Button goes blue when out of sync.
- **Guest auto-setup at login** (SPARCplug `8e315d3`, applied live + verified):
  root and tvernon get `TERM=vt100` on `/dev/console` and `DISPLAY=10.0.2.2:0`
  on every login. No Set Up Terminal step needed.
- **Buttons:** **xterm** (launches a guest xterm via Helios `run_command`,
  DISPLAY 10.0.2.2:0) and **Resize TTY**, both `.disabled(!ready)` so they're
  live only after boot. Header shows "115200 baud". Shut Down / Force Quit
  unchanged.
- **Ctrl+Right VT Fonts menu fixed** (was our copy/paste override swallowing
  button 3; now gated on `!ctrlHeld`). Ctrl+Left works. Both verified live.
- Full suite **1435 tests, 0 failures**; SwiftPM + Xcode app build clean.

## Known rough edges

- **nano "level 12 not serviced" (accepted).** nano's single giant-`write()`
  screen redraw storms the FIFO-less emulated zs (one interrupt per byte, no
  gaps) and Solaris logs unclaimed level-12 (serial IPL) interrupts that pollute
  the console. NOT the baud (38400 does it too). cm/vi are chunked and don't
  trip it. Real fix = patch the escc IUS emulation in vendored qemu (deep,
  deferred). See the STATUS history / `45eec74`.

## What's next (v1 odds-and-ends)

- Scrollback (`sb_pushline`).
- cm alt-screen: cm uses the old `?47`, unhandled by libvterm 0.3.3 -> a
  vendored `47->1047` patch in `Sources/CVTerm/state.c` if cm's alt-screen
  matters (recorded in `VENDOR.md`).
- Reconcile terminal point-size / scaleFactor with `FontResolver` /
  `XTERM_FONT_QUALITY` so the console matches the server text-quality bar.
- Prune the now-unused `ConsoleSanitizer` (still feeds the String marker path in
  `QemuEngine.ingest`).
- **Carryover from session 4 (untouched this session):** the xterm ctrl-button
  **menu-orphan** -- needs a capture that runs *past* the ButtonRelease to
  confirm whether the menu window (`0x440002B`) is genuinely left mapped. Prime
  suspect is grab-release Enter/Leave delivery.

## What's committed (recent; all pushed)

- `~/dev/X`:
  - `dbeac10` console buttons: drop Set Up Terminal, add xterm, gate on ready.
  - `839e42c` quick wins (baud in header, no launch-blue button, kill console
    spam). `e1c69a1` blue Resize-TTY-when-stale. `e37acb2` manual Resize TTY.
  - `aa72d4a` resizable grid. `a09130f` lock in 115200. `2fbd7dd` coalesced
    rendering. `a9af169` terminal-query replies on feed. `dea9d62` wire the
    terminal into the console window. `4830555` vendor libvterm + spike.
  - `295d223` Ctrl+Right VT Fonts fix. `306a35a` launcher seed helios-port doc.
- `~/dev/SPARCplug`:
  - `8e315d3` baseline-config section 9: console DISPLAY + TERM=vt100 at login.

## Switching to the other Mac

- **VM is RUNNING** with an image lock (`SUN40G.qcow2.macxserver-lock`). If you
  open the other Mac it'll see `remoteLocked` until this one's VM is shut down.
  Shut it down cleanly here first if you're switching.
- The SPARCplug `8e315d3` guest change was also applied LIVE to the running
  image (persists in the qcow2), so a fresh boot already has TERM/DISPLAY set.
- Let Dropbox finish syncing the memory dir + cx tree before opening the other
  Mac.
- `/sos` first over there -- it'll pull X + SPARCplug.

## Pointers

- Console terminal: `Sources/CVTerm/` (vendored libvterm + `VENDOR.md`),
  `TerminalEmulator.swift`, `TerminalView.swift` (SwiftXServerCore),
  `SparcPlugConsoleWindowController.swift` (SwiftXServer), `CONSOLE_TERMINAL.md`.
- Console plumbing: `QemuEngine` (`onConsoleData`, `sendConsole`, `launchXterm`,
  readiness via Helios `hello`), `SerialConsoleClient` (now bidirectional).
- Guest config: `~/dev/SPARCplug/guest/sparcstation-baseline-config.sh` (sect 9).
