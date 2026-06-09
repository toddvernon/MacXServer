# CLAUDE.md

swift-x is a project to build a modern X11 server in Swift on macOS, to
display X applications from real vintage Sun workstations (and other X11
clients) with proper modern rendering.

## Read these files first

Before doing any work, read these in order:

1. `PROJECT.md` — what we're building, why, the two-product plan, and what's explicitly out of scope
2. `ARCHITECTURE.md` — how the components fit together
3. `DECISIONS.md` — architectural choices and the alternatives we rejected. If you find yourself questioning a design choice, it's probably already discussed here

When working on a specific product, also read the corresponding `PRODUCT_N_*.md` if it exists.

For ANY graphics work — adding a new draw op, touching pixmaps, CopyArea, PutImage, or anything that calls into a `PixelBuffer` or `FlippedXView` backing — read `GRAPHICS_Y_FLIP.md` FIRST. It documents the y-down convention, the `ctx.draw(image:in:)` gotcha that ate a week of debugging in May 2026, the `drawImageRespectingYFlip` helper that every image-source draw must go through, and the asymmetric-source orientation test that every new graphics op needs.

For any rendering, font, display-scaling, or terminal-text work: also read `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. It is load-bearing for everything visual the server does — substitution table, cell-snapping math, scaling planes, quality bar. Anything visual that doesn't honor it is a bug.

For xterm / terminal-text rendering specifically: `XTERM_FONT_QUALITY.md` is the resolved design for cell-follows-font (the iTerm2 playbook — integer pointSize, CTFont-derived cell metrics, reported metrics === rendered metrics by construction). Same constraint set as the scaling doc, narrower scope.

For Motif and Xt text widgets (XmText, XmLabel, XmPushButton, XmCascadeButton, dtpad, dthelpview, xfontsel) — basically any non-terminal text rendering: `MOTIF_TEXT_QUALITY.md`. The companion to XTERM_FONT_QUALITY for the proportional-font, per-character-CHARINFO playbook. Also documents the resource-curation strategy (`RESOURCE_MANAGER` content driving widget defaults, tiered delivery from hardcoded → config file → settings UI).

## Where things are

- Documentation: top-level markdown files
- Source: `src/` (organized by component as the project grows)
- Tests: `tests/`, including the captured X session corpus once Product 1 starts producing one
- Build: simple Makefiles per platform, no imake / autotools / CMake
- Reference material (X11R6 source, X.org spec, XQuartz, ICCCM, etc.): `reference/` (gitignored, 650MB+, so it's not shipped in the repo; bring your own copy). Before making any protocol-level claim, check `reference/README.md` (Quick lookup) for the topic-to-file map and read the authoritative source rather than guessing.
- Archived docs: `archive/` holds superseded status snapshots, completed plans, closed investigations, and the 2026-05-14/15 audit + comparison research forks. Their findings have been promoted into the live ledgers (SHORTCUTS, OPCODE_STATUS, DECISIONS) where actionable; archive files are kept for citation and historical context. Don't reach for these unless you're chasing the provenance of a SHORTCUTS entry that cites them.

## Conventions

**Voice and style for documentation and comments**: Casual, first-person,
direct, technical. No em-dashes. No marketing language.

**Code style preferences**:
- Swift for Mac-side code
- Boring, obvious code over clever code

**Architectural philosophy to preserve**:
- Own and understand the whole stack. Don't delegate to abstraction layers you can't see through.
- Minimal tooling. If it hasn't been asked for, don't add it. (No Dockerfile. No CI yet.)
- Explicit over implicit. Five readable lines beat one line that does magic.
- Extensive test suites where possible

## What to ask the maintainer before doing

- Adding any new dependency
- Changing the build system structure
- Adding a new top-level component or module
- Anything that touches `DECISIONS.md` (those are settled questions; if you want to revisit, flag it)
- Anything that changes architecture in `SERVER_RESOLUTION_SCALING_AND_FONTS.md` — scaling factors, the substitution table, cell-sizing math, three-plane decomposition, quality bar
- Anything that changes architecture in `MOTIF_TEXT_QUALITY.md` — the per-character `characterWidth` invariant, the two-sided reporting/rendering enforcement, the resource-curation strategy and its tiered delivery
- Anything in the "Non-goals" section of PROJECT.md

## What you can do without asking

- Write code per the current product plan
- Write tests
- Refactor within an existing module
- Update documentation to reflect what was actually built
- Append to `DECISIONS.md` when a new decision gets made (with a date and clear rationale)
- Suggest changes — just don't make architectural ones unilaterally

## Working conventions

- **Hardcodes / stubs:** every time we hardcode something to make a bigger thing work, log it in `SHORTCUTS.md` in the same change. Periodically prune as real implementations land.
- **XErrors are a real protocol output, not an internal panic.** When a request can't be served, emit the correct XError on the wire (per the X11 spec) and log the condition. Real clients handle XErrors routinely — BadWindow on a race is normal. What's NOT acceptable is silently faking a success to dodge the error. In tests, an emitted XError on a path we claim to support is a failure. The forgiving-stub pattern that got M1–M3 across the line was a deliberate, time-boxed trade; M3 is done and the cost-benefit has flipped — hidden lies now cost more debugging time than they save in velocity.
- **Lying on the wire is a ledgered exception, not a default.** If we deliberately return a fake-success because emitting the correct XError would break a working client we care about, the lie must be (a) listed in `SHORTCUTS.md` with a "what real looks like" exit plan, (b) annotated at the call site with a comment referencing the SHORTCUTS entry, and (c) revisited periodically. Lies without that contract are bugs, not tech debt. SHORTCUTS is the active ledger of currently-justified lies, not a wish list of things we forgot to do.
- **Opcode confidence:** every time an opcode is implemented, changed, or stubbed in the server, update `OPCODE_STATUS.md` with status and confidence. Honest low confidence is fine; hidden low confidence is not.
- **Rendering choices:** before reaching for a Mac graphics primitive, check `RENDERING_DESIGN.md`. The architectural commitments at the top apply to every opcode; the per-opcode mapping is a best-guess to keep choices consistent across sessions.
- **Keep working artifacts in the tree:** all design docs, decision records, status trackers, and reference material go in the project tree, not in personal directories or tmp paths.
- **End-of-day status:** rolling `STATUS.md` at the top level. Overwrite at end of day; never create dated `STATUS_YYYY-MM-DD.md` files (git log preserves the historical snapshots). The "what's working / what's broken / what to do next" hand-off doc.

### Review gates (subagent-driven)

Three review checkpoints with subagents. They exist to catch consistency and spec-compliance issues that a single session will quietly miss.

- **Pre-implementation planning agent (selective).** Fires before implementing a *tricky* opcode: any rendering opcode, anything with byte-format conversion (`PutImage`, `GetImage`, `CopyArea`), anything with subtle X11 semantics (`ConfigureWindow` stack-mode/sibling, `ChangeProperty` modes, polygon fill-rules), or any opcode you're uncertain about. The agent reads the spec section in `reference/x11-protocol-spec/x11protocol.html`, checks `RENDERING_DESIGN.md` for the primitive mapping, checks `reference/X11R6/` for the era-correct behavior, and reports: implementation approach + edge cases + confidence target. Skip for trivial opcodes (e.g. `FreeGC`).
- **Milestone review agent (mandatory).** Fires at M1, M2, M3 boundaries — no exceptions. The agent reads the milestone definition in `PRODUCT_2_SERVER.md`, checks the actual implementation against it, runs `swift test`, audits `SHORTCUTS.md` for stale entries, audits `OPCODE_STATUS.md` for honest confidence claims, and runs the live fixture if applicable (xclock for M3). Reports: pass / fail / specific gaps.
- **Periodic ledger audit (lightweight).** After every ~5 opcodes implemented, fire a quick agent pass over `OPCODE_STATUS.md` and `SHORTCUTS.md`: do entries reflect reality? Anything getting stale? Catches drift before it accumulates.

When launching review agents, prefer forking (no `subagent_type`) so the fork inherits the project conventions. The intermediate exploration usually isn't worth keeping in main-thread context.

## Current product

(Update this as we move through products.)

**Product 1: Capture tool (macXcapture).** v1 CLI shipped 2026-05-06. v2
(library + Mac GUI app + server-side capture for public-release bug
reporting) largely landed 2026-05-29: `SwiftXCaptureUI` extracted as a
shared library; capture app shipped with a stacked 6-step Record wizard,
`.xtap` viewer windows with syntax-highlighted decoded chrono output, and
Save As / Export as Text. Server-side auto-capture working. Red XTAP app
icon, distinct from the blue X server icon. Inline narrative landmark
detector (`# ...` story-form callouts) shipped 2026-05-30 with capture-side
parity in the server's debug viewer and viewer-side landmark navigation
(sidebar + Cmd-]/Cmd-[). Decoder coverage push (Phases 1-3 of the
2026-05-29 mission doc) shipped 2026-05-30: framer Phase 1 closed 16
requests + 6 replies + 5 events, extension dumper registry landed,
BIG-REQUESTS / MIT-SHM / XKB / XInput v1 / RENDER all decoded.
**`macXcapture-feature-checklist.md` is the source of truth for OSS-launch
readiness** (24 Yes / 35 Partial / 67 No / 1 N/A as of 2026-05-30; the 67
No rows are the remaining work). See `PRODUCT_1_CAPTURE.md` for the
mission statement and the phased decoder coverage plan.

**Product 2: Swift X server.** In progress. M1, M2, M3 (full) all green
as of 2026-05-07. Phase 1 of `SERVER_RESOLUTION_SCALING_AND_FONTS.md`
shipped same day: display-adaptive integer scaling at startup (Studio
Display picks 1280×900@3x; 4K / MBP / 1080p get appropriate presets), Core
Text scalable font substitution with cell-snapping, ImageText8 +
PolyFillRectangle rendering, ListFonts + GetKeyboardMapping +
GetModifierMapping + GetPointerMapping + QueryColors + GetSelectionOwner
replies. `macxserver` runs an NSApplication runloop with one GCD
`protocolQueue` per session that owns the socket + session state
(consolidated from split read/write threads on 2026-05-10; see DECISIONS).
**Live xterm and xcalc working** (2026-05-07 / 05-08). **Cut/paste
both directions** (2026-05-08, PRIMARY only). **CDE dt-apps boot as of
2026-05-10** (dtcalc / dtterm / dthelpview / dticon -- the 2026-05-18
MATCH_SELECT-time fix was the unlock, not the CDE-impersonation that day's
patch originally claimed; the impersonation is dormant and the entry point
is sealed under a `RETIRED` banner. **Don't propose resurrecting `SDT
Pixel Set` / `Customize Data:N` for theming or rendering bugs** -- see
DECISIONS.md 2026-05-18).
**quickplot fully functional same day** (MATCH_SELECT-time fix).
**Optional Motif WM frame** for X top-levels shipped 2026-05-24
(`MotifFrameView`, opt-in via Preferences → Display). **x11perf 254/254
clean sweep** 2026-05-22 + 69 new error-path tests on the same day caught
6 silent-drop bugs. **Server bg-paint contract honored end-to-end** as
of 2026-05-19 (clipping + paint-on-grow + GCState bg default fix).
**Root-window properties now server-global** as of 2026-05-27 (was the
oldest architectural bug); unblocked Motif clipboard cross-session
copy/paste. **Remote app launcher** shipped 2026-05-27 (telnet → vintage
Sun → DISPLAY+launch; passwords in Keychain; optional verbose progress
window). **Motif frame chrome configurable** via `[motif-frame]` in
`~/.macxserver-resources` (2026-05-27). **SHAPE extension** shipped
2026-05-28 (major opcode 128): oclock renders round, xeyes as a bare oval,
Motif-frame integration handles shaped clients via mwm's `SetFrameShape`
policy. Bounding shape on top-level fully visual; clip shape and
descendant-window shape stored but not yet applied to rendering (SHORTCUTS
exit plan). See `PRODUCT_2_SERVER.md` for milestone definitions and
`OPCODE_STATUS.md` / `SHORTCUTS.md` for what's shipped vs stubbed.
