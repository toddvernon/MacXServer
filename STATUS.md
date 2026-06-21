# Status 2026-06-21 (end of day)

Two Macs converged on Helios today and the result is a clean milestone: the
guest daemon is **v1 feature-complete, init-ready, AND validated on the real
SPARCplug Solaris 2.6 image**, with a Mac-side bridge so **Claude Code drives
the guest over the wire**. The laptop finished the daemon on the Mac (all 8
verbs, 114 tests, daemonize/log/pidfile, init script + deploy.sh, Solaris-clean
packaging); this desktop then built it on the 2.6 image, drove every verb on
real hardware emulation, added the CLI bridge, and settled the access topology.
(Histories had diverged -- both Macs branched from last night's `b3e364c`; this
roll is the merge.)

## Headline: heliosAgent is done on the Mac AND proven on Solaris

All **8 v1 verbs** implemented, **114 tests green** on Mac (`make test`), and
**all 8 exercised on the real 2.6 image**:

- **hello / run_command / shutdown** -- `run_command` execs `/bin/sh -c`
  (`process.cpp:118`), so pipes/$PATH/globs work, stdout+stderr combined.
- **read_file / write_file** -- base64 content (byte-exact, NUL/high-byte safe);
  write is atomic (temp + rename) and preserves mode/owner on overwrite. On
  Solaris: round-trip byte-exact, new files 0644, **mode-preservation confirmed**
  (chmod 600 -> overwrite -> still 0600).
- **stat / list_dir** -- lstat metadata, symlink-truthful with `target`.
- **search** -- shell-quoted native `grep -rHn`, structured matches, injection
  probe confirmed it doesn't execute. Needs GNU grep on Solaris (installed, A4).
- **shutdown** -- ACK then `init 5`. Validated as a **real graceful halt as root**
  (ACK -> daemon + OS down -> client `ConnectionRefused`). Needs root; matches the
  rc2.d posture. This is the Phase C orphan-graceful-shutdown unlock.

## Daemon hardening + init/deploy (laptop, B7)

- `-d` daemonize (double-fork/setsid/stdio->/dev/null), `-l` CxLogFile logging
  (pid+timestamp, always-flush), `-P` pidfile, SIGTERM clean-stop.
- **SO_REUSEADDR** via new `CxSocket::setReuseAddr` (cx net) -- restart doesn't
  hit TIME_WAIT. Bind/listen failure exits 1 with a message (was an uncaught
  CxSocketException abort).
- `init/heliosAgent` SVR4 init script + `deploy.sh` (root-on-Sun: installs
  binary + init script, wires rc symlinks, restarts; idempotent = upgrade path).
  All live-verified on Mac.

## Mac-side bridge (desktop, Phase D1, DONE)

`~/dev/SPARCplug/helios/`: `helios_client.py` (stdlib protocol client), `helios`
CLI (hello/run/read/write/ls/stat/search/shutdown), `helios-survey` (read-only
toolchain walk -> Markdown), README. Reaches the guest daemon on 2125 via an ssh
local-forward over the existing 2222 hostfwd (`ssh -N -f -L
2125:127.0.0.1:2125 sparcplug`); the dedicated 2125 hostfwd (C2) will retire the
tunnel. Ran a full image survey + the write_file round-trip through it.

## GNU grep for `search` (desktop, A4)

`search` shells `grep -rHn`, which stock Solaris grep can't do. Installed **GNU
grep 2.7 + pcre 8.10** from the free NUST sunfreeware mirror (libiconv/libintl/
libgcc already on from sun26gnu). Helper: `~/dev/SPARCplug/guest/get-grep.sh`.

## Packaging / tooling (laptop)

- **Mac tarballs are Solaris-clean** -- `make cx*_unix.tar` writes plain ustar
  (`COPYFILE_DISABLE=1 --no-xattrs`, no `.DS_Store`), no more macOS pax/xattr
  cruft, no Linux detour. heliosAgent added to `cxapps_unix.tar`.
- **New umbrella repo `toddvernon/cx-build`** (private, at `~/Dropbox/dev/cx`):
  tracks just the top-level build glue (distribution makefile, README, shared
  workspace) that spans cx/cx_tests/heliosAgent.

## Architecture settled (DECISIONS)

- **2026-06-20 control-plane floor/ceiling:** Helios is the zero-config floor
  (the critical path may never depend on anything else); ssh is the opt-in,
  additive-only ceiling; one plane owns each job (liveness/shutdown = Helios).
- **2026-06-21 access topology -- peer, not hub:** macXserver and Claude Code are
  co-equal clients of the one daemon; macXserver owns the network path (qemu
  hostfwd) + discovery but never brokers the protocol. Real-Sun case + deploy
  parity + keeping the GUI out of the agentic hot path decide it.
- **C6 widened to a guided sysadmin GUI** -- curated deterministic recipes (DNS,
  add-user, timezone, NFS, ...) so novices do Solaris admin via Settings dialogs.
  Tool-driven or template-driven, snapshot-first, no LLM in the dialog path.

## Daemon hardening items (open, both in HELIOS_PLAN D1)

- **Orphan-reap:** a fork-per-connection child can orphan if a client vanishes
  mid-request without EOF. Mitigated by always sending `timeout_ms`; real fix is
  child-side dead-client detection (SO_KEEPALIVE / recv timeout).
- **shutdown ACK is optimistic:** ACKs before running the command and never
  reports its exit status, so a failed `init 5` (non-root) is indistinguishable
  from success. Fix: euid-check at startup + log the command's exit status.
- Still deferred (not blocking): configurable bind for a real Sun, workspace-root
  confinement, auth (no auth in v1, localhost-only via hostfwd), streaming/job/
  pty verb family, read_file range.

## What's committed (all pushed)

- **cx** `412b68a` (CxSocket::setReuseAddr). **heliosAgent** `a7c72e3` (hardening
  + init + deploy.sh). **cx-build** `f24f4f6` (umbrella repo).
- **swift-x / X**: laptop's `87c898f`/`2ea67e8`/`4c72104`/`5f09710`/`4dcce26`/
  `64bae1e` (Phase A/B5/B7 + STATUS) and desktop's `be39250`/`81859b5`/`cc42619`
  (Solaris-verified file verbs + D1, shutdown 8/8, topology decision) + this
  merge.
- **SPARCplug** `4915beb` (helios/ bridge + get-grep.sh), `b0c2953` (shutdown CLI
  subcommand), `26891c9` (gitignore pycache).
- Clean image backup `SUN40G backup 2026-06-21.qcow2` (1.8G, clean-shutdown,
  pre-write_file test). Memory updated (Dropbox).

## What to do next

- **Close M-B:** run the daemon's own 114-test suite (B6) on the 2.6 image with
  its tarball. (A2 cx tests + every verb by-hand are already green on Solaris, so
  this is the last formal M-B gate.) Optionally `./deploy.sh` to install it into
  init so it autostarts and survives reboots.
- **Daemon hardening:** the two D1 items (orphan-reap, shutdown euid/exit-status)
  before heavy agentic use.
- **Survey polish:** collapse the ~80 round-trips into one guest-side shell loop.
- **Phase C (release-gating):** Swift `HeliosClient` (C1), boot integration +
  daemon-port hostfwd (C2), liveness->readiness (C3), shutdown verb (C4), delete
  console auto-login (C5), guided-admin GUI (C6), launcher-over-Helios (C7).
- **Phase D:** the MCP server (the CLI already gives ~90% of the value; hold D2
  until shelling the CLI gets annoying).

## Switching Macs (do before leaving)

- Shut the VM down cleanly so the lock releases (laptop won't see `remoteLocked`).
- Let Dropbox finish syncing the cx tree (`~/Dropbox/dev/cx` -- heliosAgent + cx
  net change + cx-build), then `git pull` X + SPARCplug on the other Mac (cx /
  heliosAgent / cx-build also have GitHub remotes). **Pull before working** -- the
  two-Mac divergence today was from not pulling first.
- macXserver Preferences are per-Mac; both Macs have their ssh key.

## Pointers

- Daemon: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, test/, init/,
  deploy.sh). cx net change: `cx/net/socket*`.
- Mac bridge: `~/dev/SPARCplug/helios/` (README has the tunnel command).
- grep installer: `~/dev/SPARCplug/guest/get-grep.sh`.
- Plan/tracker: `HELIOS_PLAN.md`. Why: `Helios-Mission.md`. Decisions: DECISIONS
  2026-06-17 / 06-20 (mission + floor/ceiling) / 06-21 (topology).
- Image + backup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ `SUN40G backup
  2026-06-21.qcow2`). Lock: `<image>.macxserver-lock`.
