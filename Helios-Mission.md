# Helios: Agentic Development and Control for Vintage Sun Workstations

*Working name: **Helios** (a heliostat reflects modern light onto a fixed Sun). Alternatives: Sundial, Photon, Apollo. Name TBD.*

> **STATUS / SEQUENCING (updated 2026-06-20).** Helios is moving from
> design to build. The priority is **inverted from earlier drafts**: the
> guest agent's first job is to plug the holes in macXserver's *control* of
> SPARCplug (graceful shutdown, liveness, orphan recovery, image repair),
> not the agentic-coding loop. The SPARCplug *release* is now parked behind
> having that control plane in place. The agentic-coding loop is the second
> use case, built on the same daemon, and the loop itself is **Claude Code**,
> not something we build. See "Priorities and build order" below.

> **ACCESS MODEL (decided 2026-06-17).** The sole access mechanism is a
> single **Sun-side guest agent on a TCP port** that proxies command
> execution and filesystem access, with the serial console as a secondary
> mix-in for boot and recovery. The earlier NFS/NAS file plane and the
> terminal-fd command channel are **deprecated**. Rationale in DECISIONS.md
> (2026-06-17). The superseded NFS design is fenced off in
> `SPARCSTATION_PLUGIN.md`.

> **CLIENT MODEL (decided 2026-06-20).** The agentic-coding client is the
> **Claude Code app (or Claude Desktop) driving a SPARCplug MCP server**
> that bridges to the daemon. We build the bridge; Claude Code's mature agent
> loop is the workbench. The in-app "promote-to-AI" chat loop inside
> macXserver from earlier drafts is **superseded** for the primary path and
> demoted to a possible later feature for end-users who don't run Claude Code.
> Rationale in DECISIONS.md (2026-06-20).

---

## Mission

The story is **Claude doing agentic, native software development on a classic Sun** -- writing, compiling, and running real SPARC/SunOS code on a machine that could never run a modern agent itself **without turning the Sun into a modern machine.** The trick is that nothing modern moves onto the Sun: the intelligence, the network, the secrets, and the editing logic all live on the Mac. The Sun stays exactly as period-correct as it is today and contributes the one thing only it can: executing native SPARC/SunOS code. Claude Code, on the Mac, reaches it through an **MCP bridge that sits over the Helios agent** -- a small guest agent running inside the Sun.

That same agent, because it's a clean general mechanism with no opinion about who's calling, is *also* what macXserver uses to control SPARCplug (shutdown, liveness, orphan recovery, image repair, file transfer). That second use is real and it ships first, but it's a consequence of building the agent well, not the headline. The headline is the Sun doing agentic development it has no business being able to do.

Development happens entirely on **SPARCplug**, the bundled emulated SPARCstation -- self-contained, reproducible, no hardware required. The Sun (emulated or real) is reached through a single **guest agent** running inside it, listening on a TCP port, that proxies both commands and filesystem access. The serial console is a secondary, mixed-in channel for boot and recovery. There is no NFS and no shared mount.

---

## One general agent (the duality is plumbing, not the pitch)

Helios the agent is deliberately dumb: a general exec + file + liveness proxy that knows nothing about LLMs or control policy. All policy lives in the clients. That's an implementation choice, and it has a convenient consequence -- the same agent ends up serving two very different clients. Worth being clear that this duality is an implementation fact, **not** the interesting story. The interesting story is the agentic one; the control plane is what falls out of having built the right mechanism to make it possible.

**The agentic client (the story).** Claude Code, on the Mac, pointed at an MCP bridge that sits over the agent. Claude develops native software on the Sun -- edit on the Mac, compile and run on the iron -- with a world-class agent loop we don't have to build. This is the reason Helios exists.

**The control client (the plumbing that ships first).** macXserver itself, no AI, deterministic. It plugs the holes we hit building the plugin: graceful shutdown that doesn't depend on console-scraping or telnet (which Solaris 2.6 refuses for root), a real "is the guest up and ready" liveness signal, orphan recovery, a curated image-repair GUI, the per-launcher file browser, and -- because `run_command` gives clean exec with real exit codes and no prompt-scraping -- the **least-brittle transport for the remote app launcher**. These are operational features the appliance needs anyway, so they're built first and the SPARCplug release is parked behind them.

Both ride the *exact same* daemon verbs, so building the control plane well builds almost all of the agentic substrate for free. That's the whole payoff of keeping the agent policy-free -- but it's a happy implementation outcome, not a combined "it serves two masters!" narrative. Nobody is moved by a daemon with two callers; they're moved by a 1998 Sun doing agentic development.

---

## The daemon: one mechanism, built Mac-first

A small daemon, baked into the SPARCplug image and started at boot, listening on a TCP port reached from the Mac via slirp `hostfwd` (`127.0.0.1:<port>` -> guest). It proxies, over one structured request/response channel:

- **command execution** -- run a shell command via fork/exec, return stdout, stderr, and the real exit code;
- **filesystem access** -- read, write, list, stat, and search files on the Sun's local disk;
- **liveness** -- a cheap handshake (version, hostname, uptime) so a client knows the guest is up and responsive.

Because the agent runs *on* the Sun, it sees the entire local filesystem with no NFS plumbing. Clean text in, structured results out, no terminal escape codes.

**Built on cx, which is why we develop it on the Mac first.** The daemon is plain POSIX C++ over Todd's **cx** libraries (`~/Dropbox/dev/cx`: base, net, json, log, process -- no STL, no templates, g++ 2.95.3 / `_SOLARIS6_` safe). cx runs identically on macOS, Linux, and Solaris 2.6, so the entire daemon -- protocol, framing, the exec engine, file verbs, error handling, and its test suite -- gets built and proven **on the Mac**, where the edit/compile/debug loop is seconds, not minutes-through-qemu. The Mac-side clients talk to a daemon on `localhost` during dev; no image, no slirp, no qemu needed.

That makes Solaris a *validation* step, not a development environment: recompile, run the same test suite on the 2.6 image, fix the platform deltas cx didn't already hide. It extends the project's "dev on emulator, deploy on iron" parity one rung further back: **dev on Mac -> validate on emulator -> deploy on iron, same code the whole way.** What Mac-first can't prove is Solaris-specific *semantics* (`init 5` behavior, rc/boot integration, slirp wiring, `cc`/`make` quirks); those are real but small and late.

**Wire protocol.** Newline-delimited JSON, one persistent connection, one request in flight at a time. Metadata travels as JSON strings; **file content travels base64-encoded** (cx's `b64` module) so the channel is byte-exact and immune to the NUL-truncation edge in the JSON parser. (cx's old code-transfer bug -- unescaped emit plus a parser that ate `//` and `/*` -- was fixed in cx commit `75b8304`; build the json/b64 libs from current source, not a stale `.a`.)

---

## The two clients

### Client 1 -- macXserver control plane (Swift, in macXserver)

macXserver owns the guest **lifecycle and deterministic control**: boot the image, set up the hostfwd, poll liveness, drive graceful shutdown, run the image-repair GUI, and ship the daemon baked into the image. No AI, no API key. A single Swift `HeliosClient` (socket + JSON/base64 codec) is the shared substrate; the control logic is a consumer of it.

This directly retires the control debt we accumulated building the plugin: graceful shutdown moves off console-scraping and off the dead telnet path onto the daemon's `shutdown` verb (which also works on an orphan, since the daemon lives in the guest and outlives the parent); the daemon's liveness replaces the fragile console `login:`-scrape for readiness; and the console auto-login can be deleted, leaving the console a pure observation glass-TTY.

### Client 2 -- Claude Code via the SPARCplug MCP server

The agentic-coding client is **the Claude Code app (or Claude Desktop)**, pointed at a **SPARCplug MCP server** that bridges MCP (to Claude Code) to the Helios protocol (to the daemon). The daemon verbs show up in Claude Code as native tools (`run_command`, `read_file`, `write_file`, `list_dir`, `stat`, `search`). We build the bridge; Claude Code is the loop.

We do **not** rebuild the agent loop. Claude Code already has a world-class agentic loop -- planning, self-correction, subagents, file editing -- and is the tool Todd uses daily. The MCP bridge is small, and a CLI shim (`helios run ...`, `helios read ...`) is an even smaller intermediate form Claude Code can drive over Bash before the MCP server exists.

The same MCP server reaches the emulator (over hostfwd) and a real bare-metal Sun (over its network) with no change, so Claude Code is the **constant operator** across the dev-Mac / validate-emulator / deploy-iron rungs.

**The self-hosting bootstrap.** The moment the MCP bridge exposes `run_command` + file ops, Claude Code can do the Solaris-side grind itself: validate cx on the image, fix configs, chase `cc`/`make` quirks, even help finish the daemon. The capability threshold for "the agent builds its own remaining work" is *earlier* than the full control suite -- it is just exec + file ops + the bridge. This is why a minimal bridge is worth reaching early: it is a labor multiplier, not just the eventual product. This week's image-lock + auto-backup + control-verb work is exactly the safety floor that makes letting the agent mutate the real image sane.

### Optional later -- in-app AI chat (end-users without Claude Code)

A shipped SPARCplug customer who can't drop to Claude Code is the *only* reason to build an in-app loop + chat UI inside macXserver (the old "promote-to-AI" split-window idea). It would sit on the same `HeliosClient` codec. The deterministic image-repair GUI already covers most of what such a user needs, so this is a deferrable product call, not a prerequisite for anything.

---

## The console (the secondary channel)

macXserver owns the serial-console fd and renders it in the observation window. It is the channel for the things the daemon can't cover: boot and recovery before the agent is up (single-user, `fsck`), human observation, and interactive prompts. It is **not** a control channel and not a command channel. A full VT100 terminal *emulator* is therefore not on the critical path; the console can stay a glass-TTY.

---

## Key design decisions

**The daemon is pure mechanism.** It knows nothing about control policy or LLMs. Both the control plane and the agentic loop are clients. This layering is the whole game: it is what lets one daemon serve two very different use cases with no rework.

**A capable agent on a port, not a filesystem mount.** Claude's edit logic runs client-side at full strength -- read a file through the agent, edit it in the harness, write it back through the agent -- but the bytes transit the port, not a mount. Search runs through the agent too. This trades "Mac-side ripgrep over a mount" for a self-contained appliance with zero NFS infrastructure (the explicit decision of 2026-06-17).

**Linear by default; the screen is not the surface.** Agentic dev is overwhelmingly line-oriented: shell, compiler, build, run, line-mode debugger. The agent's exec returns a clean transcript and an exit code directly via `waitpid` -- no escape codes, no 80-column wrapping. The console's live stream is kept only for interactive prompts and human watching.

**Editing goes through the agent, which retires the 2D problem.** The agent reads and writes files directly, so Claude never puppeteers `cm` or `vi`. The one job left for a 2D screen model is *observing a full-screen program the agent is itself building/testing*, served by the X-side framebuffer (Phase 2 below), not the serial console.

**Identity is whatever the agent runs as.** No shared filesystem means no cross-host uid mapping. Files the agent creates are owned by the Sun user it runs as.

**Sun-specific rules go in the system prompt** (i.e. in Claude Code's context, not the daemon): `sh` not bash (backticks not `$()`), `nawk` not old awk, Sun `cc`/`make` quirks, `dbx` not gdb, BSD-vs-SysV flag differences. A pre-baked GNU-ish toolchain in the image (gcc/gmake/bash/gdb) dissolves most of these; see SPARCSTATION_PLUGIN.md.

---

## Tool surface (the daemon verbs)

One verb set, ranked by the control holes it fills first (the control plane and the agentic client both use the same verbs):

1. **`hello` / liveness** -- version, hostname, uptime. The foundation, and immediately useful as macXserver's real "guest is ready" signal (replaces console `login:`-scraping).
2. **`shutdown`** -- graceful `init 5`. Fills the #1 control hole; works on an orphan too; lets us delete console auto-login. The first shippable control win.
3. **`run_command(cmd, cwd, timeout_ms)`** -- fork/exec on the Sun, returns stdout, stderr, exit code. Rides the cx `CxProcess` timeout/cwd extension (designed in `Tools/CX_PROCESS_TIMEOUT_AND_CWD.md`).
4. **`read_file` / `write_file`** -- unlocks the image-repair GUI and the agent edit cycle. Content base64-encoded.
5. **`list_dir` / `stat`** -- browsing for the repair GUI and agent navigation.
6. **`search`** -- grep/find on the Sun. Matters at dev-loop scale, not for control.

---

## Priorities and build order

Control-first, Mac-first, with a minimal agentic bridge reached early as the labor multiplier:

**Phase A -- substrate (on the Mac, plus one Solaris validation).**
1. Run `Tools/helios-tool-survey.sh` on the image; capture results.
2. Validate cx on Solaris 2.6 (build the libs, pass cxnet/cxjson/cxlog/cxstar). The real risk gate; never run yet.
3. Apply the `CxProcess` timeout/cwd extension (designed, 12 tests, not yet applied). Cross-platform, so build/test it on the Mac.

**Phase B -- daemon mechanism + control plane (the release-gating work).**
4. Daemon: protocol, listener, verbs 1-3 (liveness, shutdown, run_command), built and tested on the Mac.
5. Swift `HeliosClient` + wire macXserver's control consumer (liveness + shutdown). First real win: un-parks graceful shutdown, deletes console auto-login.
6. Boot integration: `/etc/init.d/helios-seed` + rc symlink, baked via `sparcstation-baseline-config.sh` (pattern proven by `guest/sshd-init.sh`). Validate the daemon on the 2.6 image.
7. File verbs (4-5) + the curated image-repair GUI.

**Phase C -- agentic coding (Claude Code + MCP).**
8. The SPARCplug MCP server (or first a CLI shim) bridging Claude Code to the daemon.
9. Point Claude Code at a booted SPARCplug; pass the hello-world self-correction test (below). From here the agent does its own grind on the image.

**Phase D (later) -- program-under-test lens.** The server-side text framebuffer so the agent can *see* full-screen programs it builds (the path to working on `cm` itself). X-side rendering, not serial-console emulation.

**Out for now:** driving editors on the Sun, RCS/SCCS on the Sun, multi-session orchestration, binary artifact management, NFS/NAS of any kind, and the in-app AI chat.

---

## Definition of Done (agentic MVP)

The control plane has its own acceptance (graceful shutdown + liveness driving macXserver, console auto-login deleted). The *agentic* milestone passes when, with **no human intervention after the initial prompt**, Claude Code (via the MCP bridge, against a booted SPARCplug) can:

1. Create a `hello.c` on the Sun containing a **deliberate syntax error**.
2. Compile it, observe the compiler's failure, and read the error.
3. **Correct** the source.
4. Rebuild successfully.
5. Run the binary and capture `Hello, world` as output.

This single loop exercises the whole architecture: file write (Mac -> bridge -> daemon -> Sun disk), remote build (Sun, via the daemon), result retrieval, error comprehension, self-correction, and run. A good *first real* job to follow it: "validate cx on this image and report what fails" -- dogfooding that proves the loop and does real work (take a backup first; the auto-backup makes agent mistakes recoverable).

---

## Curated image-repair GUI (the agent's first user-facing payoff)

The same daemon file primitives unlock a near-term, shippable feature that needs **no agentic loop at all**: a Mac-side GUI that edits the handful of things a guest image commonly needs fixed, driven entirely through `read_file` / `write_file`. Just structured forms over the daemon's filesystem proxy.

The curated set is small and known (~10 items): `/etc/vfstab` mounts, network config (hostname, IP/netmask/gateway, `/etc/defaultrouter`), DNS (`/etc/resolv.conf`, `nsswitch.conf`), timezone, root password, default shell, NFS/automount entries, `inetd.conf` services, `/etc/system` tunables, X/CDE display defaults. Each is a Mac-side form that reads the current file through the daemon, presents validated fields, and writes it back.

**Because we ship the image, we can do anything we want.** We control the exact paths, formats, and sane defaults, so the GUI validates against known templates and never guesses. This is also the strongest reason the console can stay a glass TTY: the config-and-repair tasks that argued for an interactive terminal move into structured GUI forms. The one residual terminal case is a hard-down boot where the filesystem is too broken for the daemon to start (interactive `fsck` in single-user); the glass-TTY console covers that until we shrink it.
