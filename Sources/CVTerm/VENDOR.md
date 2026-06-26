# CVTerm -- vendored libvterm

This directory is a **vendored copy** of libvterm, the terminal-emulator
state machine that backs Vim's and Neovim's `:terminal`. We compile it from
source into our own binary as a SwiftPM C target (`CVTerm`); it is not a
fetched package, not a prebuilt `.a`/`.dylib`, and not a separate
executable. See `DECISIONS.md` (2026-06-26) and `CONSOLE_TERMINAL.md` for
why this and not SwiftTerm / a port of xterm.

## Provenance

- **Upstream**: libvterm by Paul "LeoNerd" Evans
  <https://www.leonerd.org.uk/code/libvterm/>
- **Version**: 0.3.3
- **License**: MIT (see `LICENSE` in this directory)
- **Imported**: 2026-06-26

## What we took, and the layout

SwiftPM C-target convention:

- `include/` -- the two public headers (`vterm.h`, `vterm_keycodes.h`).
  SwiftPM puts these on the module's header search path, so Swift sees
  `import CVTerm` and dependents `#include` them.
- target root -- the `.c` sources plus the private headers
  (`vterm_internal.h`, `utf8.h`, `rect.h`) and the pre-generated tables
  (`fullwidth.inc`, `encoding/*.inc`). The release ships these tables
  generated, so there is **no build-time codegen**.

## Local modifications

**None.** This is an unmodified 0.3.3 source drop. If we ever need to patch
it, record the change here (what + why) so the next update can re-apply or
retire it.

## Updating

Deliberate, manual, never automatic:

1. Download the new release tarball from the upstream URL above.
2. Re-copy `include/*.h`, `src/*.c`, the private headers, and the `.inc`
   tables into the same layout.
3. Bump the version + import date above; re-apply any local modifications
   and update that section.
4. Build + run the terminal tests.
