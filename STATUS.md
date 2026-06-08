# Status 2026-06-08

Strategy day. Zero commits on this repo. The work was scoping the
macXserver public release, surfacing and addressing a multi-Mac
Claude Code sync gap, and drafting comment-policy + project-style
overrides for the post-split CLAUDE.md files. All artifacts live in
Dropbox at `~/Dropbox/dev/X/` (intentionally outside this git tree)
since they'll be tested across both Macs before execution.

## What landed today

1. **Public release plan** at `~/Dropbox/dev/X/PUBLIC-RELEASE-PLAN.md`.
   Four parallel audit agents surveyed file structure,
   documentation, source code sensitivity, and public-repo
   essentials. Synthesized into a phased plan:
   - **Phase 0 (multi-Mac):** split `CLAUDE.md` and `.claude-memory/`
     out of the git tree into Dropbox so personal workflow notes
     stop being committable. Requires both Macs for live testing.
   - **Phase 1 (single Mac):** license decision (Apache-2.0
     recommended for patent grant), X11R6 attribution on Region/ +
     ShapeExtension port files, hostname sweep
     (`*.example.com` → `*.example.com`) across ~50 hits, public-repo
     essentials (LICENSE, CONTRIBUTING with the `.xtap`
     capture-submission flow and Claude Code playbook,
     CODE_OF_CONDUCT, `.github/` templates), doc-comment pass on
     Tier 1 core runtime files, history filter via `git filter-repo`,
     push to public.
   - **Phase 2 (optional):** documentation coalesce (FONT_RENDERING,
     RENDERING_INTERNALS, APP_COMPATIBILITY merges).
   - Strip list validated: `.claude-memory/`, `CLAUDE.md`,
     `STATUS.md`, `archive/`, `state_of_apps`, empty `swiftpm/`.
   - Audit surfaced **X11R6 license-attribution gap** on
     `Sources/SwiftXServerCore/Region/{Region,RegionOp,RegionExtras}.swift`
     and `Sources/SwiftXServerCore/ShapeExtension.swift` (must-fix).

2. **Global Claude Code setup plan** at
   `~/Dropbox/dev/X/fixing_global_claude_setup.md`. The realization
   driving it: user-level config under `~/.claude/` (CLAUDE.md,
   settings, skills, agents, commands) doesn't sync between Macs by
   default. That's the divergence point for any multi-Mac dev. Fix
   is the same Dropbox-symlink pattern already used for
   `<project>/.claude/` and `reference/`: canonical files live in
   `~/Dropbox/dev/claude-shared/`, symlinks point at them from
   `~/.claude/`. This runs before Phase 0 because the project
   CLAUDE.md split assumes the user-level slot is in place.

3. **Doc-comment policy override drafted** for the post-split CLAUDE
   files. Surfaced that Claude Code's built-in default "no
   comments" rule was honored throughout the 30-day build, leaving
   public API surface mostly undocumented (110 of 244 files have
   any `///` comments; ~3400 doc-comment lines across ~3900 public
   declarations). Override drafted: required `///` doc comments on
   public types and methods, terse style, examples for the X11R6
   ports and framer stubs. Belongs in the **project** CLAUDE.md so
   contributors (and their own Claude sessions) get the convention
   too.

4. **"Entering a new project" rule drafted** for personal CLAUDE.md.
   Says: observe the project's existing comment style first, match
   it instead of importing habits from other projects. Pairs with
   the doc-comment policy: personal rule says "match what's there",
   project rule says "here's what's there".

5. **Public-repo prep discussion** continued: addressed the
   "binary-only vs. one-time filter-and-publish vs. dual-repo
   mirror" question. Working approach: one-time filter via
   `git filter-repo`, retire the private repo. Two-Mac sync
   continues via Dropbox for personal artifacts that shouldn't
   ship.

## What's next

- **Tomorrow morning, first thing:** execute
  `~/Dropbox/dev/X/fixing_global_claude_setup.md` to wire the
  user-level Claude Code symlinks. Single-Mac to start; cross-Mac
  verification needs both eventually.
- Then **Phase 0** of `PUBLIC-RELEASE-PLAN.md` (multi-Mac CLAUDE
  split) at first opportunity when both Macs are accessible.
- Then **Phase 1** (license, sanitization, public-repo essentials,
  doc-comment pass, history filter, push). Estimated 4-6 hours
  single-Mac.
- Confirm captures publication scope: 71 paired `.xtap` files from
  Sun workstations are intentionally meant to ship per
  `captures/README.md` framing, but worth explicit owner
  confirmation. Same for `captures/fixtures/sun_resource_manager.bin`.
- Outstanding pre-existing items still apply:
  - Orphan screenshot in macxserver-hugo dir
  - Photo `todd-vernon.jpg` (1.8 MB) could be downscaled
  - URL slug for "How menus know where they are" still
    `/the-synthetic-configurenotify/`
  - Em-dash sweep across older macxserver-hugo content overdue

---
