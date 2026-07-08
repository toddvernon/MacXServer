# Status 2026-07-08

## Headline: helios agent 0.2.0 is live on the ENTIRE real Sun fleet (11
machines) and the telnet-launcher regression is closed. The machine editor got
its password field back (machine-level now, with a one-shot lift from the old
per-launcher keys), verbose became a right-click launch gesture instead of
persisted config, and the launcher progress window states its wire facts. The
ss5 no-xterm mystery unwound into two separate bugs (stale 0.1.0 agent + a
colon-less DISPLAY), both fixed.

## Fleet / hardware

- heliosAgent deployed on all 11 real machines: ipc, ipx, ipx2, lx, ss1, ss2,
  ss10, ss20, ss5, u1, u5. Fleet complete.
- u5 revived: new NVRAM battery + idprom reprogram. Open puzzle: the previous
  battery was only ~3 months old and the machine ran continuously (battery is
  only drawn while powered OFF), so suspect a leakage path in the battery
  hack -- classic culprit is the dead internal cell in the M48T59 not being
  isolated, draining the new coin cell in parallel. If this battery dies fast
  too, that's the confirmation.
- ss5 had been quietly running agent 0.1.0 (a redeploy never actually landed /
  restarted the daemon -- uptime proved it was the same 2-day-old process).
  0.2.0 now deployed: OS auto-detects (sunos414), DNS admin lights up.
- Vintage lesson re-learned: SunOS 4.x DES crypt only reads the FIRST 8 chars
  of a password. A "wrong" test password that differs after char 8 logs in
  fine. Make test passwords wrong early in the string.

## What changed in swift-x this session

### Telnet password is machine-level (DECISIONS 2026-07-08)
- `Machine.password` (cleartext in machines.json, same trust level as the old
  launchers file). Edited in Settings > Connection, next to Prompt, shown when
  telnet is in play: secure field + "Show" checkbox.
- One-shot lift on load: legacy per-launcher password keys (the migration had
  seeded the same password onto EVERY launcher -- my live file had 92 copies)
  move to the machine, never re-encode. Old launcher-file migration lifts too.
- Injection is telnet-only at resolve time: ssh stays keys-only (no spurious
  warnings), helios has its own secret. Blank = prompt on first launch ->
  Keychain (Debug builds: the 0600 dev-secrets file).
- The field commits AS YOU TYPE (like the autoBackup toggle). The first cut
  waited for Return/pane-exit and I proved the hole immediately: typed a wrong
  password, launched from the menu, old password silently used. The other text
  fields still commit on Return/exit only -- fine for visible text, watch it.

### Verbose is a launch gesture, not launcher config (DECISIONS 2026-07-08)
- `MachineLauncher.verbose` is gone (editor toggle too). Legacy key ignored on
  decode, dropped on next save, same treatment as memoryMB.
- Right-click a launcher -> "Run with Progress Window": Overview chips AND the
  Settings-page X11 Launchers rows (rows also got plain "Run"). Plain click
  runs silent. The bit rides onLaunch(id, name, verbose) -> executeLaunch.
- Progress window header now states the wire facts in monospace:
  "telnet . tvernon@ipc.vernon.com:23 . DISPLAY 192.168.7.5:0" -- transport,
  account, port, and the DISPLAY actually handed to the client.

### DISPLAY typo fix-up at the edit boundary
- "desktop.vernon.com" without :0 is never valid X and fails brutally
  silently (client dies at connect under nohup >/dev/null AFTER the launch
  reports success -- exactly what ate ss5's xterms). The Settings DISPLAY
  field now appends :0 on field exit when the display number is missing, so
  the stored config matches what the field shows. Deliberately NOT a silent
  resolve-time fixup (Todd's call; memory has the principle).

## What's working / verified

- Full suite green (swift test), including new coverage: password round-trip +
  lift + telnet-only injection + machine-key-wins, legacy verbose drop.
- Telnet launchers against the real fleet work end to end (the 2026-07-07
  pinned regression is CLOSED -- machine shellPrompt + password did it).
- ss5: OS detected, DNS admin enabled, xterms launch (after the DISPLAY fix).
- File Transfer, DNS, System line all live across the fleet.

## What's broken / open

- SwiftUI/SourceKit shows stale phantom errors on Machine.password in the
  editor until Xcode reindexes -- the compiler is fine, ignore the squiggles.
- One manual step on the OTHER data front: nothing. machines.json migrated
  itself (passwords lifted, verbose keys drop on next save).
- u5 battery watch (see Fleet above).
- Console windows are still hide-on-deactivate utility panels -- convert if it
  annoys.

## What's next

- MCP bridge (still the standing next lead).
- Image download implementation per IMAGE_DOWNLOAD_PLAN.md.
- nuc machine has no OS set (external, non-Sun) -- harmless, DNS stays dimmed
  there by design.

## Committed this session

- swift-x: this session's commit on top of fce765c (password field + verbose
  gesture + progress-window detail + DISPLAY fix-up + DECISIONS + tests).
- SPARCplug, cx repos: no changes.

## Switching Macs

- REBUILD IN XCODE (model + UI changes; also clears the SourceKit phantoms).
- Let Dropbox finish syncing memory (fleet-deployment note, u5 battery
  puzzle, normalize-at-edit-boundary principle) before opening the laptop.
- No VMs running, no image locks. The fleet is all real hardware now and
  stays up on its own.
