# Status 2026-06-12

Feature day: SSH launcher, macxserver.com page documenting it,
**MacXServer v0.9.2 shipped** (signed/notarized/stapled, on the website),
and the Gatekeeper browser-dependence investigation docs from yesterday's
research finally committed to the tree. The Launchers menu now supports
modern Linux/BSD/Solaris boxes alongside the telnet path for vintage Sun
workstations: new `transport = ssh` key on the host block, spawns
`/usr/bin/ssh` with `BatchMode=yes` (keys-only, no password injection),
direct-DISPLAY back to our server on 6000 (no `-X` X11 forwarding).
Decisions and trade-offs logged in DECISIONS.md (2026-06-12 entry).
Website launcher feature page updated and deployed twice — once for the
SSH framing, once for the bold "keys only" call-out.

**Working tree clean. Both repos pushed.** Tests green
(21 launcher + full suite). Live downloads on macxserver.com pull v0.9.2.

Yesterday's launch-day notes — public-release flip, v0.9.0 shipping, and
the four bug fixes (Gatekeeper docs, xterm menu drift, dtfile transparent
icons, orphaned xterm menu) — moved to the body below for the record.

## Release: MacXServer v0.9.2 (today)

- Tag: `MacXServer-v0.9.2`. GitHub release at
  `releases/tag/MacXServer-v0.9.2`. Hugo `appVersion` bumped to 0.9.2;
  website download button verified live and pointing at the new artifact.
- Built, signed (Developer ID Application), notarized (notarytool
  --wait), stapled, and republished via `./release.sh MacXServer 0.9.2`.
  Validated end-to-end against the live download: `spctl -a` accepts
  "Notarized Developer ID"; `xcrun stapler validate` passes.
- MacXCapture untouched this session — still at v0.9.1; no rebuild
  needed.
- Gotcha worth not unlearning: the test-download hint that release.sh
  prints at the end deliberately uses `unzip` (which strips the
  codesign-friendly metadata `ditto` packed in, so `spctl` fails on the
  result). That false alarm was the only thing that prompted validating
  the 0.9.2 publish from the right tool (`ditto -x -k`) and confirming
  the actual artifact is healthy. Comment in release.sh now documents
  the trap so it stays a canary, not a bug.

## What's next / open

- No new open bugs from today. SSH launcher works on Todd's nuc; xterm
  font sized via `-fn 10x20` in the launcher entry.
- macXcapture still at v0.9.1. If a capture-side feature lands, cut
  v0.9.2 there too; otherwise no need.
- The Gatekeeper investigation has a probe script ready to run on a
  fresh Mac. Live status remains "pipeline healthy, dialog is the
  standard Sequoia first-launch path"; no action item until the next
  in-the-wild report.

## SSH launcher (today)

- New transport `transport = ssh` on the launcher-file host block. Default
  remains `telnet` so every existing `~/.macxserver-launchers` keeps
  working byte-for-byte. Default port shifts to 22 when transport is ssh.
- New `SSHLauncher` in `Sources/SwiftXServerCore/`. Spawns
  `/usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15 -p PORT user@host '…remote command…'`. Stdout +
  stderr stream into the existing progress window.
- Remote command shape is identical to the telnet path: `/bin/sh -c
  'DISPLAY=…; export DISPLAY; nohup CMD </dev/null >/dev/null 2>&1 &'`.
  The `/bin/sh -c` wrap is mandatory — accounts whose login shell is
  csh/tcsh (caught while setting up Todd's nuc: `2: Command not found.`
  was csh choking on `2>&1`) reject Bourne syntax outright. X traffic
  goes direct to our server on 6000; we do NOT use ssh's `-X`/`-Y` X11
  forwarding (no remote-sshd config required, no xauth cookie on our side).
- Auth is keys-only. `BatchMode=yes` makes ssh fail fast instead of hanging
  if keys aren't set up. AppDelegate's ssh dispatch skips the password
  prompt and Keychain entirely. A `password = …` field on an ssh entry is
  parsed but ignored, with a load-time warning emitted via the log sink.
- New `RemoteLauncher` protocol so `AppDelegate.activeLauncher` can hold
  either type. TelnetLauncher and SSHLauncher both conform.
- Tests: `LauncherFileTests` gained `testTransportParsing`,
  `testTransportItemOverride`, `testSSHWithPasswordWarns`.
  `SSHLauncherTests` pins the exact argv shape and the auth-failure-text
  detector. All 21 launcher tests green, build clean.
- Seed comment in `DefaultLaunchers.swift` documents `transport`, the
  per-transport default port, and the keys-only constraint. Existing
  installed launcher files are not migrated automatically (the seed only
  writes on first run when the file is missing); the format is
  forward-compatible so this is a no-op for current users.
- macxserver.com launcher feature page shipped same day: "Two transports"
  paragraph documenting both telnet and ssh, a `[host:nuc]` config example
  with the `-fn 10x20` font tip that came out of debugging Todd's NUC,
  bold "Password auth isn't supported on the SSH path. Keys only." line
  to make the keys-only constraint unmissable. Comparison-table row in
  `why-macxserver-instead-of-xquartz.md` rewritten from "Sun" to
  "Sun/Linux". Two deploys via `deploy.sh` (rsync to linode); production
  verified live both times. Homepage framing ("modern attaches to the
  Swift foundation, not to what the server runs") deliberately left
  untouched — feature page describes capability, homepage holds the line
  on positioning.

## Gatekeeper browser-dependence docs (today, work from 2026-06-11)

Three artifacts from the June 11 investigation finally tracked in git
(they'd been sitting untracked in the working tree). Continues the
Gatekeeper thread from commits `4fbeeea` / `9b5d45e` / `8b47cd1`:

- `GATEKEEPER_BROWSER_INVESTIGATION.md` — the dossier, written for a
  fresh-eyes analyst with no project context and no preferred answer.
  Documents the reproducible Safari-vs-Chrome difference on first launch,
  what we've verified is healthy (signing, notarization, stapling),
  competing explanations, and what we'd still want to confirm.
- `GATEKEEPER_BROWSER_FINDINGS.md` — that analyst's report back, plus
  Todd's reader's-note that the analyst's "Safari working is luck"
  framing oversteps the empirical observation (the same mechanism the
  analyst proposed — translocation + `LSQuarantineType` + Sequoia
  launch-responsibility — *predicts* the reproducible asymmetry, so the
  difference is real even though the folk-LLM allowlist story isn't).
- `scripts/gatekeeper-probe.sh` — diagnostic script that captures
  quarantine xattr / spctl / stapler / translocation state side by side
  for the two browser download paths, ready to run on a fresh Mac when
  one's available.

Live status of the original report is unchanged from yesterday: pipeline
is healthy, dialog is the standard Sequoia first-launch path,
download-page docs already updated.

## 2026-06-11 — Launch day + four bug fixes (preserved for the record)

## Release / launch

- Repo `toddvernon/MacXServer` is public. **MacXServer v0.9.0** and
  **MacXCapture v0.9.0** are shipped as GitHub releases, signed +
  notarized + stapled (verified the live download zips: `spctl` →
  "accepted, Notarized Developer ID"; `stapler validate` passes). Both
  Hugo sites' download buttons point at the v0.9.0 artifacts.
- Earlier today's cleanup pass (commit `1d31ebf`): dropped the pre-GUI CLI
  capture wrappers (`run-*.sh`, `connection.example.json`) and stray repo
  droppings; README capture section now points at the GUI Record mode.

## Gatekeeper "could not verify" report (resolved — was not a bug)

A friend got the macOS "Apple could not verify MacXServer is free of
malware" dialog. Downloaded the exact live zips and proved our artifacts
ARE notarized + stapled + Gatekeeper-accepted, so the pipeline is healthy.
The dialog is the quarantined-first-launch path (stale copy or a transient
online check). Added a **"First launch on macOS"** section to both
download pages explaining the System Settings → Privacy & Security →
"Open Anyway" step, and softened the over-promising "first launch is
clean" line. Deployed to macxserver.com + macxcapture.com, verified live.
Still waiting on the friend's macOS version + `spctl`/`stapler` output to
confirm it was a stale copy vs a transient check.

## Bug fix 1 — xterm menu drift (commit `f3bfcdf`)

Ctrl-click menus drifted off the window the further it was dragged toward
the screen's right/bottom. Root cause: the advertised X root (1280×900 on
the 5K) was smaller than the area windows can be dragged into; a window
dragged past the advertised width reported an X-root x the client clamped
its popup against. Fix: `DisplayConfig.pick()` now uses the preset table
only to gate the integer scale, then derives the logical root as
`floor(native ÷ scale)` so the X screen covers the whole panel. Scale
chosen per display is unchanged (font sizing unaffected). Touched the
preset contract in SERVER_RESOLUTION_SCALING_AND_FONTS.md (Todd approved);
DECISIONS.md entry added. Tests updated + `testLogicalRootSpansWholeDisplay`.

## Bug fix 2 — dtfile transparent icons (commit `ceef64e`)

Folder/document icons drew with a gray box and a white strip (the
transparent regions weren't clipped). Wire-confirmed from an in-process-tee
capture: dtfile sets a depth-1 `clip_mask` pixmap on the GC + clip origin
per icon, then CopyArea. We honored the clip-rectangle list but dropped the
pixmap clip_mask entirely. Fix: thread clip_mask + origin from GCState →
handleCopyArea → bridge; read the mask via the existing `StippleBitGrid`,
convert opaque bits to horizontal run-rects at the clip origin, clip the
blit to them (rect-clip, not a CG image-mask, to dodge the y-flip hazard).
Two asymmetric orientation/polarity tests added per GRAPHICS_Y_FLIP.md.
Verified visually on real dtfile. OPCODE_STATUS/SHORTCUTS/OPCODES_PUBLIC
updated.

## Bug fix 3 — orphaned xterm menu (commit `bfdadde`)

A Ctrl+button xterm popup menu could be left stranded on screen as a black
window. Root cause was the mouse-up, not the Ctrl key (Todd's hunch about
Ctrl was a red herring): xterm grabs the pointer when it posts the menu and
dismisses on ButtonRelease outside a menu item, so the dismiss depends on
getting that release. Our cross-NSWindow drag monitor
(`dispatchCrossWindowDrag`) dropped any event whose cursor was over no
managed window — fine for motion, fatal for the release. So a release over
empty desktop never reached xterm and the menu hung around. Fix: route the
off-window release to the grab anchor instead of dropping it. New
`dragAnchorWindowId` remembers the last top-level the pointer was over
during the grab (survives going off-window, unlike `dragLastWindowId` which
nils for enter/exit bookkeeping); the release is reported relative to it
with out-of-bounds coords, which is how real X reports a release outside the
event window. The session's grab redirect re-targets to the actual grab
window. Verified live (drag menu onto desktop, release → dismisses).

Belt-and-suspenders in the same commit: **"Drop All Clients" is now a true
nuke.** After cancelling the sessions it calls
`CocoaWindowBridge.closeAllWindows()`, which closes and forgets every
managed NSWindow regardless of hierarchy or session ownership, and clears
any lingering grab tracking / native-drag lock. `cleanupOnDisconnect` only
reaps windows still linked to a session's window table, so an orphan whose
slot drifted from the table could survive it; this guarantees the screen is
clear. Wired via a weak bridge ref on the AppDelegate. AppKit-side code, so
not exercised by the mock-bridge unit suite.

## Housekeeping

- Reconciled GetInputFocus/QueryKeymap public coverage (synthetic-reply
  wording) so `check-opcode-coverage-drift.sh` is clean (commit `2af23c8`,
  site deployed).
- Two diagnostic improvements are now permanent in the capture dumper and
  earned their keep today: `root=(x,y)` printed on pointer events, and
  `clipMask`/`clipXOrigin`/`clipYOrigin` decoded on GC ops.

## What's working

- 1265 tests green. Both apps build + ship signed/notarized. Live xterm,
  dtfile icons now correct, menus track their windows across the display and
  no longer orphan when dismissed off-window.

## What's next / open

1. **Friend's Gatekeeper report** (now its own doc:
   `GATEKEEPER_FIRST_LAUNCH.md`): he sent the actual dialog screenshot, and
   it's the **standard Sequoia/26 quarantine block** ("Apple could not verify
   ... is free of malware", Move to Trash / Done), which a correctly
   notarized app also shows. That de-escalates it: "Open Anyway" is never in
   that dialog (it moved to System Settings > Privacy & Security since
   Sequoia), so his "no Open Anyway" likely just means he stopped at the
   dialog and never opened Settings. Pivotal open question: after clicking
   Done, does Settings > Privacy & Security show an Open Anyway button? If
   yes, it's the expected gate (done). If genuinely absent, fall back to
   damaged-copy (unzip stripped xattrs) or managed/non-admin Mac. Repro'd on
   two Macs (macOS 26 + 25, exact versions TBC via `sw_vers`); scene
   preserved. Pipeline verified good, no build change expected.
2. **Latent server gaps** (carryover, untouched): pixmap clip_mask is
   honored for CopyArea only, not other output ops (no client needs it yet);
   native-title-bar drag-lock gap on Motif-Frame-OFF windows; same-window
   memmove CopyArea still ignores the rect-list clip. The orphan-xterm-menu
   carryover (was on the 06-10 list) is now closed — see Bug fix 3.
3. Key-material housekeeping (from 06-10): move `Certificates.p12` out of
   plain Dropbox to 1Password if desired.
4. No other known bugs as of end of day (Todd: "that's all the bugs I know
   of right now").

# Status 2026-06-10

Two big threads today: finished the code-signing + notarization setup (both
Macs can now ship signed + notarized releases), and a long website-polish pass
across both Hugo sites. Also nailed down the launcher-file format, fixed its
docs, and ran a clean-room audit of the public repo.

## Signing + notarization: DONE on both Macs

- **Developer ID Application cert** issued and installed:
  `Developer ID Application: CarePenguin, inc (X478U667PR)`. Signed under the
  CarePenguin team because the personal "Todd Vernon" team (NXNG297DL6) was
  inaccessible (the covey@ Apple ID login was blocked on the developer
  portal). The team string only shows via `codesign -dvv` / `spctl`, never in
  a Gatekeeper dialog, so it's cosmetic. `release.sh` is hardcoded to
  `TEAM_ID=X478U667PR`.
- **notarytool keychain profile `notary`** created and validated against Apple
  on both Macs.
- **Smoke test passed**: `./release.sh MacXCapture 0.0.1` ran the full loop
  (archive → sign → notarize Accepted → staple → zip → GitHub release → Hugo
  deploy). The throwaway 0.0.1 release + tag were deleted afterward.
- **Laptop provisioned over SSH**: imported the cert via `.p12`, then had to
  run `security set-key-partition-list` (imported keys fail codesign with
  `errSecInternalComponent` in a non-GUI session without it). Documented in
  NOTARIZE-SETUP.md. Verified with a real codesign of a throwaway binary.
- Private cheat-sheet at `RELEASING.local.md` (gitignored, synced via Dropbox,
  symlinked into both working trees) holds the team ID, notary Key ID /
  Issuer ID, troubleshooting, and the new-Mac setup steps.

## In-repo (~/dev/X) commits today

- Retarget `release.sh` to the CarePenguin team; neutralize the team comment
  (dropped the covey@ backstory from the public file).
- `NOTARIZE-SETUP.md`: document `set-key-partition-list` for SSH/headless
  imports; genericize the identity examples for the public repo; fix the
  smoke-test version example (the script requires strict X.Y.Z semver).
- `USING_CLAUDE.md`: human-facing companion to CLAUDE.md (how to drive Claude
  Code on this project, the required-reading map, the ground rules, PR flow).
  Linked from README and CONTRIBUTING.
- `.gitignore`: add `RELEASING.local.md`.

## Clean-room audit (pre-public-release check)

Fresh `git clone` into /tmp, judged only the clone. Result: clean.
- No secrets/keys/certs in tree or history; notary Key ID / Issuer ID in zero
  commits; private files (`CLAUDE.local.md`, `RELEASING.local.md`,
  `connection.json`, `.claude-memory`) correctly absent from the clone.
- Builds from scratch following the repo's own docs: `swift build -c release`
  (~33s), `swift test` (1262 tests, 0 failures), `xcodebuild -scheme
  MacXServer` (BUILD SUCCEEDED).
- Onboarding docs strong (README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY,
  LICENSE, CLAUDE.md, USING_CLAUDE.md); no dangling references to private
  files. Verdict: publish-ready.

## Websites (both Hugo sites, tracked in their own repos)

All committed to MacXServerSite / MacXCaptureSite and deployed live.
- Prose wrapped to 80 cols across macxserver-hugo; homepage intro tightened.
- Launcher feature page rewritten to the real two-level format
  (`[host:KEY]` / `[KEY/ITEM]`); the old example used a fake `keychain` key
  and an unsupported multi-app-per-section shape. New config-editor screenshot.
- macxcapture About page: added the Todd photo + full-width content to match
  macxserver.
- macxserver: About moved to the last nav item; quickplot GitHub link removed
  (can't distribute that app); deep-dives intro made full width;
  title/tagline spacing bumped.
- **Mobile hamburger menu** on both sites (oldsilicon desktop-first pattern):
  the horizontal nav ran off-screen below 769px; now it collapses to a
  tappable dropdown, with the normal horizontal nav restored on desktop.
- CSS confirmed consistent between the two sites (intentional accent-color and
  per-site differences only; no real drift).

## Launcher file format (resolved)

- Real format confirmed in `LauncherFile.swift`: two accepted shapes
  (`[host:KEY]` + `[KEY/ITEM]` two-level, or legacy flat `[label ...]`). Nine
  keys: host, user, command, port, verbose, login_prompt, password_prompt,
  shell_prompt, password. No `keychain` key (Keychain is automatic via the
  `user@host` account; omit `password` to use it, or set it inline as
  plaintext).
- The shipped seed (`DefaultLaunchers.swift`) already documents the two-level
  format correctly. Todd's installed `~/.macxserver-launchers` was from an
  older seed (flat, missing `password`); migrated it to two-level (backup at
  `~/.macxserver-launchers.bak`).

## What's next

1. **Flip the GitHub repo public** (`toddvernon/MacXServer`) in Settings — the
   one remaining manual step. The clean-room audit says it's ready.
2. **Cut the first real release(s)** at launch: `./release.sh MacXServer
   X.Y.Z` and `./release.sh MacXCapture X.Y.Z`. Until then both sites'
   download buttons point at `...-v0.0.0...` and 404 (placeholder appVersion;
   `release.sh` bumps it on a real run).
3. Key-material housekeeping: the notary `.p8` Downloads copy was deleted; a
   password-protected cert backup remains at
   `~/Dropbox/dev/X/Certificates.p12`. Move it to 1Password if you'd rather it
   not sit in Dropbox.
4. Carryover server work (untouched today): re-test the orphan xterm
   right-click menu (should be covered by the Motif grab fix); decide on the
   native-title-bar drag-lock gap on Motif-Frame-OFF windows.
