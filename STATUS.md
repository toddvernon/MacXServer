# Status 2026-06-21 (end of day)

The day the Helios daemon stopped being a Mac-only thing. It now **runs on the
real SPARCplug Solaris 2.6 image**, **all 8 verbs are validated there**, and
there's a Mac-side CLI bridge so **Claude Code drives the guest over the wire** --
no console typing. We went from "compiles on the Mac" to "I can walk around
inside the image and edit files" in one session.

## Headline: Helios is live on real Solaris, and Claude can drive it

- **Built + ran on the 2.6 image.** The cx app `cx_apps/heliosAgent` compiled
  under g++ 2.95.3 and ran on SUN40G.qcow2. The listener / accept-fork /
  newline-JSON framing / dispatch and the cx `75b8304` emit fix all work on SPARC.
- **All 8 verbs Solaris-validated:** `hello`, `run_command`, `stat`, `list_dir`,
  `read_file`, `search` by hand, then `write_file` via the new CLI. `write_file`
  round-trip is byte-exact, new files come out 0644, and **mode-preservation on
  overwrite is confirmed** (chmod 600 -> overwrite -> still 0600; the
  atomic-rename re-apply path). `shutdown` does a clean root `init 5` (below).
- **`run_command` execs `/bin/sh -c`** (`process.cpp:118`), so pipes, `$PATH`,
  globs and redirects all work; stdout+stderr come back combined.

## The Mac-side bridge (Phase D1, DONE)

`~/dev/SPARCplug/helios/` (committed): `helios_client.py` (stdlib protocol
client), `helios` CLI (hello/run/read/write/ls/stat/search/shutdown),
`helios-survey` (read-only toolchain walk -> Markdown), README.

- **The seam:** the daemon listens on guest:2125 but macXserver's qemu only
  forwards 2123/2222, so reach it via an ssh local-forward over the 2222 hostfwd:
  `ssh -N -f -L 2125:127.0.0.1:2125 sparcplug`. Then everything talks to
  127.0.0.1:2125. Tunnel is independent of the daemon, survives a daemon restart.
- Ran a full **image survey** through it (SunOS 5.6 sun4m, gcc 2.95.3 / gmake 3.82
  / gdb 4.17 / grep 2.7 / OpenSSH 5.1p1 / vim 7.3 / bash 4.1; perl + python
  ABSENT; 259 entries in /usr/local/bin) and the write_file round-trip.

## GNU grep for the `search` verb

`search` shells `grep -rHn`, which stock Solaris grep can't do. Installed **GNU
grep 2.7 + pcre 8.10** from the free NUST sunfreeware mirror
(`download.nust.na/.../unixpackages/sparc/5.6`); libiconv/libintl/libgcc were
already on from the sun26gnu set. Helper: `~/dev/SPARCplug/guest/get-grep.sh`
(checks pkginfo, wgets the gap over slirp, pkgadds, ldd-verifies). Lands at
`/usr/local/bin/grep`; the daemon's PATH already prefers `/usr/local/bin`.

## shutdown verb -- VALIDATED (real init 5)

Done in three steps. (1) With the dev `HELIOS_SHUTDOWN_CMD='echo would-shutdown'`
override, the verb ACK'd `{status: shutting down}` and the VM stayed up -- proves
the verb fires and ACKs *before* acting. (2) Relaunched without the override, but
the daemon was running as **tvernon** and `init 5` needs root, so it silently
EPERM'd while still ACKing "shutting down" -- the ACK doesn't reflect command
success (logged as a hardening item). (3) Relaunched as **root** (matching the
production rc2.d posture); the verb fired, `init 5` ran, the daemon and OS came
down, and the client saw `ConnectionRefused`. Clean graceful halt. This is the
Phase C orphan-graceful-shutdown unlock. **Takeaway: the daemon must run as root**
(also required for `write_file` to `/etc` in the repair GUI).

## Daemon hardening item (surfaced today)

Two items for the hardening list (both in HELIOS_PLAN D1):
- **Orphan-reap.** A fork-per-connection child can orphan if the client vanishes
  mid-request without EOF (a no-`timeout_ms` hung `--version` probe + the client's
  read-timeout firing left one idle child; killed by hand). Mitigated by the
  always-send-`timeout_ms` convention. Real fix: child-side dead-client detection
  (SO_KEEPALIVE / recv timeout). Matters at agentic volume.
- **shutdown ACK doesn't reflect success.** The verb ACKs `{status: shutting
  down}` before running the command and never reports its exit status, so a
  failed `init 5` (non-root, missing binary) looks identical to a successful one.
  Fix: check `euid == 0` at startup (or pre-flight the shutdown command) and log
  the command's exit status, so a misconfigured deploy doesn't read as healthy.

## What's committed

- swift-x `be39250` (HELIOS_PLAN: file verbs + write_file Solaris-verified, D1),
  `8d34465` (STATUS roll), + this end-of-day roll.
- SPARCplug `4915beb` (helios/ bridge + guest/get-grep.sh), + the `shutdown`
  CLI subcommand.
- Clean image backup `SUN40G backup 2026-06-21.qcow2` (1.8G, made via
  macXserver's backup button after a clean shutdown, before the write_file test).
- Memory updated (Dropbox): `project_helios_daemon_solaris_validated`.

## What to do next

- **Daemon hardening** (both items above): orphan-reap + the shutdown
  euid-check/exit-status logging. Small, worth doing before heavy agentic use.
- **Survey polish:** collapse the ~80 round-trips into one guest-side shell loop
  (chatty + buffer-floods the console now).
- **Close M-B:** the daemon's own `make test` on Solaris (B6) and cx's four
  critical tests (A2) -- shipped over as their own tarballs and run on the image.
- **Phase C wiring** (the release-gating win): Swift `HeliosClient`, boot
  integration, liveness->readiness, shutdown verb, delete console auto-login,
  image-repair GUI, launcher-over-Helios transport (C1-C7).
- **D2 MCP server** later -- the CLI already gives ~90% of the value; hold D2
  until shelling the CLI gets annoying.

## Pointers

- Daemon: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, test/).
- Mac bridge: `~/dev/SPARCplug/helios/` (README has the tunnel command).
- grep installer: `~/dev/SPARCplug/guest/get-grep.sh`.
- Plan/tracker: `HELIOS_PLAN.md`. Why: `Helios-Mission.md`.
- Image + backup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ `SUN40G backup
  2026-06-21.qcow2`). Lock: `<image>.macxserver-lock`.
