# Status 2026-07-05

## Headline: Machine Manager P0 + P1 shipped in a day. macXserver is now organized around a machine list; external real hosts (ss5) are first-class with in-app Helios secrets.

Started the day discussing the MACHINE_MANAGER_REFACTOR proposal, approved the
identity inversion, then built the whole P0+P1 stack and proved it against the
real ss5. All pushed to main. At the doc's "stop after P1 and reassess" boundary.

## What's working / done this session

- **P0 -- MachineController extracted** (d3a30af): per-machine runtime unit (one
  QemuEngine + isReady), keyed by id. No behavior change; verified live.
- **P1a -- data layer** (192cf7f, e065a62): Machine model as **flat JSON**
  (`~/.macxserver-machines.json`) after Todd called the INI-with-inheritance
  format confusing. Lean MachineLauncher, terse encode / forgiving decode,
  one-shot migrator from the legacy launchers file. 12 tests.
- **P1b -- MachineRegistry** (d3a3def): machine home + live controllers +
  MCP-visible `snapshot()`. AppDelegate loads it at launch (migrating on first
  run), reaches the bundled controller through it. Still one-at-a-time.
- **P1c-1 -- Machines list window** (f0d4dff): the front door -- a row per
  machine (status dot, launchers, bundled-VM lifecycle buttons). Opens on launch,
  close != quit, doesn't hide on deactivate.
- **External-host Helios secrets** (1647a02, 10d2fa9): per-external-machine
  daemon secret entered in-app (show/hide toggle), stored in Keychain, supplied
  on every Helios call via `heliosSecret(host:user:)`. **Proven against the real
  ss5 with a static secret.** Most of the doc's P3 "external hosts" phase.
- **Keychain gating** (7837aac, cb3180e, 6971dd0): reads only on-demand (no
  launch prompt); disabled in Debug (ad-hoc signature churn), with a 0600
  `~/.macxserver-dev-secrets.json` fallback so secrets/passwords persist in dev.
- **P1c-2 -- menu + status reorg** (24b2a66, 8d61db8): SPARCstation + flat
  Launchers menus -> one registry-driven **Machines** menu; new **Server** menu
  (listener status + Drop All Clients); status-item "N running" dashboard.
  Launchers stay editable via the file, reconciled into the registry.
- **Docs**: MACHINE_MANAGER_REFACTOR has a "Shipped 2026-07-05" section;
  DECISIONS 2026-07-05 entry marked "approved AND P0+P1 shipped"; SHORTCUTS has
  a "Machine manager (P1 transitional)" section.

swift test: 1454 pass / 0 fail throughout.

## What's broken / rough (all transitional, in SHORTCUTS)

- **No in-app machine editor yet.** Machines are still edited by hand in
  `~/.macxserver-launchers`, reconciled into the registry on launch + file
  change. "Add Machine" is a stub alert. This is the biggest wart.
- External-host reachability dot is static (no `hello` poll yet).
- Bundled VM engine config still built from Preferences (makeSparcConfig), not
  from the machine -- identical output today; unifies when the Config UI moves.
- `SPARCSTATION_PLUGIN.md` + `PRODUCT_2_SERVER.md` not yet updated to the reframe.

## What's next (reassess boundary -- Todd to steer)

- **Add/Edit-Machine UI** (my lean): in-app add/edit/remove, retiring the
  launcher-file reconcile. Self-contained, completes the manager feel.
- **MCP bridge**: consume `MachineRegistry.snapshot()` so Claude Code drives the
  golden-master convergence (dial in reference VM -> deploy to real boxes over
  Helios). The payoff of the whole reframe. (Per memory: MCP path decided
  2026-06-20.)
- **P2 concurrency** (dynamic ports / unique MACs / N engines / socket fabric):
  deferred -- less urgent for a real-hardware-heavy fleet.
- Visual tweaks to the list window (Todd flagged for later).

## Committed this session (all pushed to origin/main, ~/dev/X)

d3a30af P0 MachineController -> 192cf7f/e065a62 P1a JSON model -> d3a3def P1b
registry -> f0d4dff P1c-1 list window -> 1647a02/10d2fa9 external secrets ->
7837aac/cb3180e/6971dd0 Keychain gating+dev fallback -> 24b2a66 P1c-2a Server
menu+dashboard -> 8d61db8 P1c-2b Machines menu. Plus this STATUS roll + the
Shipped/DECISIONS doc updates.

## Switching Macs

- Nothing image-side changed (no VM run this session for the manager work).
  Normal Dropbox sync for memory. All code rode git to origin/main.
- The real ss5 is on the LAN at 192.168.7.19 with a Helios secret now stored in
  macXserver (Keychain on Release; `~/.macxserver-dev-secrets.json` in Debug --
  that dev file is machine-local, not synced, so re-enter the secret on the other
  Mac's Debug build if testing there).
- macXserver must be rebuilt in Xcode on the other Mac to pick up all of P0-P1.
