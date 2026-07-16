# Status 2026-07-16 (evening roll, desktop)

## Headline: v0.9.9 is live on the beta repo, the bundled install became
a wizard and got field-tested same day, and the publish surgery is now
automated. Test-what-users-get is almost real: solaris26's release copy
is stripped and cataloged; sunos414's strip hit a real bug (homes
survived the rm); netbsd waits on a port.

## What happened this session

**v0.9.9 beta cut** (release.sh --beta, built + proven same day).
--beta publishes the identical signed/notarized/stapled artifact to the
private macxserver-beta repo and skips every public surface (Hugo
bump, site deploy, project.yml bump/commit/push). First run 403'd:
Apple wanted the updated Program License Agreement accepted -- that's
the first check on any future mystery notary failure. After Todd
accepted, the full pipeline ran clean: notarization Accepted, staple
validated, spctl says Notarized Developer ID. Closes the A5 proof; A6
(clean-Mac acceptance) remains.

**Tools/reset-to-stranger.sh** (phase 3a). One-command wipe to a true
first run, hard-gated to the dedicated tester account (no force flag)
and refuses while the app or a qemu guest runs. Both guards verified
live; the wipe path first runs for real in the tester account.

**Bundled install is a wizard** (DECISIONS 2026-07-16, supersedes the
2026-07-10 in-window half; Todd's call after the Add Machine wizard
field test). Imageless machine's Overview = hero marketing pane + one
Install button -> InstallStarterWizardView: location (images dir,
prefilled, persists as the one global pref only when changed) -> login
(collected BEFORE download; no popups after) -> network (default
touches nothing; optional DNS written at ready, failure soft) ->
summary-as-confirm. Bubble, blue Download button, isFirstRun retired.
pendingFirstLogin cleared on failure/cancel so credentials never
outlive their install.

**Dev catalog dotfile** (Todd field-tested the wizard, hit the empty
public catalog, and the env-var answer was unusable from Xcode).
DEBUG builds read ~/.macxserver-dev-catalog.json as the catalog when it
exists; compiled out of Release. build-catalog.sh --local (new) emits a
fully-offline file:// catalog from release copies and arms the symlink.
Wizard summary + NSLog announce dev-catalog mode. Todd's full wizard
run WORKED end to end against it (download, boot, TESTIMAGES custom
location honored) right up to...

**...the tvernon collision, which drove three fixes** (Todd's calls):
1. *Reserved usernames*: UserAdmin.reservedNames(os:) per-OS stock
   account lists (union when OS unknown); usernameProblem(os:) wired
   into the wizard, FirstLogin, and addUser. Typing tvernon/root now
   fails at the keyboard, not after boot.
2. *Local catalogs use STRIPPED images* -- test what users get. New
   strip-release.sh automates the whole publish surgery: boots the
   release copy headless (console to log), strips accounts with
   readback verifies, optional --root-password rotation, halts on the
   console halt marker, reaps qemu + lock.
3. *Template account goes too*: HELIOS_USER_MANAGEMENT already ruled it
   dead weight; publish-prep gate FLIPPED from "template present +
   locked" (wrong, mine) to "both dev accounts absent"; dotfile check
   demoted to advisory WARN against root's home. Docs updated both
   sides (PUBLISH_PREP.md around the automated path, FIRST_RUN line
   corrected to "root + stock system accounts only").

## What's working / what's broken

- swift build clean; 1581 tests / 0 failures (reserved-name tests
  added; the duplicate-refusal test refixtured off tvernon).
- solaris26-release.qcow2: STRIPPED and verified (tvernon + template,
  records + homes), clean init-5 power-off. Trustworthy.
- **sunos414-release.qcow2: BAD -- delete + re-cut.** Records stripped
  but BOTH home dirs survived `/bin/rm -rf` (script caught it and
  failed honestly). Debug next session: boot the copy, run the rm by
  hand over helios, read the error. Suspects: 4.1.4 rm path/symlink
  quirk, or /home mount weirdness on the converged image.
- netbsd release copy: not yet stripped -- Todd's wizard-test NetBSD VM
  holds port 2145 (image in ~/TESTIMAGES; lock is machine-local).
- The armed dev catalog (~/.macxserver-dev-catalog.json) still points
  at the OLD un-stripped staging set. Rebuild after all three strips.
- SourceKit shows phantom errors on the new code; compiler disagrees.

## What's next

1. Finish the stripped local catalog: shut down the test NetBSD VM,
   re-cut + strip sunos414 (debugging the rm failure), strip netbsd,
   ./build-catalog.sh --local, then re-run the wizard flow against
   what users will actually get.
2. Todd's phase-1 half: pick the published root password, then
   cut/strip --root-password/gate/--publish x3 (the automation now does
   the heavy lifting), then the stranger download test.
3. A6 clean-Mac acceptance with the v0.9.9 beta artifact (tester
   account; screenshots feed the Gatekeeper walkthrough).
4. Phase 3c remainder: per-OS curated launcher seeding (the big
   net-new piece).
5. Carried: CanonicalDotfiles DISPLAY decision, UserAdmin live test on
   2.6/4.1.4, DefaultLaunchers.swift retirement.

## Committed / push state

- X repo, main: 0c85854 (install wizard) -> 9e2ea4b (dev-catalog
  dotfile) -> 912436e (reserved usernames + FIRST_RUN fix) + earlier
  today 3a8b0e1 (release.sh --beta), f7c511f (v0.9.9 ledger), f3693cf
  (reset-to-stranger), 0cf65e9 (morning STATUS) + this roll. Pushed at
  /eos.
- SPARCplug, main: 83cb61b (--local) -> d5728f9 (dotfile arm) ->
  fcd18c0 (strip-release + gate flip) -> c18a8d0 (self-released lock
  fix). Pushed at /eos.
- macxserver-beta: release MacXServer-v0.9.9 (zip + GPL source).
- cx repos: untouched this session.

## Switching Macs

- Pull X + SPARCplug. App code changed a lot: Xcode rebuild required
  (xcodegen already ran for the new wizard file).
- The dev-catalog dotfile, TESTIMAGES dir, DerivedData build, and
  release-images/ staging are all THIS-Mac-local; the other Mac needs
  its own --local build if testing there.
- Todd's test NetBSD VM may still be running here (left to his call at
  /eos); its image + lock live in ~/TESTIMAGES, machine-local, so the
  other Mac can't collide with it.
