# Helios — Agentic Development for Vintage Sun Workstations

*Working name: **Helios** (a heliostat reflects modern light onto a fixed Sun). Alternatives: Sundial, Photon, Apollo. Name TBD.*

> **STATUS / SEQUENCING (as of 2026-06-16): DO NOT IMPLEMENT YET.**
> Helios is gated behind the SPARCplug "shippable plugin v1" milestone
> (three deliverables: engine-in-app binary, on-demand disk-image
> install, observation window + launcher enable). See the "Next
> milestone" section in `SPARCSTATION_PLUGIN.md`. Future sessions are
> welcome to *discuss* Helios, but should not write any Helios code or
> start any Helios work until plugin v1 has shipped. This is a
> deliberate sequencing decision by Todd, not an oversight. Treat this
> document as design-only background until then.

> **ACCESS MODEL DECIDED 2026-06-17.** Earlier drafts used an NFS/NAS
> file plane (the Mac as NAS, the Sun mounting it over NFS) plus command
> submission through the terminal fd. Both are **deprecated**. The sole
> access mechanism is now a single **Sun-side guest agent on a TCP port**
> that proxies both command execution and filesystem access, with the
> serial console as a secondary mix-in for boot and recovery. NFS was a
> large infrastructure overhang for a self-contained appliance; a capable
> agent on a port replaces it and generalizes (the same protocol reaches
> a real Sun over its real network later). Primary target is SPARCplug,
> the bundled emulator. Rationale in DECISIONS.md.

---

## Mission

Bring Claude-driven, agentic software development to classic Sun workstations **without turning the Suns into modern machines.** The intelligence, the network, the secrets, and the editing logic all live on the Mac. The Sun stays exactly as period-correct as it is today and contributes the one thing only it can: executing and running native SPARC/SunOS code.

The agent loop runs on the Mac against the Anthropic API. **Development happens entirely on SPARCplug**, the bundled emulated SPARCstation -- self-contained, reproducible, no hardware required. The Sun (emulated or real) is reached through a single **guest agent** running inside it, listening on a TCP port, that proxies both commands and filesystem access back to the loop. The serial console is a secondary, mixed-in channel for boot and recovery. There is no NFS and no shared mount.

**Dev on the emulator, deploy on the iron -- same agent.** Because the access mechanism is an agent on a port (not NFS, not anything emulator-specific), the exact same protocol reaches a real Sun over its real network that reaches SPARCplug over slirp. So all development happens on the emulator -- fast to spin up, identical every time, no physical Sun in the loop -- and the only thing that touches real hardware is *deployment*: a real Sun runs the same guest agent and is driven by the same macXserver, with no protocol change. Develop against the emulator, ship to the metal. That dev/deploy parity is a direct dividend of choosing the agent over NFS.

---

## Definition of Done (Minimal Viable Test)

Helios passes its first milestone when, **with no human intervention after the initial prompt**, it can:

1. Create a `hello.c` on the Sun that contains a **deliberate syntax error**.
2. Compile it, observe the compiler's failure, and read the error.
3. **Correct** the source.
4. Rebuild successfully.
5. Run the binary and capture `Hello, world` as output.

This single loop exercises the whole architecture end to end: file write (Mac -> agent -> Sun disk), remote build (Sun, via the agent), result retrieval (agent -> Mac), error comprehension, self-correction, and run. If this works, everything else is scale and polish.

---

## The Solution: One Agent, Two Channels

**Control plane -- the guest agent on a port.** A small daemon baked into the SPARCplug image, started at boot, listening on a TCP port reached from the Mac via slirp `hostfwd` (`127.0.0.1:<port>` -> guest). It proxies two things to the Mac-side loop over one structured request/response channel:

- **command execution** -- run a shell command via fork/exec, return stdout, stderr, and the real exit code;
- **filesystem access** -- read, write, list, stat, and search files on the Sun's local disk.

Because the agent runs *on* the Sun, it sees the entire local filesystem (`/etc`, `/var/adm/messages`, `/var/sadm`, the workspace) with no NFS plumbing and no visibility tradeoff. Clean text in, structured results out, no terminal escape codes.

**Console plane (the mix-in) -- the serial console.** macXserver owns the serial-console fd and renders it in the observation window. It is the channel for the things the agent can't cover: boot and recovery before the agent is up (single-user, `fsck`), human observation of what's happening, and interactive prompts. It is *not* the command channel anymore.

**Where the loop lives.** On the Mac, inside macXserver. It holds the API key and runs the tool-use loop, talking to the guest agent over the forwarded port. A 1990s Sun doing TLS to `api.anthropic.com` is infeasible (cipher suites, certs, CPU) and never has to -- it only runs the agent on a port it already trusts.

---

## Key Design Decisions

**Built into macXserver; nothing external.** Helios is part of macXserver, not a sidecar process. macXserver owns both channels as internal state: the guest-agent socket and the serial-console fd. There is no external PTY, ssh harness, or NFS mount to integrate. This is what makes the single-window experience possible.

**A capable agent on a port, not a filesystem mount.** The agent *is* the filesystem interface. Claude's edit logic still runs Mac-side at full strength -- read a file through the agent, edit it in the harness, write it back through the agent -- but the bytes transit the port, not a mount. Search runs through the agent too (grep/find on the Sun, or pull-and-search on the Mac). This trades the "Mac-side ripgrep over a mount" convenience for a self-contained appliance with zero NFS infrastructure, which is the right trade for a shipping plugin and the explicit decision of 2026-06-17.

**Linear by default; the screen is not the surface.** Agentic dev is overwhelmingly line-oriented: shell, compiler, build, run, line-mode debugger. The agent's exec returns a clean transcript and an exit code directly -- no escape codes, no 80-column wrapping, complete when the process exits. (The old `cmd > out 2>&1; echo $? > status` dance was an NFS-era workaround and is gone; the agent captures all three natively via `waitpid`.) The console's live stream is kept only for interactive prompts and human watching.

**Editing goes through the agent, which retires the 2D problem.** The main reason to drive a full-screen program was to edit. The agent reads and writes files directly, so Claude never puppeteers `cm` or `vi`. The one job left for a 2D screen model is *observing a full-screen program the agent is itself building/testing* -- and that is served by the X-side framebuffer (Phase 2), not the serial console. Later-phase instrument, not the workbench, not needed for the MVP.

**Identity is whatever the agent runs as.** With no shared filesystem there's no cross-host uid mapping to reconcile. Files the agent creates are owned by the Sun user it runs as. The old NFS uid-squashing problem simply doesn't exist.

**One namespace, no path translation.** Files live on the Sun's local disk and are addressed by their Sun paths through the agent. There is no parallel Mac mountpoint and no path-translation bookkeeping.

**Sun-specific rules go in the system prompt.** `sh` not bash (backticks not `$()`), `nawk` not old awk, Sun `cc`/`make` quirks, `dbx` not gdb, BSD-vs-SysV flag differences. A pre-baked GNU-ish toolchain in the image (gcc/gmake/bash/gdb) dissolves most of these; see SPARCSTATION_PLUGIN.md.

---

## Tool Surface (MVP)

Exposed to Claude for the milestone, all backed by the guest agent:

- **File tools** -- write `hello.c`, read it, edit it, list/stat, search. Backed by the agent's filesystem proxy; the edit logic runs Mac-side, only the bytes cross the port.
- **`run_command(cmd)`** -- run a shell command on the Sun via the agent's exec; returns stdout, stderr, and exit code directly. The command and its output also surface in the console observation pane.

Deferred (post-MVP): `send_keys` / `read_screen` over the console for interactive programs, and the X-side framebuffer grid for observing programs-under-test.

---

## Curated image-repair GUI (the agent's first payoff)

The same agent primitives that serve the dev loop unlock a near-term, shippable feature that can land **as part of, or before,** the full Helios loop: a Mac-side GUI that edits the handful of things a guest image commonly needs fixed, driven entirely through the agent's file read/write. No terminal, no agentic loop required -- just structured forms over the agent's filesystem proxy.

The curated set is small and known (~10 items): `/etc/vfstab` mounts, network config (hostname, IP/netmask/gateway, `/etc/defaultrouter`), DNS (`/etc/resolv.conf`, `nsswitch.conf`), timezone, root password, default shell, NFS/automount entries, `inetd.conf` services, `/etc/system` tunables, X/CDE display defaults. Each is a Mac-side form that reads the current file through the agent, presents validated fields, and writes it back.

**Because we ship the image, we can do anything we want.** We control the exact paths, formats, and sane defaults, so the GUI can validate against known templates, stage good versions, and never guess. This is the opposite of the bare-metal case where you're spelunking an unknown box over a serial line.

This is also the strongest reason the console can stay a glass TTY rather than a real terminal emulator: the config-and-repair tasks that were the main argument for an interactive terminal move into structured GUI forms. The one residual terminal case is a *hard-down* boot where the filesystem is too broken for the agent to start (interactive `fsck` in single-user). Even that is ours to shrink -- because we own the image, we can arrange for the agent to be reachable in a maintenance context -- but until we do, the glass-TTY console covers it.

---

## MVP Execution Trace

How the hello-world test flows through the architecture:

1. **Write (buggy).** Claude writes `hello.c` to the Sun disk through the agent's file tool -- `printf("Hello, world\n")` missing its semicolon.
2. **Build.** `run_command("cc hello.c -o hello")` runs on the Sun; the agent returns stderr and a nonzero exit code.
3. **Observe failure.** Claude reads the `cc` error and its line number straight from the tool result -- no file-and-mount round trip.
4. **Fix.** Claude edits `hello.c` through the agent, adding the semicolon.
5. **Rebuild.** `run_command("cc hello.c -o hello")` -> exit code 0.
6. **Run.** `run_command("./hello")` -> stdout `Hello, world`.
7. **Verify.** **pass** iff stdout contains `Hello, world` and both the build and run returned 0.

---

## The Workbench (macXserver, the primary surface)

The experience *is* macXserver. The SPARCstation console window can be **promoted to AI**, which splits it:

- **Top half -- the live console.** The serial-console view, still rendering the Sun session, so the user watches in real time exactly what Helios is doing (the agent's commands and their output echo here for transparency).
- **Bottom half -- the agent chat.** The conversation: user prompts, Claude's responses, a compact rendering of each tool call (e.g. `cc hello.c -> exit 1`, expandable to the output), and an input box.

On promotion, keyboard input routes to the chat input -- your typing now talks to Claude (a hint/steering channel), not the shell. A reserved **panic key** demotes instantly and hands the raw console back. A border/titlebar color marks promoted windows.

Build order within this surface: the **guest-agent core** (the daemon + the Mac-side client + the forwarded port: exec + file ops) is the foundation and is what the MVP test exercises; the console integration and the split-window chrome are presentation over that same core.

---

## Scope & Phases

**Phase 0 -- Guest-agent core + MVP.** The Sun-side agent daemon (exec + filesystem ops), baked into the image and started at boot; the Mac-side client and slirp `hostfwd` wiring inside macXserver; the console observation hook. Pass the hello-world self-correction test. Drivable before the full UI exists, but lives in macXserver from day one.

**Phase 0.5 -- Curated image-repair GUI.** Mac-side forms over the agent's file primitives for the ~10 common image fixes (see "Curated image-repair GUI" above). Needs only the agent's read/write, not the tool-use loop, so it can ship before or alongside the MVP and is a clean first user-facing payoff.

**Phase 1 -- The split-window workbench.** Promote-to-AI, top-console / bottom-chat layout, keyboard-routes-to-chat, panic key, visible promotion marker.

**Phase 2 -- Program-under-test lens.** The server-side text framebuffer (shadow cell grid fed by ImageString / CopyArea / ClearArea on the X side) so the agent can *see* full-screen programs it's developing -- the path to agentically working on `cm` itself. Note this grid is X-side rendering, not serial-console terminal emulation.

**Explicitly out for now:** driving editors on the Sun, RCS/SCCS on the Sun, multi-session orchestration, binary artifact management, and NFS/NAS of any kind.
