# Helios — Agentic Development for Vintage Sun Workstations

*Working name: **Helios** (a heliostat reflects modern light onto a fixed Sun). Alternatives: Sundial, Photon, Apollo. Name TBD.*

---

## Mission

Bring Claude-driven, agentic software development to classic Sun workstations **without turning the Suns into modern machines.** The intelligence, the network, the secrets, and the editing all live on the Mac. The Sun stays exactly as period-correct as it is today and contributes the one thing only it can: executing and running native SPARC/SunOS code.

The agent loop runs on the Mac against the Anthropic API. The Sun is a dumb-but-capable execution target reached over a terminal session. Files live on shared NAS storage that both sides already mount, so editing and search happen on the Mac at full strength and never go through the terminal.

---

## Definition of Done (Minimal Viable Test)

Helios passes its first milestone when, **with no human intervention after the initial prompt**, it can:

1. Create a `hello.c` on the Sun that contains a **deliberate syntax error**.
2. Compile it, observe the compiler's failure, and read the error.
3. **Correct** the source.
4. Rebuild successfully.
5. Run the binary and capture `Hello, world` as output.

This single loop exercises the entire architecture end to end: file write (Mac→NAS), remote build (Sun), result retrieval (NAS→Mac), error comprehension, self-correction, and run. If this works, everything else is scale and polish.

---

## The Solution: Two Planes

**File plane — the Mac, over the NAS.**
Source of truth is the NAS. The Mac mounts it; the Sun mounts it over NFS. Claude's native file tools (read / write / edit) and search (ripgrep, git) operate on the Mac side at full speed. Editing a file is a local Mac operation, not a terminal puppeteering exercise.

**Execution plane — the Sun, inside macXserver's own terminal.**
macXserver *is* the terminal. It owns the window, the master fd of the session to the Sun, and the rendered cell grid — so there is no external PTY to bolt on; the tty stream and the screen are already internal state of the app. The agent submits commands (`cc`, `make`, `./a.out`, `dbx`) by writing to that fd exactly as a user's keystrokes would, and reads results from the stream (and, for bulk output, from files over NFS). The Sun does only what it alone can: compile and run native code.

**Where the loop lives.**
On the Mac, inside macXserver. It holds the API key and runs the tool-use loop. A 1990s Sun doing TLS to `api.anthropic.com` is infeasible (cipher suites, certs, CPU) and never has to — it only sees bytes on a session it already trusts.

---

## Key Design Decisions

**Built into macXserver; the terminal is not external.** Helios is part of macXserver, not a sidecar process. Because macXserver owns the terminal, the session's byte stream and cell grid are internal data structures the agent reads directly — there is no separate PTY or ssh harness to integrate. This is what makes the single-window experience possible and what unifies the "stream vs grid" question: the integrated terminal naturally has both.

**Linear by default; the screen is not the surface.** Agentic dev is overwhelmingly line-oriented: shell, compiler, build, run, line-mode debugger. Their output is a transcript. Redirecting to a file and reading over NFS (`cmd > out.log 2>&1; echo $? > status`) is *cleaner* than reading the terminal — no escape codes, no 80-column wrapping, unlimited scrollback, and the file is simply complete when the process exits. A thin live-stream reader is kept only for interactive prompts (a build asking y/n).

**Editing moves to NFS, which retires the 2D problem.** The main reason to drive a full-screen program was to edit. The agent edits files directly on the Mac instead, so it never puppeteers cm or vi. The one job left for a 2D screen model is *observing a full-screen program the agent is itself building/testing* (e.g. developing cm). That's a later-phase instrument, not the workbench, and not needed for the MVP.

**Identity is a number, not a name.** `toddvernon` on the Macs vs `tvernon` on the Unix boxes is cosmetic — NFS authorizes by numeric uid, and vintage Suns are NFSv2/v3 (no name mapping). The NAS squashes all access on the dev share to one owner (`all_squash, anonuid=<nas-uid>`), and the SMB/Mac login maps to the same NAS user. Same bytes, same owner-of-record, two labels.

**The Sun's only must-have native tool is fast search — and even that is optional.** git, patch, and recursive grep stay Mac-side over NFS. The Sun-specific rules reduce to: `sh` not bash (backticks not `$()`), `nawk` not old awk, Sun `cc`/`make` quirks, `dbx` not gdb, BSD-vs-SysV flag differences. These go in the system prompt.

**Path translation is the one bit of bookkeeping.** The harness knows two roots — the Mac mountpoint (e.g. `/Volumes/dev`) and the Sun mountpoint (e.g. `/net/nas/dev`) — and swaps between them when handing a path to a file tool (Mac) versus a PTY command (Sun).

---

## Tool Surface (MVP)

Exposed to Claude for the milestone:

- **Mac-native file tools over NFS** — write `hello.c`, read it, edit it. No terminal involved.
- **`run_command(cmd)`** — submit a shell command on the Sun by writing to the integrated terminal's master fd (the same path a keystroke takes). Implementation wraps it as `cmd > <out> 2>&1; echo $? > <status>`, then reads `<out>` and `<status>` back over NFS. Returns stdout/stderr text and exit code. The command and its output remain visible in the live terminal pane.

Deferred (post-MVP): `send_keys` / `read_screen` for interactive programs, and the framebuffer grid for observing programs-under-test.

---

## MVP Execution Trace

How the hello-world test flows through the architecture:

1. **Write (buggy).** Claude writes `hello.c` to the Mac mount via the file tool — `printf("Hello, world\n")` missing its semicolon.
2. **Build.** `run_command("cc hello.c -o hello")` runs on the Sun; output → `build.log`, exit code → `build.status`.
3. **Observe failure.** Mac reads `build.status` (nonzero) and `build.log` over NFS; Claude sees the `cc` error and its line number.
4. **Fix.** Claude edits `hello.c` on the Mac mount, adding the semicolon.
5. **Rebuild.** `run_command("cc hello.c -o hello")` → `build.status` now `0`.
6. **Run.** `run_command("./hello")` → `run.out`.
7. **Verify.** Mac reads `run.out`; **pass** iff it contains `Hello, world` and both statuses were `0`.

---

## The Workbench (macXserver, the primary surface)

The experience *is* macXserver. An xterm launched from the launcher can be **promoted to AI**, which splits its native Mac window:

- **Top half — the live terminal.** The same terminal view, still rendering the Sun session. The user watches the agent's commands run and scroll in real time — full transparency into exactly what Helios is doing.
- **Bottom half — the agent chat.** The conversation: user prompts, Claude's responses, a compact rendering of each tool call (e.g. `cc hello.c → exit 1`, expandable to the output), and an input box.

On promotion, the keyboard detaches from the shell and routes to the chat input — your typing now talks to Claude (a hint/steering channel), not the shell. A reserved **panic key** demotes instantly and hands the raw terminal back. Promotion snapshots the current screen as the agent's first observation, and a border/titlebar color marks promoted windows.

Build order within this surface: the **terminal-integration core** (own the fd, read the stream, write commands, capture exit status) is the foundation and is what the MVP test exercises; the split-window chrome is the presentation layer over that same core.

---

## Scope & Phases

**Phase 0 — Terminal-integration core + MVP.** Inside macXserver: own the session fd, write commands, capture stream and exit status, file plane over NFS. Pass the hello-world self-correction test. Can be driven before the full UI exists, but lives in macXserver from day one.

**Phase 1 — The split-window workbench.** Promote-to-AI, top-terminal / bottom-chat layout, keyboard-routes-to-chat, panic key, visible promotion marker.

**Phase 2 — Program-under-test lens.** The server-side text framebuffer (shadow cell grid fed by ImageString / CopyArea / ClearArea) so the agent can *see* full-screen programs it's developing — the path to agentically working on cm itself.

**Explicitly out for now:** driving editors on the Sun, RCS/SCCS on the Sun, multi-session orchestration, binary artifact management.
