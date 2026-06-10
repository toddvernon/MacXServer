# Status 2026-06-10

Mostly off-repo work today (Claude Code multi-Mac sync, macxcapture.com
site shipped, contact forms wired on both sites, linode setup for the
new domain). On this repo specifically, one commit: the
`release.sh` + `NOTARIZE-SETUP.md` pair that wires up signed +
notarized macOS releases of both apps.

## What landed in this repo today

- `release.sh` at the project root — one script handling both apps
  (MacXServer and MacXCapture, which share this Xcode project). Run
  `./release.sh <App> <version>` and it does the full loop:
  preflight → xcodebuild archive (Developer ID, hardened runtime,
  version passed via MARKETING_VERSION / CURRENT_PROJECT_VERSION
  build settings, no project.pbxproj edits) → exportArchive with an
  on-the-fly developer-id export-options plist → ditto-zip for
  notarytool upload → `notarytool submit --wait` → `stapler staple`
  → re-zip with the stapled ticket → bump `appVersion` in the
  corresponding Hugo site's hugo.toml → `gh release create` (tag is
  `<App>-v<version>`, since both apps live in the same GitHub repo
  and `/releases/latest/` would be ambiguous) → cd to the Hugo site
  and `./deploy.sh`.
- `NOTARIZE-SETUP.md` at the project root — one-time per-Mac setup:
  generate a CSR in Keychain Access, request a **Developer ID
  Application** cert on developer.apple.com (separate from the
  existing Apple Development certs), download + install, then create
  an App Store Connect API key (.p8 / Key ID / Issuer ID) and run
  `xcrun notarytool store-credentials notary --key ... --key-id ...
  --issuer ...` once. Also covers exporting the cert as .p12 for the
  other Mac.

## What this unblocks

A first signed + notarized release of either app, on demand. Apple's
$99/year Developer Program enrollment is already in place; the
Developer ID Application cert and the notarytool keychain profile
are the two pieces the script's preflight currently checks for and
that I haven't created yet (those are user-only steps).

## Off-repo today (context, not in this repo's git log)

- macxcapture.com site shipped and live (Hugo sources at
  `~/Dropbox/dev/MacXServer/macxcapture-hugo/`, mirrored to
  github.com/toddvernon/MacXCaptureSite, deployed to the linode at
  /var/www/macxcapture.com/, Let's Encrypt cert via `certbot
  --nginx`). Pattern matches macxserver.com end to end.
- `/about/` page on both sites with Formspree contact forms (separate
  endpoints per site: `xykapqlg` for macxcapture, `xqeolvgv` for
  macxserver). Lightbox click-to-zoom on macxcapture's hero +
  screenshot cards.
- `/download/` page on both sites with a download CTA button that
  currently shows the "first build pending" placeholder. Flips to a
  real link to `releases/download/<App>-v<Version>/<App>.zip` once
  `release.sh` ships the first version and bumps the `appVersion`
  param.
- Global Claude Code config (`~/.claude/CLAUDE.md`,
  `settings.json`, `skills/`, `agents/`, `commands/`, `hooks/`) now
  syncs across both Macs via Dropbox symlinks to
  `~/Dropbox/dev/claude-shared/`. Bidirectional sync verified.
  Pattern documented in
  `.claude-memory/reference_multi_mac_project_sync_pattern.md`.

## What's next

1. Run through `NOTARIZE-SETUP.md`'s three steps (Developer ID cert,
   API key, `notarytool store-credentials`). ~15 minutes of clicking
   through developer.apple.com.
2. Smoke-test: `./release.sh MacXCapture 0.1.0`. Watch the preflight
   pass, archive succeed, notarization come back clean, release land
   on GitHub, macxcapture.com's download button flip live.
3. If that works, ship `MacXServer 0.1.0` the same way.
4. Verify the orphan xterm right-click menu is gone (carryover from
   yesterday's Motif grab fix — same root cause, should be covered,
   just hasn't been re-tested).
5. Decide whether to close the native-title-bar drag-lock gap (Motif
   Frame OFF windows only get the `isMovable=false` layer of the
   yesterday's two-layer fix; the chrome-click dismiss path is
   Motif-Frame-only) now or after the first public release.
