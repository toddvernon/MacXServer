# Status 2026-07-08 (evening)

## Headline: audit day, no code touched. Two subagent audits of the machine
settings UI and the state/config model landed in MACHINE_SETTINGS_AUDIT.md,
and SETTINGS_CLEANUP_PLAN.md is the execution plan for tomorrow. One focused
day closes out VM land, then we're back to X11 work.

## What happened this session

- Pulled the other Mac's f577f81 (machine-level telnet password + verbose
  launch gesture) clean at session start.
- Audited: settings-field organization, label discoverability, the Identity
  section naming, and a full state x config-item cross-reference (does the
  UI expose what the code reads, and vice versa). Top findings hand-verified
  against the code, not just taken from the agents.
- Wrote MACHINE_SETTINGS_AUDIT.md (inventory, proposed section reorg, drafted
  captions/renames, 10 ranked findings) and SETTINGS_CLEANUP_PLAN.md (the
  four-phase day plan).

## Headline findings (details + line cites in the audit doc)

- F1 HIGH: Machine.ports is consumed everywhere, editable nowhere, and the
  port-conflict dialog tells the user to fix it "in Settings" where no
  control exists. Externals can't see their ports at all.
- F2 HIGH: networkMode is dead persisted config, and the live qemu hostfwd
  string binds all interfaces, so guest telnet/ssh/helios are LAN-reachable
  while the .slirp doc claims loopback-only.
- Also real: telnet Keychain slot shared by all loopback VMs with the same
  user (F6), DNS admin gated on an OS it never uses (F4), menu vs Overview
  disagree on Admin verbs (F5), launchers keyed by name with no uniqueness
  check (F9), hardcoded "ogin:"/"assword:" needles (F3, deferred).
- Reorg proposal: Identity -> Machine (Name/Kind/OS), Connection (Host/
  "Connect with"/Ports/Helios Secret), new Login section (User/Password/
  Shell prompt), DISPLAY renamed "Show windows on" and moved to Launchers,
  Runtime section dissolves to an Overview facts row.

## What's working / what's broken

- No code changed today; everything from yesterday's status still holds
  (fleet complete, telnet regression closed, suite green as of f577f81).
- The audit findings ARE the broken list now; they're ledgered in the audit
  doc with severity ranks.

## What's next (tomorrow, in order)

1. Open SETTINGS_CLEANUP_PLAN.md and confirm the three decisions at the top
   (delete networkMode + loopback binding, drop the DNS OS gate, ports/MAC
   facts to Overview).
2. Run the plan: Phase 1 (F2 + ports editor), Phase 2 (reorg + captions),
   Phase 3 (small fixes), Phase 4 (cleanup + docs + manual pass).
3. Then back to X11 land: MCP bridge is still the standing lead, image
   download per IMAGE_DOWNLOAD_PLAN.md behind it.

## Committed this session

- swift-x: audit + plan docs on top of f577f81.
- SPARCplug, cx repos: no changes.

## Switching Macs

- Docs-only session, so no rebuild strictly needed for this commit, but if
  the laptop hasn't rebuilt since f577f81 (model + UI changes), rebuild in
  Xcode before running the app.
- No VMs running, no image locks.
- Let Dropbox finish syncing memory before opening the other Mac (no new
  memories written today, so low stakes).
