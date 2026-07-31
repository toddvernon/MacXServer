# Status 2026-07-31 (Mac Studio)

## Headline: macXserver understands IRIX 6.5. Yesterday's Indigo became a
## fleet member; today the Mac side caught up: MachineOS grew .irix65 (the
## first external-host-only OS), with every per-OS value probed live on
## the box over helios before it was written down. Items 6-9 of the
## 07-30 IRIX-integration queue landed in one pass.
## NOTE: the 07-28 rebrand-to-macSPARCstation queue is STILL front of
## queue and untouched; carried below in full.

## What happened today

One commit in this tree: e9299ad "IRIX 6.5 joins MachineOS: first
external-host-only OS". Committed to main, NOT yet pushed.

**The shape:** MachineOS gained `.irix65` plus an `emulatable` flag.
IRIX can't be emulated by the bundled qemu-system-sparc, so the flag
gates the emulation-only surfaces (bundled fixtures, starter-image
seedOS picker, qcow2 OS picker, the emulated branch of the Settings OS
picker); the emulation-only profile properties (bootDiskUnit,
bootCommand, console markers, progress transcripts) hold commented
inert values. The exhaustive-switch forcing function
(GUEST_OS_PROFILE.md) worked exactly as designed: the build refused
until all ~15 per-OS behaviors were answered. DECISIONS.md has the
entry (one enum + capability flag, not a parallel ExternalOS type).

**Every guest-facing value was probed live on indigo4k first** (small
newline-JSON helios client from the Mac, run_command verbs):

- shutdownCommand `/etc/shutdown -y -g0 -i0`, lockstep with heliosAgent
  PROTOCOL.md (init 5 is NOT power-off on IRIX).
- detect() maps sysnames IRIX and IRIX64 both to .irix65, so the
  sysinfo prober auto-adopts the OS on real SGI boxes.
- ClockAdmin: `/sbin/date` (bin/date and usr/bin/date are symlinks),
  SVR4 grammar. Both set forms (MMddHHmm.ss and MMddHHmmccyy) executed
  on the box against its current time: exit 0, clock lands right, `+%Y`
  prints 2026 -- no Y2K gate needed on 6.5.8f.
- UserAdmin: stock 6.5 is unshadowed -- hash in /etc/passwd field 2,
  4.1.4-style. Homes in /usr/people (learned, not assumed). SGI
  reserved-name roster lifted from the actual stock passwd (sysadm,
  cmwlogin, sgiweb, rfindd, ...; the mixed-case EZsetup/4Dgifts can't
  collide with our [a-z] username rules). loginShell probe now walks
  candidates ([/usr/local/bin/tcsh, /bin/tcsh]) so IRIX users get
  /bin/tcsh instead of falling to csh.
- xBinDirs `/usr/bin/X11`; curatedAppLaunchers(.irix65) = the 4
  hand-verified apps (xterm/xclock/xcalc/xman) + 6 present-on-box and
  proven under macxserver from the other guests' lists.
- ImagePorts.externalHost (23/22/2125) is now a named constant, was two
  drifting inline copies.

**Tests:** 1588 pass. New IRIX pins in QemuEngine/ClockAdmin/UserAdmin
tests; fixture-count tests now key on `emulatable`; the catalog
unknown-OS fixture renamed to ultrix45 (irix65 is a known OS now).

## What's working / what's broken

- Working: swift build + full test suite green. Indigo4k already exists
  in the live machines.json (external host, os unset); on the next app
  rebuild the prober will adopt IRIX 6.5 and the dashboard line renders
  "IRIX 6.5 IP20 · 384MB · ..." with no further config.
- The RUNNING app predates all of this -- needs an Xcode rebuild before
  any of it is visible.
- Indigo4k entry rides telnet transport; with the agent live, helios is
  the better daily path (passwordless, PATH from the OS profile). Its
  launcher list is just one xterm; the curated IRIX set can be pasted
  in while the app is quit.
- Deployed agent on the Indigo still predates the /proc disk filter and
  the sysmp-first avenrun fix (repo has both) -- dashboard will show a
  bogus "/proc 14% full" row until the next tar ships up.
- GNU grep still absent on the Indigo; helios search verb errors there.
- Indigo RTC battery still a watch item (1970 after a power cycle = the
  Dallas chip).
- Release images: cut and publish-ready ON THE LAPTOP ONLY; held
  pending the rebrand URLs.

## What's next

**Front of the queue (carried from 07-28, untouched again today -- the
rebrand must settle before publish):**

1. Todd answers the four rebrand sub-decisions: (a) display casing
   (assume macSPARCstation), (b) rename macxserver-images in place
   (recommended: raw-URL redirect keeps v0.9.9 beta binaries alive) vs
   fresh repo, (c) lockstep .macxserver-lock rename or leave, (d)
   bundle id com.toddvernon.macsparcstation.
2. Execute the rename batch: images repo + pinned URL FIRST (unblocks
   --publish), then app identity + strings + config paths + migration.
3. New site: clone MacXServerSite as the base for macsparcstation.com,
   rework around the grander pitch; banner the old site over.
4. ./build-catalog.sh --publish from THE LAPTOP (images gated and
   waiting; tag defaults to v2026.07) once URLs are final.
5. Virgin-box end-to-end acceptance: fresh account, real domain, real
   download, install wizard, boot to ready.

**IRIX follow-ups (small):**

6. Xcode rebuild + click-through: Indigo4k adopts IRIX 6.5 in the
   Overview, Settings OS picker shows it (external hosts only), wizard
   seedOS list does NOT show it.
7. Indigo4k entry polish (app quit first): transport -> helios, paste
   the curated launcher set, verify a helios xterm launch end-to-end.
8. Ship the next heliosAgent tar to the Indigo (picks up the /proc
   filter + sysmp avenrun); install GNU grep tardist or set HELIOS_GREP.
9. Clock panel + user admin against the Indigo live (the builders are
   probe-verified; the full pipelines haven't run against it yet).

**Carried from earlier sessions:** Xcode rebuild + click-through of the
07-28 UX consolidation (wizard domain field, settings panes, seeded
launchers, image-folder mover, Forget Password, slimmed menus); laptop
machines.json fixture reseed (optional); CanonicalDotfiles DISPLAY
decision; UserAdmin live test on 2.6/4.1.4.

## Committed / push state

- X, main: e9299ad (IRIX MachineOS support, docs, tests) + the STATUS
  rolls. Pushed at /eos.
- cx family + SPARCplug: untouched today.
- Off-ledger: the Rachio yard weather page got its chart layout fixed
  (wind + rainfall now full-width, x-axis labels thin to fit) and was
  deployed to the pi. Lives in ~/Dropbox/dev/Rachio (Dropbox-synced,
  not one of the session repos).

## Switching Macs

- The Indigo stays up as a boot-wired fleet member.
- Release images still wait on the LAPTOP; rebrand queue is the gate.
