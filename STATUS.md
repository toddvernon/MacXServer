# Status 2026-07-17 (session roll, desktop)

## Headline: the bundled release images are actually clean now. All three
stripped, swept, and verified; the local dev catalog rebuilt and armed off
the stripped set; the sunos414 "BAD" verdict turned out to be a false
alarm from a 4.1.4 ls quirk. Plus a small app fix: an imageless bundled
machine locks to the Overview install pitch.

## What happened this session

**Imageless bundled machines show Overview only** (MachinesWindowView).
When a bundled machine has no image yet, the Overview/Settings/Launchers
segmented picker disappears and the pane pins to the starter-hero install
pitch. The page switch is guarded (not just picker-hidden), so losing the
image while sitting on Settings snaps back to the invitation instead of
stranding a dead tab. Scoped to bundled machines: a user-created
imageless VM keeps all three tabs since Settings is where it gets fixed.

**The strip list grew: fred and synology** (Todd's calls). fred is his
second daily test account; it really was on solaris26 and netbsd gold
(stripped from both, record + home). synology (uid 1025, his NAS-mount
login) was found in 4.1.4's passwd and joined the list too. Both are in
strip-release.sh and the publish-prep gate now.

**sunos414 was never bad.** Booted the "BAD" copy to debug the rm
failure: records and homes were already gone. The real bug was the
verify: SunOS 4.1.4 ls prints "not found" but EXITS 0 on a missing
operand (old-BSD ls), so the ls -d existence check false-alarmed. Exit
codes otherwise propagate fine over helios (proved with exit 3). Both
scripts now verify with `sh -c 'test -d ...'`; the gate had the same bug
inverted and would have failed a CLEAN 4.1.4 image forever. No re-cut
was needed.

**Homes-parent sweep** (new surgery step + gate check). Gold accumulates
dev residue outside any account's home: cx build tars, test binaries,
redeploy scripts on 4.1.4; TT_DB + tmp on solaris26; tmp on netbsd.
strip-release.sh now sweeps everything but lost+found out of the homes
parent (each removal logged); publish-prep gates on it. Watch item:
TT_DB is ToolTalk's per-filesystem db dir, regenerable on demand, but if
dt-apps misbehave on the published solaris26 it's the first suspect
(whitelisting it next to lost+found is a one-liner).

**All three release copies stripped + verified, catalog rebuilt.**
./build-catalog.sh --local ran clean off the stripped set; the armed
dev catalog (~/.macxserver-dev-catalog.json -> catalog-staging, tag
v2026.07) now serves exactly what users will get. Guests halted cleanly,
no qemu running, no locks. Todd is testing the wizard flow against it.

Docs updated to match: SPARCplug docs/PUBLISH_PREP.md (including the ls
quirk warning), HELIOS_USER_MANAGEMENT.md, BETA_PLAN.md.

## What's working / what's broken

- solaris26 / sunos414 / netbsd release copies: stripped (tvernon, fred,
  synology, template), homes parents swept to lost+found, verified.
  Trustworthy.
- Local dev catalog armed off the stripped set. Disarm with
  `rm ~/.macxserver-dev-catalog.json`.
- Gold still carries all the accounts and junk BY DESIGN (gold never
  changes); every future cut gets the full treatment automatically.
- swift build clean after the Overview-only change; SourceKit phantom
  errors on recent code persist (compiler disagrees, carried).

## What's next

1. Todd's wizard-flow testing against the stripped catalog (in progress
   when this session closed).
2. Todd's phase-1 half: pick the published root password, then
   cut/strip --root-password/gate/--publish x3, then the stranger
   download test.
3. A6 clean-Mac acceptance with the v0.9.9 beta artifact.
4. Phase 3c remainder: per-OS curated launcher seeding.
5. Carried: CanonicalDotfiles DISPLAY decision, UserAdmin live test on
   2.6/4.1.4, DefaultLaunchers.swift retirement.

## Committed / push state

- X repo, main: Overview-only for imageless bundled machines, strip-list
  doc updates, this roll. Pushed at /eos (hashes in the /eos summary).
- SPARCplug, main: fred + synology strip, homes-parent sweep, the 4.1.4
  ls-quirk verify fix in strip + gate, PUBLISH_PREP.md. Pushed at /eos.
- cx repos: untouched this session.

## Switching Macs

- Pull X + SPARCplug. MachinesWindowView changed: Xcode rebuild needed.
- The armed dev catalog, catalog-staging/, release-images/, TESTIMAGES,
  and DerivedData are all THIS-Mac-local. The other Mac needs its own
  cut/strip/--local run to test the download flow there.
- No VM left running; no image locks anywhere.
