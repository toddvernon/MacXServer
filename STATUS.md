# Status 2026-06-30 (evening)

## Headline: all three SPARCplug guests now run heliosAgent

Big session. SunOS 4.1.4 got bootstrapped end to end and now runs heliosAgent
alongside Solaris 2.6 and NetBSD 9.2. I can drive all three guests from the Mac
over the helios JSON daemon -- including compiling software on them remotely,
which is how I built ncftp on the SunOS box without ever logging in.

## What's working

- **NetBSD 9.2 guest fully set up:** root password (Kemosabe1) + passwordless
  ed25519 key login, `PermitRootLogin yes`. heliosAgent installed as an rc.d
  service (`/etc/rc.d/heliosagent`, `heliosagent=YES`), listening on guest 2125,
  reachable from the Mac via the 2145->2125 hostfwd. Reboot-survivable.
- **SunOS 4.1.4 guest fully set up:** heliosAgent built on-box and running
  (guest 2125, Mac via 2135->2125), installed via deploy.sh's new sunos4 branch
  (/etc/rc.local stanza). `run_command` confirmed (uname, etc.). ncftp 2.4.3
  built + installed to /usr/local/bin, defaulting to passive mode for both
  tvernon (~/.ncftp/prefs) and root (NCFTPDIR=/.ncftp in /.cshrc, since root's
  home is `/` and ncftp won't use the fs root as a config dir).
- **deploy.sh is now multi-platform:** solaris (SysV) / netbsd (rc.d) / sunos4
  (rc.local), with robust binary search. New init/heliosagent.netbsd rc.d script.
- **sunos414-full.sh gained an `ISO=` flag** to attach a CD. The hard-won part:
  qemu-sparc needs an explicit `-device scsi-cd,scsi-id=6,logical_block_size=512`
  -- Sun only talks to 512-byte CD sectors, and the bare `-drive media=cdrom`
  form parks the disc empty at id 2. See memory reference_sparcplug_sunos_cdrom_512.
- Mac-side helper `helios.py` (in this session's scratchpad) drives any guest via
  run_command (cmd/cwd/user fields).

## What's broken / rough

- The SunOS heliosAgent binary rests on hand-edits + a `vsprintf` stopgap (4.1.4
  lacks vsnprintf). The PROPER fixes (bounded vsnprintf shim, getopt decl,
  -lsocket/-lnsl per-release split) are in the Mac repo, uncommitted-until-this-eos.
  Plan: pull the real sources over the now-working channel, rebuild, redeploy.
- Reboot-survival on SunOS (rc.local) not yet verified with an actual reboot.

## What's next

- **cx makefile arch-detection cleanup** (the agreed punch list, not started --
  see memory project_cxlibs_arch_build_cleanup): build dirs collapse to
  `sunos_` (empty arch suffix); fix ARCH across all platforms, keep Mac building,
  then validate library+test+helios builds on all three guests via helios. Fast
  because Claude drives the builds over the wire.
- Clean-rebuild SunOS heliosAgent from the committed sources (bounded shim).

## Committed this session

- `~/dev/X`: this STATUS roll.
- `~/dev/SPARCplug`: sunos414-full.sh ISO= flag + 512-byte CD fix (iso-payload/
  staging is gitignored -- regenerable build artifacts, ~26MB).
- `~/Dropbox/dev/cx` (cx_apps/heliosAgent): SunOS 4.1.4 build porting +
  multi-platform deploy.sh + netbsd rc.d script.

## Switching Macs

- The SunOS 4.1.4 VM was LEFT RUNNING (with the helios-cx ISO attached). If you
  open the other Mac, the image lock will block it -- shut the VM down first
  (halt at the console, Ctrl-A X) or it'll show remoteLocked.
- Let Dropbox finish syncing the cx tree + `.claude-memory/` before the other Mac.
- The other cx agent was working the NetBSD lib fixes in the cx/ subtree (clean
  here); coordinate before assuming that's done.
