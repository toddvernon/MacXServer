# Status 2026-06-20 (end of day)

Big day. The morning was orphan-safety + SSH; the afternoon refocused the Helios
mission and built the guest agent from zero to **three working verbs**. The
daemon now does liveness, graceful shutdown, and command execution -- all built
and tested on the Mac.

## Headline: the Helios daemon exists and works (on the Mac)

New repo **github.com/toddvernon/heliosAgent** (public, a cx app like cm). It's a
fork-per-connection TCP daemon speaking newline-JSON, built on cx so it'll
recompile unchanged on Solaris later.

- **hello** -- liveness (agent/version/protocol/host/uptime).
- **shutdown** -- graceful `init 5`; ACK-first, dev-safe via `HELIOS_SHUTDOWN_CMD`;
  outlives macXserver so it covers the orphan case the telnet path couldn't.
- **run_command** -- fork/exec with cwd + timeout; returns {exit_code, output,
  timed_out}. The dev-loop engine and the future launcher transport.
- **Concurrency**: fork-per-connection from the start (parent only accepts/forks;
  SIGCHLD reaping; the connection child resets SIGCHLD so CxProcess keeps the
  real exit status). Verified concurrent + clean (no zombies).
- **Tests**: 51 checks in `test/` (`make test`), all green; verbs also
  live-verified over the socket with nc.

## Also landed today

- **Mission refocused (DECISIONS 2026-06-20).** Control-first; daemon = pure
  mechanism built Mac-first; agentic client = **Claude Code + a SPARCplug MCP
  server**, NOT an in-app loop. Docs rewritten: `Helios-Mission.md`,
  `HELIOS_PLAN.md` (new tracker), DECISIONS, PLUGIN_V1_PUNCHLIST,
  SPARCSTATION_PLUGIN. Release parked behind the control plane.
- **cx A3 (pushed to cx + cx_tests).** `CxProcess::run(cmd, cwd, timeout_ms)` +
  `wasTimedOut()` (fork/pipe/select, SIGTERM->1s->SIGKILL, 128+signal); old
  `run()` delegates (backward-compatible). New `cx_tests/cxprocess/` (25 checks).
  cm clean-rebuilt against the new ABI.
- **macXserver.** L2b orphan shutdown-progress panel
  (`SparcShutdownProgressWindowController`) committed `2e98817`; L1 image lock
  verified live; telnet graceful-shutdown path parked (2.6 refuses root telnet).
- **SSH on the Studio.** `~/.ssh/sparcplug_rsa` + config + guest authorized_keys;
  `ssh sparcplug` passwordless from both Macs now.

## What's committed

All five repos clean. Pushed: swift-x (`cdf2718`), cx (`fa56882`),
cx_tests (`43d775c`). heliosAgent (`18c3116`) pushed to its new remote. SPARCplug
clean (no changes today). Memory updated (Dropbox).

## What to do next

- **Daemon file verbs:** `read_file`/`write_file` (base64 content),
  then `list_dir`/`stat`/`search`. Unlocks the image-repair GUI + the agent edit
  cycle. (HELIOS_PLAN Phase B / verb ranking.)
- **Solaris validation (never run yet):** build cx + the daemon on the 2.6 image,
  run cxprocess + helios tests there (HELIOS_PLAN A2/B6). The real risk gate.
- **macXserver Phase C wiring:** Swift `HeliosClient`, boot integration (rc +
  hostfwd), liveness->readiness, shutdown verb, delete console auto-login,
  image-repair GUI, launcher-over-Helios transport (C1-C7).

## Switching to the laptop (do before leaving)

- **Shut down the orphan VM cleanly** (see below) so the lock releases and the
  laptop doesn't see `remoteLocked`.
- **Let Dropbox finish syncing** the qcow2 + lock removal, AND the cx tree
  (`~/Dropbox/dev/cx` -- heliosAgent + the cx/cxtests changes ride Dropbox to the
  laptop). `git pull` X + SPARCplug on the laptop (cx also has GitHub remotes if
  you prefer pull over Dropbox).
- Per the switching-Macs memory: macXserver Preferences (disk image path, shared
  folder) are per-Mac; the laptop already has its ssh key set up.

## Pointers

- Daemon: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, test/). cx change:
  `cx/process`. Tests: `cx_tests/cxprocess`.
- Plan/tracker: `HELIOS_PLAN.md`. Why: `Helios-Mission.md`. Decisions: DECISIONS
  2026-06-17 (access model) + 2026-06-20 (mission refinement).
- Image + autobackup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2`. Lock:
  `<image>.macxserver-lock`.
