# Using Claude Code on this project

A lot of MacXServer was built with [Claude Code](https://claude.com/claude-code),
and the repo is deliberately set up to keep working that way. You don't have to
use an AI agent to contribute, but if you do, this is how to get good results
without relearning the traps that already cost real debugging time.

## The one thing that matters

`CLAUDE.md` at the repo root is the agent's brief. Claude Code loads it
automatically when you open the project, so most of the setup is just "open
the repo and start." Everything below is what's already in that brief, spelled
out for a human deciding how to drive.

## Getting started

1. Install Claude Code and open this repo as the working directory. It picks up
   `CLAUDE.md` on its own.
2. Ask for what you want. The agent is told to read `PROJECT.md`,
   `ARCHITECTURE.md`, and `DECISIONS.md` before doing real work, so it starts
   with the project's actual shape instead of guessing.
3. Build and test the normal way: `swift build -c release` and `swift test` are
   the dev loop. Open `MacXServer.xcodeproj` and run the `MacXServer` or
   `MacXCapture` scheme for the polished apps with icons and menu-bar presence.
   See `CONTRIBUTING.md` for the full build notes.

## Required reading by task type

`CLAUDE.md` maps kinds of work to the docs you (or the agent) must read first.
The short version, because these are the ones that bite:

- **Any graphics work** (draw ops, pixmaps, `CopyArea`, `PutImage`, anything
  touching a pixel buffer): read `GRAPHICS_Y_FLIP.md` first. The y-down
  convention and the `drawImageRespectingYFlip` helper are load-bearing.
- **Rendering, fonts, display scaling, terminal text:**
  `SERVER_RESOLUTION_SCALING_AND_FONTS.md`, plus `XTERM_FONT_QUALITY.md` for
  xterm specifically.
- **Motif / Xt text widgets** (anything non-terminal): `MOTIF_TEXT_QUALITY.md`.
- **A new or tricky opcode:** check `RENDERING_DESIGN.md` for the primitive
  mapping and `OPCODE_STATUS.md` for current status and confidence.

Skipping these is how you reintroduce a bug the project already fixed.

## The ground rules the agent follows

These come from `CLAUDE.md`; they're worth knowing so you can tell when the
agent is off the rails:

- **XErrors are real protocol output, not panics.** When a request can't be
  served, emit the correct XError on the wire. Silently faking success is a bug,
  not a shortcut.
- **Ledger your shortcuts.** Every hardcode, stub, or deliberate lie-on-the-wire
  goes in `SHORTCUTS.md` with an exit plan, annotated at the call site.
- **Track opcode confidence.** Implementing or changing an opcode updates
  `OPCODE_STATUS.md` with honest confidence. Low confidence is fine; hidden low
  confidence is not.
- **Architecture is settled in `DECISIONS.md`.** Don't unilaterally revisit
  those. Propose, don't redecide.
- **Review gates.** Tricky opcodes get a pre-implementation planning pass;
  milestones get a review pass. `CLAUDE.md` describes when each fires.

## Submitting changes

Same as any other contributor, AI-assisted or not (see `CONTRIBUTING.md`):

- Keep `swift test` green and add tests for new behavior.
- Match the existing style: casual, first-person, direct comments. Boring,
  obvious code over clever code. No marketing language, no em-dashes.
- Open a PR against `main`. Explain what changed and why; if you used an agent,
  that's fine, but you own the diff. Review it like you wrote it.

If you only read one file, read `CLAUDE.md`. This doc just tells you why it's
there.
