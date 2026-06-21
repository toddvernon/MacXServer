# Helios build plan

The working tracker for building Helios, the SPARCplug guest agent. The
*what and why* live in `Helios-Mission.md`; the *decisions* in `DECISIONS.md`
(2026-06-17 access model, 2026-06-20 mission refinement). This doc turns the
mission's phases into concrete, dependency-ordered tasks with acceptance
criteria, in the same spirit as `PLUGIN_V1_PUNCHLIST.md`.

Created 2026-06-20.

## Shape (one mechanism, two clients)

- **Daemon** (guest, cx C++): pure mechanism -- exec + file + liveness. Knows
  nothing about control policy or LLMs. Built and tested **on the Mac first**,
  validated on Solaris 2.6 second.
- **Client 1 -- macXserver control plane** (Swift): lifecycle + deterministic
  control + repair GUI. The release-gating use case.
- **Client 2 -- Claude Code via a SPARCplug MCP server** (the bridge): the
  agentic-coding use case, and the self-hosting bootstrap lever.

Verb set, ranked by the control hole each fills: `hello` (liveness) ->
`shutdown` -> `run_command` -> `read_file`/`write_file` -> `list_dir`/`stat`
-> `search`.

Wire protocol: newline-delimited JSON, one persistent connection, one request
in flight; metadata as JSON strings, file content base64 (cx `b64`). cx json
code-transfer bug fixed in cx `75b8304` -- build json/b64 from source.

## Settled decisions (don't relitigate)

- Access = a Sun-side agent on a TCP port (slirp `hostfwd`), console is
  observation-only. (DECISIONS 2026-06-17.)
- Control-first; release parked behind the control plane; daemon = pure
  mechanism, Mac-first; agentic client = Claude Code + MCP, not an in-app
  loop. (DECISIONS 2026-06-20.)
- Built on cx (`~/Dropbox/dev/cx`: base/net/json/log/process/b64), no STL,
  g++ 2.95.3 / `_SOLARIS6_` safe.

## Proposed code layout (NEEDS SIGN-OFF -- new components)

Flagged per CLAUDE.md (new top-level components need maintainer sign-off):

- **Daemon source**: `~/dev/SPARCplug/helios/` (guest artifact, baked into the
  image; built from cx). Alternative: a `helios/` dir in the cx repo as a cx
  app, mirroring `cx_apps/cm`.
- **Mac-side `HeliosClient`**: a new file/group in `Sources/SwiftXServerCore`
  (cross-cutting, testable without UI), consumed by macXserver.
- **MCP bridge**: smallest form is a `helios` CLI; the MCP server can live in
  `~/dev/SPARCplug/helios/mcp/` or be lifted from cx's `cm` MCP bridge.

Decide before Phase B starts. The rest of the plan assumes these paths.

---

## Phase A -- Substrate (Mac + one Solaris validation)

The de-risking phase. Mostly verifying cx is the solid foundation we think it
is, plus the one extension `run_command` needs.

- [ ] **A1. Capture the guest tool survey.** Run `Tools/helios-tool-survey.sh`
  on the booted image; commit the output (e.g. `Tools/survey-<date>.txt`).
  Confirm g++/gmake/ar/ld + `-lsocket -lnsl` link sanity are green. Never run
  before.
- [x] **A2. Validate cx on Solaris 2.6. DONE 2026-06-20.** Built cxlibs,
  cxtests, and cxapps (the cx_apps suite, *not* heliosAgent yet) on the 2.6
  image -- everything compiled and passed. Because cxtests includes the new
  `cxprocess` suite, this also clears the **A3 CxProcess Solaris run** that was
  pending below: the fork/pipe/select/signal exec primitive `run_command` rides
  on is validated on 2.6, not just the Mac. Built json/b64 from current source;
  cx `75b8304` (the JSON emit fix) confirmed in the tree. The real risk gate is
  passed. heliosAgent's own daemon build on 2.6 is still pending (Phase B / B6).
- [x] **A3. CxProcess timeout/cwd extension. DONE (Mac) 2026-06-20.** Added
  `run(cmd, cwd, timeout_ms)` + `wasTimedOut()` to `cx/process` (fork/pipe/
  select, SIGTERM→1s→SIGKILL on the process group, 128+signal exit mapping);
  old `run()` delegates so it's backward-compatible. New `cx_tests/cxprocess/`
  suite (25 checks) green and wired into the cx_tests top-level; cm clean-
  rebuilt against the new ABI. **Solaris run DONE 2026-06-20** (rode the A2 cx
  validation -- cxtests' cxprocess suite passed on the 2.6 image). This is what
  `run_command` rides.
  - **run_command verb DONE (Mac) 2026-06-20** on top of it: daemon verb #3,
    reads cmd/cwd/timeout_ms, returns {exit_code, output, timed_out};
    fork-per-connection child resets SIGCHLD so CxProcess's waitpid keeps the
    real exit status. Live-verified over the socket; +12 daemon tests (51 total).
- [ ] **A4. (Optional, non-blocking) sunfreeware additions.** Bake gdb/gawk/
  gsed/ggrep into the image via `install_sunfreeware()` in
  `Tools/sparcstation-baseline-config.sh` (`Tools/SUNFREEWARE_ADDITIONS.md`).
  Agent ergonomics, not a daemon dependency.

**Acceptance (M-A):** cx builds and its four critical tests + the new CxProcess
tests pass on both Mac and the 2.6 image. The exec primitive exists and is
tested. **MET 2026-06-20** (A2/A3); A1 survey-artifact capture is the only
loose end and it's non-blocking -- a clean cx build already proves the
toolchain.

---

## Phase B -- Daemon mechanism (Mac-first)

Build the whole daemon on the Mac against `localhost`; no qemu in the loop.

- [x] **B1. Protocol spec. DONE (Mac) 2026-06-20.** Newline-JSON envelope,
  verb/id request, ok/result|error response, base64-content convention. Written
  as `cx_apps/heliosAgent/PROTOCOL.md` in the cx repo.
- [x] **B2. Daemon skeleton + concurrency. DONE (Mac) 2026-06-20.** CxSocket
  listener + accept loop + `recvUntil('\n')` framing + JSON parse/dispatch/write,
  in `~/Dropbox/dev/cx/cx_apps/heliosAgent` (HeliosAgent.cpp / Dispatch.cpp /
  Verbs.cpp + makefile mirroring cm). **Fork-per-connection from the start**
  (parent only accepts+forks; stateless verbs; SIGCHLD/`waitpid` reaping; fork
  not threads since cx targets no-pthreads platforms). Verified concurrent: a
  held-open client doesn't block a second one. Protocol errors return ok:false,
  never drop the connection. Builds and runs on macOS; smoke-tested with nc.
- [x] **B3. `hello` / liveness verb. DONE (Mac) 2026-06-20.** Returns agent,
  version, protocol, hostname, daemon uptime. Verified via nc.
- [ ] **B4. `run_command` verb.** On the CxProcess extension; returns stdout,
  stderr, exit code; honors cwd + timeout.
- [x] **B5. File verbs. DONE (Mac) 2026-06-20.** All five landed on cx (b64 +
  raw POSIX for byte-exact I/O, atomic rename, perm preservation; CxJSONArray
  for listings; native grep via CxProcess for search). `read_file`/`write_file`
  (base64, atomic, mode/owner-preserving), `stat`/`list_dir` (lstat metadata,
  symlink-truthful + target), `search` (shell-quoted native grep -rHn,
  structured file/line/text matches, stderr discarded, `truncated` flag, no
  silent caps). All live-verified over the socket incl. a shell-injection
  attempt that did NOT execute. +63 daemon tests (114 total). PROTOCOL.md has
  the wire shapes. **All 8 v1 verbs now implemented.** Detailed spec below.
  Solaris note: `search` needs GNU/xpg4 grep (A4), not stock /usr/bin/grep.

  **No `edit_file` verb. Editing is reconstructed Mac-side.** The daemon is a
  byte mover. Claude Code's Edit is whole-file under the hood (read entire file,
  exact-string substitute in RAM, write entire file back); the "partial edit"
  is in the *instruction*, not the disk op. So the MCP bridge implements Edit on
  the Mac as `read_file` -> substitute (with the unique-match + read-before-edit
  invariants) -> `write_file`. The string-substitution step must round-trip raw
  bytes / Latin-1, **not** UTF-8, or it can corrupt a Sun source file it never
  meant to touch. Keeping edit logic off the 2.6 box is deliberate: no escaping
  a substitution through JSON -> sh -> ed on g++ 2.95.

  **`read_file`** -- whole file as base64. Optional byte/line range for big
  files (logs); source files are small, whole-file is the norm. Regular files
  only: a dir/symlink/device/fifo target returns `ok:false` (use `stat` to learn
  the type first). May echo `mode` cheaply, but the edit path does not depend on
  it (see write preservation).

  **`write_file`** -- whole file from base64, written **atomically**: temp file
  in the target's directory, then `rename()` over the target so a crash never
  leaves a half-file. Two non-obvious correctness rules baked in:
  - **Preserve mode and owner on overwrite, by default.** `rename()` swaps in a
    fresh inode, so without this every write silently resets perms to umask
    defaults: a `0755` script comes back `0644` and won't run; an `/etc` file
    comes back wrong-owner and `sshd`/`init` quietly reject it. Before the
    rename, stat the existing target and re-apply its mode (and owner, when the
    daemon runs as root) to the temp file. This is a correctness floor, not a
    nice-to-have, and it means the bridge's Edit needs no extra round-trip to
    carry attributes.
  - **Do NOT preserve mtime.** A write stamps mtime to now, on purpose, so
    `make` rebuilds after an edit. Preserving the old mtime would break the
    compile loop.
  - Optional explicit `mode` param for the cases preservation can't cover:
    creating a new file, or deliberately setting perms (repair GUI making a
    script `+x`, stamping `/etc/shadow` back to `0400`). Owner-set needs a
    root daemon; for dev-user editing you already own the files.

  **`stat` / `list_dir`** -- metadata, the verbs that carry attributes: type,
  mode, uid, gid, size, mtime. This is what the repair GUI reads to display and
  validate configs against known templates, and what callers use to check type
  before a blind `read_file`.

  **`search`** -- runs the Sun's native `grep`/`find` via the exec path and
  returns structured matches. Run it where the files are; don't drag the tree to
  the Mac. Prefer `ggrep` once baked (A4) over the primitive `/usr/bin/grep`.

  **Out of scope (we aren't building an OS):** ACLs (`getfacl`/`setfacl`),
  extended attributes, atime games, and content read/write of non-regular
  files.
- [~] **B6. Daemon test suite. GROWN (Mac) 2026-06-20.** Tests live WITH the
  app (`cx_apps/heliosAgent/test/`, `make test`), not in cx_tests -- it's an app,
  not a lib module, and ships as its own unit to Solaris. They drive
  `heliosDispatch()` directly (no socket): **114 checks green on Mac** across all
  eight verbs -- hello, run_command, read_file/write_file (byte-exact round-trip,
  perm preservation), stat/list_dir (incl. symlink truthfulness), search (incl.
  shell-injection guard), shutdown, plus unknown/missing-verb, bad JSON, default
  id, and response escaping (proves the cx 75b8304 emit fix in our path).
  Solaris run pending (with the daemon's own tarball, not cxtests-unix.tar).
- [~] **B7. Config + bind posture + init readiness. MOSTLY DONE (Mac)
  2026-06-21.** The daemon now drops into Solaris init: getopt flags (`-d`
  daemonize via double-fork/setsid/stdio-redirect, `-p` port, `-l` CxLogFile
  logfile with pid+timestamp per line, `-P` pidfile), SIGTERM clean-stop
  (removes pidfile), and **SO_REUSEADDR** (new `CxSocket::setReuseAddr` in the
  cx net layer) so restarts don't hit TIME_WAIT. Bind/listen failure now exits
  1 with a message instead of aborting on an uncaught CxSocketException. Shipped
  `init/heliosAgent` SVR4 init script (start/stop/restart/status off the
  pidfile). All live-verified on Mac (daemonize, logging, immediate same-port
  restart, clean bind-conflict exit, SIGTERM). Shipped `deploy.sh` too: run as
  root on the Sun after `make`, it installs the binary + init script, wires the
  rc symlinks, and (re)starts -- idempotent, so it's also the upgrade path.
  **Still open:** bind address is INADDR_ANY (correct for hostfwd; making it
  configurable for a real Sun is the remaining bit), workspace-root confinement,
  and auth -- all deferred (no auth in v1, localhost-only via hostfwd). Baking
  the rc symlinks into the *image* (vs running deploy.sh by hand) is Phase C/C2.

**Acceptance (M-B):** the daemon passes its suite on Mac and on the 2.6 image,
and every verb is drivable by hand (nc or the CLI shim).

---

## Phase C -- Control plane (macXserver) -- the release-gating win

Wire the daemon into macXserver and retire the control debt. Each step here
pays off a parked punchlist item (L0/L2/L3).

- [ ] **C1. Swift `HeliosClient`.** Socket + newline-JSON codec + base64
  helpers, in `SwiftXServerCore`. Unit-tested against a loopback/mock daemon.
- [ ] **C2. Boot integration.** `/etc/init.d/helios-seed` + rc symlink
  (`S98`/`K30`-style, pattern from `guest/sshd-init.sh`), baked via
  `sparcstation-baseline-config.sh`. Add the daemon-port `hostfwd` to
  `QemuEngine` launch args.
- [ ] **C3. Liveness drives readiness.** Replace the console `login:`-scrape
  "guest is up" detection with `hello`; drive the boot thermometer / ready
  state from it. Detects a hung guest too.
- [ ] **C4. Graceful shutdown via the daemon.** `shutdown` verb replaces the
  telnet/console `init 5`. Works on an orphan (daemon outlives the parent), so
  this **un-parks L2(c)** and gives L2's Reconnect-and-shutdown. Update the
  orphan dialog to use it.
- [ ] **C5. Delete console auto-login (L0).** Remove the `login:`-scrape ->
  type-`root` -> console-`init 5` path entirely; console becomes a pure
  observation glass-TTY. Decouples macXserver from the guest password policy.
- [ ] **C6. Image-repair GUI (Phase 0.5).** Mac-side forms over
  `read_file`/`write_file` for the ~10 curated config items (vfstab, network,
  DNS, timezone, root pw, shell, NFS/automount, inetd, /etc/system, X/CDE).
  Validate against known templates; never guess. No AI loop needed.
- [ ] **C7. Launcher transport over Helios (least-brittle X-client launch).**
  macXserver's remote app launcher today shells X clients onto the Sun over
  **telnet** (brittle: expect/password/prompt-scraping, tcsh mangling) with
  **ssh** as the second transport. Add a third `LauncherEntry` transport,
  `helios`, that sets `DISPLAY` and execs the X client via the daemon's
  `run_command` -- no prompt-scraping, clean exit codes, the least-brittle path.
  Keep telnet (maintain) and ssh (expand); helios becomes the preferred
  transport once the daemon ships. Needs `run_command` (verb 3) + `HeliosClient`
  (C1). Touches `LauncherEntry.transport` (parser + seed + Todd's dotfile -- see
  the launcher-file-format memory) and `SSHLauncher`/`TelnetLauncher` siblings.

**Acceptance (M-C, release-gating):** macXserver boots SPARCplug, detects
readiness via the daemon, shuts down gracefully via the daemon (including an
orphan), with zero console scraping; the repair GUI edits configs. **This
unblocks resuming the SPARCplug v1 packaging** (`PLUGIN_V1_PUNCHLIST.md`
Tracks A/C/E).

---

## Phase D -- Agentic coding (Claude Code + MCP)

The vision, built cheaply on the proven daemon. We build the bridge, not a
loop.

- [ ] **D1. `helios` CLI shim.** `helios run/read/write/ls/stat/search` over
  the protocol. Smallest bridge; Claude Code drives it via Bash *today*.
  Enables early dogfooding before the MCP server exists.
- [ ] **D2. SPARCplug MCP server.** Expose the verbs as MCP tools; bridge
  MCP <-> Helios protocol. Lift the pattern from cx's `cm`
  (`MCPHandler.cpp`/`mcp_bridge.cpp`).
- [ ] **D3. Claude Code wiring + Sun system prompt.** Register the MCP server;
  bake the Sun-specific rules (`sh` not bash, `nawk`, Sun `cc`/`make`, `dbx`)
  into the agent's context.
- [ ] **D4. Hello-world MVP acceptance.** Autonomous: write buggy `hello.c` ->
  compile -> read error -> fix -> rebuild -> run -> capture `Hello, world`, no
  human intervention after the prompt.
- [ ] **D5. First real dogfood job.** "Validate cx on this image and report
  what fails," with a backup taken first. Proves the loop and does real work;
  from here the agent does its own Solaris grind.

**Acceptance (M-D):** the hello-world loop passes autonomously and the agent
can do real build/fix work on the image.

---

## Phase E -- Program-under-test lens (later)

- [ ] **E1.** Server-side text framebuffer (shadow cell grid fed by
  ImageString/CopyArea/ClearArea on the X side) so the agent can *see*
  full-screen programs it builds -- the path to working on `cm` itself. X-side
  rendering, not serial-console emulation. Out of scope until D is solid.

---

## Cross-cutting

- **Safety floor (already built).** The image lock + auto-backup +
  Force-Quit-with-verify (`PLUGIN_V1_PUNCHLIST.md` L1/Lifecycle) are what make
  letting the agent mutate the real image sane. Take a backup before any
  agent-driven session that writes to the image.
- **Punchlist reconciliation.** Phase C resolves L0 (C5), L2 graceful path +
  Reconnect (C4), and the control half of L3; L4 (kqueue watchdog) stays
  optional.
- **Deploy parity.** Same daemon + protocol + MCP server reach the emulator
  (hostfwd) and a real Sun (its network). Claude Code is the constant operator
  across dev-Mac / validate-emulator / deploy-iron.

## Open questions

- Code layout sign-off (see above) before Phase B.
- Daemon language detail: straight cx C++ app vs. a cx `cx_apps`-style app.
- MCP server host language (reuse cx's C++ bridge vs. a small Swift/other).
- Real-Sun auth posture for the daemon port (deferred; localhost-only for now).
- Daemon-port discovery: fixed hostfwd port vs. macXserver advertising it.
