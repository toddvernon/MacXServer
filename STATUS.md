# Status 2026-06-11

Public-repo cleanup pass. Removed the pre-GUI CLI capture workflow now that
MacXCapture's Record mode covers interactive proxy capture, and swept out a
few stray artifacts.

- Deleted `run-all.sh`, `run-capture.sh`, `run-server.sh`, and the
  `connection.example.json` template. Todd doesn't run the CLI proxy by hand
  anymore and Claude drives `macxcapture` subcommands / the binary directly,
  not these wrappers. CLI proxy mode still exists on the binary
  (`--listen`/`--forward`/`--output`); it's just no longer scripted.
- Deleted stray files: `state_of_apps` (7-byte scratch file containing
  "xeyes"), `xterm.xtap`, `xterm.xtap.json` (leftover capture droppings in the
  repo root; nothing referenced them).
- README capture section rewritten to point at the GUI Record mode;
  `.gitignore` comment for `connection.json` updated to match.
- Pulled `OPCODES_PUBLIC.yaml` + `scripts/check-opcode-coverage-drift.sh` from
  the other Mac (committed there 06-10) via fast-forward.
- Commit: `1d31ebf`. Branch is 1 ahead of origin, unpushed.

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
