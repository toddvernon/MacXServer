# Gatekeeper first-launch investigation

Status: **OPEN but likely benign**, blocked on one check from the reporter.
Opened 2026-06-11. The exact dialog he hit (see "Exact dialog") turns out to
be the standard macOS Sequoia/26 quarantine block, which a correctly
notarized app also shows, so the leading explanation is now "expected
first-launch gate, he just has not done the System Settings > Open Anyway
step." Do NOT touch the binary or the signing pipeline: our published
artifacts are proven healthy (see "What's verified good"), so any real fault
is on the download/transfer or the reporter's machine, not the build.

## The report

A friend tried to launch **MacXServer v0.9.0** and got the macOS "could not
verify ... is free of malware" style block. Key facts, captured before he
touched anything:

- He reproduces the block on **two of his Macs: one on macOS 26, one on
  macOS 25.** (Exact point versions still unconfirmed. An earlier mention
  in conversation said "27", so the numbers need pinning down with
  `sw_vers` on each machine before we trust them. The only thing certain is
  it's recent macOS, well past the Sequoia 15 Gatekeeper-UX change.)
- He believes he has the correct binary, but that has NOT been verified on
  his machine yet (right file is not the same as intact signature after his
  unzip/transfer).
- He reports **no "Open Anyway" button**, but see the dialog analysis below:
  that button is never in this dialog, it lives in System Settings, and it is
  not yet confirmed whether he actually checked there.
- **He deliberately did nothing else.** No `xattr`, no re-download, no
  right-click-Open, no moving the app. The download is sitting in its
  as-received state on purpose, to preserve the scene for diagnosis. Keep it
  that way until we've captured the commands below against it.

## Exact dialog (captured 2026-06-11)

Screenshot: `gatekeeper-dialog-2026-06-11.png`. Verbatim:

> **"MacXServer" Not Opened**
>
> Apple could not verify "MacXServer" is free of malware that may harm your
> Mac or compromise your privacy.
>
> [ Move to Trash ]   [ Done ]

What this tells us, and it changes the read:

- This is the **standard macOS Sequoia (15) / macOS 26 quarantine block** for
  any app downloaded from the internet that has not yet been user-approved.
  Apple's wording is deliberately alarming and does NOT distinguish a
  properly notarized app from a non-notarized one; a correctly
  notarized + stapled app, freshly downloaded, shows this exact dialog on
  first launch on these OS versions. So the dialog by itself is NOT evidence
  of a bad binary.
- It is **not** the "...is damaged and can't be opened" dialog, which would
  point at a broken signature. So the damaged-bundle hypothesis is weaker
  than it was, though not yet ruled out (a verify on his copy still settles
  it).
- Crucially, **"Open Anyway" was never going to be in this dialog.** Since
  Sequoia, Apple removed the in-dialog / Control-click bypass. The only two
  buttons here are "Move to Trash" and "Done", by design. The override now
  lives in **System Settings > Privacy & Security**, and it appears there
  only AFTER you click "Done" on this dialog and the OS logs the blocked
  app. So "he doesn't get the Open Anyway button" is ambiguous: it may simply
  mean he stopped at this dialog (consistent with preserving the scene) and
  never opened Settings.

Revised most-likely read: this is probably the **expected first-launch gate**
and the resolution is the Settings > Privacy & Security > Open Anyway step he
has not taken yet. The one thing that would make it a real problem is if he
clicks Done, goes to System Settings > Privacy & Security, and the Open
Anyway button genuinely is NOT there. That specific check is now the pivotal
open question (see below).

## What's verified good (don't re-litigate the pipeline)

On 2026-06-11 we downloaded the live published v0.9.0 zips from the GitHub
releases and confirmed on a known-good Mac:

- `spctl -a -vvv` -> "accepted, source=Notarized Developer ID"
- `stapler validate` -> passes

So the published bytes are genuinely signed, notarized, and stapled, and the
release pipeline is healthy. Whatever the friend is hitting is downstream of
that.

## The pivotal question: is Open Anyway in Settings or not?

Given the dialog is the standard quarantine block, the whole investigation
now hinges on one check he has not done yet: **click "Done", open System
Settings > Privacy & Security, scroll to the bottom of the Security section,
and look for a "MacXServer was blocked..." line with an "Open Anyway"
button.**

- **Button is there** -> this was the expected gate all along. Click Open
  Anyway, authenticate, relaunch, confirm. Nothing wrong with the app or the
  pipeline; the friction is just Sequoia/26 being aggressive. Done.
- **Button is genuinely NOT there** (after the launch attempt logged it) ->
  now it is real, and it points at one of:
  1. **Damaged / broken-signature copy.** His unzip tool or transfer method
     stripped extended attributes / resource forks and invalidated the
     signature. Our server copy validates clean; his on-disk copy may not. A
     `codesign --verify` on his copy settles this.
  2. **Managed Mac or non-admin account.** An MDM / configuration profile
     (work or school laptop) can suppress the Open Anyway override entirely,
     and a standard non-admin user cannot complete it. If either Mac is
     company-managed, that alone explains a missing button.

## Test procedure (for Todd, when a test machine is available)

This is the exact thing to run. It is in two stages: Stage 1 confirms or
kills the leading "it's just the expected gate" theory; Stage 2 only runs if
Stage 1 says the override is genuinely missing.

**Make the test valid first:**

- Use a Mac that has **never approved or run MacXServer** before (otherwise
  Gatekeeper won't prompt at all). A fresh machine, or a fresh user account,
  works. Ideally on macOS 26 or 27 to match the reporter.
- **Download the published v0.9.0 zip fresh, via a browser** from the live
  macxserver.com download button (or the GitHub release). Do NOT use a copy
  you built locally or copied over with scp/AirDrop, those may not carry the
  quarantine bit and would make the gate not fire, defeating the test.
- Unzip by double-clicking in Finder (default Archive Utility).

**Stage 1, the pivotal check:**

1. Double-click `MacXServer.app`. Expect the dialog in the screenshot
   ("...could not verify ... is free of malware", Move to Trash / Done).
2. Click **Done** (NOT Move to Trash).
3. Open **System Settings > Privacy & Security**, scroll to the bottom of the
   Security section.
4. Look for a line like "MacXServer was blocked to protect your Mac" with an
   **Open Anyway** button.
   - **Button present:** click it, authenticate, double-click the app again,
     click **Open** on the final confirm. If it launches, the test is done
     and the verdict is: **expected first-launch gate, app + pipeline are
     fine.** This is almost certainly the answer for the reporter too, he
     just needs steps 2-4. Record the result here and close the item.
   - **Button genuinely absent** (after the step-1 launch attempt logged it):
     go to Stage 2.

**Stage 2, only if Open Anyway is truly missing:**

Run against the actual downloaded app and record the output in this doc:

```sh
APP="/path/to/MacXServer.app"
sw_vers                                          # exact macOS version
codesign --verify --deep --strict -vvv "$APP"    # does the copy still validate?
spctl -a -vvv -t exec "$APP"                      # Gatekeeper's verdict
xattr -l "$APP"                                   # quarantined? odd attrs?
```

Also note: is this Mac company/school **managed** (MDM), and is the account
an **admin**? Then the decisive test:

```sh
xattr -dr com.apple.quarantine "$APP"
```

Launch again. **Runs** -> it was the quarantine gate / a suppressed override
(managed or non-admin), bytes are fine. **Still won't run** -> the copy's
signature is broken (download/unzip damage), re-download clean or ship a pkg.

## Data to collect from the reporter (do this before any workaround)

Send back, for each affected Mac:

- **First and most important:** after clicking "Done" on the dialog, does
  System Settings > Privacy & Security show an "Open Anyway" button for
  MacXServer? (This is the pivotal check above; it likely resolves the whole
  thing.)
- `sw_vers` (pins the real macOS version).
- Whether the Mac is **company/school managed** and whether his account is
  an **admin** (decides hypothesis 2).
- Output of these against his actual, untouched copy:

  ```sh
  APP="/path/to/MacXServer.app"
  codesign --verify --deep --strict -vvv "$APP"   # does HIS copy still validate?
  spctl -a -vvv -t exec "$APP"                     # what does Gatekeeper say?
  xattr -l "$APP"                                  # quarantined? any odd attrs?
  ```

## The decisive test

After the data above is captured (scene preserved first), the single most
informative move is to strip quarantine and launch:

```sh
xattr -dr com.apple.quarantine "/path/to/MacXServer.app"
```

- **Runs after that** -> the bytes are perfect; it was purely the quarantine
  gate plus his machine not offering the override (managed policy, non-admin,
  or UX he could not find). Nothing wrong with the app.
- **Still won't run** -> his copy's signature is genuinely broken. The real
  bytes are good, so a clean re-download with the default Archive Utility, or
  shipping a different artifact (below), fixes it.

## Candidate fixes (choose after the test result)

- Clean re-download extracted with macOS's default Archive Utility (not a
  third-party unzip), if it was a damaged-bundle case.
- **Ship a notarized `.pkg` installer.** Apps placed by a signed + notarized
  pkg installer are NOT quarantined, so they launch with no first-launch gate
  at all. Needs a Developer ID *Installer* cert (separate from the
  Application cert we already have). This is the conventional way to remove
  the friction entirely if we decide the gate is too rough on non-technical
  users.
- A notarized DMG is tidier than a raw zip but still carries quarantine, so
  it does NOT remove the gate; it only makes the download cleaner.

The drag-from-zip path we ship today is a fully supported distribution
method and works on macOS 25/26/27; the question here is specifically why
this reporter's copy or machine is not taking the normal override, not
whether the approach is valid.
