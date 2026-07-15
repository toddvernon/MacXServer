# Status 2026-07-15

## Today so far: the Settings Connection section is retired (af5644a,
Todd's call). Its User row was redundant once the Overview became the
one place the active user changes -- and the declare-at-birth carve-out
was too: fresh VMs declare their first login via the FirstLogin window
(re-offered every boot while user-less), fresh external boxes via the
Change Login sheet (its gate already covers never-probed machines), so
Settings never needs to write machine.user. Host, the only other thing
Connection held, moved up into the Machine section (an external host's
address is identity anyway). Real hazard closed while in there:
Settings commits its whole draft, so a pane that sat open through an
Overview user switch would have written the OLD account's user+password
back; commit() now adopts the live user (and password, unless the
Telnet/SSH field actually edited it) -- same stale-draft pattern as
launchers/detected-OS. Predates today, but the field going invisible
made it worth closing now. DECISIONS 2026-07-14 got a next-day
addendum. Build clean, suite 1574 / 0 failures. NOT eyeballed in the
running app.

# Rolled from 2026-07-14 (evening, Mac Studio)

## Headline: the active user is now changeable everywhere, tiered by
what the box supports. Change… on the Overview opens the Users panel
when the agent answers (unchanged), or a new lightweight Change Login
sheet when it can't serve -- proven against the box's OWN login channel
before anything is adopted. The nuc (Linux, sshd-only) drove the second
half: ssh-transport machines prove with a BatchMode key check and no
password field at all.

**Tiered Change… + Change Login sheet** (fa88f42; DECISIONS 2026-07-14).
Agent answering = Users panel; external box the panel can't serve =
Change Login sheet (username + password, verified by a live telnet
login via TelnetLauncher probe mode); agent exists but can't serve (VM
stopped, wrong secret) = dead button with the reason in the tooltip.
Three real bugs fell out of the probe's tests: looksLikeShellPrompt
never matched bracket prompts on CRLF streams (Swift's "\r\n" is one
grapheme); a refused/unreachable telnet connect hung forever
(NWConnection .waiting unhandled); adoptMachineLogin left a stale
cleartext machine.password on user switch.

**ssh proof channel for the nuc** (9d9e1ea; DECISIONS same-day
addendum). The nuc firewall-DROPs the helios port and runs only sshd,
so proof now keys off machine.transport: ssh = SSHLauncher.loginProbe
(BatchMode, remote command `true`), telnet/helios = the telnet probe.
Gate widened to "the panel can't serve it" including unreachable;
unauthorized stays dead on purpose.

**Also that morning:** cleared the stale solaris26 + sunos414 image
locks (laptop's 07-13 unclean quit; verified no qemu on either Mac
first). Earlier same day (this Mac): Overview restructured into titled
sections (Active User / Target Machine, dcb0cbc) with the status line
leading with the machine name ("NetBSD Running").

## What's working / what's broken

- swift build clean; swift test 1574 / 0 failures (32 skipped).
- NOT eyeballed in the app yet (the standing GUI pass, grew again):
  Settings without Connection (Host under Machine), the Change Login
  sheet (telnet and ssh flavors), Overview titled sections,
  identity-first header, menu-bar reorg, download flow, first-run
  choreography.
- Ledgered residue (SHORTCUTS "Change Login proof channel"):
  helios-transport boxes prove over telnet; a DROP-firewalled box's dot
  still says "unreachable" while its ssh launchers work -- honest fix
  is a transport-port TCP check in the prober's aliveness verdict.

## What's next

1. **Todd's manual GUI pass** (carried, grew): the new Settings layout,
   Change Login on the nuc (ssh) and a real Sun with the agent stopped
   (telnet), Overview sections, identity-first header, menu-bar reorg,
   download flow via SPARCPLUG_CATALOG_URL, first-run.
2. CanonicalDotfiles DISPLAY decision (SHORTCUTS, carried).
3. Catalog data side: E1 baseline masters -> build-catalog.sh ->
   upload; root-password policy for published masters.
4. Cut v0.9.9 (A5/A6 release pipeline proof).
5. UserAdmin live test against Solaris 2.6 + 4.1.4; retire orphaned
   DefaultLaunchers.swift. Maybe the prober transport-port aliveness
   check (gives the nuc an honest dot).

## Committed / push state

- X repo: af5644a (Connection section retired) + this roll on main,
  NOT pushed yet (push at /eos as usual). Everything through 6fbe19f
  (the 07-14 evening arc) is on origin/main.
- SPARCplug / cx repos: no changes this session.

## Switching Macs

- Swift sources changed: pull, then rebuild in Xcode.
- No VMs running on this Mac; no image locks outstanding.
