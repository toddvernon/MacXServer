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
- [~] **A4. sunfreeware additions.** GNU grep 2.7 + pcre 8.10 **installed
  2026-06-21** from the NUST sunfreeware mirror (libiconv/libintl/libgcc were
  already on from the sun26gnu set) — this is NOT optional, it's the backend the
  `search` verb shells (`grep -rHn`). Helper: `~/dev/SPARCplug/guest/get-grep.sh`.
  Remaining ergonomics (gdb/gawk/gsed) are still optional; bake the lot via
  `install_sunfreeware()` in `Tools/sparcstation-baseline-config.sh`
  (`Tools/SUNFREEWARE_ADDITIONS.md`) when convenient.

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
- [x] **B4. `run_command` verb. DONE + Solaris-verified 2026-06-21.** On the
  CxProcess extension; returns stdout, stderr, exit code; honors cwd + timeout.
  Ran `uname -a` / `cc -V` by hand over telnet on the 2.6 image, clean exit codes.
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

  **Solaris-validated 2026-06-21.** All five exercised on the real 2.6 image:
  `read_file`/`stat`/`list_dir`/`search` by hand, then `write_file` via the Mac
  CLI after a clean-shutdown image backup -- byte-exact round-trip, new-file
  0644, and mode-preservation on overwrite confirmed (chmod 600 -> overwrite ->
  still 0600). `search` needed GNU grep -rHn (grep 2.7 + pcre 8.10 installed,
  A4). With `shutdown` (real root `init 5`, see C4 / the 2026-06-21 STATUS) that
  makes **all 8 verbs Solaris-green**.
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

- [x] **C1. Swift `HeliosClient`. DONE 2026-06-21.**
  `Sources/SwiftXServerCore/HeliosClient.swift`: blocking POSIX-socket client
  (Darwin sockets, matching `Listener.swift`), newline-JSON framing, all 8 verbs
  with typed Codable results, base64 read/write helpers, bounded connect (poll)
  + read/write timeouts (SO_RCVTIMEO) so a hung guest surfaces as `.timedOut`.
  16 tests in `HeliosClientTests.swift` drive a real in-process mock daemon over
  loopback (round-trip every verb, byte-exact base64 incl. NUL/high bytes,
  optional-field omission, persistent multi-call, `ok:false` -> `.protocolError`,
  EOF -> `.connectionClosed`, refused connect). Not thread-safe by design (one
  request in flight); consumers drive it from their own queue. Next: C3/C4/C7
  build on it.
- [x] **C2. Boot integration. DONE 2026-06-23.** The QEMU side was already
  in place (`QemuEngine` adds the `hostfwd=tcp::2125-:2125` + the `-prom-env`
  secret). The guest/baking side is now `guest/get-helios.sh`: a Mac-side
  orchestrator that builds the cx source tars (top-level cx makefile's
  `cxlibs_unix.tar` / `cxapps_unix.tar`), ships them to the guest (helios
  `put_file` if the daemon's up, else `scp`), builds the cx libs + heliosAgent
  on the guest under g++ 2.95, and runs `deploy.sh` (binary + `S98`/`K30` rc
  links + restart). Builds/installs over `ssh sparcplug`, not helios, so the
  daemon's self-restart can't sever the connection. Validated end-to-end on the
  live image (all four phases green, daemon re-locked + enforcing). The rc
  wiring lives in `deploy.sh` (not a separate `helios-seed`); the init script
  reads the per-boot secret via `eeprom`. **Gotcha baked into the script:**
  the deploy-time PATH must include `/usr/sbin` or the restart can't find
  `eeprom` and the daemon silently comes up unlocked. See SPARCSTATION_PLUGIN.md
  "Helios daemon on the image" for the full sequence + gotchas.
  - **C2-follow-on (1) DONE 2026-06-23:** the heliosAgent init script now echoes
    `heliosAgent started` to the boot console on a successful start (`&&` after
    the `-d` launch, which only fires once bound+listening). Reliable late-boot
    marker coinciding with when `hello` answers. (`cx_apps/heliosAgent/init/`.)
  - **C2-follow-on (deferred, do next time we touch the daemon init/deploy):**
    (2) **Optional own-the-markers play:** replace C3's scraped Solaris-version
    boot strings with our own markers -- a single tiny boot-marker rc script with
    symlinks at a few S-numbers (S05/S40/S70), each echoing its stage to
    `/dev/msglog` (console, not syslog -- must be visible pre-daemon). Gives a
    monotonic progress bar decoupled from 2.6's exact console text; matters more
    once we target the real box. Cosmetic only (hello is the authoritative ready
    signal), so it's polish, not correctness. Bake into the image the same way as
    the daemon init script.
- [x] **C3. Liveness drives readiness. DONE 2026-06-21.** `QemuEngine` polls
  `hello` every 2s after launch (one-shot connect = the liveness probe, off
  `queue` so console ingest keeps flowing); first success fires `onReady`, drives
  progress to the authoritative 1.0, and stops the poll. Boot milestones are now
  cosmetic only (top out at 0.90; the old `console login:` -> 1.0 readiness proxy
  is gone). A ~240s budget without an answer, OR the `RUN fsck MANUALLY`
  maintenance-drop phrase appearing in the console (preempts the budget), fires
  `onBootStalled(reason)` -- the console window flips to "Booting…" -> "Ready" /
  "Boot stalled" with the reason and Force Quit. Layered signal, no `State` enum
  churn (per the design call). Report-only: launcher gating deferred to C7. Pure
  helpers (`indicatesFsckStall`, `bootProgress`) unit-tested; the poll loop /
  timeout is live-verified on the image. Next: C5 deletes the now-unused console
  auto-login + `login:` scrape.
- [x] **C4. Graceful shutdown via the daemon. DONE 2026-06-21.** `QemuEngine.shutDown()`
  now calls `HeliosClient.shutdown()` (off `queue`, so console ingest / clean-halt
  detection keeps flowing) and fell back to writing `init 5` to the console if the
  daemon was unreachable (that fallback later removed by C5); which path ran is surfaced in the observation
  console via `emitDiagnostic`. The orphan dialog's "Try to Shut It Down" is now
  `attemptHeliosShutdown` (was `attemptTelnetShutdown`): it dials the daemon on
  the 2125 hostfwd instead of telnet-as-root (refused on 2.6), and the progress
  panel flips to the failure buttons fast on a daemon-unreachable error
  (`orphanShutdownFailed`) instead of waiting out the 35s countdown. Success is
  still pid-death, not the ACK. `TelnetLauncher` stays for the remote app
  launcher; only the orphan-shutdown use of it was removed. **Un-parks L2(c).**
  Needs live verification on the image (network glue, not unit-testable without a
  guest); `HeliosClient` itself is covered by C1's 16 tests.
- [x] **C5. Delete console auto-login (L0). DONE 2026-06-21.** Removed the
  `login:`-scrape -> type-`root` block, the `loginPrompt`/`loginUser` constants,
  the `loggedIn` flag, the C4 console-`init 5` fallback, and the now-unused
  `writeConsole`/`sendConsole`. The serial console is observation-only: nothing
  writes to qemu's stdin (the pipe is held open but silent so qemu doesn't hit
  EOF). Shutdown is daemon-only -- if the daemon is unreachable we revert to
  `.running` and tell the user to Force Quit (honest, vs. a fake console
  fallback that couldn't work anyway once auto-login was gone). Decouples
  macXserver from the guest password policy. 1367 tests green.
- [ ] **C6. Guided sysadmin GUI (Phase 0.5).** Not just *repair* a broken image
  -- make a 1998 Solaris box approachable to someone who's never touched one.
  Mac-side Settings dialogs that run curated, deterministic recipes over the
  daemon's verbs for the common admin tasks (DNS, add-a-user, timezone/hostname,
  NFS/automount shares, plus the repair items: vfstab, network, root pw, shell,
  inetd, /etc/system, X/CDE). Two recipe styles: **tool-driven** where a Solaris
  tool exists (`useradd`/`passwd` via `run_command` -- never hand-edit
  `/etc/passwd`), **template-driven validated file edits** otherwise (DNS =
  read/transform/write `/etc/resolv.conf` + the `hosts: files dns` line in
  `/etc/nsswitch.conf`). Rules: validate against known templates, never guess,
  **snapshot the image first**, idempotent + reversible, **no LLM in the dialog
  path** (frozen recipes; the agent is for open-ended work). Pipeline: agent
  works a task out once on the real image, the validated sequence hardens into a
  dialog. See DECISIONS 2026-06-21.
- [x] **C7. Launcher transport over Helios. DONE 2026-06-21.** Added a third
  `LauncherTransport.helios` (parser default port 2125) + `HeliosLauncher`
  (`RemoteLauncher`): connects `HeliosClient` to `entry.host:entry.port` and
  execs the X client via `run_command` with the `DISPLAY=...; nohup ... &` wrapper
  (returns at once, client keeps running). No password/Keychain (AppDelegate
  skips it like ssh), no prompt-scraping, clean exit code, and the daemon's
  /bin/sh sidesteps the csh login-shell trap. **Runs as `entry.user`** via the
  daemon's run-as-validated-user (2026-06-22, see below) -- not root. Seed doc +
  a live `[host:SPARCplug-helios]` entry in Todd's dotfile point at
  127.0.0.1:2125 / display 10.0.2.2:0. Tests: `HeliosLauncherTests` +
  `LauncherFileTests` helios parse. Needs a live launch to confirm end-to-end.
- [x] **Run-as-validated-user (daemon). DONE + DEPLOYED + live-validated 2026-06-22.**
  `run_command` gained an optional `user` field: the daemon (root)
  `getpwnam`-validates it (unknown user -> ok:false) and `CxProcess` drops
  privileges in the child before exec -- `initgroups`+`setgid`+`setuid` + a
  login-ish HOME/USER/LOGNAME/SHELL env, failed drop exits 127 (never falls
  through to root). Portable LCD calls (getpwnam/initgroups/setgid/setuid/putenv),
  no `#ifdef`. Absent user = root (admin tasks). `HeliosLauncher` passes
  `user=entry.user`, dropped the temp-file/su stopgap. **Built clean under g++
  2.95 on the real 2.6 image and validated live: `run id --user tvernon` ->
  `uid=1000(tvernon)`.** Swift 1369 + 117 daemon tests green (the 117 now also
  pass on Solaris -- B6 closed). See DECISIONS 2026-06-22.
- [x] **Streaming file transfer (put_file / get_file). DONE + DEPLOYED 2026-06-22.**
  `write_file`/`read_file` (base64 in one JSON line) choked moving a 4.7MB tar
  (write_file timed out at 55s) -- so added two streaming verbs: a JSON header
  (`path`,`bytes`) then a raw length-prefixed body streamed straight to/from disk
  in 64KB chunks, no base64, no full-file buffering. The one place the protocol
  carries a raw body; framing is clean because `recvUntil` reads byte-at-a-time
  (no read-ahead). Handled in the connection loop (`heliosHandleStreaming`) since
  the verbs need the socket. Validated live: **4.7MB put + get round-trip,
  byte-identical, ~0.2s each** (vs the 55s timeout). Python CLI `put`/`get`,
  PROTOCOL.md updated. write_file/read_file stay the small-file/base64 path.
- [x] **Daemon self-deploy proven 2026-06-22.** Bootstrapped the first deploy
  over scp (the new verbs didn't exist on the running daemon yet), then
  **redeployed using ONLY helios**: `put_file` the cxapps tar (7.3MB, 0.28s),
  then `run_command` drove untar + clean rebuild + deploy.sh -- the daemon shipped
  its own replacement and self-restarted (the forked connection-child outlives
  the restart and returns the deploy log). No ssh/scp in the loop.
- [x] **C8. Per-launcher Helios file browser. DONE + DEPLOYED + verified
  2026-06-24.** A `filebrowser = true` launcher entry (helios
  transport only) becomes a "Files…" menu item that opens a single-pane browser
  of `user`'s home dir on the SPARCstation. Folder/doc icons, double-click to
  enter / `..` to go up; drag a file row out to Finder to download (lazy
  `get_file` in the file-promise callback), drag files in from Finder to upload
  (`put_file` into the current dir). Everything runs AS `user`.
  **Daemon (Mac-built, redeploy pending):** extended the run-as drop from
  `run_command` to every file verb (`read_file`/`write_file`/`stat`/`list_dir`/
  `get_file`/`put_file`) -- optional `user`, reversible `seteuid`/`setegid` +
  `initgroups` around the op (fork-per-connection makes the process-wide euid
  change safe), fails closed (ok:false) if the drop can't complete, never runs
  as root. So a browse sees the user's view and an upload lands user-owned.
  **Swift:** `HeliosClient` gained streaming `getFile`/`putFile` + `user` on the
  file verbs; new `FileBrowserWindowController`/`PanelView`/`Model` (DNS-editor
  shape). Tests: daemon run-as (131 cpp), HeliosClient streaming + user (5),
  launcher `filebrowser` parse (1). **Deployed to the live 2.6 image via
  get-helios.sh and verified: write_file as tvernon lands owned by tvernon
  (uid 1000) not root, and a file verb with a bogus user is rejected.**
- [ ] **C9. Helios on a *real* SPARCstation (not just the bundled emulator).**
  Nothing in the daemon or the protocol is emulator-specific -- it's plain cx
  over TCP -- so a real Sun running heliosAgent should work as a helios-transport
  launcher (incl. the file browser) the same way the bundled box does. Two gaps
  block it today, both on the macXserver side, not the daemon:
  - **Auth on a real box -- the secret hack doesn't port.** The emulator's
    per-boot secret works because macXserver owns *both* the boot and the
    transport: it mints a fresh secret each launch, injects it via
    `-prom-env helios-secret=` (the init script reads it from OBP and hands it to
    the daemon), and it's almost ceremonial anyway because the channel is
    loopback only macXserver can reach. On real iron you lose both: macXserver
    doesn't boot the box (no per-session injection point -- you'd be setting an
    `eeprom` var by hand), and the transport is the LAN, so the secret stops being
    ceremonial and becomes the only thing guarding the agent.
    - **Preferred path: let the transport carry the trust (ssh tunnel, no
      load-bearing secret).** You almost always already have ssh to a real Sun.
      Run Helios over an `ssh -L`-forward to 2125 (exactly how the original
      python client was designed to reach it), bind the daemon loopback-only on
      the box, and ssh has already authenticated + encrypted the channel. The
      Helios secret goes back to ceremonial *for the same reason it is in the
      emulator* -- the transport is trusted -- so it's defense-in-depth, not the
      gate. This keeps the auth posture in how the client reaches the box (the
      C9-era principle), not in the daemon. Work: teach the helios launcher /
      `HeliosFileBrowserConfig` to optionally stand up an ssh local-forward (reuse
      the ssh-transport plumbing) and dial 127.0.0.1:<localport> instead of the
      box directly.
    - **Fallback: static secret in the launcher config** (for "I don't want ssh
      in the loop"). Add a per-entry secret to `LauncherEntry` -- a Keychain
      reference, like the telnet password, not cleartext -- and feed it into the
      helios secret provider (`HeliosLauncher` + `HeliosFileBrowserConfig`)
      instead of `qemuEngine.currentSecret` (the bundled guest's per-boot secret,
      meaningless to any other box). Then the box runs its agent with that fixed
      secret on its own LAN bind.
    Until either lands, the menu's wrong-transport dialog is honest ("the bundled
    SPARCstation is the only machine set up with the agent") and a real-box helios
    key would fail to connect/auth even with the agent installed.
  - **Agent deployment to a real box.** `get-helios.sh` builds + deploys to the
    bundled qcow2 over the daemon itself; a real Sun needs a bootstrap path
    (build from cx on the box, or cross-build + scp/ftp the binary + init
    script). The daemon already builds clean under g++ 2.95 on 2.6, so this is
    packaging, not porting.
  Once auth + deploy land, a real-box helios key that can't reach an agent fails
  the normal way: the browser window opens and banners the connection error.
**Acceptance (M-C, release-gating):** macXserver boots SPARCplug, detects
readiness via the daemon, shuts down gracefully via the daemon (including an
orphan), with zero console scraping; the repair GUI edits configs. **This
unblocks resuming the SPARCplug v1 packaging** (`PLUGIN_V1_PUNCHLIST.md`
Tracks A/C/E).

---

## Phase D -- Agentic coding (Claude Code + MCP)

The vision, built cheaply on the proven daemon. We build the bridge, not a
loop.

- [x] **D1. `helios` CLI shim. DONE 2026-06-21.** `~/dev/SPARCplug/helios/`:
  `helios_client.py` (stdlib protocol client) + `helios` CLI
  (hello/run/read/write/ls/stat/search) + `helios-survey` (read-only toolchain
  walk → Markdown) + README. Mac reaches the guest daemon via an ssh
  local-forward over the existing 2222 hostfwd
  (`ssh -N -f -L 2125:127.0.0.1:2125 sparcplug`). Claude Code drives all 7
  working verbs over Bash *today*; ran a full image survey + the write_file
  round-trip through it. This is the substrate the MCP server (D2) wraps next.
  - **Hardening TODO (1) orphan-reap:** a fork-per-connection child can orphan if
    the client vanishes mid-request without EOF (seen once when a no-`timeout_ms`
    command hung and the client's read-timeout fired). Mitigated by convention
    (client always sends `timeout_ms` < its own read timeout, so the daemon
    answers first). Real fix: child should detect a dead client (SO_KEEPALIVE /
    recv timeout) instead of trusting EOF. Matters at agentic command volume.
  - **Hardening TODO (2) shutdown ACK is optimistic:** the verb ACKs `{status:
    shutting down}` before running the command and never reports its exit status,
    so a failed `init 5` (non-root, missing binary) is indistinguishable from a
    successful one (found 2026-06-21 running the daemon as a non-root user). Fix:
    check `euid == 0` at startup (or pre-flight the shutdown command) and log the
    command's exit status, so a misconfigured deploy doesn't read as healthy.
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
- [x] **Daemon auth (shared secret) — DONE + live-validated 2026-06-22 (B7 closed).**
  Every request must carry a matching `auth` string, checked at the dispatch
  layer (`Dispatch.cpp`, both the line and streaming paths) before verb routing,
  constant-time compare, reject with `ok:false "unauthorized"`. **Require-if-
  configured:** no secret set -> open (dev/`make test`); secret set -> enforced.
  **Key distribution is Todd's firmware trick (validated 2026-06-22):** macXserver
  generates a fresh random secret each launch (`QemuEngine.generateHeliosSecret`),
  passes it to the guest via qemu `-prom-env 'helios-secret=S'` (a custom OBP
  NVRAM var — confirmed readable by Solaris `eeprom helios-secret`, and confirmed
  **runtime-only: never persists to the qcow2**, so it's disk-free). The daemon's
  init script reads it (`eeprom helios-secret`) and passes `-s`; macXserver's own
  daemon calls + the launcher present it; the **"Claude development"** Preferences
  checkbox (off by default) writes it `0600` to `/tmp/sparkplug` so Claude Code's
  CLI/client can authenticate (`HELIOS_SECRET` env or that file). Never echoed to
  the boot console (no capture leak). 122 daemon tests; live on real Solaris:
  no-auth/wrong-auth -> `unauthorized`, correct -> ok. **Honest scope:** a
  plaintext secret on the cleartext channel is a speed-bump (kills
  unauthenticated/cross-VM/port-scan; solid on loopback), NOT crypto — HMAC/TLS
  is the LAN-case upgrade. Emulator-specific (prom-env); a real Sun would provision
  the secret another way (manual `eeprom`/config). See DECISIONS 2026-06-22.
- Daemon-port discovery: fixed hostfwd port vs. macXserver advertising it.
