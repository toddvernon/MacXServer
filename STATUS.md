# Status 2026-07-12

## Headline: fleet ops day -- color xterm everywhere, the 4.1.4
date-year trap closed (Y2K patches found + deployed + reboot-proven on
real hardware), every clock synced, and a new Clock admin agent in the
app (dd66491) that makes future syncs a button with a Y2K-probe-gated
Force Set path.

## What happened this session

**Color xterm deployed fleet-wide.** The R6 ANSI-color xterm from the
sunos VM image copied over Helios to ipc/ipx/ss1/ss5 at
/usr/openwin/bin/xterm (sum 37852 208 verified per box), distro binary
preserved as xterm.orig everywhere; the VM's old `xterm.old` renamed to
match. Verified loadable on all four (R6 shared libs present).

**ss5 DISPLAY residue cleaned + upstream issue ledgered.** ss5's
qcow2-heritage dotfiles set `DISPLAY=10.0.2.2:0` (slirp gateway) for
root+tvernon; its heliosAgent had inherited it, making display-less X
clients hang in TCP connect (looked like a bad binary). Commented out
in all four dotfiles, agent restarted clean. The same lines turned up
in fred's dotfiles on real ipc -- written by app-side add-user, because
CanonicalDotfiles hardcodes the slirp DISPLAY. Fred fixed by hand;
**SHORTCUTS gained "Canonical dotfiles on real hardware"** (the fix --
strip/substitute DISPLAY for external hosts at plan time -- needs a
decision on the byte-exact-embed invariant). NOT residue: ss5 runs a
real console X session (X :0 + mwm + 3 xterms); left alone.

**The 4.1.4 date-year trap is closed.** Stock /bin/date can't set a
year >= 2000 (BugId 1086103) and a bad year bricks the TOD (recovery =
boot install media). Found Sun's fix -- **105143-03** (/bin/date) +
106182-02 (/usr/5bin/date) + 105147-01 (eeprom) -- on the live ICM
sunsite mirror, md5-verified, staged in
`~/Dropbox/dev/SPARCplug/patches/sunos414-y2k/`. Deployed both date
patches to the VM + all six real 4.1.4 boxes (ipc, ipx, ipx2, ss1, ss2,
ss5; originals kept as date.FCS, patched sums 26729 8 / 05997 16).
Proven with the two-reboot protocol: baseline reboot, year-set with the
patched date, reboot again -- clean on the VM and on **real ipx** (real
Mostek round-trip, back in ~75s both times).

**Every fleet clock synced to the Mac** using the safe 8-digit no-year
`date -u mmddhhmm` form (ss5 was -7d, ipc +57m, ipx +1h45m, ss2 -2h10m,
ipx2 +10m). Gotcha discovered: a big forward jump makes the in-flight
helios run_command report timed_out (agent deadline uses guest wall
clock) -- harmless, verify with a fresh request.

**Clock admin agent shipped (dd66491).** Overview -> Helios Admin
Agents -> **Clock**: shows plain-English skew (sysinfo.time vs Mac) and
sets the guest clock as root, Mac = truth. Per-OS grammar validated
live on all three guests (BSD no-year default everywhere; year forms
only when the year is wrong; SVR4 ccyy-suffix on 2.6). 4.1.4 year
changes gate on a live `date '+%Y'` probe of the box's own binary --
probe fails => the button becomes **Force Set** behind an explicit
unbootable-risk warning (Todd's call). Fail-closed core throws before
any set reaches the box; read-back verify (15s tolerance); each request
separate (a compound set+read once wedged NetBSD). ClockAdmin.swift +
ClockPanelView/ClockWindowController, gated like Users. 15 new core
tests; DECISIONS 2026-07-12 (incl. rejected rdate-cron alternative --
guest-side moving parts + boot-hang reach). xcodegen re-run.

## What's working / what's broken

- swift build + xcodebuild clean; swift test **1570 tests, 0 failures**.
- Clock panel NOT yet eyeballed in the running app (needs an Xcode
  rebuild; all clocks currently read in-sync, so knock a VM clock
  sideways to see the interesting path).
- Still NOT eyeballed from before: menu-bar reorg, download flow,
  first-run choreography (the standing manual GUI pass).
- ss5 heliosAgent env still carries harmless residue (REMOTEHOST, PWD
  from an old telnet session); clears on next boot.

## What's next

1. **Todd's manual GUI pass** (carried): menu-bar reorg, download flow
   (SPARCPLUG_CATALOG_URL), first-run choreography -- now plus the new
   Clock panel (normal set + the Force Set warning path).
2. **CanonicalDotfiles DISPLAY decision** (new, SHORTCUTS): strip or
   substitute the slirp DISPLAY when add-user targets an external host.
3. Catalog data side: E1 baseline masters -> build-catalog.sh -> upload;
   root-password policy for published masters. (The sunos414 master now
   carries the Y2K date patches + xterm.orig convention.)
4. Cut v0.9.9 (A5/A6 release pipeline proof).
5. UserAdmin live test against Solaris 2.6 + 4.1.4; retire orphaned
   DefaultLaunchers.swift.

## Committed / push state

- X repo: dd66491 (clock admin agent) committed to main, NOT pushed.
- SPARCplug / cx repos: no changes.

## Switching Macs

- Swift sources + xcodeproj changed: pull, then rebuild in Xcode.
- Three VMs running under this Mac's Xcode debug build (solaris26,
  sunos414, netbsd; locks held). The sunos414 image gained today's
  patches (date + date.FCS, xterm.orig rename) -- next quit backs it up.
- Y2K patch tarballs are in Dropbox (SPARCplug/patches/sunos414-y2k/),
  so they ride to the other Mac automatically.
