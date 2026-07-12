# Status 2026-07-11 (night roll)

## Headline (late addition): add-user reworked to LEARN the box's
conventions -- Todd's ipc field test broke the template assumption
(real boxes have no /home/template), so the curated dotfiles moved
app-side and uid/gid/home-parent/shell are now derived from the box's
own passwd/group and previewed in the Add sheet before commit. Suite
1555 green. Earlier today: the active-user model (below).

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

**Set Active field-tested by Todd, one real bug found + fixed.** Adding
fred/kemosabe, launching an xterm as fred: worked first try. Switching
BACK to tvernon (same password): failed to verify. Root cause: tvernon
and root on the NetBSD image predate UserAdmin and carry **NetBSD
sha1crypt** hashes (`$sha1$rounds$salt$digest`, the installer's
passwd(1) default), and passwordMatches only spoke 13-char DES. Fix:
`UserAdmin.sha1Crypt` ported from NetBSD lib/libcrypt/crypt-sha1.c
(iterated HMAC-SHA1 via CommonCrypto, crypt64 output with the
byte-0-padded tail quirk), pinned against 3 vectors minted by the live
guest's own pwhash(1), and double-checked against tvernon's real hash.
Unknown modular-crypt formats ($1$, $2a$) now throw an honest
"can't check this hash format" instead of a false "wrong password".
Solaris/4.1.4 are DES-only, so this was NetBSD-specific. 3 more core
tests (suite 1547 / 0).

**Add-user rework: app-side templates + learned conventions** (evening;
DECISIONS 2026-07-11 second entry, HELIOS_USER_MANAGEMENT decision #6).
Todd added fred on ipc (real IPC): failed at `cp -r /home/template` --
real hardware never got the convergence staging. Clean pre-commit
failure (ordering design held), but the strategy was image-specific.
Rework, ratified by Todd:
- CanonicalDotfiles.swift: guest-config/dot.{cshrc,login,profile}
  embedded byte-exact (base64; the cshrc prompt block carries literal
  ESC/BEL). Homes are staged mkdir + write_file + chown; the guest
  template account is vestigial (strip from masters at E1).
- UserAdmin.planAddUser: derives uid / gid / home parent / shell from
  the box's passwd + group + a tcsh probe. Learned live against ipc:
  homes at /home2 (not /home), and its one countable human gid is 1
  (daemon -- sloppy old account), which drove the "system gids < 10
  never count" guard; ipc's plan resolves to uid 1001 / staff (10) /
  /home2/<user> / tcsh.
- Add sheet previews the plan ("Will create: uid ... group ... home
  ...") before commit; the previewed plan is the one that executes.
  Delete's rm-guard accepts the learned parents too.
- 8 new/reworked core tests; live test now round-trips the .cshrc
  bytes. xcodegen re-run for the new file.
- **Field-verified by Todd on ipc (real SunOS 4.1.4) same evening:**
  add-user works end-to-end on real hardware. The learned-conventions
  path is proven outside the images.

Also: xcodegen re-run this morning (no project.yml change today; the
.xcodeproj was regenerated on request after yesterday's pull).

## What's working / what's broken

- swift build clean; swift test **1555 tests, 0 failures**.
- Set Active fully verified in the real app by Todd against the running
  NetBSD guest: add fred -> xterm launches as fred, AND the switch back
  to tvernon works with the sha1crypt fix. Both hash formats proven in
  the field.
- Still NOT eyeballed in the real app: yesterday's list (menu-bar reorg,
  download flow, first-run choreography).
- The Download button still fails cleanly until the catalog is uploaded
  (by design; SPARCPLUG_CATALOG_URL=file://... to test).

## What's next

1. **Todd's manual GUI pass** (carried from 07-10): menu-bar reorg,
   download flow (local catalog via SPARCPLUG_CATALOG_URL), and first-run
   choreography. Users-panel items all DONE: add-user verified on real
   ipc 4.1.4, Set Active verified both directions on NetBSD.
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
