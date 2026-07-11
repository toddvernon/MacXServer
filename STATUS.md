# Status 2026-07-11

## Headline: the active-user model is settled and built. One active user
per machine (machine.user + telnet Keychain); launchers follow it until
switched; switching is a Users-panel action ("Set Active...") gated on
proving you know the account's password, verified host-side against the
guest's stored DES hash. The panel also now states that admin runs as
root over the admin connection. Suite green at 1544. Yesterday's big
manual-GUI-pass item still stands and has grown: the Set Active flow is
on the checklist too.

## What happened this session

**Active-user model designed + built** (commit 45498d5; DECISIONS
2026-07-11, HELIOS_USER_MANAGEMENT.md decision #5). The conversation
started from "the add-sheet checkbox is the only way to point launchers
at an account"; settled on one active user per machine, switchable on
the fly with password proof, and rejected per-launcher user fields
(Keychain/UI multiplication for a mostly-Todd problem; can return later
as an optional override) and ask-at-launch (kills one-click launchers).

- **Core:** `UserAdmin.verifyPassword` -- reads the hash-bearing file
  per OS (Solaris /etc/shadow, 4.1.4 /etc/passwd, NetBSD
  /etc/master.passwd) over Helios as root, re-crypts the entered
  password with the stored salt host-side, compares. Cleartext never on
  the wire; locked fields (`*`, `*LK*`, `NP`) never verify, so template
  can't be made active. Plus `hashFile(os:)`, `storedHash(in:name:)`,
  `passwordMatches`.
- **Panel:** "Set Active..." button (dimmed for template and the
  already-active account; root allowed on purpose) opens a password
  sheet; wrong password stays on the sheet with an inline error, right
  password adopts via the existing `adoptMachineLogin` (machine.user +
  telnet Keychain slot). Badge renamed "launchers" -> "active"; the
  add-sheet toggle is now "Make this the active user (launchers log in
  as it)"; the delete warning speaks the same language.
- **Root note:** panel header now says changes are made as root over the
  admin connection -- Todd's call that it's unorthodox we never make you
  select root for admin, so the UI states it instead of leaving it
  implicit.
- **Tests:** 6 new core tests (per-OS hash-file geometry, hash
  extraction prefix discipline, pinned crypt vector + DES 8-char
  truncation, locked-field refusals, per-OS verify round trips pinning
  exactly one file read, unknown-user error). Full suite 1544 / 0
  failures.

Also: xcodegen re-run this morning (no project.yml change today; the
.xcodeproj was regenerated on request after yesterday's pull).

## What's working / what's broken

- swift build clean; swift test **1544 tests, 0 failures**.
- NOT yet eyeballed in the real app: everything from yesterday's list
  (menu-bar reorg, download flow, Users panel, first-run choreography)
  PLUS today's Set Active flow. The NetBSD guest is running under the
  Xcode debug build; its tvernon account is a live target for trying the
  switch after an Xcode rebuild.
- The Download button still fails cleanly until the catalog is uploaded
  (by design; SPARCPLUG_CATALOG_URL=file://... to test).

## What's next

1. **Todd's manual GUI pass** (carried from 07-10, grown): menu-bar
   reorg, download flow (local catalog via SPARCPLUG_CATALOG_URL),
   Users panel, first-run choreography, and now Set Active (try right +
   wrong password against the running NetBSD guest).
2. Data side of the catalog: E1 baseline masters -> build-catalog.sh ->
   upload to macxserver.com/images/. Settle the root-password policy for
   published masters (the one open decision).
3. Cut v0.9.9 -- proves the A5/A6 release-pipeline work end-to-end.
4. UserAdmin live test against Solaris 2.6 + 4.1.4 (one env var each
   when those guests are booted).
5. Legacy cleanup (own decision): retire orphaned DefaultLaunchers.swift.

## Committed / push state

- X repo: 2 commits ahead of origin, NOT pushed: 541245c (yesterday's
  eos STATUS roll -- the eos push evidently didn't happen; flagged at
  sos, Todd hasn't called the push yet) and 45498d5 (active-user model).
  Plus this STATUS roll on top. Push at /eos or on request.
- SPARCplug: in sync with origin. cx repos: no changes.

## Switching Macs

- Swift sources changed: rebuild in Xcode on the other Mac after pulling.
- The NetBSD guest is STILL RUNNING under this Mac's Xcode debug build
  (lock held at images/netbsd/netbsd-boot.qcow2); shut it down before
  /eos if wrapping up.
