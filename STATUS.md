# Status 2026-06-20 (end of day)

Two things today: finished the orphan-safety UX (live shutdown panel) and set
up SSH on the Studio, then a long design session that **refined the Helios
mission** and rewrote the docs around it. The headline is the design shift, not
the code.

## The big shift: Helios mission refined (docs rewritten)

We worked out the agent's shape and reprioritized. Three linked decisions
(DECISIONS 2026-06-20; full model in the rewritten `Helios-Mission.md`):

1. **Control-first.** The guest agent's first job is to plug macXserver's
   *control* holes (graceful shutdown, liveness, orphan recovery, image-repair
   GUI), not the agentic-coding loop. The **SPARCplug release is now parked
   behind having that control plane in place.**
2. **The daemon is pure mechanism, built Mac-first.** One daemon (exec + file +
   liveness) on cx, knowing nothing about control policy or LLMs. Because cx is
   cross-platform, the daemon + test suite get built and proven **on the Mac**;
   Solaris 2.6 becomes a validation step, not a dev environment.
3. **The agentic client is Claude Code + a SPARCplug MCP server, not an in-app
   loop.** We build the MCP bridge; Claude Code is the workbench. The old
   "promote-to-AI" in-app chat is superseded (demoted to a maybe-later feature
   for end-users without Claude Code). This also makes the self-hosting
   bootstrap cheap: once the bridge exposes run_command + file ops, Claude Code
   does the Solaris grind itself.

Docs reconciled to this: `Helios-Mission.md` (full rewrite), `DECISIONS.md`
(new 06-20 entry), `PLUGIN_V1_PUNCHLIST.md` (orphan section + L3), and
`SPARCSTATION_PLUGIN.md` (milestone resequenced). **Not yet committed** --
review the doc changes before committing.

## What landed today (code)

- **Orphan recovery UX (L2b) -- DONE, committed `2e98817`.** New
  `SparcShutdownProgressWindowController`: the silent ~35s "Try to Shut It Down"
  poll is now a live countdown panel that auto-boots on power-off or flips
  in-place to Force Quit / Show Me How / Cancel on timeout. `swift build` +
  1347 tests green; Xcode project regenerated for the new file.
- **L1 (image lock) verified live** by Todd (orphan dialog fires as intended).
- **SSH on the Studio (desktop) -- working.** Generated `~/.ssh/sparcplug_rsa`,
  added the `Host sparcplug` config block, installed the Studio pubkey into the
  guest via tftp. `ssh sparcplug` is passwordless from both Macs now. Switching-
  Macs memory updated.
- **Telnet graceful shutdown PARKED** (committed in `2e98817`): Solaris 2.6
  refuses root telnet login, so "Try to Shut It Down" always times out. Not
  switching to ssh (dev-only). The daemon `shutdown` verb is the real fix.

## Prior work still green (earlier 06-20, pre-session)

- Image lock L1 (host-aware, 10 unit tests), guest backspace fix, OpenSSH on
  the image, auto-backup on clean shutdown.
- macXserver app + X server + bundled engine: `swift build` / `swift test`
  clean (1347 tests, 29 skipped by design).

## What to do next (Helios, control-first, Mac-first)

Build order from `Helios-Mission.md` "Priorities and build order":

- **Phase A -- substrate.** (1) run `Tools/helios-tool-survey.sh` on the image,
  capture results; (2) **validate cx on Solaris 2.6** -- Todd is doing this now
  (the real risk gate, never run before); (3) apply the `CxProcess` timeout/cwd
  extension (designed in `Tools/CX_PROCESS_TIMEOUT_AND_CWD.md`, 12 tests, not
  yet applied) -- cross-platform, build/test on Mac.
- **Phase B -- daemon + control plane.** Daemon protocol + verbs 1-3 (liveness,
  shutdown, run_command) on the Mac; Swift `HeliosClient`; wire macXserver's
  control consumer (un-parks graceful shutdown, deletes console auto-login);
  boot integration + Solaris validation; file verbs + repair GUI.
- **Phase C -- agentic.** SPARCplug MCP server (or CLI shim) -> Claude Code ->
  hello-world MVP -> the agent does its own grind.

Open: confirm cx commit `75b8304` (the json code-transfer fix) is in the tree
shipped to the image; build cx json/b64 from source, not a stale `.a`.

Deferred v1 polish (unchanged): Restore-from-Backup UI, Track C downloader,
A4-A6 bundling + clean-Mac acceptance, wrap remaining Preferences tabs in
ScrollView.

## Pointers

- Mission + build order: `Helios-Mission.md`. Decision record: DECISIONS
  2026-06-20. Orphan tracker: `PLUGIN_V1_PUNCHLIST.md` (Lifecycle L1-L4).
- cx libs: `~/Dropbox/dev/cx` (base/net/json/log/process/b64). Validation
  plan: `Tools/CX_VALIDATION_ON_SOLARIS.md`. cx MCP precedent: the `cm` app.
- Wire protocol: newline-JSON + base64 content (cx json fixed in `75b8304`).
- Image + autobackup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ dated sibling).
- Lock file: `<image>.macxserver-lock`, next to the qcow2 (Dropbox).
