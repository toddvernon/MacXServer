# Status 2026-06-30 (late)

## Headline: cx build-system rationalized (Mac + Linux green). Tomorrow is the glorious helios day.

Spent the session cleaning up the cx build system: all platform detection is
now centralized, the SunOS/Solaris directory collision is fixed, archives are
consolidated and object-safe, and build junk is out of Dropbox sync. Mac and
Linux both build and test clean. The remaining piece is validating the three
SPARC guests over helios.

## TOMORROW (the plan, and it will be glorious)

**Build everything on all the Sun VMs via helios and fix whatever breaks.**
Boot NetBSD 9.2 / SunOS 4.1.4 / Solaris 2.6, drive the builds over the helios
daemon (run_command), and shake out the cross-platform problems:

1. Ship the updated cx makefiles + `cx/platform.mk` to each guest (they hold
   older copies) -- git pull on guest if it has the repo, else tar+ship.
2. Build cx libs + cx_tests + heliosAgent on each guest. Fix what breaks.
3. **NetBSD: prove the NORMAL makefile path works now** (the ARCH drift that
   scattered libs across lib/netbsd_sparc vs lib/netbsd_ is fixed) and then
   RETIRE `cx_apps/heliosAgent/build_helios_netbsd.sh`.
4. **Tighten the thread/tz Solaris gates**: the top cx + cx_tests makefiles
   gate with `[ "$(UNAME_S)" != "sunos" ]`, which wrongly excludes Solaris too.
   Now that PLATFORM_OS distinguishes sunos4 from solaris6/10, make it
   sunos4-only -- but validate on real Solaris before flipping.
5. Surface/fix any lib that should build on a platform but is excluded.
6. Fold in the uncommitted SunOS source fixes (getopt decl, vsnprintf shim,
   -lsocket/-lnsl per-release split).
7. IRIX last, via the real Indy (Indigo PSU is dead) -- deferred.

Full detail lives in memory: project_cxlibs_arch_build_cleanup.

## What's working / done this session

- **`cx/platform.mk`** is the single source of truth for platform detection.
  All 58 makefiles (cx libs, cx_tests, cm, ss, heliosAgent + test) now
  `include` it instead of carrying a copy-pasted ~60-line uname block that had
  drifted.
- **Dir naming: `$(PLATFORM) = $(PLATFORM_OS)_$(ARCH)`.** PLATFORM_OS encodes
  the sun-family release (sunos4 / solaris6 / solaris10) so their incompatible
  binaries never collide in one lib dir (the NFS problem). linux_x86_64 and
  darwin_arm64 are unchanged. The compile macro (-D _SUNOS_ etc.) stays
  separate from the dir token and is untouched.
- **Archives consolidated into the umbrella makefile** (~/Dropbox/dev/cx/makefile):
  the three targets (cxlibs/cxapps/cxtest_unix.tar) now exclude object dirs with
  anchored <os>_* patterns + a complete file-type list, and ship platform.mk.
  The duplicate archive targets in cx/makefile and heliosAgent/makefile were
  deleted (get-helios.sh already builds from the umbrella).
- **Object dirs out of Dropbox sync**: com.dropbox.ignored on 132 paths (all
  per-platform obj dirs + lib/). Deleted 12 orphaned empty-arch `linux_` dirs.
- **Regressions caught + fixed**: regex BUILD_REGEX and ss DEVELOPER opt-ins
  (module-local logic my bulk transform ate, restored after the include).
  Latent bugs fixed: clean lib path, netbsk typos, double-darwin ARCH.
- **Clean-from-scratch build + tests green on Mac** (16/16 libs, every cx_tests
  suite 0 failed, cm/ss/heliosAgent link, helios_test 131/0). **Linux verified
  by Todd** (no-op, dir name unchanged).

## Committed this session (all pushed to origin/main)

- `~/Dropbox/dev/cx` (umbrella): 90d80b4 -- archive hardening + platform.mk shipped
- `~/Dropbox/dev/cx/cx`: 99f0575 (platform.mk + conversions), ba42900 (drop dup archive)
- `~/Dropbox/dev/cx/cx_tests`: c51ed1f
- `~/Dropbox/dev/cx/cx_apps/cm`: 70ed933
- `~/Dropbox/dev/cx/cx_apps/ss`: e99383b
- `~/Dropbox/dev/cx/cx_apps/heliosAgent`: 6081ab3 (conversions), 4867d09 (drop dup archive)
- `~/dev/X`: this STATUS roll.

## Switching Macs

- **Let Dropbox finish syncing the cx tree + `.claude-memory/`** before opening
  the other Mac.
- **On the desktop, re-apply the Dropbox no-sync on cx object dirs** (it's a
  local xattr, not git, so it doesn't travel). From `~/Dropbox/dev/cx`:
  ```sh
  find cx cx_tests cx_apps -type d \( -name 'darwin_*' -o -name 'linux_*' \
    -o -name 'sunos*' -o -name 'solaris*' -o -name 'netbsd_*' -o -name 'irix*' \
    -o -name 'nextstep_*' \) -exec xattr -w com.dropbox.ignored 1 {} \;
  xattr -w com.dropbox.ignored 1 lib
  ```
- No VM was running this session; no image lock to worry about.
