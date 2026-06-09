# Status 2026-06-09

Two things today: the Motif move-during-menu corruption bug got fixed
end to end (morning), and the source repo went through full
open-source-release prep (afternoon). The repo is Apache-2.0 with
contributor docs and a cleaned history, sitting one step from public.

## Open-source release prep

The repo is ready to publish:

- Apache-2.0 `LICENSE` + `NOTICE`, with the X Consortium / Digital
  Equipment notices retained on the four files ported from X11R6
  (mi/miregion.c, Xext/shape.c).
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, GitHub issue/PR templates,
  CODEOWNERS, SECURITY.
- `///` doc comments across the Tier 1 public API (ServerSession, the
  WindowBridge protocol + CocoaWindowBridge, ResourceTables,
  FontResolver, USKeymap, SelectionMediator, LauncherFile, the
  Region/Shape ports, the app entry points).
- README refreshed: a clickable hero linking to macxserver.com, and
  build/run instructions that lead with Xcode + the GUI (swift build
  makes bare binaries with no app icon; it is the test/headless path).
- History cleaned, fixtures and config sanitized, test suite green
  (1262 tests) throughout.

## Motif menu position corruption (fixed)

Opening a Motif pulldown and moving the window left every later menu
popping up at the old position. Two root layers: a grab-state spec
miss (an explicit XGrabPointer must replace the implicit grab; we were
not clearing `implicitGrab`) and a missing rootless emulation of the
server-wide hardware pointer grab (AppKit owned the title bar
independently). Fixed both, plus Mac-UX polish so a title-bar click
during a menu both dismisses the menu and starts the drag in one
gesture. Verified live against dtpad. Details in git history and the
implicit-grab memory.

## What works

- Server M1-M3 green; xterm, xcalc, xeyes, xclock, twm/mwm, quickplot,
  and the CDE dt-apps run from a real Sun against the Mac.
- Motif menus hold position across window moves.
- Capture tool (GUI + CLI + server-side `--capture`) working.
- 1262 tests green.

## What's next

1. Final review of the repo on GitHub, then publish it.
2. Verify the orphan xterm right-click menu is gone (the same grab fix
   should cover it; recheck: xterm right-click, dismiss, look for a
   stranded popup).
3. Decide whether to close the native-title-bar drag-lock gap (Motif
   Frame OFF windows only get the isMovable=false layer, no
   click-dismiss) now or later.
