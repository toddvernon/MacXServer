# Status 2026-07-16 (beta-planning session, desktop)

## Headline: the road to friends is planned, decided, and half-built.
BETA_PLAN.md is the new sequencing doc (gold images -> gold apps ->
tested flows -> seed friends), Phase 0's decisions are made and
ledgered, both hosting repos exist, and Phase 1's script side (the
publish pipeline) is done -- restructured mid-session on Todd's catch
so gold masters never take the publish surgery.

## What happened this session

**Flow validation + look-about (no code).** Mapped the two onboarding
flows as ASCII charts before any implementation: the shipped external-
host wizard (one pending change: seed the curated OS-keyed launcher set,
not a single xterm) and the proposed bundled-fixture reshape (blank
marketing detail pane + install wizard over the BUILT 2026-07-10 guts:
download pipeline, FirstLogin, deferred add-user). Look-about found the
real gaps: catalog never hosted (the critical path), root-password
policy undecided, per-OS known-working app curation doesn't exist
anywhere in code (all three fixtures get identical 7 xterms), clock
sync is manual, Gatekeeper walkthrough still open. Charts + gaps live
in BETA_PLAN.md's appendix and phase 3.

**BETA_PLAN.md** (4ca6cae). Four phases, Todd's order: (1) gold images
on GitHub, (2) gold notarized apps installable like a stranger, (3)
flow testing + onboarding iteration against gold artifacts only (reset-
to-stranger script, nine-row test matrix, wizard reshape lands here),
(4) friends, gated on Restore-from-Backup + known-issues + feedback
channel. Discovery that shrank the work: release.sh already does the
full notarize -> GitHub release loop (A5), so phase 2 is mostly a
--beta flag.

**Phase 0 DONE** (650476a; DECISIONS 2026-07-15 entry). Repos created
and live: public `toddvernon/macxserver-images` (catalog.json IN the
repo -- the pinned raw URL already serves the empty seed catalog --
payloads as release assets) and private `toddvernon/macxserver-beta`
(tester README: install, Gatekeeper dance, update story, Issues as
feedback). Reverses the 2026-07-10 macxserver.com hosting call (never
uploaded, nothing real moved). Root password policy: rotate at publish,
document on the quickstart page. `ImageCatalog.defaultURL` repointed at
the raw URL; ImageCatalogTests 4/4 green. Local clones at
~/dev/macxserver-images and ~/dev/macxserver-beta.

**Phase 1 script side DONE** (SPARCplug ad5c72c + 26aa09c). The publish
pipeline, restructured after Todd caught that v1 mutated gold in place:

- `cut-release.sh <os>`: clones gold -> release-images/<os>-release
  .qcow2 (APFS clonefile, instant; lock-checked both sides; prints the
  per-OS boot override -- IMAGE= for solaris, BOOT_IMG= for the rest).
  Gold keeps tvernon + dev root password forever.
- `publish-prep.sh <os>`: read-only gate against the RUNNING release
  copy. Check 0 proves via the image lock that the guest isn't gold;
  then current fail-closed daemon (0.2.0, wrong-secret probe must be
  denied), tvernon stripped, template locked, root rotated (DES
  recompute under stored salt), canonical dotfiles byte-exact, baseline
  resolv.conf, 4.1.4 Y2K date sums, clock year.
- `docs/PUBLISH_PREP.md`: the strip/rotate surgery recipes per OS
  (userdel where it exists, read/modify/write/readback on 4.1.4).
- `build-catalog.sh`: --tag + --publish GitHub tail (release create,
  asset upload, catalog.json commit+push); sources ONLY release-images/
  so publishing gold is impossible by construction. Dry-run verified.

## What's working / what's broken

- swift build + full test suite untouched except ImageCatalog (4/4).
- Guest-facing gate checks (hello version key, Y2K sums, Solaris
  template path) written from source + memory, not yet run against a
  live guest -- first real run may need a line or two.
- The empty catalog is live; app Download buttons will correctly find
  no entries until Todd's publish.

## What's next

1. Todd's half of phase 1: pick the published root password, cut +
   surger + gate each release copy, `./build-catalog.sh --publish`,
   then the stranger download test on a clean account (all three OSes).
2. Phase 2 script side (can start any time): release.sh --beta (repo
   override + skip the Hugo site tail), then cut v0.9.9 and run the A6
   clean-Mac acceptance.
3. Phase 3 prep when testing starts: Tools/reset-to-stranger.sh + the
   test matrix in BETA_PLAN.md.
4. Carried: CanonicalDotfiles DISPLAY decision (SHORTCUTS), UserAdmin
   live test vs Solaris 2.6 + 4.1.4, orphaned DefaultLaunchers.swift
   retirement, per-OS curated launcher distillation (phase 3's big
   net-new piece).

## Committed / push state

- X repo, main, NOT pushed: 4ca6cae (BETA_PLAN) -> 650476a (phase 0) ->
  d47545f + 1d429bd (plan notes) + this roll.
- SPARCplug repo, main, NOT pushed: ad5c72c (publish pipeline) ->
  26aa09c (release-copy restructure).
- New GitHub repos pushed at creation: macxserver-images (public),
  macxserver-beta (private).

## Switching Macs

- Push X + SPARCplug at /eos; the other Mac needs both plus fresh
  clones of the two new repos if working the publish side there.
- App code change is one line (ImageCatalog.defaultURL); Xcode rebuild
  as usual.
- No VM ran this session; no image locks held.
