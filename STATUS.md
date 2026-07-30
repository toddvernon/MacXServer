# Status 2026-07-30 (Mac Studio, end of day)

## Headline: IRIX day. The PSU-repaired Indigo came back to life and by
## end of day it's a full helios fleet member: cx libs, cm, and
## heliosAgent all ported to IRIX 6.5, agent validated live over the
## wire, deployed with boot wiring. First non-Sun machine on the fleet.
## macXserver-side integration is deliberately deferred to a follow-up
## session (list below).

## What happened today

All of today's code landed in the cx-family repos (cx, heliosAgent,
cm), not this tree. This STATUS is the cross-reference.

**The machine:** SGI Indigo R4400 (IP20), hostname indigo4k, revived by
Todd's ITT PEC4044B power supply repair (writeup:
https://oldsilicon.com/technologies/indigo-pec4044b-power-supply-repair/
-- thermally drifting cap in the supervision circuitry commanding false
shutdowns; scoped the status pin to prove commanded-vs-forced before
touching parts).

**X server validation, zero changes needed:** IRIX xclock (with second
hand, so a 1s redraw cadence soak), xman, and the stock /usr/bin/X11
clients all rendered correctly against macxserver. First client lineage
that isn't Sun/MIT-on-Sun. xscope exists on the box as an era-correct
protocol second-opinion (proxy display :1) if we ever want to diff a
decode against macXcapture's.

**The port, in commit order of pain:**

- cx libs built on IRIX essentially clean. One real fix: logfile.cpp
  called pthread_self() everywhere but SunOS 4; on IRIX that's
  libpthread-only, and linking libpthread into a forking daemon changes
  6.5 libc process semantics, so the thread-id log column is guarded
  out like SunOS. platform.mk also learned uname -s = IRIX64 (64-bit
  kernels, same n32 userland -> same irix6 platform).
- heliosAgent needed: a signal-handler cast (SGI C++ headers declare
  handlers as `void (*)(...)`; "prohibits conversion from (int) to
  (...)" is the tell), -lelf for nlist (xload's -lmld answer is
  COFF/o32-era; no n32 libmld on 6.5), per-OS grep default
  (/usr/freeware/bin/grep -- base grep has no -r), and the IRIX
  shutdown command (/etc/shutdown -y -g0 -i0; init 5 is NOT power-off
  there).
- Full SysInfo collector for IRIX: mem via sysmp(MP_SAGET, MPSA_RMINFO),
  swap via swapctl(SC_GETSWAPTOT/SC_GETFREESWAP), disks via
  getmntent+statvfs, load via nlist("/unix","avenrun") + /dev/kmem at
  FSCALE 1024, lifted from xload's #ifdef sgi in reference/X11R6.
  Validated live: sysinfo load matched uptime to the digit, memMB 384,
  hostid = IP (correct SGI behavior, not a bug).
- Deploy: init/heliosagent.irix (SysV + chkconfig-aware, no eeprom
  dance; secret comes from /etc/helios/helios.json like the real Suns),
  deploy.sh IRIX|IRIX64 case (init.d + S98/K30 links + chkconfig -f on),
  makefile install targets for irix/irix64 in heliosAgent AND cm (cm's
  silent no-op install was a user-reported bug; ss left alone, it never
  had guest installs).
- Two post-validation fixes are in the repos but NOT yet on the box
  (next tar ship-up): /proc leaked into the disks list (IRIX pseudo-fs
  mounts from a '/'-prefixed source, so the shared isLocalDisk source
  test passes it; now gated on mnt_type efs/xfs) and sysInfoStartup now
  prefers sysmp(MP_KERNADDR, MPKA_AVENRUN) over nlist for the avenrun
  address (asks the running kernel, no /unix dependency).

**Deployed state on the Indigo:** agent 0.2.0 running as a boot service,
secret file in /etc/helios/helios.json (fleet-standard value; unique
per-box secrets remain the known fleet-wide gap). RTC had reset to 1970;
date set by hand, clock-chip battery is a watch item (same failure
family as the Sun NVRAMs).

## What's working / what's broken

- Working: hello / sysinfo / run_command validated from the Mac against
  the deployed agent. IRIX X clients render on macxserver.
- Deployed binary predates the /proc disk filter and the sysmp-first
  avenrun lookup; harmless (one bogus disks row), fixed on next tar.
- GNU grep not confirmed installed on the Indigo; search verb errors
  until the freeware tardist goes in or HELIOS_GREP points somewhere
  capable.
- Indigo RTC battery suspect. If the clock is 1970 again after a power
  cycle, it's the Dallas chip.

## What's next (the macXserver integration session)

1. MachineOS gains an IRIX case: shutdownCommand must be
   /etc/shutdown -y -g0 -i0, kept in step with heliosAgent PROTOCOL.md
   (same lockstep rule as the existing three).
2. Add indigo4k as an external-host machine (helios port 2125); fleet
   heuristics confirm-don't-decide applies -- it's a new OS lineage, so
   expect every confirm.
3. Remote app launcher: IRIX flavor. Absolute paths from /usr/bin/X11,
   and a curated launcher list for the SGI (xterm, xclock, xcalc, xman
   verified today; SGI toolchest/Motif apps unexplored).
4. sysinfo prober: IRIX serves every field; check the dashboard renders
   a non-Sun uname sanely (sysname "IRIX", machine "IP20").
5. Carried from 07-28: Xcode rebuild + click-through of the UX
   consolidation, Todd's phase-1 publish half, A6 clean-Mac acceptance,
   laptop fixture reseed, CanonicalDotfiles DISPLAY decision, UserAdmin
   live test on 2.6/4.1.4.

## Committed / push state

- cx, main: logfile pthread guard, platform.mk IRIX64, PLATFORM_SUPPORT
  IRIX notes section. Pushed.
- heliosAgent, main: signal cast, IRIX SysInfo collector + post-
  validation fixes, -lelf, grep/shutdown defaults, deploy.sh + new
  init/heliosagent.irix, PROTOCOL/SYSINFO_PLAN doc rows. Pushed.
- cm, main: irix/irix64 install branches. Pushed.
- X, main: this STATUS roll only (no code). Pushed.
- SPARCplug: untouched today.

## Switching Macs

- cx family lives in ~/Dropbox/dev/cx (Dropbox-synced) AND is pushed to
  GitHub; either sync path works on the laptop.
- git pull X on arrival for this STATUS.
- Memory got a new file (reference_heliosagent_irix_port) plus updates;
  let Dropbox finish syncing before opening the laptop.
- The Indigo stays up as a boot-wired fleet member; nothing running on
  the Macs to hand off.
