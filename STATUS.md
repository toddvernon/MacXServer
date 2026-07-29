# Status 2026-07-28 (MacBook Pro, second session, end of day)

## Headline: PIVOTAL DAY. The product rebrands to macSPARCstation
## (macsparcstation.com) before first real release. Also: all three
## release images are cut, stripped, gated, and publish-ready with the
## published root password ("root") -- publish deliberately HELD until
## the rebrand settles the repo names and pinned URLs.

## What happened this session (laptop, after pulling the Studio's day)

**Release-image pipeline ran end to end.** Fresh copies cut from gold
x3, strip-release.sh with --root-password root x3 (all readback
verifies clean; 4.1.4 shed a pile of cx dev residue from /home), then
booted all three again and publish-prep GATE PASSED on all three
(solaris26 19/0, sunos414 18/0 incl. Y2K date check, netbsd 16/0; only
warns are the known-cosmetic root dotfile drift). Beyond the script's
checks I recomputed each stored DES hash host-side: root's password IS
"root" on all three. Captured .accounts lists are pure stock. Guests
halted clean, no locks anywhere. The copies live in
**~/dev/SPARCplug/release-images/ ON THE LAPTOP** (local disk, not
Dropbox, not git) -- publishing must happen from this Mac or re-cut.

**The rebrand decision (DECISIONS.md 2026-07-28 entry).** macXserver
grew into "a SPARCstation on your Mac"; the app publishes as
macSPARCstation at macsparcstation.com. NOT macsparcserver.com -- Todd
bought that first by mistake, wrong Sun line, dead domain, never use
it. macxserver.com survives as the "30 days" build-story annex.
Rationale: rename cost is at all-time minimum (zero real users,
catalog unpublished), and the virgin-box acceptance test must run
against the final brand/domain/URLs or it tests the wrong product.

**Blast-radius inventory done** (in the 2026-07-28 conversation,
summarized): Tier 1 user-visible = project.yml identity (PRODUCT_NAME,
bundle id com.toddvernon.swiftx.server), ~90 in-app string hits,
ImageCatalog.swift:72 pinned raw URL + build-catalog.sh IMAGES_REPO,
website (MacXServerSite repo, not cloned on this Mac), quickstart page
(documents root password "root"), macxserver-beta naming. Tier 2
config surface = ~/.macxserver-* files, Application Support/macXserver,
Keychain service "macxserver-launcher", /tmp/macxserver, socket names;
one-shot rename-on-launch migration recommended. Tier 3 keep = Swift
module names, xcodeproj filename, helios, historical docs.
.macxserver-lock suffix is the judgment call (shared protocol string
with SPARCplug emu/imagelock.sh; lockstep rename recommended).

## What's next (HIGH PRIORITY, front of the queue per Todd)

1. Todd answers the four rebrand sub-decisions: (a) display casing
   (assume macSPARCstation), (b) rename macxserver-images in place
   (recommended: raw-URL redirect keeps v0.9.9 beta binaries alive) vs
   fresh repo, (c) lockstep .macxserver-lock rename or leave, (d)
   bundle id com.toddvernon.macsparcstation.
2. Execute the rename batch: images repo + pinned URL FIRST (unblocks
   --publish), then app identity + strings + config paths + migration.
3. New site: clone MacXServerSite as the base for macsparcstation.com,
   rework around the grander pitch; banner the old site over.
4. ./build-catalog.sh --publish from THIS LAPTOP (images are gated and
   waiting; tag defaults to v2026.07) once URLs are final.
5. Virgin-box end-to-end acceptance: fresh account, real domain, real
   download, install wizard, boot to ready.
6. Carried from the Studio session: Xcode rebuild + click-through of
   the wizard domain field / settings panes / seeded launchers /
   image-folder mover / Forget Password / slimmed menus; laptop
   machines.json fixture reseed (optional); CanonicalDotfiles DISPLAY
   decision; UserAdmin live test on 2.6/4.1.4.

## What's working / what's broken

- Publish pipeline proven end to end through the gate; nothing broken.
- Neither the app nor swift build was touched this session; the tree
  is the Studio's pushed state (842b47f) plus DECISIONS/STATUS.
- The laptop app hasn't launched since the Studio's launcher-seed work
  landed, so its ~/.macxserver-launchers self-clean + old-seed fixture
  notes from the last STATUS still apply here.

## Committed / push state

- X, main: DECISIONS.md rebrand entry + this STATUS roll (hash in the
  /eos summary). Pushed.
- SPARCplug, main: clean, nothing new (release-images/ is gitignored
  build artifacts by design). b78dc89 unchanged.
- cx tree: untouched.

## Switching Macs

- The publish-ready release copies + .accounts files exist ONLY on the
  laptop's local disk. Run --publish here, or re-cut/strip/gate on the
  other Mac (the pipeline is ~20 min, fully automated).
- No VMs running, no image locks anywhere.
- Memory got the rebrand file (project_rebrand_macsparcstation.md);
  let Dropbox sync before opening the Studio.
