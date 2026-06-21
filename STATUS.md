# Status 2026-06-21 (end of day)

The Helios guest daemon is **v1 feature-complete and drops into the Solaris init
system**. Since yesterday's three-verb daemon: the five file verbs landed, then
today the daemon got the operational hardening to run as a real boot service.
Next stop is the actual build on SPARCplug.

## Headline: heliosAgent is done (on the Mac) and init-ready

All **8 v1 verbs** implemented, **114 tests green** (`make test`), every one also
live-verified over the socket.

- **hello / shutdown / run_command** (from 2026-06-20).
- **read_file / write_file** -- base64 content (byte-exact, NUL/high-byte safe);
  write is atomic (temp + rename) and preserves mode/owner on overwrite (explicit
  `mode` wins; new files default 0644; mtime advances so `make` rebuilds).
- **stat / list_dir** -- lstat metadata (type/size/mode/uid/gid/mtime),
  symlink-truthful with a `target` field; list via CxJSONArray.
- **search** -- shells native `grep -rHn`, shell-quoting pattern+path so
  metacharacters can't inject, stderr discarded, structured file/line/text
  matches with a `truncated` flag. Live injection probe confirmed it doesn't
  execute. Needs GNU/xpg4 grep on Solaris, not stock `/usr/bin/grep`.

## Today's work: daemon hardening + init/deploy (B7)

- **Daemonize** (`-d`): double-fork/setsid/chdir/stdio->/dev/null. Foreground
  stays the dev default.
- **Logging** (`-l`) via **CxLogFile**: append, pid+timestamp per line,
  always-flush so it survives the per-connection forks and `_exit`. Logs startup
  + each request's ok/ERROR outcome. Falls back to stderr.
- **Pidfile** (`-P`); **SIGTERM** clean-stop removes it.
- **SO_REUSEADDR** before bind via a **new `CxSocket::setReuseAddr`** in the cx
  net layer, so a restart doesn't trip over TIME_WAIT.
- **Clean bind-conflict**: cx's bind throws, so it's wrapped -- a port-in-use now
  exits 1 with a message instead of aborting (was exit 134, uncaught exception).
- **`init/heliosAgent`** SVR4 init script + **`deploy.sh`** (run as root on the
  Sun after `make`: installs binary + init script, wires rc symlinks, restarts;
  idempotent, so it's also the upgrade path). Both ride the `make archive`
  tarball to the Sun.
- All live-verified on Mac: daemonize, logging, same-port restart, clean
  bind-conflict exit, SIGTERM cleanup.

## What's committed (all pushed)

- **cx** (`412b68a`) -- `CxSocket::setReuseAddr` (net layer).
- **heliosAgent** (`a7c72e3`) -- daemon hardening + init/heliosAgent + deploy.sh.
- **swift-x / X** (`5f09710`) -- HELIOS_PLAN B5 complete + B7 mostly-done.
- SPARCplug clean (no changes). All three repos clean; cx rides Dropbox + GitHub.

## What to do next

- **Build heliosAgent on SPARCplug (the real gate now).** Pull cx + heliosAgent
  on the Sun, build cx from source (setReuseAddr comes with it), `make` the
  daemon, then `./deploy.sh` as root to install into init and start it. Watch
  two things: `search` wants GNU/xpg4 grep, and confirm CxLogFile compiles under
  `_SOLARIS6_` (it did in the cxtests run, so it should). This closes B6's
  pending Solaris run and most of M-B.
- **Then macXserver Phase C:** Swift `HeliosClient` (C1), boot integration +
  hostfwd (C2), liveness->readiness (C3), shutdown verb (C4), delete console
  auto-login (C5), image-repair GUI (C6), launcher-over-Helios (C7).
- **Then Phase D:** the MCP bridge (CLI shim first), the self-deploy loop.

## Still open on the daemon (deferred, not blocking)

- Bind address is INADDR_ANY (right for hostfwd; configurable bind for a real Sun
  is the remaining B7 bit). Workspace-root confinement. Auth (no auth in v1,
  localhost-only via hostfwd). Streaming/job/pty verb family (post-v1: long
  builds go dark, no interactive dbx). `read_file` offset/length range.

## Switching to the laptop (do before leaving)

- **Shut down the orphan VM cleanly** so the lock releases (laptop won't see
  `remoteLocked`).
- **Let Dropbox finish syncing** the cx tree (`~/Dropbox/dev/cx` -- heliosAgent +
  the cx net change ride Dropbox), then `git pull` X + SPARCplug on the laptop
  (cx + heliosAgent also have GitHub remotes if you prefer pull over Dropbox).
- Per the switching-Macs memory: macXserver Preferences are per-Mac; the laptop
  already has its ssh key.

## Pointers

- Daemon: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, test/, init/,
  deploy.sh). cx net change: `cx/net/socket*`.
- Plan/tracker: `HELIOS_PLAN.md`. Why: `Helios-Mission.md`. Decisions: DECISIONS
  2026-06-17 (access), 2026-06-20 (mission), 2026-06-21 (control-plane
  floor/ceiling: Helios = zero-config floor, ssh = opt-in ceiling).
- Image + autobackup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2`. Lock:
  `<image>.macxserver-lock`.
