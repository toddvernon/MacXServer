# First-run experience -- the stranger's first five minutes

Status: **BUILT 2026-07-10.** The choreography over the curated image
downloader + the UserAdmin engine. Not yet eyeballed in the real app (it's
UI + AppDelegate orchestration; needs the Xcode rebuild + a local catalog
to click through) -- that's part of Todd's manual GUI pass.

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

## What this flow requires (all BUILT 2026-07-10 except the last)

- The `UserAdmin` engine + Users panel (HELIOS_USER_MANAGEMENT.md) -- DONE.
- Deferred-apply plumbing -- DONE. `pendingFirstLogin[id]` holds the
  credentials; `applyPendingFirstLogin` fires from the engine's `onReady`
  and runs the UserAdmin pipeline over the now-live daemon, then
  `adoptMachineLogin` sets `machine.user` + the telnet Keychain slot. The
  row shows "Creating your login..." (`applyingLogin`) while it runs; a
  failure keeps the guest up and points at the Users panel to retry.
- The bubble + blue-button state in MachinesWindowView -- DONE. Driven by
  `MachinesModel.isFirstRun` (an emulated VM exists but none has an image);
  the Overview shows the bubble over an imageless machine and renders
  Download Image blue while it's true.
- `FirstLoginWindowController` -- DONE. The "one more thing" panel
  (username prefilled from the Mac short name, password x2, the 8-char +
  "takes a couple of minutes to boot" notes, Add User & Start / Skip).
- Fixture seeding change: `machine.user = ""` -- DONE. `bundledFixtures()`
  seeds user-less; the `bundledUser` parameter (and its NSUserName/launcher
  derivation) was removed root-and-branch since fixtures no longer carry a
  user. (Side effect: a fresh install no longer writes the legacy
  all-comments `~/.macxserver-launchers` template; it was documentation
  only, zero live entries, so the fresh-install machine set is unchanged.)
- Published masters carry root + template + daemon only (tvernon stripped
  at publish prep) -- NOT DONE (publish-prep step, gated on E1).

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
