# Machine Manager refactor — design proposal

Status: **direction approved by Todd 2026-07-05; no code yet.** Written overnight
2026-07-04 from your brain-dump plus a full read of the current code and the
architecture/decisions docs; the big questions were talked through and settled on
2026-07-05 (see "Settled 2026-07-05" below, and the DECISIONS.md entry of the
same date). Casual voice. This is now the build spec, not a maybe.

## Settled 2026-07-05

The conversation that turned this from proposal to plan. The decisions:

- **The identity inversion is greenlit.** macXserver becomes a machine manager;
  the X server recedes to a stated-but-secondary service. Todd's "why," sharper
  than the doc's original one: *managing a heterogeneous collection of old
  machines is genuinely hard — OS config drift, hard to build things everywhere —
  and this app is the control plane that makes it not-hard, identically whether a
  box is emulated or real iron.* Plus the consumer angle: an "experience what Sun
  machines were like" tool for people who'll never own the hardware.
- **Golden-master is the config-management story, and it lives OUTSIDE the app.**
  We are NOT building a fleet/config-management feature (no Ansible-for-Suns).
  Instead: dial the reference VM in by hand, then *Claude* deploys the delta over
  Helios to bring the real boxes into compliance. The app only needs the
  lifecycle manager + the external-host kind + a registry Claude can see. Scale
  stays hobby (a handful to a couple dozen boxes); the LAN-only/hobby-grade
  non-goal holds.
- **The registry must be visible to the MCP bridge** (see the MachineRegistry
  bullet). It's the discovery layer the golden-master workflow rides on.
- **Networking:** slirp stays default; add the socket-fabric second NIC so VMs
  can talk to each other; hostfwd (incl. `0.0.0.0` bind) for inbound on demand;
  full vmnet-bridged is out of scope for privilege/security reasons. See
  "Networking."
- **App flow:** separate first-class windows (Machines = front door on launch,
  X Server = on-demand live view), not a unified sidebar shell. Launchers move
  under machines. Capture stays a feature of the X server, not a peer surface.
  See "Menus and app flow."

## Shipped 2026-07-05 (P0 + P1 complete)

Built and pushed the same day the direction was approved. Commits on main:

- **P0 — `MachineController` extracted** (d3a30af). The per-machine runtime unit
  (one `QemuEngine` + `isReady`), keyed by id; AppDelegate routes through it. No
  behavior change; verified live.
- **P1a — data layer** (192cf7f, e065a62, +ports polish). `Machine` model, then
  converted to **flat JSON** (`~/.macxserver-machines.json`) per Todd's call --
  the INI-with-inheritance was confusing. Lean `MachineLauncher`, terse encode,
  forgiving decode; one-shot migrator from the legacy launchers file; 12 tests.
- **P1b — `MachineRegistry`** (d3a3def). The machine home + live controllers +
  MCP-visible `snapshot()`. AppDelegate loads it at launch (migrating on first
  run), reaches the bundled controller through it. Still one-at-a-time.
- **P1c-1 — Machines list window** (f0d4dff). The front door: a row per machine
  with status dot, launchers, and bundled-VM lifecycle controls. Opens on launch,
  close != quit (status item persists), doesn't hide on deactivate.
- **External-host Helios secrets** (1647a02, 10d2fa9, and the Keychain-in-Debug
  work 7837aac / cb3180e / 6971dd0). Per-external-machine daemon secret entered
  in-app (with a show/hide toggle), stored in the Keychain (Release) or a 0600
  dev file (Debug), supplied on every Helios call via `heliosSecret(host:user:)`.
  **Proven against the real ss5** with a static secret. This is most of the doc's
  P3 "external hosts" phase, pulled forward.
- **P1c-2 — menu + status reorg** (24b2a66, 8d61db8). SPARCstation + flat
  Launchers menus replaced by one registry-driven **Machines** menu; new
  **Server** menu (listener status + Drop All Clients); status-item "N running"
  dashboard. Launchers stay editable via the file, reconciled into the registry
  (`MachineRegistry.reconcile`).

**Reassess boundary reached** (the doc's "stop after P1"). What's next, weighed
against the golden-master "why": **add/edit-machine UI** (retire the launcher-file
reconcile, manage machines in-app) and the **MCP bridge** (consume `snapshot()`
so Claude drives reference→target convergence) lead; **P2 concurrency** is
deferred as less urgent for a real-hardware-heavy fleet. Transitional debts in
SHORTCUTS ("Machine manager (P1 transitional)").

### Shipped 2026-07-05 (P1c — in-app machine management, one unified window)

The first of those two leads landed. The Machines list and the add/edit editor
are **one window** (`MachinesWindowView`, HSplitView per the NSPanel gotcha): a
master list of machines on the left (`[+] [−] [clone]` toolbar), and a
per-machine detail pane on the right that switches between an **Overview** tab
(operate: status + lifecycle buttons + launcher buttons you click to *run*) and a
**Settings** tab (edit: the config form + add/edit/remove launchers). This
restores the doc's original "The list window" sketch, which always described a
single Machines surface doing both — the first cut built the editor as a second
window and Todd (rightly) called out the redundancy; the two collapsed into one
the same day. (The X Server stays its own separate window per "Menus and app
flow"; only the *Machines* editor folded in.)

In-app **add / edit / remove / clone** writes straight through a new
`MachineRegistry.add` / `remove` / `imageClaimant` surface. **The per-launch
launcher-file reconcile is retired** — `~/.macxserver-launchers` is imported once
on first run (`loadOrMigrate`) and then ignored; the JSON registry is
authoritative. The old launcher-file editor UI was deleted with it. **Clone**
(Todd's ask) copies a machine's config + all its launchers but not the disk image
or MAC (`Machine.cloned()`), so it seeds a new external host or a VM skeleton
without duplicating a qcow2. Honest scope guards: the bundled VM's kind/host are
locked and its image stays in Preferences lockstep (disabled while running);
memory/MAC/network-mode stay out of the UI (they'd be no-ops pre-P2); additional
emulated VMs can be configured but are flagged un-startable until P2. One model
(`MachinesModel`) backs the whole window: `machines` for the master/Settings,
per-id `rows` for the Overview, same gating as the Machines menu. swift test 1458
pass. Remaining transitional debts + the honest deferrals are in SHORTCUTS. Next
lead: the **MCP bridge**.

## Shipped 2026-07-06 (P2 — the concurrent multi-engine runtime)

Milestone #6 un-deferred and landed. Any number of emulated VMs run at once;
the console-follows-the-wired-machine steal is gone. What P2 turned out to be
(with the decisions that refined this doc's original calls — full rationale in
DECISIONS 2026-07-06):

- **A fresh `MachineController` per start**, built from
  `machine.makeEngineConfig()` — image, memory, ports, MAC, OS profile all off
  the machine; config edits apply at the next boot with no rebuild bookkeeping.
  `makeSparcConfig()`, the Preferences↔machine image sync, and the single
  `bundledMachine` resolver are deleted.
- **Per-machine console windows** keyed by machine id (titled by machine,
  per-machine frame autosave), per-machine DNS-admin windows, per-machine
  readiness + boot progress on the controller. Every closure resolves the
  current controller through the registry at fire time.
- **Sticky port assignment, NOT the dynamic allocator this doc proposed.**
  Todd's call: "dynamic by assignment time, not by invocation." A user-created
  emulated VM gets `ImagePorts.block(n)` (n = 5, 6, …; same 21n3/22n2/21n5
  mnemonic; bundled fixtures keep deriving blocks 2–4) assigned ONCE by the
  registry and persisted; clones get a fresh block; a start-time
  `portConflict` guard covers hand-edited JSON. The ecosystem's fixed-port
  assumption (emu scripts, helios CLI, Claude conventions) holds.
- **Per-machine MAC derived from the machine id** (locally-administered
  `02:` + id bytes; explicit override wins). The duplicate-MAC latent bug is
  dead.
- **Secrets: /tmp/sparkplug retired** (toggle, Config window, plumbing). The
  image lock next to the qcow2 now records the **helios port** alongside the
  per-boot secret, making it the complete reach-the-daemon handle for orphan
  recovery and the interim Claude-side channel; `MachineRegistry.snapshot()`
  carries `heliosPort` as MCP-bridge groundwork. `HeliosClient` requires an
  explicit port (the Solaris-2125 default died).
- **Whole-fleet flows**: the launch orphan scan walks every machine's image
  lock (ports from the lock), the quit dialog handles N running guests
  (detach leaves all their locks/secrets live), auto-backup is per-machine
  (`Machine.autoBackup`, edited in Settings next to the new memory field and
  the Reveal-in-Finder button), and the Machines → Config submenu reduced to a
  top-level global "Shared Folder…" item.

swift test 1481 pass. Next lead unchanged: the **MCP bridge** (the registry
snapshot + per-machine secrets are the discovery payload it serves).

## TL;DR

Turn macXserver from "one bundled Solaris VM, hidden under an X server" into a
**machine manager**: a bounded set of machines you add, start, stop, back up,
manage over Helios, and hang launcher commands under. A machine is one of two
kinds — an emulated qemu VM (full lifecycle) or an external real Sun on the LAN
(no lifecycle you own, but console/Helios/launchers). The X server stays the
technical heart and still runs standalone; it just stops being the thing the UI
is organized around.

The honest headline: **most of the hard machinery for this already exists.** The
per-image port blocks, guest-OS auto-detection, the QMP/Helios two-plane control
design, lock-as-VM-handle with orphan adoption, and the Helios peer-client
management channel are all built or designed. What you're actually overturning is
a *stated stance*, not a technical wall (see "The elephant" below). The two real
un-built pieces are the concurrent multi-engine runtime and Helios-on-real-iron.

Your three answers are baked in: unify VMs + real hosts, curated catalog + BYO
images, and (my call) dynamic host-port allocation for the emulated VMs.

## The elephant: this inverts a written decision

Before anything else, the thing you should decide on with eyes open. The plugin
doc is explicit and emphatic:

> SPARCSTATION_PLUGIN.md, Phase 2: "NOT a VM list, NOT a configuration panel.
> One machine, one set of controls." … closing line: "Resist the temptation to
> expand scope beyond 'one machine, pre-installed, just works.'"

And the whole architecture treats the emulator as "invisible scaffolding under
the X server," with the X server as the user-facing product (PROJECT.md,
ARCHITECTURE.md, SPARCSTATION_PLUGIN.md "Why this matters"). Your instinct — "the
primary utility now is the VM manager" — is a real inversion of that, not a
tidy-up. Per CLAUDE.md, product-stance and DECISIONS changes need your explicit
sign-off, so this doc is a proposal to *revisit* that stance, not a license to
start typing.

My read on why the inversion is now defensible, so you can gut-check it:

- The app already *is* two things. The single-machine framing was written when
  the emulator was genuinely a hidden appliance. It isn't anymore — there's a
  console window, backups, orphan reconnect, image locking, Helios management, a
  DNS admin panel. The scaffolding became furniture.
- SPARCplug widened the audience past Sun owners (the plugin doc itself says
  this in Phase 4: "the Solaris experience becomes the product"). Once the
  emulator is the draw, "manage your vintage machines" is the honest product.
- Real hardware (ss5) is now in the picture. The moment there's more than one
  box — emulated or real — "one machine, one set of controls" stops describing
  reality, and a list is the natural shape.

But the inversion has a hard boundary I'd hold, because a settled decision backs
it (DECISIONS.md 2026-06-21, "peer clients not a hub"): **"VM manager primary"
must not mean "VM manager becomes a broker."** It owns machine *lifecycle*, the
network *path* (its qemu adds the hostfwds), and *discovery*. It must never
proxy the X protocol or the Helios protocol. Claude Code and macXserver stay
co-equal Helios peers; the X server keeps its own per-connection session model.
"Primary" is about what the UI is organized around, not about routing bytes
through the manager.

If you don't buy the inversion, the fallback is smaller and still worth doing:
keep the X-server framing, but make the *plumbing* multi-machine (sections on the
Machine model, ports, and locking all stand on their own). The UI reframe is the
separable, more contentious half.

## What exists today (grounded, not from memory)

The current couplings, so the proposal is concrete about what moves:

- **AppDelegate is the god-object.** `Sources/SwiftXServer/AppDelegate.swift`
  (~1500 lines) owns the status item, the whole main menu, every window
  controller, the one `qemuEngine`, all VM lifecycle, launcher logic, and the
  lock/orphan dialogs. This is the primary refactor seam.
- **One engine, one of everything.** `qemuEngine: QemuEngine?` is a single
  optional. One console window, one `sparcReady` Bool, one `currentSecret`, one
  hardcoded MAC (`DE:AD:BE:EF:F3:E5`), one dev-secret path (`/tmp/sparkplug`),
  one `sparcplug.diskImagePath` preference. The `State` enum has no machine
  identity. The SPARCstation menu is a fixed submenu with singular verbs.
- **Ports are already built for concurrency, but unused.** `ImagePorts`
  (QemuEngine.swift) defines non-overlapping per-OS blocks (Solaris 2123/2222/
  2125, SunOS 2133/2232/2135, NetBSD 2143/2242/2145). But `makeSparcConfig`
  never sets `.ports`, so every launch uses the Solaris block, and static
  `heliosHostPort`/`telnetHostPort` hardwire it. `HeliosClient` defaults its port
  to the global `heliosHostPort` (2125) at every call site. The plugin doc is
  explicit (line ~280): "per-image ports are wired so the concurrent-three-images
  runtime can land later without a port redesign." The runtime is the missing
  piece, and it's already named as milestone #6.
- **Lock is the VM handle.** `ImageLock`/`ImageLockManager` writes a host-aware
  advisory lock next to the qcow2, carrying pid + secret + qmp/console socket
  paths. `evaluate()` returns free / staleSameHost / localOrphan / remoteLocked.
  Its whole job is preventing a second qemu from opening the same image
  (corruption), and it's the substrate for orphan reconnect
  (`QemuEngine.attach(toOrphan:)` drives a VM it didn't spawn). This generalizes
  cleanly to per-image, and it already enforces your "can't attach the same
  image twice" rule at the OS level.
- **Two control planes, deliberately divergent.** QMP (via `QmpClient`, owned by
  `QemuEngine`) is the hypervisor plane: liveness, clean qcow2 quit, the
  `SHUTDOWN` clean-halt event, snapshots. Helios is the guest-OS plane: `init 5`
  shutdown (the only FS-clean stop on sun4m), exec, files. **A real Sun has no
  QMP.** DECISIONS.md 2026-06-24 makes this split load-bearing: the two planes
  diverge *by deployment on purpose*. This is why the Machine model below uses
  capability sets, not one uniform interface.
- **Launchers are a flat host-keyed file.** `~/.macxserver-launchers`, parsed by
  `LauncherFile.swift`. Crucially, the `[host:KEY]` block → `[KEY/item]` merge is
  *already* "shared machine defaults + per-item overrides." That's the exact seam
  to formalize into a machine. Today a launcher binds to a host by naming
  host/user strings directly; "is this the bundled VM?" is a loopback heuristic
  (`isBundledGuestTarget`, host == 127.0.0.1) that already can't tell three
  bundled guests apart on different loopback ports.

Bottom line: the plumbing is ~70% there. The gaps are the concurrent runtime,
per-machine identity threaded through ports/secret/MAC, and the UI.

## The core new abstraction: `Machine`

One model, two kinds, capability sets that differ by kind. This is the piece
that makes "unify VMs + real hosts" honest without pretending a real Sun has a
power button you control.

```
Machine
  id            stable UUID (registry key, never the image path or host)
  name          user label ("Solaris 2.6", "the real SS5")
  kind          .emulatedVM | .externalHost
  os            OSType (solaris26 | sunos414 | netbsd | …) — drives qemu -M,
                the guest X bin dirs, helios quirks. Auto-detected from the
                image where possible (the guest-OS-detection design already
                exists), user-set for external hosts.
  connection    host, per-transport ports (or a port block), default user,
                default transport, DISPLAY override
  launchers     [LauncherCommand]  — the per-machine sub-list

  // emulatedVM only:
  image         path to the qcow2 (the lifecycle identity)
  macAddress (unique per machine), portAllocation
                (no memoryMB since 2026-07-07: every VM gets the SS-5's
                256MB max; a legacy memoryMB key is ignored on decode)
  networkMode   .slirp (default) | .slirpLanExposed | .socketFabric
                — see "Networking" below. Changes MAC handling, whether
                host-port-forwards apply, and how Helios/console reach the box.

  // runtime, not persisted:
  controller    MachineController?  (nil until started / adopted)
```

**Capabilities by kind** (this is the anti-"uniform lie" guard):

| capability            | emulatedVM | externalHost |
|-----------------------|:----------:|:------------:|
| start / stop / backup |     yes    |      no      |
| snapshot (QMP)        |   later    |      no      |
| console viewer        |     yes    |   maybe*     |
| Helios manage         |     yes    |     yes      |
| launchers             |     yes    |     yes      |
| runstate              | full FSM   |  reachable?  |

\* An external Sun's console is a serial line macXserver isn't hosting, so
"console" for a real box is at best a telnet/ssh session, not the QMP-backed
serial socket. I'd ship external-host console as "not available in v1" and
revisit, rather than fake it.

The UI renders a row per machine but greys/omits controls the kind doesn't have.
Runstate for an emulated VM is the existing 4-state FSM (notInstalled/stopped/
running + a readiness dot from `sparcReady`); for an external host it's just a
periodic Helios `hello` reachability check (up / down / unknown).

## Runtime: extract `MachineController`, keep it out-of-process

Lift everything that's currently a single global into a per-machine controller,
then hold a keyed collection instead of one optional.

- **`MachineController`** owns `{ QemuEngineConfig, QemuEngine, QmpClient,
  console window, ImageLock sidecar, currentSecret + its secret file,
  sparcReady, the port allocation }` for one machine, keyed by `machine.id`.
  This is a near-mechanical extraction: almost every `qemuEngine?.foo` in
  AppDelegate becomes `controller.engine.foo`. Do this first, with exactly one
  machine, so it's a no-behavior-change refactor before any multi anything.
- **`MachineRegistry`** replaces the single `qemuEngine?` property: the list of
  configured machines, their controllers (nil until running), persistence, and
  the invariants (image uniqueness, port allocation). AppDelegate talks to the
  registry; the god-object shrinks.
  - **The registry is the discovery layer, and it must be visible to the MCP
    bridge — not buried in AppDelegate.** This is the seam the golden-master
    workflow rides on: dial the reference VM in by hand, then Claude brings the
    real boxes into compliance over Helios. For Claude to do that it has to *see
    the collection* — what machines exist, their kind, and how to reach each
    one's Helios plane. So the registry is a first-class type in
    `SwiftXServerCore` that both AppDelegate and the MCP bridge query: the
    manager still owns discovery and the network path, Claude does the actual
    reference→target convergence over Helios as a co-equal peer, and macXserver
    brokers nothing (DECISIONS.md 2026-06-21, "peer clients not a hub").
    Concretely: don't let the machine list live as private AppDelegate state;
    the MCP bridge needs a read path to it.
- **Dynamic host ports (my call on your open question).** Keep `ImagePorts` as
  the *shape* (telnet/ssh/helios triple) but allocate the actual numbers from a
  reserved range (say 2200–2399) when a machine starts, record them in the lock
  + registry, free them on stop. Reasons: you asked for "any number, bounded,"
  and the fixed per-OS blocks cap you at one instance per OS (two Solaris VMs
  collide today). Dynamic allocation is a small allocator plus threading the
  triple through `buildArguments` and every `HeliosClient(port:)` construction —
  which you have to do for multi-machine anyway, because the global
  `heliosHostPort` default has to die. External hosts need no allocation; they're
  reached at their real LAN ports directly.
- **Unique MAC per machine.** The hardcoded `DE:AD:BE:EF:F3:E5` is a latent bug
  the moment two guests run at once (duplicate MAC on the same host slirp).
  Derive it from `machine.id` (locally-administered range, e.g. `02:…`).
- **Kill the loopback heuristic.** `isBundledGuestTarget(entry)` becomes "ask the
  owning machine": secret comes from `machine.controller?.currentSecret` (nil for
  external), readiness gating from the machine's own state. This also fixes the
  already-broken "three bundled guests all look like 127.0.0.1" problem.

Everything stays out-of-process qemu-over-sockets (DECISIONS.md 2026-06-16, the
licensing + crash-isolation seam). Nothing here fuses the engine into the app.

## Networking

Decided with Todd 2026-07-05 after walking the qemu options. The headline:
**slirp stays the default, we add cheap unprivileged capabilities, and we
deliberately do NOT chase full LAN-citizen bridging.** This is the 90%-of-the-
value-for-10%-of-the-pain line, and it keeps the app unprivileged (no root, no
Apple `com.apple.vm.networking` entitlement, no shipped setuid helper), which
matters for the ad-hoc/Dev-ID signing + minimal-tooling story.

Where things stand today (grounded): every VM uses qemu **slirp** (user-mode)
networking. Outbound is free — the guest sits on a private 10.0.2.0/24 and qemu
NATs it out through the Mac to anything the Mac can reach (the "slirp NATs to any
destination" fact). Inbound is only via explicit host-port-forwards (the telnet/
ssh/helios triple), bound to the Mac's **localhost**, so only the host app can
reach a guest. And each slirp instance is its own island — **VMs cannot see each
other** (each thinks it's the only 10.0.2.15 on its own private net).

Two separable capabilities, each with a cheap and a "real" version. We take the
cheap ones and skip the real one:

- **VMs talk to each other → qemu `-netdev socket` fabric (TAKEN).** A second
  NIC on each guest, wired to a shared virtual Ethernet segment (multicast or
  listen/connect socket) so the guests share an L2 broadcast domain. Fully
  unprivileged, internal to the Mac. This is `networkMode = .socketFabric`.
  - It's a **second** interface, not a replacement: the guest keeps `le0` on
    slirp (free outbound + the existing hostfwds) and gets `le1` on the fabric.
    qemu attaches a second netdev to a second NIC device; the guest sees two
    Ethernets. Everything we have today is preserved and the inter-VM path is
    added on top.
  - The fabric is dumb L2 — no DHCP (slirp is what hands out 10.0.2.15). So each
    guest needs a **static IP on `le1`** on a private inter-VM subnet we pick
    (e.g. 10.99.0.x). That's guest-side config, and it drops straight into the
    `guest-config/` canonical dotfiles as "each machine's inter-VM address" — so
    the golden-master workflow covers the networking config too (dial in `le1`
    on the reference, deploy it out).

- **Reachable from other than the host app → hostfwd, incl. `0.0.0.0` bind
  (CHEAP, on demand).** Host-port-forwards already ARE the mechanism (the telnet/
  ssh/helios triple). Two orthogonal knobs, both trivial, both compatible with
  the fabric: add more/different forwards = one more hostfwd line; make a forward
  reachable from the LAN instead of just the Mac = bind it to `0.0.0.0` instead
  of `127.0.0.1` (one line, no privileges). That's `networkMode =
  .slirpLanExposed` when a machine opts a forward out to the LAN. Independent of
  the fabric — one is inbound-from-Mac/LAN, the other is guest-to-guest.

- **Full LAN citizen (vmnet-bridged) → OUT OF SCOPE, documented wall.** Bridging
  a VM onto a real interface so it pulls a real LAN IP (indistinguishable from
  the real ss5) is the clean "real" answer and would nicely unify emulated VMs
  with external hosts on the network side. But macOS `vmnet` needs qemu **as
  root** or the Apple-gated `com.apple.vm.networking` **entitlement**, or a
  shipped privileged `socket_vmnet`-style helper (the Lima/colima path). All
  three collide with the unprivileged + minimal-tooling philosophy, and bridging
  unpatched 30-year-old OSes (telnet/rsh, no modern crypto) onto real networks is
  a genuine security exposure that the LAN-only/hobby-grade non-goal exists to
  fence out. Parked as "advanced, maybe never, loudly opt-in if ever." If it's
  ever wanted, `socket_vmnet` is the escape hatch that keeps qemu unprivileged.

Consequences that thread into the rest of the design:

- **Unique per-machine MAC stops being optional.** Already flagged as a latent
  bug (the hardcoded `DE:AD:BE:EF:F3:E5`); on any shared segment (even the
  internal fabric) duplicate MACs collide. The derived-from-`machine.id` MAC is a
  hard prerequisite the moment the fabric exists.
- **`networkMode` gates which machinery applies.** The dynamic host-port
  allocator only matters for slirp-mode inbound; a hypothetical bridged machine
  wouldn't use hostfwds at all (you'd reach its real IP, exactly like ss5). Noted
  so the port allocator isn't assumed universal.
- **Build work is small:** attach the second socket netdev in `buildArguments`,
  pick the inter-VM subnet + put static `le1` config in guest-config, and add the
  `networkMode` field. No privilege story changes.

## Launchers become a machine's sub-list

Your instinct here matches the code's existing shape exactly. Formalize the
`[host:KEY]` block into a first-class `[machine:KEY]` that carries the connection
identity + port block + kind, and make launcher items its children:

```
[machine:solaris]
  kind      = emulatedVM
  os        = solaris26
  image     = ~/Library/.../solaris-2.6.qcow2
  user      = tvernon

[solaris/xterm cyan]
  command   = xterm -fg cyan -bg black ...

[machine:ss5]
  kind      = externalHost
  host      = 192.168.7.19
  user      = tvernon
  transport = helios

[ss5/Files]
  filebrowser = true
```

- The Launchers menu stays exactly as a user-facing concept (you said keep it),
  but it's now generated per machine from the registry — model the menu build on
  the existing `rebuildLaunchersMenu` (it's already the one N-of-things pattern
  in the app, keyed by `group/name`). Editing launchers = adding commands under a
  machine, in the list window's per-machine sub-list.
- DISPLAY computation is unchanged (`entry.display ?? advertisedHost:display`);
  the per-machine `display` override handles the slirp `10.0.2.2:0` case.
- Migration: an existing `~/.macxserver-launchers` maps almost 1:1 — each
  `[host:KEY]` becomes a `[machine:KEY]` (kind inferred: loopback → emulatedVM
  bound to the current bundled image, else externalHost). The single
  `sparcplug.diskImagePath` becomes the one seed emulated machine. I'd write a
  one-shot migrator so nobody hand-edits.

Whether the machines registry and the launchers live in one file or two is a
detail; I lean one file (`~/.macxserver-machines`, machines with nested
launchers) so a machine and its commands travel together, with the old
launchers file auto-migrated and then ignored.

## The list window

A single window, one row per machine, matching your sketch:

```
 [+]  add machine

 ●  Solaris 2.6        running   ~/…/solaris-2.6.qcow2   [stop] [backup] [manage] [console]
    └ xterm cyan   ·   xterm green   ·   dtterm   ·   Files…            [+ command]
 ○  SunOS 4.1.4       stopped   ~/…/sunos414.qcow2      [start][backup] [manage] [console]
    └ (no launchers)                                                     [+ command]
 ◐  the real SS5      reachable 192.168.7.19 (external) [—]   [—]  [manage] [—]
    └ xterm cyan   ·   Files…                                            [+ command]
```

- **Runstate dot**: filled/hollow/half for running-ready / stopped / reachable-
  external. Emulated VMs show the boot progress from `onProgress`.
- **[+] add machine** flow: pick kind. Emulated → pick OS from the **catalog**
  (curated downloadable images: Solaris 2.6 / SunOS 4.1.4 / NetBSD, the ones you
  already host) *or* "point at my own qcow2" (BYO). External → host + user +
  transport. The per-row **download** button is the catalog fetch for a machine
  whose image isn't local yet (progress + checksum; and given today's finding,
  **verify the download**, don't trust size).
- **Per-row buttons** map straight to existing engine verbs: start/stop
  (start / graceful `shutDown` / Force Quit), backup (`backUpDiskImage`), manage
  (opens the Helios-backed surface — file browser + DNS admin + run-a-command,
  the existing pieces), console (the reconnectable serial console window).
- **Per-machine launcher sub-list** with `[+ command]` to add/edit — this is the
  new home of launcher editing, replacing the standalone Launchers panel (the
  menu it drives stays).

Menu restructure: the fixed "SPARCstation" submenu with singular verbs goes away.
In its place, a **Machines** menu rebuilt from the registry (a submenu per
machine with that machine's verbs + its launchers), plus a top item that opens
this list window. The status bar surfaces a one-line manager summary (N running)
alongside the existing listener status.

## App identity: X server as a quiet service

You said VM manager primary, X server supporting. Concretely, and keeping the
"not a hub" boundary:

- The **X server keeps running exactly as it does** — same per-connection
  `protocolQueue` session model (DECISIONS.md 2026-05-10, untouched), same
  listener on :6000, usable with zero VMs. It is still the technical heart.
- What changes is *surface*: the app opens to / is organized around the machine
  list; the X server becomes a background service surfaced in status + settings
  (listening address, scale, clipboard, Motif frame). You rarely think about it,
  the same way you rarely think about the audio daemon.
- **One shared X server, N machine clients.** All machines DISPLAY to the same
  Mac screen (real X: one server, many clients). No multi-display in scope.
- Optional nicety, not v1: label incoming X sessions by originating machine
  (which hostfwd/IP they came from), so a window knows "this is from the SunOS
  VM." The session model is per-X-connection today with no VM notion, so this is
  net-new and I'd defer it.

## Menus and app flow

Settled with Todd 2026-07-05. The reframe finally gives the app a **front door**;
today there is none — it's a status-bar item plus a standard main menu bar, and
everything happens through menus that spawn transient windows (the status-bar
menu is deliberately bare: listener address + Stop Server; the comment there even
says "everything else lives in the standard app menu"). The center of gravity
moves from the menu bar to a window.

Grounded starting point (`AppDelegate.installMainMenu`, ~354-560): App menu
(About/Ack · Prefs/Resources/Fonts · Capture actions · Drop All Clients ·
Hide/Quit) · Edit (the X clipboard Cut/Copy/Paste) · **Launchers** (flat, from the
launcher file) · **SPARCstation** (Start/ShutDown/ForceQuit · Console/Backup ·
Config submenu · Admin submenu) · Window. The `SPARCstation` menu's verb set is
the exact template for a per-machine submenu.

**Chosen shape — separate first-class windows, not a unified sidebar shell.** We
considered a single window with a source-list of surfaces (Machines / X Server /
Capture); Todd chose separate windows as the lower-risk path that doesn't turn
this into a big multi-surface application shell. Capture is NOT a peer surface —
server-side capture is a *feature* of the running X server (Preferences toggle +
the existing App-menu actions), and the standalone macXcapture app is a separate
target entirely, out of this reorg.

Two first-class windows:

- **Machines** — the front door. Opens on launch, is the thing the app is
  organized around, and **closing it does not quit** (you're managing long-lived
  VMs; the status item is the persistent presence). This is the list window
  described under "The list window."
- **X Server** — the server's "stated top-level presence," as its own on-demand
  window rather than a sidebar row: the *live runtime* view — connected clients,
  listener status, Drop-a-client / Drop All Clients. Raised on demand, not on
  launch. Config (scale, clipboard, Motif frame, listen address) stays in
  Preferences; this window is what-it's-doing, Preferences is how-it's-set-up.

Menu bar becomes thin — command surfaces for the windows, not the home:

- **App** — About, Acknowledgements, Preferences, Quit.
- **Machines** (replaces SPARCstation) — "Machine List…" (raise the window) · a
  submenu per machine, rebuilt from the registry, carrying that machine's verbs +
  its launchers · "Add Machine…". Launchers live here, under their machine — the
  flat top-level Launchers menu goes away (we'll feel out whether per-machine-only
  is enough).
- **Server** — "Show Server Window…" · Drop All Clients · listener status. The X
  server's stated presence in the menu bar; opens the X Server window.
- **Edit**, **Window** — unchanged.

**Status item** grows from "listener + Stop Server" into the glanceable manager
dashboard: a one-line "N running" summary, each machine with a running/stopped dot
+ quick start/stop, and "Open Machine Manager." This is what you use when the
windows are closed, and it's the persistent menu-bar presence that makes
close-doesn't-quit correct.

Capture actions stay in the App menu as they are today; the Capture toggle stays
in Preferences.

Net flow: launch → Machines window (front door) → close it and the app keeps
running in the menu bar → status item is the glanceable dashboard → menu bar is
thin (App / Machines / Server / Edit / Window). The `SparcPlugConsoleWindow`,
`FileBrowserWindow`, and `DnsAdminWindow` controllers are reused per machine as
before; the split-view in any new window uses HSplitView, not
NavigationSplitView (the documented NSPanel gotcha).

## Invariants and rules

- **One live opener per image** (your "can't attach the same image to two items"
  rule): enforced twice — the registry refuses to add/start a second machine
  pointing at an image already claimed, and the `ImageLock` enforces it at the OS
  level as the backstop (including the cross-Mac Dropbox case, best-effort). Each
  running emulated machine gets its own lock sidecar, its own QMP/console socket
  paths, its own secret file (the single `/tmp/sparkplug` becomes per-machine).
- **Capability divergence is real, not cosmetic.** Never call start/stop/snapshot
  on an external host. The kind gates the verbs.
- **Peer-client, not hub** (DECISIONS.md 2026-06-21). The manager owns lifecycle
  + network path + discovery. It never brokers X or Helios protocol traffic.
- **One plane owns each job** (DECISIONS.md 2026-06-20 floor/ceiling). Helios is
  the zero-config floor for liveness/shutdown/launch; QMP is the emulator-only
  hypervisor plane; ssh is the opt-in ceiling. Keep per-machine ownership clean;
  don't co-own liveness.
- **LAN-only, hobby-grade** (PROJECT.md non-goals, sign-off-gated). A "machine
  manager" must not drift toward WAN/fleet/24x7 framing. This is a manager for a
  handful of boxes on your bench, not a datacenter console.

## Prerequisites and risks (the un-built parts)

1. **Concurrent multi-engine runtime** — deferred milestone #6. Running N
   `QemuEngine`s at once needs: dynamic ports (above), unique MACs (above),
   per-machine sockets/locks/secrets (above), and validation that slirp + the
   host handle several guests. This is the biggest new build, but every piece is
   scoped.
2. **Helios on real iron** — HELIOS_PLAN C9, unbuilt, and it's the gate on the
   "external host" kind being genuinely first-class. Two macXserver-side gaps:
   auth (the `-prom-env` per-boot secret trick doesn't port to a box you don't
   boot; the intended path is an ssh `-L` tunnel carrying trust, or a per-machine
   Keychain secret) and agent deployment (get-helios deploys over the daemon
   itself; a real box needs a bootstrap — which we partly walked through with ss5
   today). Until C9, external hosts work for launchers + file browser against a
   box that *already* runs the daemon (like ss5 now), but "add a raw real Sun and
   deploy Helios to it from the UI" is future work.
3. **MAC-address collision** is a real latent bug today (single hardcoded MAC);
   the refactor has to fix it, but flagging it because it bites the moment two
   VMs run even in a half-built state.
4. **Cross-Mac lock is best-effort** (Dropbox latency). Multi-machine doesn't
   make this worse per-image, but the list window should show "remotely locked"
   honestly rather than imply certainty.
5. **Sign-off gates** (CLAUDE.md): this touches DECISIONS.md (the one-machine
   stance, the bundled-engine framing), adds at least one new top-level type
   (`Machine`/`MachineRegistry`/`MachineController` — I'd keep them in
   `SwiftXServerCore` alongside `QemuEngine`, not a new module, to stay inside
   the existing layout), and revisits a product non-goal. None of it is a
   unilateral change; that's what this doc is for.

## Suggested phasing (each phase shippable)

- **Phase 0 — extract, no behavior change.** Pull `MachineController` out of
  AppDelegate with exactly one machine. Pure refactor; the app behaves
  identically. De-risks everything after.
- **Phase 1 — registry + list window, still one-at-a-time.** Add
  `MachineRegistry`, the list window, the `[machine:KEY]` file + migrator. You
  can add/remove machines and switch which one is active, but only one runs at a
  time (keeps ports/MAC static). Ships real UI value with none of the concurrency
  risk.
- **Phase 2 — concurrency.** Dynamic ports, unique MACs, per-machine sockets/
  locks/secrets, N engines at once. Un-defers milestone #6. The heavy phase.
- **Phase 3 — external hosts + launchers-under-machines.** External-host kind
  (against boxes already running Helios, like ss5), fold launcher editing into
  the per-machine sub-list, kill the loopback heuristic. Depends on C9 for the
  full "deploy Helios to a raw box" story; works now for daemon-ready boxes.
- **Phase 4 — catalog + add-machine polish.** Curated downloadable images with
  verified downloads, the OS-from-image auto-detect wired into add-machine.
- **Phase 5 — the identity reframe.** Make the app open to the machine list, X
  server recedes to a service surfaced in status/settings. This is the
  contentious, separable half; it can trail or be dropped without losing the
  plumbing wins.

I'd stop after Phase 1 and reassess — that's where you find out if the list-first
UX actually feels right before paying for concurrency.

## Decisions I made (confirm or overrule)

- **Reframe is real but bounded.** VM-manager-primary means UI organization, not
  a protocol hub. X server stays standalone and is the technical heart. If you
  want the full "X server disappears into a service," that's Phase 5 and I'd want
  your explicit yes because it overturns the stated stance.
- **Dynamic ports** over fixed per-OS blocks (your open question). Enables >1 of
  an OS and any-number-bounded; costs a small allocator.
- **Two kinds via capability sets**, not a uniform machine interface — because a
  real Sun genuinely has no QMP/start/stop, and DECISIONS.md makes that split
  load-bearing.
- **One file** (`~/.macxserver-machines`) with launchers nested under machines,
  old launcher file auto-migrated. Could be two files; minor.
- **External console deferred** — a real box's serial line isn't ours to host;
  don't fake it.
- **Label-X-by-machine deferred** — net-new against the per-connection session
  model, nice-to-have.

Open questions for you:

1. Do you actually want the Phase 5 identity inversion, or is "multi-machine
   plumbing under the existing X-server framing" enough? (The plumbing wins don't
   require the reframe.)
2. Bound: what's the real max machine count you care about — ~6, or genuinely
   dozens? Changes how hard the allocator/UX work.
3. External hosts in v1: only boxes already running Helios (works now), or do you
   want "add a raw Sun and deploy Helios from the UI" (needs C9) in scope?
4. Snapshots (QMP) in the list window — Phase 2, or later? They're emulator-only
   and would widen the capability gap between the two kinds.

## Files this touches (map for whoever builds it)

- Extract/own: `Sources/SwiftXServer/AppDelegate.swift` (the god-object; menu
  build 354-560, engine wiring 209-257, launcher/gating 712-923, orphan 1136-,
  backup 1017-, validateMenuItem 1495-).
- Core model: new `Machine`/`MachineRegistry`/`MachineController` in
  `Sources/SwiftXServerCore`, alongside `QemuEngine.swift` (`ImagePorts` 32-49,
  `currentSecret`, `heliosHostPort`/`telnetHostPort` 930-937 — these globals
  die), `ImageLock.swift`, `SparcBackup.swift`.
- Launchers: `LauncherFile.swift` (the `[host:KEY]`→`[machine:KEY]` model),
  `DefaultLaunchers.swift`, `HeliosClient.swift` (per-machine port, not the
  global default), the transports.
- UI: new list-window controller (NSPanel + NSHostingView, HSplitView not
  NavigationSplitView per the documented gotcha), reusing
  `SparcPlugConsoleWindowController`, `FileBrowserWindowController`,
  `DnsAdminWindowController` per machine.
- Docs to update on sign-off: DECISIONS.md (new entry for the stance change),
  SPARCSTATION_PLUGIN.md (the "NOT a VM list" section), PRODUCT_2_SERVER.md.
