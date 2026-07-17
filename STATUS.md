# Status 2026-07-17 (second roll, Mac Studio)

## Headline: the Mac Studio now has its own stripped local catalog, armed.
Same pipeline as yesterday's run (cut x3, strip x3, build-catalog --local),
executed fresh on this machine because the catalog artifacts are per-Mac.
Wizard testing against a clean stripped catalog can continue here.

## What happened this session

**Sorted out which Mac had what.** Yesterday's roll said "desktop" but the
armed catalog, catalog-staging/, and release-images/ turned out to live on
the other Mac (this Studio's repos were 15/7 behind at /sos and had no
artifacts). No harm, the pipeline is per-Mac by design; today's run gave
the Studio its own set.

**Full cut/strip/build on the Studio.** All three release copies cut from
the Dropbox gold masters, stripped over helios with readback verifies
(tvernon, fred, synology, template; homes parents swept to lost+found --
sunos414 gave up the usual cx tars and redeploy scripts, solaris26 its
TT_DB and tmp), then ./build-catalog.sh --local built catalog-staging
(499M/591M/324M payloads, tag v2026.07) and armed
~/.macxserver-dev-catalog.json. No --root-password on this run, same as
the laptop's local build: the copies keep the dev root password until the
publish pass. Guests halted cleanly; no qemu, no locks.

**Confirmed the tvernon guard in add-user.** Todd hit the wizard's red
"system account" message typing tvernon on netbsd; that's
UserAdmin.usernameProblem -> reservedNames (UserAdmin.swift:170) working
as designed (tvernon + template are reserved on every OS since the
2026-07-16 field find). Two observations left on the table, no action
taken: (1) the message text is slightly off on stripped images where
tvernon no longer exists (cosmetic, arguably right anyway); (2) fred and
synology are NOT in the reserved list, so typing fred on a gold-based
machine still hits the opaque apply-time wall; adding them to common in
reservedNames is a two-word change if Todd wants parity.

## What's working / what's broken

- Studio local catalog armed off freshly stripped copies. Disarm with
  `rm ~/.macxserver-dev-catalog.json`. Laptop has its own equivalent set.
- All strips verified clean on the first pass, including the 4.1.4
  test-d verify fix from yesterday (no ls false alarms).
- No code changes this session; SourceKit phantom-error carry-over from
  yesterday presumably still stands (nothing rebuilt today).

## What's next

1. Todd's wizard-flow testing on the Studio against the armed catalog
   (in progress when this session closed).
2. Todd's phase-1 half: pick the published root password, then
   cut/strip --root-password/gate/--publish x3, then the stranger
   download test.
3. A6 clean-Mac acceptance with the v0.9.9 beta artifact.
4. Phase 3c remainder: per-OS curated launcher seeding.
5. Optional small one: add fred + synology to reservedNames common (see
   above).
6. Carried: CanonicalDotfiles DISPLAY decision, UserAdmin live test on
   2.6/4.1.4, DefaultLaunchers.swift retirement.

## Committed / push state

- X repo, main: this STATUS roll only (hash in the /eos summary). All
  other repos untouched and in sync; session outputs are gitignored
  build artifacts (release-images/, catalog-staging/) by design.

## Switching Macs

- Both Macs now have their own armed dev catalog; they don't sync and
  don't need to.
- No VM left running; no image locks anywhere.
- Nothing to pull beyond this STATUS roll.
