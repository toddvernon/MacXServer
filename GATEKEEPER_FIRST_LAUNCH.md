# Gatekeeper first-launch investigation

Status: **OPEN**, blocked on diagnostic data from the reporter. Opened
2026-06-11. Do NOT touch the binary or the signing pipeline until the data
below comes back: our published artifacts are already proven healthy (see
"What's verified good"), so any real fault is on the download/transfer or
the reporter's machine, not the build.

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
- **He does NOT get an "Open Anyway" button** in System Settings > Privacy &
  Security after the block. This is the most important detail. The normal
  notarized-app first-launch gate DOES offer that button; its absence means
  Gatekeeper is not offering a user override.
- **He deliberately did nothing else.** No `xattr`, no re-download, no
  right-click-Open, no moving the app. The download is sitting in its
  as-received state on purpose, to preserve the scene for diagnosis. Keep it
  that way until we've captured the commands below against it.

## What's verified good (don't re-litigate the pipeline)

On 2026-06-11 we downloaded the live published v0.9.0 zips from the GitHub
releases and confirmed on a known-good Mac:

- `spctl -a -vvv` -> "accepted, source=Notarized Developer ID"
- `stapler validate` -> passes

So the published bytes are genuinely signed, notarized, and stapled, and the
release pipeline is healthy. Whatever the friend is hitting is downstream of
that.

## Why "no Open Anyway button" matters

A missing override button (after a real launch attempt) is not the expected
one-time gate. It points at one of two situations:

1. **Damaged / broken-signature path.** If the dialog actually reads "...is
   damaged and can't be opened, move it to the Trash" rather than the
   developer-trust wording, the embedded signature is failing validation and
   macOS deliberately offers no override. Usual cause: the right file
   downloaded, but his unzip tool or transfer method stripped extended
   attributes / resource forks and invalidated the signature. Our server
   copy validates clean; his on-disk copy may not.
2. **Managed Mac or non-admin account.** An MDM / configuration profile
   (work or school laptop) can suppress the Open Anyway override entirely,
   and a standard non-admin user cannot complete it. If either Mac is
   company-managed, that alone explains the missing button.

## Data to collect from the reporter (do this before any workaround)

Send back, for each affected Mac:

- The **exact dialog wording, word for word** (developer-trust vs "damaged"
  decides hypothesis 1 vs not).
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
