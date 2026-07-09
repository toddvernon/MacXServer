# Status 2026-07-09

## Headline: settings cleanup day executed, then revised live. All four
phases of SETTINGS_CLEANUP_PLAN.md shipped (9 of 10 audit findings
closed, F3 deferred to SHORTCUTS by design), and Todd's manual pass drove
an evening round: sections regrouped by PLANE (Helios and Telnet/SSH each
own a section, transport demoted to launcher config), helios secret keyed
by host, prober candidacy = secret-saved. See the three 2026-07-09
DECISIONS entries. Next session opens on X11 work (MCP bridge lead, or
the CLIPBOARD/editres gaps).

## Evening revision (Todd's manual pass, after the morning phases)

- Fleet dots mystery solved: every fleet agent was fine (all accept
  secret "test"; verified by direct hello) -- the per-Mac Debug secret
  store ~/.macxserver-dev-secrets.json just lacked 8 of 11 entries on the
  desktop. Backfilled; memory updated (switching-Macs checklist + the
  fail-closed-auth note).
- Settings sections are planes now: Machine / Connection (host, user) /
  Helios (port, secret, live status line) / Telnet-SSH (ports, password,
  shell prompt, always visible) / Disk Image. Launchers became their own
  TAB (Overview / Settings / Launchers) holding "Show windows on",
  "Connect with", and the list; per-tab drafts commit only the fields
  they own, so the tabs can't clobber each other.
- "Connect with" = how launcher commands sign in, nothing more. Prober
  candidacy is secret-saved-only; secretless external = gray "not watched
  (no Helios secret)" instead of a bogus "refused" orange.
- Helios secret keyed helios:<host> (was user@host; editing User detached
  the secret -- the ipc confusion). Legacy entries migrate on read.
- Wording: "this Mac" never "this server"; effective-default gray
  placeholders say so in the caption; Overview section renamed "Helios
  Admin Agents".

## What happened this session

Todd confirmed the three morning decisions as recommended: delete
networkMode + bind loopback, drop the DNS OS gate, ports/MAC facts to
Overview. (Context that drove the first one: VM-to-VM networking someday
is unaffected -- each guest is its own slirp NAT; guest A can reach guest
B via 10.0.2.2:port even with loopback binding, and a real shared segment
would be a new netdev + fresh design anyway.)

- **Phase 1a (F2)**: `MachineNetworkMode` deleted (was decoded/encoded,
  read by nothing); qemu hostfwds now `hostfwd=tcp:127.0.0.1:...` --
  guests are no longer LAN-reachable. DECISIONS entry.
- **Phase 1b (F1)**: editable Ports row (telnet/ssh/helios) in Settings ->
  Connection for BOTH kinds; blank = derived, placeholders show the
  derived block, all-blank clears the override. Commit-time collision
  check via new `MachineRegistry.portBlockClaimant` (+ tests); fields
  freeze while running. The port-conflict dialog's "fix it in Settings"
  is finally true.
- **Phase 2**: section reorg to Machine / Connection / Login / X11
  Launchers / Disk Image. Renames: Transport -> "Connect with" (Telnet /
  SSH / Helios agent), DISPLAY -> "Show windows on" (moved to Launchers),
  Prompt -> "Shell prompt", Identity -> "Machine"; OS picker shows
  displayName. Runtime section dissolved to an Overview monospaced
  ports+MAC facts line. Helios Secret moved Overview -> Settings ->
  Connection; dialog text rewritten. Hover tooltips promoted to visible
  fieldCaption footnotes everywhere (incl. the F10 telnet-PATH asymmetry
  in the launcher-command caption).
- **Phase 3**: F5 menu parity (both kinds get Admin submenu = File
  Transfer + DNS, gates mirror the Overview; external Helios Secret menu
  item retired). F9 launcher-name uniqueness blocks Done in the editor
  sheet. F6 telnet Keychain account = user@host:port with one-shot
  fallback migration (old entry left alone). F4 DNS admin no longer
  OS-gated.
- **Phase 4**: F7 verbose field/parse removed from LauncherFile (doc block
  fixed); F8 startup no longer reads ~/.macxserver-launchers when
  machines.json exists (bundledUser falls back to NSUserName()); loopback
  host list deduped (MachinesFile.isLoopback now public, AppDelegate
  delegates). F3 ledgered in SHORTCUTS. DECISIONS entries x3 (loopback
  bind, settings naming doctrine, keychain key). Audit doc annotated
  per-finding shipped/deferred.

## What's working / what's broken

- swift test green after every phase: 1506 tests, 0 failures (2 new port
  tests added).
- machines.json migration is automatic: legacy networkMode key ignored on
  decode, old telnet Keychain entry copied forward on first use.
- NOT yet done: the manual pass (Phase 4 tail) -- needs a human on the
  GUI. Checklist: rebuild in Xcode (model + UI changed), one fixture VM
  (boot, xterm launch, DNS, File Transfer, Back Up), one real host (ipc
  or ss5: probe dot, DNS, File Transfer, telnet launch with progress
  window), spot-check menu vs Overview verb parity, eyeball the new
  Settings sections + captions.

## Behavior changes to notice while testing

- Guest ports refuse connections from other LAN machines now (loopback
  bind) -- expected, it's the F2 fix.
- First telnet launch per VM may prompt once if the legacy shared
  user@host Keychain entry doesn't match that VM (the per-machine key fix
  working as intended).
- External machines' menu: Helios Secret is gone; set it in Settings ->
  Connection.

## What's next

1. Todd's manual pass per the checklist above; fix anything it surfaces.
2. Back to X11 land: MCP bridge is the standing lead; image download per
   IMAGE_DOWNLOAD_PLAN.md behind it; CLIPBOARD/editres gaps in the
   feature matrix as the protocol-side alternative.

## Committed this session

- swift-x: 81719de (1a), 164066d (1b), 7aac433 (2), 6e80a27 (3), + the
  Phase 4 commit on top.
- SPARCplug, cx repos: no changes.

## Switching Macs

- Code + model changed: rebuild in Xcode on the other Mac before running
  the app (MacXServer.xcodeproj, not swift build).
- No VMs running, no image locks.
- No new memories written yet this session.
