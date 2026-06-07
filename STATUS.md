# Status 2026-06-07

Light day. One commit on this repo (`32b020b`: delete the stale
`blog/` directory and its 11 staged posts; per-day narrative now lives
in the macxserver-hugo deep-dives + 30-Day Sprint ledger). The rest of
the day was site polish on macxserver-hugo and a planning
conversation about taking the server repo public.

Server code is unchanged from 2026-06-04.

## What landed today

1. **`blog/` directory deleted** (`32b020b`). Ten draft posts and a
   README, 2170 lines, all replaced by the macxserver-hugo deep dives.

2. **macxserver-hugo site polish** (in the other repo). Highlights:
   - Todd rewrote the home-page intro paragraph. I proofed it
     (`macOS Core Graphics`, capitalized `Sun`, `GitHub`, comma after
     `Claude Code`) and linked the repo on the word `GitHub`.
   - Linked `oldsilicon.com` in the home intro.
   - "Why not XQuartz?" was promoted to the top nav at the end of
     yesterday's evening session; Todd asked for it removed today.
     Article still lives at
     `/deep-dives/why-macxserver-instead-of-xquartz/` and is still
     linked from the home-page intro.
   - End-of-day commit from last night (`531858c` on this repo) wrote
     the rolling STATUS for 2026-06-06 and updated
     `feedback_macxserver_site_framing.md` to reflect that the XQuartz
     comparison is now part of the site with honest framing rules.

3. **Public-repo prep, discussion only.** Todd is thinking about
   making the macXserver source repo public. Three patterns surfaced:
   two-repo public mirror, one-time `git filter-repo` cleanup, or
   binary-only release. Working recommendation is the filter approach
   with a narrow strip list: `.claude-memory/`, `STATUS.md`,
   `CLAUDE.md`, and probably `archive/`. The substantive docs
   (`DECISIONS.md`, `SHORTCUTS.md`, `OPCODE_STATUS.md`,
   `GRAPHICS_Y_FLIP.md`, the scaling and font docs) should stay in
   the public repo as contributor onboarding material; they're
   unusually good and worth showing off. Pre-publish checks: confirm
   nothing under `reference/` (X11R6 source, etc.) ever got committed
   (gitignored, but verify), and decide on `tests/` `.xtap` captures
   from Sun workstations.

## What's next

- Orphan screenshot (`Screenshot 2026-06-06 at 9.27.43 AM.png`) still
  sitting uncommitted at the top of
  `~/Dropbox/dev/MacXServer/macxserver-hugo/`. Todd hasn't said what
  it's for. Ask before next commit.
- Photo `todd-vernon.jpg` on the About page is 1.8 MB at 2500×3333,
  renders at 220px. Page-weight only; visually fine.
- URL slug for "How menus know where they are" is still
  `/deep-dives/the-synthetic-configurenotify/`. No inbound link
  breakage yet but the slug doesn't match the title.
- Em-dash sweep across existing site content is overdue (Todd's voice
  rule bans them; older content still has `&mdash;` everywhere).
  Today's new content avoided them; older content didn't get touched.
  Not asked for yet; flag if it becomes a topic.
- Public-repo prep decision pending: which strip list, when to filter,
  whether to mirror or rewrite history. No action requested yet, just
  surfaced.
- Five deep-dive ideas seeded but unwritten from earlier sessions.

---
