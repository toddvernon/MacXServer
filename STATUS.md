# Status 2026-06-06

Two-session website day. Zero commits to this repo; all work on
macxserver-hugo (github.com:toddvernon/MacXServerSite). Early session
built out the Deep dives section. Evening session restructured the
navigation, wrote and promoted the XQuartz comparison article, and ran
a content-cleanup pass across every page. The server itself is
unchanged from 2026-06-04.

## Early-session work

1. **Deep dives section** (`26da053` on MacXServerSite). New
   `/deep-dives/` nav with RSS feed at `/deep-dives/index.xml` and feed
   auto-discovery in `<head>`. Conversational Q&A format: Todd's intro
   sets up a problem, his question in a blue blockquote, Claude's
   response in a green-sidebar `claude-response` box via a `{{% claude
   %}}` Hugo shortcode.

2. **Four deep-dive posts**: *Cell follows font* (Day 5), *Pixel
   perfect* (Day 12), *How menus know where they are* (Day 16 ICCCM
   4.1.5), *Lift, don't intellectualize* (Day 21 miregion port).

3. **Stats strip + ledger label cleanup**. Dropped the "12+ live X
   clients" cell from the home-page stats strip and renamed "wire
   interactions" to "opcodes".

4. **All 19 .md files wrapped to 80 cols** for hand-editability. Script
   at `/tmp/wrap-md.py` (frontmatter-safe, code/HTML/shortcode/
   table-safe). Saved as memory `feedback_markdown_wrap_80.md`.

5. **Detail-page screenshot frame removed**. Card treatment now scoped
   to `body.home .hero-image img` only; deep-dive and feature
   screenshots show bare so their captured native shadows don't get
   double-stamped.

## Evening-session work

6. **Why not XQuartz? deep dive** (new). At
   `/deep-dives/why-macxserver-instead-of-xquartz/`. Honest scorecard:
   parity → wins → losses → not-in-mission tables. Leads with display
   scaling and display quality as THE #1 motivation (not Mac
   integration, which is second-tier). Names the 5K Studio Display
   failure mode on XQuartz and the Linux equivalent (`xrandr --scale`,
   `Xft.dpi`, `GDK_SCALE`, `QT_SCALE_FACTOR` don't compose into a
   working solution). Closes with a "look at the screenshots, or just
   try it, it's free" callout.

7. **Navigation restructure**:
   - New "The Project" page at `/the-project/` carrying the project
     intro + "Why" sections that previously lived on About.
   - "Ledger" menu item renamed to "30-Day Sprint". URL stays
     `/ledger/` so every `[Day N](/ledger/#day-N)` link still works.
   - "Why not XQuartz?" promoted to top nav, weight 2.
   - About page trimmed to just the bio (About me + Around the web +
     contact pointer), expanded with content pulled from
     oldsilicon.com/about (NASA X-Planes start, three Boulder
     companies, VictorOps/Splunk exit, Wrecking Crew Labs framing).
     Todd's photo added as a right-float.
   - Final menu order: **The Project · Why not XQuartz? · 30-Day
     Sprint · Features · Deep dives · About · GitHub**.

8. **Day-N hyperlinks across 19 files**. Mechanical pass: bare "Day N"
   in body prose became `[Day N](/ledger/#day-N)`; plural ranges
   "Days 1-2" link to the start day. Script at `/tmp/link_days.py`
   skipped frontmatter, blockquotes, `<figure>` blocks, and code
   blocks. Cleanup pass dropped redundant "see the [ledger]" suffixes
   from feature-page Related sections (they had become double-links
   after the first pass).

9. **Page-layout fixes**:
   - Feature single layout switched to `prose-wide` to match deep-dive
     column width (was using narrower `.prose`).
   - About / `_default` single layout: removed `container narrow`,
     gives the wider feature/deep-dive column.
   - Card images switched from `object-fit: contain` to `object-fit:
     cover` with `object-position: top left` so off-aspect-ratio cards
     fill the frame instead of letterboxing.
   - New `Params.tagline` field on `_default/single.html` takes
     precedence over `.Description` for the lede. Lets a page have a
     short visible tagline while keeping a long SEO description.

10. **Content cleanup across feature + deep-dive pages**:
    - "Why it matters" headers dropped on all 8 feature pages (read as
      defensive product-pitch language); prose under them folded into
      "What it does" as continuation paragraphs.
    - Jargon strip: undefined "gold" and "chrome" (inside-baseball)
      rewritten as "reference" / "captured originals" / "the Sun" and
      "frame" / "styling" / "appearance" respectively. Defined "gold"
      inside `the-corpus-is-the-test-suite` article body kept (it's
      defined in context); "gold standard" English idiom in
      cell-follows-font kept; "Chrome browser" proper noun kept.

11. **New screenshots on shaped-windows feature page**: oclock-over-
    Excel image (Excel toolbar visibly cut behind the round window
    proves transparency is real), xeyes-over-xterm image (eyes peering
    at a `ls -l` listing through the SHAPE mask). Old fallbacks at
    `shaped-windows-card.png` and `shaped-windows-hero.png` left on
    disk in case of revert.

12. **Mission Control proof image** wired into the first-class-windows
    feature page after a live test confirmed F3 / Control-F3 / Cmd-Tab
    all participate correctly with X windows.

13. **macxserver.com still live** at HTTPS. About 20 commits, 20
    deploys, no infra changes.

## What's next

- Orphan screenshot (`Screenshot 2026-06-06 at 9.27.43 AM.png`) still
  sitting uncommitted at the top of `~/Dropbox/dev/MacXServer/macxserver-hugo/`.
  Todd hasn't said what it's for. Ask before next commit.
- The 1.8 MB `todd-vernon.jpg` on the About page could be downscaled
  (currently 2500×3333, renders at 220px). Page-weight only; visually
  fine.
- URL slug for "How menus know where they are" is still
  `/deep-dives/the-synthetic-configurenotify/`. No inbound link
  breakage yet but the slug doesn't match the title.
- Em-dash sweep across existing site content is overdue (Todd's voice
  rule bans them; older content still has `&mdash;` everywhere).
  Tonight's new content avoided them; older content didn't get
  touched. Not asked for yet; flag if it becomes a topic.
- Five deep-dive ideas seeded but unwritten from earlier sessions.

---
