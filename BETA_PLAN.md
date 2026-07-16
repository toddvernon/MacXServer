# Beta plan -- gold images, gold apps, tested flows, then friends

Status: **ACTIVE 2026-07-15. Phase 0 DONE same day** -- Todd confirmed the
shapes; both repos exist (`macxserver-images` public with the live pinned
catalog URL serving an empty catalog, `macxserver-beta` private with the
tester README), D1-D3 are ledgered in DECISIONS 2026-07-15, and
`ImageCatalog.defaultURL` points at the raw catalog URL. Next: phase 1. The premise, from Todd: all the remaining
first-run and onboarding work is gated on *him* being able to test the
product like a stranger. So the order is (1) gold images downloadable from
GitHub, (2) gold notarized app builds installable from GitHub, (3) iterate
on the documented flows against those artifacts, (4) seed friends.

The good news discovered while planning: most of the machinery already
exists. `release.sh` does the full archive -> notarize -> staple -> GitHub
release loop (A5, proven on a scratch bundle 2026-07-10). The download
pipeline, catalog format, `build-catalog.sh`, first-login choreography, and
deferred user creation are all BUILT (FIRST_RUN_EXPERIENCE.md,
IMAGE_DOWNLOAD_PLAN.md). What's missing is hosting, one release-script
mode, the verification passes, and the testing itself.

---

## Phase 0 -- decisions to pin (DONE 2026-07-15; kept for rationale)

**D1. Images host on GitHub, in their own public repo.** Reverses the
2026-07-10 DECISIONS entry (catalog on macxserver.com); Todd's call
2026-07-15. Proposed shape:

- New public repo `toddvernon/macxserver-images`. Public is required: the
  app fetches anonymously. Same distribution posture as the oldsilicon.com
  ZuluSCSI copies, so nothing newly exposed.
- `catalog.json` lives IN the repo (small, diffable, history for free):
  `https://raw.githubusercontent.com/toddvernon/macxserver-images/main/catalog.json`
- Payloads are **release assets** (git can't hold 250 MB files; releases
  take up to 2 GB per file, free egress):
  `https://github.com/toddvernon/macxserver-images/releases/download/v2026.07/<os>-boot.qcow2.gz`
- Publishing an update = new release tag + edit catalog.json on main.
  The pinned catalog URL never changes.

App-side cost: one line (`ImageCatalog.defaultURL`) plus the DECISIONS
append. `SPARCPLUG_CATALOG_URL` stays as the dev/test override.

**D2. Beta app builds go to a private repo, not the public one.** The
public `toddvernon/MacXServer` releases page is the eventual real channel;
half-tested 0.9.x builds shouldn't be the first thing a visitor sees.
Proposed: private repo `toddvernon/macxserver-beta`, and a `--beta` flag on
`release.sh` that (a) overrides `REPO`, (b) **skips the Hugo site version
bump + deploy** (that tail publishes to the website; a beta cut must never
touch it). Friends get invited as repo collaborators later, which also
hands them the Issues tab as the feedback channel (phase 4).

**D3. Root password policy for the published masters.** The one decision
that must precede gzipping images (it changes what's inside them).
Recommendation for beta: **rotate to a fresh documented password at
publish prep** and print it on the download/quickstart page. These VMs are
loopback-bound (DECISIONS 2026-07-09), exposure is a local-Mac story, and
a documented root password is a feature for tinkerers. Folding a
root-password-set step into the first-run wizard stays on the table for
the wizard reshape (phase 3), not a gate now.

**D4. (Defer.) Images-directory wizard step.** Keep-or-cut can wait for
phase 3; the fixed App Support default is fine for all beta testing.

---

## Phase 1 -- gold images on GitHub

Goal: on a Mac that has never seen the dev tree, the app's Download button
produces a booting, helios-answering guest for all three OSes.

> Script side DONE 2026-07-15 (SPARCplug ad5c72c): `publish-prep.sh` is
> the read-only verification gate (item 1's checklist, executable),
> `docs/PUBLISH_PREP.md` carries the strip/rotate mutation recipes, and
> `build-catalog.sh` grew `--tag` + the `--publish` GitHub tail (item 2),
> dry-run verified. Remaining: Todd's hands-on half -- pick the root
> password, apply the recipes per master, pass the gate, publish, then
> the stranger download test (item 4).

1. **Publish-prep each master** (the E1 verification, now a real checklist
   per image -- solaris26, sunos414, netbsd):
   - current heliosAgent binary baked in, rc-started, fail-closed auth
     confirmed (no secret = deny-all);
   - `template` user present and locked; canonical dotfiles current;
   - **`tvernon` stripped** (masters carry root + template + daemon only,
     per FIRST_RUN_EXPERIENCE.md -- the NOT DONE item);
   - root password per D3;
   - Y2K patches present (4.1.4), clock sane;
   - resolv.conf at the untouched slirp baseline;
   - boots to ready under the app; `GuestOSDetector` banner reports the
     right OS.
   Do this once, scripted or documented as `publish-prep` alongside
   `build-catalog.sh` in the SPARCplug repo, so image updates are
   repeatable and don't depend on remembering the tvernon strip.
2. **Point `build-catalog.sh` at GitHub**: `BASE_URL` becomes the release
   download URL (script takes the tag as an argument), and grow an upload
   tail: `gh release create v2026.07 --repo toddvernon/macxserver-images`
   + asset upload + push the updated catalog.json. One script run = one
   published image set, same as the macxserver.com design intended.
3. **App change**: `ImageCatalog.defaultURL` -> the raw catalog URL.
   Existing file:// fixture tests unchanged.
4. **Verify like a stranger**: on the other Mac (or a clean account), with
   no `SPARCPLUG_CATALOG_URL` in the environment, download all three
   through the app UI over the real network. Watch the thermometer phases,
   confirm the triple verification passes, boot each to ready, create a
   user through the existing first-login flow, click an xterm chip.

Exit criteria: three green rows on a machine with no Dropbox, no dev tree,
no env overrides.

## Phase 2 -- gold notarized app, installed like a stranger

Goal: Todd installs macXserver the way a friend will: browser download
from GitHub, drag to /Applications, survive Gatekeeper, boot a Sun.

1. **`release.sh --beta`** (D2): repo override + skip the site tail.
   Small, but it's the difference between "cut a beta" being one command
   vs. a manual dance.
2. **Cut v0.9.9** -- the first real full release run, i.e. the remaining
   A5 proof (archive, helper copy-in + inside-out signing, notarize,
   staple, GitHub release).
3. **A6 clean-Mac acceptance** (punchlist, still open): fresh macOS
   account, no homebrew. Download the zip **in a browser** so the
   quarantine bit is real, drag to /Applications, first launch. Confirms
   the embedded qemu helper loads under library validation and a VM
   boots. While doing it, screenshot every Gatekeeper dialog encountered
   -- that's the raw material for the download-page walkthrough
   (GATEKEEPER_FIRST_LAUNCH.md is still open and a real tester already
   hit the "malware" dialog).

Exit criteria: v0.9.9 installed from the beta repo on a clean account
boots a downloaded image end to end. Phase 1 + 2 together make every
later test run start from real artifacts.

## Phase 3 -- test the documented flows, iterate on onboarding

This is the long middle: Todd as the product's first stranger, against
gold artifacts only.

**3a. Reset-to-stranger.** A documented, safe way to get back to
first-run. Recommendation: do all flow testing in a **dedicated macOS
account** ("tester") so the reset is scoped and can never eat the dev
Mac's real state. The full reset in that account:

- quit the app; `rm ~/.macxserver-machines.json`
- `rm -rf ~/Library/Application\ Support/macXserver` (images + locks)
- `rm ~/.macxserver-resources ~/.macxserver-launchers` (if present)
- `defaults delete` the app domain
- delete Keychain items with service `macxserver-launcher`

Ship it as a small guarded script (`Tools/reset-to-stranger.sh`, refuses
to run outside the tester account) so a reset is one command, because
there will be dozens of them.

**3b. The test matrix** (each row from a fresh reset where it matters):

| Flow | Variants |
|---|---|
| First-run bundled install | x3 OSes: bubble -> download -> add user -> boot -> xterm |
| Start on imageless machine | welcome window -> both buttons |
| Skip-the-user path | machine stays user-less, offer re-arms next ready |
| Download failure paths | cancel mid-flight; network drop; low disk |
| Add Machine wizard, external | SWS2 (bracket prompt) + 4.1.4 box (custom prompt) |
| Second copy of a curated OS | + wizard -> download fork -> two NetBSDs running |
| Adopt an existing image | wizard existing-image fork, OS detection |
| Gatekeeper first launch | fresh account, browser-downloaded build |
| App replace (update story) | new build over old: machines/images/keychain survive |

**3c. Iterate.** Findings drive the already-sketched wizard reshape (the
two validated flow charts from the 2026-07-15 session, appendix below):
blank marketing detail pane for imageless fixtures, the install wizard
container over the built download/first-login guts, optional DNS step,
curated per-OS launcher seeding (the biggest net-new piece: distill the
ss2 sweep + feature matrix into "works on this OS AND present on this
image" launcher sets, validated against the actual masters). Sequence by
what testing shows hurts most, not by the sketch order. FIRST_RUN docs
get updated to match what ships (the in-window-vs-wizard DECISIONS append
lands with that work).

**3d. Onboarding surface.** The site's download page grows the Gatekeeper
walkthrough (from 2's screenshots) and a five-minute quickstart that
mirrors the tested flow exactly. Nothing on the page describes a flow
that wasn't run from the matrix.

Exit criteria: every matrix row green on gold artifacts, quickstart
written from lived runs, the worst friction items from 3c fixed.

## Phase 4 -- seed friends

Gates before the first invite (all small, all data-safety or dignity):

1. **Restore from Backup** in-app (punchlist #3 -- auto-backup exists,
   restore doesn't; becomes real the moment a friend has hours in a
   guest disk).
2. **Known-issues doc** in the beta repo README, honest.
3. **Feedback channel**: Issues on the private beta repo (invite =
   access to both releases and issues).
4. **Update story told plainly**: no auto-update in beta; re-download
   the zip, replace the app; machines, images, and logins survive
   (proven by the matrix's app-replace row).

Mechanics: invite 2-3 friends, watch the first sessions closely (offer a
screen-share for #1), fix, widen. Every friend's first five minutes is a
free rerun of the matrix by someone who didn't write it.

---

## Out of scope for beta (deliberate, mostly already ledgered)

- Auto-update / Sparkle (re-download is the story).
- Download resume (restart-from-zero, 250 MB).
- Re-download-over-existing / factory reset UI ("delete in Finder,
  download again" is the honest v0).
- Images-directory preference UI (D4, defer).
- Catalog update checking / "new image available" UX.

## Appendix -- the validated flow sketches (2026-07-15 session)

Kept here as the reference for phase 3c so we don't re-derive them; the
detailed annotated versions (built vs. new markers, failure paths) are in
the 2026-07-15 session notes and move into FIRST_RUN_EXPERIENCE.md when
that work starts.

**Adopting a real machine (shipped; one change pending):** wizard
name/kind -> host+OS -> login proved live (rejection retypes, unreachable
offers Continue Without Checking, success always confirms the prompt
needle) -> launchers -> summary -> Create. The pending change: the
launcher step seeds the curated OS-keyed set (xterm palette + known-good
X apps), not a single xterm.

**Fresh-install bundled machine (proposed reshape of the built flow):**
imageless fixture shows a blank detail pane with marketing copy + one
"Install a Bootable Starter Disk Image" button -> install wizard (image
location w/ good default, username+password, optional DNS defaulting to
untouched slirp, summary) -> download w/ triple verification on the row
thermometer -> boot -> deferred user creation (+ resolv.conf iff given)
-> green row with curated per-OS launchers. Skip and failure paths keep
the built semantics (invitation not a gate, guest stays up on add-user
failure, Cancel commits nothing).
