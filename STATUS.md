# Status 2026-07-14

## Today: Overview page restructured into titled sections (Todd's call).
The identity row and the machine state block now sit under proper
MachineSectionHeader titles like the Launchers/Admin Agents sections
always had: **Active User** (user field + Change... button inset under
it, inline "Active user" label dropped since the header carries it) and
**Target Machine** (status line + boot thermometer + lifecycle buttons,
all inset 16pt). The status line under Target Machine now leads with
the machine name so it reads as a sentence: "NetBSD Running", "ipc
Reachable". Pure view-layer change in MachinesWindowView.swift, no
model changes. swift build clean. NOT yet eyeballed in the running app
(joins the standing GUI pass, along with yesterday's identity-first
header).

# Rolled from 2026-07-13

## Identity-first Overview shipped (ba94530): detail header reads
"ipc (tvernon)", Active user row leads the page, Change... opens the
Users panel (the one switching mechanism, password proof intact).
Hostname stays editable in Settings. Suite was 1570 green.
Release-readiness picture: remaining v1 items are E1+catalog
(root-password policy is the open decision), cut v0.9.9, A6 clean-Mac
acceptance, Restore-from-Backup UI, and the standing GUI pass.

# Rolled from 2026-07-12 (fleet ops day, condensed)

Color xterm deployed fleet-wide (ipc/ipx/ss1/ss5, distro kept as
xterm.orig). ss5 DISPLAY residue cleaned; CanonicalDotfiles hardcoding
the slirp DISPLAY for external hosts is a SHORTCUTS entry needing a
decision. The 4.1.4 date-year trap is closed: Y2K date patches
(105143-03 + 106182-02) staged in Dropbox
(SPARCplug/patches/sunos414-y2k/), deployed to the VM + all six real
4.1.4 boxes, reboot-proven on the VM and real ipx. Every fleet clock
synced. Clock admin agent shipped (dd66491) with Y2K-probe-gated Force
Set; field-tested by Todd, both clocks tick in lockstep (0d3a2e7),
card reads "Sync Clock" (028dbd5). DECISIONS 2026-07-12.

## What's working / what's broken

- swift build clean today; suite was 1570 green as of 07-13 (today's
  change is view-only, no model surface touched).
- Clock panel field-verified working. The Force Set warning path still
  hasn't been seen live (every box in the fleet is patched now).
- NOT eyeballed yet: today's Overview sections, yesterday's
  identity-first header, menu-bar reorg, download flow, first-run
  choreography (the standing manual GUI pass).
- ss5 heliosAgent env still carries harmless residue (REMOTEHOST, PWD
  from an old telnet session); clears on next boot.

## What's next

1. **Todd's manual GUI pass** (carried, grew today): Overview sections
   (Active User / Target Machine + named status line), identity-first
   header, menu-bar reorg, download flow (SPARCPLUG_CATALOG_URL),
   first-run choreography.
2. **CanonicalDotfiles DISPLAY decision** (SHORTCUTS): strip or
   substitute the slirp DISPLAY when add-user targets an external host.
3. Catalog data side: E1 baseline masters -> build-catalog.sh -> upload;
   root-password policy for published masters. (The sunos414 master
   carries the Y2K date patches + xterm.orig convention.)
4. Cut v0.9.9 (A5/A6 release pipeline proof).
5. UserAdmin live test against Solaris 2.6 + 4.1.4; retire orphaned
   DefaultLaunchers.swift.

## Committed / push state

- X repo: everything pushed to origin/main at /eos today, including the
  two-day arc that had been sitting local (dd66491 clock admin agent
  through ba94530 identity-first Overview) plus today's Overview
  sections commit and this roll.
- SPARCplug / cx repos: no changes, in sync.

## Switching Macs

- Swift sources changed: pull, then rebuild in Xcode.
- No VMs running on this Mac right now, but all three image lock files
  (solaris26, netbsd, sunos414) are still present under
  ~/Dropbox/dev/SPARCplug/images/ from the 07-13 session ending without
  a clean quit. If the other Mac sees remoteLocked, that's why. Also
  means the sunos414 image's patched state (date + date.FCS, xterm.orig)
  hasn't had its post-quit backup yet.
- Y2K patch tarballs ride Dropbox (SPARCplug/patches/sunos414-y2k/).
