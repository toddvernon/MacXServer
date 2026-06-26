# CONSOLE_TERMINAL.md

The SPARCplug serial console is currently a teletype, not a terminal. This
doc scopes turning it into a real interactive terminal so a user can run
`vi`, `top`, `format`, and other curses/full-screen tools when the
graphical path isn't available.

Status: **scoped, no code yet** (2026-06-26). The dependency choice is
recorded in `DECISIONS.md` (2026-06-26). Read that entry for *why
libvterm and not SwiftTerm or a port of xterm*; this doc is the *what and
how* of v1.

## Why this matters

We already run a high-quality xterm over X. But the console channel is the
out-of-band path you need exactly when X or networking is the thing that's
broken: the PROM `ok` prompt, boot messages, single-user mode, an `fsck`
or `format` prompt, a botched network config. Now that VM control no longer
*relies* on the console for anything (Helios drives the guest, QMP drives
the VM -- see `VM_CONTROL.md`), the console is free to become a
first-class interactive surface for the user, in service of the
guided-repair story (Helios C6).

The blocker is terminal emulation. The current console
(`SparcPlugConsoleWindowController.swift`) accumulates an `AttributedString`
line buffer, handling `\n`/`\r` and passing other bytes through
`ConsoleSanitizer` -- which documents its own limitation in its header
comment: "there is no screen grid, no cursor addressing, no attributes."
When `vi` sends `ESC[2J ESC[H` you'd see the literal bytes as garbage. So
this is a replace of the rendering/model, not a patch.

## The split

The job has two halves:

1. **Emulator state machine** -- parse the escape-sequence stream into an
   80x24 grid of cells (each with character + attributes), a cursor, and a
   scroll region. This is the part that's a 30-year tar-pit to get right by
   hand, so we don't: we vendor **libvterm** (the `:terminal` backend
   shipped in Vim and Neovim).
2. **Rendering** -- draw that grid. We already own a great answer to this:
   `FontResolver` plus the `XTERM_FONT_QUALITY.md` discipline (CTFont,
   integer pointSize, reported-cell === rendered-cell). v1 reuses those
   *metric rules* but writes a *new* grid-draw routine, because the
   existing glyph drawing is welded to the X draw-op path
   (`ImageText8` / GC / drawable in `CocoaWindowBridge`) and can't be
   called standalone.

## Architecture -- four pieces

1. **`CVTerm`** -- vendor the libvterm release source as a C target in the
   Swift package, built from source. The release tarball ships the
   pre-generated encoding tables, so there's no build-time codegen. Links
   into our existing binary as object code: no separate executable, no
   separate signing, no AMFI helper-kill surface, no new entitlements
   (libvterm does no I/O of its own -- it's pure computation on byte
   buffers; we own the socket).

   **Vendoring posture** (same as the bundled qemu): we copy libvterm's C
   source *into the tree* and compile it ourselves -- nothing is fetched at
   build time, nothing links against a prebuilt `.a`/`.dylib`, nothing the
   user's machine has to have. The accurate framing is **zero external /
   runtime dependencies, one vendored third-party source we own**. What
   that implies:
   - We own the copy: it's ours to read, patch, and freeze; it can't drift
     from upstream or disappear.
   - Keep the MIT `LICENSE` alongside the vendored source.
   - Updates are a deliberate manual copy-in, never an automatic bump.
   - The "understand the stack" obligation still applies: it's a handful of
     C files, small enough to actually read, not treat as a black box.
     That's the line between vendoring and depending. (The
     external-dependency option was SwiftTerm-via-SwiftPM, which is part of
     why we passed on it.)

2. **`TerminalEmulator`** (Swift wrapper around libvterm) -- owns the
   `VTerm` / `VTermScreen`. `feed(_ data: Data)` -> `vterm_input_write`.
   Screen callbacks (damage, movecursor, settermprop, bell, `sb_pushline`
   for scrollback) update a Swift-side cell-grid model. Key/text input ->
   `vterm_keyboard_unichar` / `vterm_keyboard_key`, whose output bytes come
   back via `vterm_output_set_callback` and get written to the socket.
   libvterm tracks DECCKM and friends internally, so arrow keys encode
   correctly (`ESC[A` vs `ESC O A`) for free.

3. **`TerminalView`** (NSView) -- renders the cell grid using
   `FontResolver`'s cell metrics and the `XTERM_FONT_QUALITY` rules (the
   new draw routine), draws the block cursor, and handles
   `keyDown` / `insertText`, translating to `TerminalEmulator` input.

4. **Rewire `SparcPlugConsoleWindowController`** -- host `TerminalView`
   instead of the `AttributedString` text view. Wire
   `SerialConsoleClient.onData` -> `emulator.feed` and `emulator.output` ->
   `SerialConsoleClient.write`. Retire the `ConsoleSanitizer` + line-buffer
   path (the emulator subsumes it).

## Settled v1 parameters

- **Emulate vt100, set `TERM=vt100`.** vt100 terminfo is guaranteed present
  on Solaris 2.6 (`/usr/share/lib/terminfo/v/vt100`); the guest then emits
  the conservative vt100 set and libvterm (a superset) renders it. Smallest
  reliable target, and `vi` is perfectly happy on vt100. (xterm terminfo
  may not be in the base 2.6 install -- don't depend on it.)
- **Fixed 80x24.** No resize in v1. Resize is v1.1 because it requires
  pushing a new `stty rows/columns` to the guest on every size change; a
  serial line carries no `SIGWINCH`/winsize ioctl negotiation, so the guest
  only knows the size we tell it via `stty`.
- **Bounded scrollback (~1000 lines)** via `sb_pushline`. The current
  append-only console lets you scroll back through boot output; a fixed
  24-line screen with no history would be a regression, so v1 keeps a
  ring-buffer scrollback.
- **16 ANSI colors + attributes** (bold, reverse, underline) + default
  fg/bg. 256-color / truecolor mapped down best-effort. Solaris console
  apps lean on reverse-video and bold, not color, so this is low-risk.
- **"Send terminal setup" affordance** -- one action types
  `TERM=vt100; export TERM; stty rows 24 columns 80\n`. The emulator
  renders plain text fine at the `ok` prompt and during boot regardless;
  this is only for when you drop to a shell and want a full-screen app.
  (We can't force the guest's environment, so this is a convenience, not an
  automatic handshake -- detecting a shell prompt to auto-fire it is too
  fragile for v1.)
- **Input mapping.** Letters/digits/punctuation ->
  `vterm_keyboard_unichar`. Arrows / function keys / Enter / Backspace /
  Tab / Esc / Home / End / PgUp / PgDn / Delete -> `vterm_keyboard_key`.
  NSEvent `modifierFlags` -> `VTermModifier` (ctrl/shift/alt). Option as
  Meta (ESC prefix) on by default.

## Explicitly NOT in v1

Resize, mouse reporting, sixel/graphics, select-to-copy (v1.1), truecolor
fidelity, tabs/splits. None of these are needed to run `vi` on a recovery
console.

## Success metric

Open a file in `vi` over the console, navigate with `hjkl` and the arrow
keys, insert text, `:wq` -- clean render throughout, correct cursor, no
escape-byte garbage. Stretch: `top` and the interactive `format` / `fsck`
screens render correctly.

## Notes / risks

- **Threading.** `SerialConsoleClient` reads off its own queue; marshal
  `onData` to the main thread before driving the emulator/view. The
  emulator and view are main-thread-only.
- **Renderer reuse is metrics-only.** We reuse `FontResolver` and the
  `XTERM_FONT_QUALITY` cell rules, but the actual Core Text drawing of the
  grid is new code, because the existing path draws via X drawables/GCs.
  This is the bulk of the v1 effort and the one place to be careful about
  honoring the reported-cell === rendered-cell invariant.
- **libvterm build on macOS arm64** is plain C with no dependencies; vendor
  the release source (with its pre-generated `encoding/*.inc` tables) and
  it should compile clean as a SwiftPM C target.
- **Real-iron note.** This is the captive-emulator console. A real SS-5's
  serial console would work the same on our side (the emulator is
  transport-agnostic), but the `stty`/`TERM` setup convenience assumes a
  reachable shell.

## Effort estimate

libvterm vendor + `TerminalEmulator` wrapper ~2 days; the `TerminalView`
grid renderer is the bulk (~2-3 days -- we own the metric rules but write
fresh Core Text drawing + cursor + input); wiring +
`SparcPlugConsoleWindowController` rework + the setup affordance ~1 day.
About a week to the `vi` success metric.
