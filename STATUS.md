# Status 2026-07-05

## Headline: Machine Manager direction approved — macXserver becomes a machine manager, X server recedes to a stated-but-secondary service. Doc + DECISIONS committed; no code yet.

A design/decision session, not a coding one. Walked the overnight
`MACHINE_MANAGER_REFACTOR.md` proposal end to end with Todd and settled the
big questions. The proposal is now an approved build spec. Next actionable
work is P0 (extract `MachineController`), not started.

## What's decided this session (all in DECISIONS.md 2026-07-05 + the doc)

- **Identity inversion greenlit.** The app is organized around a machine list;
  the X server keeps running exactly as-is (per-connection `protocolQueue`,
  usable with zero VMs, still the technical heart) but becomes a
  stated-but-secondary service. Todd's "why": managing a heterogeneous
  collection of old machines is genuinely hard (config drift, build-everywhere),
  and this is the control plane that makes it not-hard — same for emulated VMs
  and real iron. Plus the "experience Sun machines" consumer angle.
- **Golden-master config story lives OUTSIDE the app.** Not building
  fleet/config-management. Dial the reference VM in by hand, then Claude deploys
  the delta over Helios to bring real boxes into compliance. Forces one rule:
  the `MachineRegistry` is visible to the MCP bridge (discovery layer Claude
  reads). Manager owns lifecycle + network path + discovery, brokers nothing
  (peer-clients-not-a-hub holds).
- **Networking**: slirp stays default; add a `-netdev socket` fabric as a second
  NIC so VMs talk to each other (static `le1` into guest-config/); hostfwd incl.
  `0.0.0.0`-bind for inbound on demand; vmnet-bridged OUT of scope
  (root/entitlement/security). `Machine.networkMode` carries the choice.
- **App flow**: separate first-class windows, not a unified sidebar shell.
  Machines window = front door (opens on launch, close ≠ quit — status item is
  the persistent presence); X Server = on-demand live-runtime window (clients,
  listener, drop). Menu bar goes thin: App / Machines (replaces SPARCstation,
  rebuilt from registry, launchers nested per-machine) / Server / Edit / Window.
  Status item becomes an "N running" dashboard. Capture stays an X-server
  feature (Prefs toggle + App-menu actions), not a peer surface.

## What's broken / rough

- Nothing new open. This was docs-only.
- Still carried from 07-04: rebuild macXserver in Xcode to pick up the 3
  launcher fixes (e8fc3ea / e01b36a / 7cac700) — committed but not in a rebuilt
  app. This becomes moot once P0 lands (same rebuild).

## What's next — the Machine Manager build plan (full detail in the doc)

- **P0 — extract `MachineController`, zero behavior change** (NEXT, not started).
  New `MachineController` in `SwiftXServerCore` owning the per-machine runtime
  (`{QemuEngine, QmpClient, console, ImageLock, secret, ports, sparcReady}`) with
  a `MachineControllerConfig` holding today's hardcoded values. AppDelegate holds
  one `controller?` in place of `qemuEngine?` + scattered globals; every
  `qemuEngine?.foo` → `controller?...`. Menu/State/refreshSparcMenu unchanged.
  Verify by Xcode rebuild + live VM run (Debug .app, not `swift build` — the
  ad-hoc-signed helper SIGKILL gotcha). Gate: no observable change.
- **P1 — registry + list window** (still one-at-a-time). `Machine` model,
  `MachineRegistry` (MCP-visible read path), `~/.macxserver-machines` file +
  one-shot migrator from `~/.macxserver-launchers` + `sparcplug.diskImagePath`,
  the front-door list window (HSplitView not NavigationSplitView), SPARCstation
  menu → Machines menu + Server menu, status-item dashboard. **Stop here and
  reassess** before paying for concurrency.
- **P2 concurrency** (milestone #6): dynamic ports, unique per-machine MAC,
  per-machine sockets/locks/secrets, N engines, + the socket-fabric inter-VM NIC.
- **P3 external hosts** (`.externalHost` kind against daemon-ready boxes like
  ss5, kill the loopback heuristic) — full "deploy Helios to a raw box" waits C9.
- **P4 catalog** (verified downloads per the NAS-corruption lesson, OS auto-detect).
- **P5 identity reframe** (app opens to the list, X server fully recedes).

## Committed this session (pushed to origin/main)

- ~/dev/X: 1d68b99 (Machine Manager: approve direction, flow + networking +
  DECISIONS entry). Touches MACHINE_MANAGER_REFACTOR.md (was untracked, now in
  the tree) and DECISIONS.md.

## Switching Macs

- Nothing image-side changed today. Normal Dropbox sync (memory + the doc rode
  git). No VM was run this session.
