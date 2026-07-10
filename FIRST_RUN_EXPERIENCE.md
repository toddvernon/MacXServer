# First-run experience -- the stranger's first five minutes

Status: **designed 2026-07-10 (Todd's UX, this session), not built.**
Depends on HELIOS_USER_MANAGEMENT.md (the add-user engine) and the curated
image downloader (shipped 2026-07-10). This is the choreography layer over
both.

## The settled shape (Todd, 2026-07-10)

In-window guided flow, not a separate wizard. The Machines window looks
exactly as it does today; a first-run prompt overlays the detail area and
walks the user through download -> login -> running SPARCstation, using
the window's real controls so the flow teaches the UI it leaves behind.

1. **The bubble.** On a fresh install the Machines window shows as normal,
   with a text-bubble prompt overlaying the VM/detail area:

   > Just getting started? Download a starter image and launch a
   > SPARCstation.

   The Download Image... button renders **blue** (borderedProminent) while
   it's the next thing to do -- the eye lands on it. The bubble is
   state-derived, not a dismissed-once flag: it shows while NO emulated
   machine has a disk image and no download is in flight, and it
   disappears (forever, in practice) once an image lands. If the user
   deletes every image someday, it honestly comes back.

2. **Download.** Clicking Download runs the existing flow (confirm sheet
   with real sizes -> row thermometer with per-phase status). No new
   download UI.

3. **"One more thing."** When the install completes, a popup (sheet on the
   Machines window) says:

   > One more thing -- add a user to the machine.

   Username + password (+ the "vintage Unix reads only the first 8
   characters" note), username pre-filled from the Mac short name,
   lowercased, truncated to 8. **Enter adds the user and starts the VM.**

4. **Boot + apply.** Mechanically the login can't be created until the
   guest's helios daemon answers, so Enter: stores the pending credentials
   (hash computed immediately, host-side; the cleartext goes to the
   Keychain telnet slot and nowhere else), boots the machine, and applies
   the add-user pipeline the moment the controller reports ready. The boot
   bar carries it: the usual boot progress, then a "creating your
   login..." tail phase, then done -- launchers live, `machine.user` set.
   To the user it reads as "Enter made the machine come up with my login".

5. **The payoff.** Row is green, the seeded xterm launcher chip is
   enabled. The user clicks it and a vintage Sun xterm lands on their Mac
   desktop.

Failure handling: if the boot reaches ready but add-user fails, the VM
stays up and the sheet's error state offers retry (the pipeline is
retryable by design -- see the ordering section of
HELIOS_USER_MANAGEMENT.md); the Users panel is the manual fallback. If
the user dismisses the "one more thing" popup, the machine still has no
user; the empty-`machine.user` + ready condition re-offers it on the next
boot (the invitation-not-a-gate rule).

## What this flow requires

- The `UserAdmin` engine + Users panel (HELIOS_USER_MANAGEMENT.md --
  host-driven option ratified 2026-07-10).
- Deferred-apply plumbing: pending-login state on the machine flow
  (credentials held until ready fires, then the pipeline runs).
- The bubble overlay + blue-button state in MachinesWindowView, driven by
  the same registry state the rows read.
- Fixture seeding change: `machine.user = ""` on fresh installs (today's
  NSUserName() fallback writes a lie for anyone who isn't Todd).
- Published masters carry root + template + daemon only (tvernon stripped
  at publish prep).

## Adjacent first-launch items (not this flow, same milestone)

- **Gatekeeper walkthrough on the site.** GATEKEEPER_FIRST_LAUNCH.md is
  still open (a real tester hit the "malware" dialog on a notarized
  build). The download page needs the System Settings -> Open Anyway
  walkthrough before any announcement drives traffic.
- **Root password policy for published images** -- the one open decision
  (HELIOS_USER_MANAGEMENT.md decision 3): ship documented, rotate at
  publish, or fold a root-password-set into first run. Loopback-bound
  hostfwds (DECISIONS 2026-07-09) bound the exposure either way.
- **First-boot expectation setting.** A cold boot to ready takes a couple
  of minutes; the boot bar plus the console window cover it, but the
  "one more thing" sheet should say "the machine takes a few minutes to
  boot the first time" so the wait reads as normal.
