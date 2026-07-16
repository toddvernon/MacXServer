#!/bin/bash
# release.sh — build, sign, notarize, and ship a release of MacXServer or MacXCapture.
#
# Usage:
#   ./release.sh <MacXServer|MacXCapture> <version> [--beta]
#
# Examples:
#   ./release.sh MacXServer 1.0.0
#   ./release.sh MacXCapture 1.0.0
#   ./release.sh MacXServer 0.9.9 --beta
#
# --beta (BETA_PLAN.md phase 2; DECISIONS 2026-07-15): the identical signed +
# notarized + stapled artifact, but published to the PRIVATE repo
# toddvernon/macxserver-beta instead of the public releases page, and with
# every public-surface step skipped: no Hugo appVersion bump, no site deploy,
# no project.yml default-version bump/commit/push. A beta cut must never
# touch the website or the source tree. The GPL source bundle still attaches
# (distribution to testers is still distribution).
#
# Prereqs (see NOTARIZE-SETUP.md):
#   1. Apple Developer Program enrollment.
#   2. "Developer ID Application" certificate installed in Keychain.
#   3. notarytool keychain profile named "notary" (xcrun notarytool store-credentials notary ...).
#   4. gh CLI authenticated (gh auth status).
#
# What this does, end to end:
#   1. Sanity: validate args, check tools, confirm Developer ID cert is in Keychain.
#      For MacXServer: also confirm the SPARCplug engine payload (sibling repo's
#      dist/) is present, relinked (zero Homebrew paths), and version-matched to
#      qemu.lock.
#   2. xcodebuild archive — Release config, signed with Developer ID Application, manual style.
#      Version is passed in via MARKETING_VERSION/CURRENT_PROJECT_VERSION build settings
#      so no project.pbxproj edit is needed.
#   3. xcodebuild -exportArchive — extracts the .app from the .xcarchive using
#      a developer-id export options plist generated on the fly.
#   4. MacXServer only: embed the SPARCplug qemu engine into the bundle
#      (Contents/Helpers + Resources/qemu-firmware) and sign it inside-out —
#      dylibs, then the helper with its JIT entitlements, then re-seal the
#      outer .app. See PLUGIN_V1_PUNCHLIST.md Track A.
#   5. ditto-zip the .app for notarization (preserves codesign metadata).
#   6. xcrun notarytool submit ... --wait — uploads to Apple, blocks until done.
#      Typical wait: 1-3 minutes. If notarization fails, the script aborts and
#      tells you to run `xcrun notarytool log <submission-id>` for the reason.
#   7. xcrun stapler staple — embeds the notarization ticket into the .app so
#      first-launch verification works offline.
#   8. Re-zip the stapled .app into the final shippable artifact.
#   9. MacXServer only: assemble the GPL corresponding-source bundle
#      (Tools/make-gpl-source-bundle.sh) — attached to the release in step 11.
#      This is the GPLv2 §3 obligation GPL_SOURCE.md promises; a MacXServer
#      release without it ships a GPL binary with no source offer.
#  10. Update appVersion in the corresponding Hugo site's hugo.toml.
#  11. gh release create — tag <App>-v<Version>, attach the zip as <App>.zip
#      (plus the GPL source bundle for MacXServer).
#  12. cd to the Hugo site and run ./deploy.sh so the download button points
#      at the new release immediately.
#  13. Bump the app target's default MARKETING_VERSION in project.yml (the
#      xcodegen source of truth), regenerate the .xcodeproj, commit + push.
#
# Why tags include the app name: both apps live in toddvernon/MacXServer, so
# /releases/latest/download/ would be ambiguous. We use stable per-version
# URLs constructed from the Hugo appVersion param instead.

set -euo pipefail

# -------- args --------

APP=""
VERSION=""
BETA=0
for arg in "$@"; do
    case "$arg" in
        --beta) BETA=1 ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *)
            if [[ -z "$APP" ]]; then APP="$arg"
            elif [[ -z "$VERSION" ]]; then VERSION="$arg"
            else echo "Too many arguments: $arg"; exit 1
            fi
            ;;
    esac
done

if [[ -z "$APP" || -z "$VERSION" ]]; then
    echo "Usage: $0 <MacXServer|MacXCapture> <version> [--beta]"
    echo "Example: $0 MacXServer 1.0.0"
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must be semver (e.g., 1.0.0). Got: $VERSION"
    exit 1
fi

case "$APP" in
    MacXServer)
        HUGO_DIR="$HOME/Dropbox/dev/MacXServer/macxserver-hugo"
        REPO="toddvernon/MacXServer"
        SCHEME="MacXServer"
        PRODUCT_NAME="MacXServer"
        ;;
    MacXCapture)
        HUGO_DIR="$HOME/Dropbox/dev/MacXServer/macxcapture-hugo"
        REPO="toddvernon/MacXServer"
        SCHEME="MacXCapture"
        PRODUCT_NAME="MacXCapture"
        ;;
    *)
        echo "Unknown app: $APP. Must be MacXServer or MacXCapture."
        exit 1
        ;;
esac

# Beta cuts publish to the private beta repo and never touch the site.
if [[ "$BETA" == 1 ]]; then
    REPO="toddvernon/macxserver-beta"
    echo "*** BETA MODE: publishing to $REPO; Hugo + version-bump steps skipped ***"
fi

# -------- config --------

# Team ID for the Developer ID Application signing cert. The signer string is
# only visible via `codesign -dvv` / `spctl`; no user-facing Gatekeeper dialog
# shows it. To sign under a different team, change this and re-issue the cert
# under that team (see NOTARIZE-SETUP.md).
TEAM_ID="X478U667PR"

# Keychain profile name created via `xcrun notarytool store-credentials`.
# Stays consistent across releases of both apps.
NOTARY_PROFILE="notary"

# Project layout
PROJECT_ROOT="$HOME/dev/X"
PROJECT_FILE="$PROJECT_ROOT/MacXServer.xcodeproj"

# SPARCplug engine payload (MacXServer releases only). Built in the sibling
# repo by build-qemu.sh + packaging/bundle-dylibs.sh: dist/ holds the relinked
# helper (all dylib load paths rewritten to @executable_path/lib/), its
# dylibs, and the OpenBIOS firmware. release.sh copies it into the bundle and
# signs it with the same Developer ID as the app — SPARCplug deliberately
# leaves signing to this pipeline so there's a single identity
# (PLUGIN_V1_PUNCHLIST.md, settled decision 2026-06-17).
SPARC_ROOT="$HOME/dev/SPARCplug"
SPARC_DIST="$SPARC_ROOT/dist"
QEMU_ENTITLEMENTS="$SPARC_ROOT/packaging/qemu.entitlements"
QEMU_LOCK="$SPARC_ROOT/qemu.lock"

# Build artifacts live in /tmp so they don't clutter the working tree.
BUILD_DIR="/tmp/macxserver-release/$APP-$VERSION"
ARCHIVE_PATH="$BUILD_DIR/$APP.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$PRODUCT_NAME.app"
NOTARIZE_ZIP="$BUILD_DIR/$APP-for-notarization.zip"
FINAL_ZIP="$BUILD_DIR/$APP.zip"
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"

# -------- sanity checks --------

echo "==> Sanity checks"

# Developer ID cert in Keychain?
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo
    echo "ERROR: No 'Developer ID Application' certificate found in Keychain."
    echo "See NOTARIZE-SETUP.md step 1."
    exit 1
fi
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
echo "    signing identity: $SIGN_IDENTITY"

# notarytool keychain profile?
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo
    echo "ERROR: notarytool keychain profile '$NOTARY_PROFILE' not configured."
    echo "See NOTARIZE-SETUP.md step 2."
    exit 1
fi
echo "    notarytool profile: $NOTARY_PROFILE (ok)"

# gh CLI ready?
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh CLI not authenticated. Run: gh auth login"
    exit 1
fi
echo "    gh CLI: ok"

# Hugo site exists? (Not needed for a beta cut, which never touches it.)
if [[ "$BETA" == 0 ]]; then
    if [[ ! -f "$HUGO_DIR/hugo.toml" ]]; then
        echo "ERROR: Hugo site not found at $HUGO_DIR"
        exit 1
    fi
    echo "    hugo site: $HUGO_DIR"
fi

# SPARCplug engine payload sane? (MacXServer bundles the qemu helper; a
# release without it ships a machine manager that can't boot a VM.)
if [[ "$APP" == "MacXServer" ]]; then
    if [[ ! -x "$SPARC_DIST/qemu-system-sparc" ]]; then
        echo "ERROR: SPARCplug engine not found at $SPARC_DIST/qemu-system-sparc."
        echo "Build it in the SPARCplug repo: build-qemu.sh, then packaging/bundle-dylibs.sh."
        exit 1
    fi
    if ! ls "$SPARC_DIST/lib/"*.dylib >/dev/null 2>&1; then
        echo "ERROR: no dylibs in $SPARC_DIST/lib — run SPARCplug packaging/bundle-dylibs.sh."
        exit 1
    fi
    if [[ ! -f "$SPARC_DIST/firmware/openbios-sparc32" ]]; then
        echo "ERROR: firmware missing at $SPARC_DIST/firmware/openbios-sparc32."
        exit 1
    fi
    if [[ ! -f "$QEMU_ENTITLEMENTS" ]]; then
        echo "ERROR: qemu entitlements not found at $QEMU_ENTITLEMENTS."
        exit 1
    fi
    if [[ ! -f "$QEMU_LOCK" ]]; then
        echo "ERROR: qemu.lock not found at $QEMU_LOCK (needed for the GPL source bundle)."
        exit 1
    fi

    # Relink audit: a dist/ that still references Homebrew paths would load
    # (or fail to load) machine-local libraries on a customer Mac. dylibbundler
    # is supposed to have rewritten everything to @executable_path/lib/.
    if otool -L "$SPARC_DIST/qemu-system-sparc" "$SPARC_DIST/lib/"*.dylib \
        | grep -E '/(opt/homebrew|usr/local)/' ; then
        echo "ERROR: SPARCplug dist still links against Homebrew paths (above)."
        echo "Re-run SPARCplug packaging/bundle-dylibs.sh."
        exit 1
    fi

    # Version cross-check: the helper we embed must be built from the QEMU
    # release qemu.lock pins, because that's exactly what the GPL source
    # bundle we attach claims to correspond to. (Also proves the binary
    # actually loads its bundled dylibs on this Mac.)
    QEMU_LOCK_VER=$(grep -E '^version[[:space:]]*=' "$QEMU_LOCK" | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
    QEMU_BIN_VER=$("$SPARC_DIST/qemu-system-sparc" --version | head -1)
    if [[ "$QEMU_BIN_VER" != *"$QEMU_LOCK_VER"* ]]; then
        echo "ERROR: engine version mismatch."
        echo "  qemu.lock pins:  $QEMU_LOCK_VER"
        echo "  dist binary is:  $QEMU_BIN_VER"
        echo "The GPL source bundle would not correspond to the shipped binary."
        echo "Rebuild dist/ from the pinned source (or update qemu.lock)."
        exit 1
    fi
    echo "    sparcplug engine: $SPARC_DIST (QEMU $QEMU_LOCK_VER, relink clean)"
fi

# Working tree clean? (advisory — releases are easier to reason about when clean.)
cd "$PROJECT_ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    echo
    echo "WARNING: Working tree has uncommitted changes:"
    git status --short
    read -p "Continue anyway? [y/N] " ok
    if [[ "$ok" != "y" && "$ok" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# -------- build --------

echo
echo "==> Cleaning build dir: $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo
echo "==> Archiving $APP at version $VERSION (Release config, signed with Developer ID)"
echo "    (this takes a couple of minutes)"

xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    clean archive | xcbeautify 2>/dev/null || \
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    clean archive

# -------- export --------

echo
echo "==> Exporting .app from archive"

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Exported .app not found at $APP_PATH"
    ls -la "$EXPORT_DIR"
    exit 1
fi

echo "    exported: $APP_PATH"

# -------- embed SPARCplug engine (MacXServer only) --------

# Layout must match QemuEngine.defaultConfig()'s bundle resolution:
#   helper   = Contents/Helpers/qemu-system-sparc  (+ lib/ beside it, because
#              dylibbundler rewrote load paths to @executable_path/lib/)
#   firmware = Contents/Resources/qemu-firmware
# Signing is inside-out (dylibs -> helper -> outer app), with the helper
# getting the JIT entitlements (allow-jit + allow-unsigned-executable-memory;
# without them TCG falls back to the interpreter, ~10x slower boot). The
# recipe was proven locally in PLUGIN_V1_PUNCHLIST.md A3. Copying into the
# bundle invalidates the app's resource seal, so the final outer re-sign is
# mandatory, and everything here must happen BEFORE notarization so Apple
# notarizes the combined bundle as one unit.

if [[ "$APP" == "MacXServer" ]]; then
    echo
    echo "==> Embedding SPARCplug engine from $SPARC_DIST"
    HELPERS_DIR="$APP_PATH/Contents/Helpers"
    FIRMWARE_DIR="$APP_PATH/Contents/Resources/qemu-firmware"
    mkdir -p "$HELPERS_DIR/lib" "$FIRMWARE_DIR"
    cp "$SPARC_DIST/qemu-system-sparc" "$HELPERS_DIR/"
    cp "$SPARC_DIST/lib/"*.dylib "$HELPERS_DIR/lib/"
    cp "$SPARC_DIST/firmware/"* "$FIRMWARE_DIR/"

    echo "==> Signing engine inside-out (Developer ID, hardened runtime)"
    for dylib in "$HELPERS_DIR/lib/"*.dylib; do
        codesign --force --timestamp --options=runtime \
            --sign "$SIGN_IDENTITY" "$dylib"
    done
    codesign --force --timestamp --options=runtime \
        --entitlements "$QEMU_ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$HELPERS_DIR/qemu-system-sparc"

    echo "==> Re-sealing outer app bundle"
    codesign --force --timestamp --options=runtime \
        --sign "$SIGN_IDENTITY" "$APP_PATH"

    echo "==> Verifying combined bundle signature"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    echo "    engine embedded + signed"
fi

# -------- notarize --------

echo
echo "==> Zipping for notarization upload"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo
echo "==> Submitting to Apple notarization (typical: 1-3 minutes)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# -------- package --------

echo
echo "==> Creating final shippable zip: $FINAL_ZIP"
# Remove any old final zip
rm -f "$FINAL_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
ls -la "$FINAL_ZIP"

# -------- GPL source bundle (MacXServer only) --------

# The bundled qemu helper is GPLv2; GPL_SOURCE.md promises the complete
# corresponding source as a bundle attached to every release. Assemble it
# now (before any publish step) so a failure here aborts the release rather
# than shipping a GPL binary with no source offer. The upstream tarball is
# cached under .build/gpl-source-cache after the first run.

GPL_BUNDLE=""
if [[ "$APP" == "MacXServer" ]]; then
    echo
    echo "==> Assembling GPL corresponding-source bundle"
    "$PROJECT_ROOT/Tools/make-gpl-source-bundle.sh" "$BUILD_DIR"
    GPL_BUNDLE=$(ls "$BUILD_DIR"/macxserver-gpl-source-*.tar.xz)
    echo "    gpl bundle: $GPL_BUNDLE"
fi

# -------- Hugo site update --------

if [[ "$BETA" == 0 ]]; then
    echo
    echo "==> Updating Hugo site appVersion in $HUGO_DIR/hugo.toml"
    if grep -q "^  appVersion = " "$HUGO_DIR/hugo.toml"; then
        sed -i "" "s|^  appVersion = .*|  appVersion = \"$VERSION\"|" "$HUGO_DIR/hugo.toml"
    else
        # Param doesn't exist yet — append it under [params].
        sed -i "" "/^\[params\]/a\\
  appVersion = \"$VERSION\"" "$HUGO_DIR/hugo.toml"
    fi
    grep "^  appVersion = " "$HUGO_DIR/hugo.toml"
fi

# -------- GitHub release --------

TAG="$APP-v$VERSION"
echo
echo "==> Creating GitHub release: $TAG (repo: $REPO)"

RELEASE_NOTES_FILE="$BUILD_DIR/release-notes.md"
if [[ "$BETA" == 1 ]]; then
    cat > "$RELEASE_NOTES_FILE" <<EOF
$APP v$VERSION (beta)

Signed and notarized for macOS. Download the zip below IN A BROWSER,
unzip, drag the .app to Applications — the repo README has the full
install walkthrough. Feedback goes in this repo's Issues; first-five-
minutes friction is a first-class bug report.

Known issues: (edit this release's notes as they're found.)

System requirements: macOS 14.0 (Sonoma) or later.
EOF
else
    cat > "$RELEASE_NOTES_FILE" <<EOF
$APP v$VERSION

Signed and notarized for macOS. Download below, unzip, drag the .app to
Applications. First-launch should be clean — no Gatekeeper warnings.

System requirements: macOS 14.0 (Sonoma) or later.
EOF
fi

if [[ -n "$GPL_BUNDLE" ]]; then
    cat >> "$RELEASE_NOTES_FILE" <<EOF

The macxserver-gpl-source tarball is the complete corresponding source for
the GPL/LGPL components bundled in the app (the qemu-system-sparc helper
and friends) — see GPL_SOURCE.md in the repo. You only need it if you want
to rebuild the emulation engine from source.
EOF
fi

RELEASE_ASSETS=("$FINAL_ZIP#$APP.zip")
if [[ -n "$GPL_BUNDLE" ]]; then
    RELEASE_ASSETS+=("$GPL_BUNDLE#$(basename "$GPL_BUNDLE")")
fi

gh release create "$TAG" \
    --repo "$REPO" \
    --title "$APP v$VERSION" \
    --notes-file "$RELEASE_NOTES_FILE" \
    "${RELEASE_ASSETS[@]}"

# -------- deploy Hugo site --------

if [[ "$BETA" == 0 ]]; then
    echo
    echo "==> Deploying Hugo site so the download button picks up the new version"
    ( cd "$HUGO_DIR" && ./deploy.sh )
fi

# -------- default version bump (project.yml is the source of truth) --------

# Purely cosmetic for dev-build UX. The shipped artifact already has
# $VERSION baked in via the xcodebuild MARKETING_VERSION override above,
# so this step has no bearing on what users download. What it fixes: a
# plain Xcode dev build picks up the project's default MARKETING_VERSION,
# which would otherwise lag a release behind — the About dialog on dev
# builds would show the previous shipped version.
#
# The bump edits project.yml, NOT the pbxproj: xcodegen regenerates the
# pbxproj from project.yml, so a pbxproj-only bump (the old approach) was
# clobbered back to the stale default on the next regeneration. The sed
# targets the "# release-version <App>" marker comment so only the released
# app's line moves (the two apps version independently; the framework
# targets' internal 0.1.0 defaults are untouched). Then regenerate the
# pbxproj so a fresh checkout builds with the right default immediately.
#
# Idempotent: re-running the same version leaves the files byte-identical
# and the `git diff` check skips the commit.
#
# Runs AFTER Hugo deploy so any failure here can't strand the public
# download button on a stale version.

if [[ "$BETA" == 1 ]]; then
    echo
    echo "==> Beta cut: skipping the project.yml default-version bump (no source-tree"
    echo "    edits, no commit, no push — the shipped artifact has $VERSION baked in)."
else
    echo
    echo "==> Bumping default MARKETING_VERSION for $APP to $VERSION in project.yml"
    PROJECT_YML="$PROJECT_ROOT/project.yml"
    PBXPROJ="$PROJECT_FILE/project.pbxproj"
    sed -i "" -E "s|MARKETING_VERSION: \"[0-9]+\.[0-9]+\.[0-9]+\" # release-version $APP|MARKETING_VERSION: \"$VERSION\" # release-version $APP|" "$PROJECT_YML"
    if ! grep -q "MARKETING_VERSION: \"$VERSION\" # release-version $APP" "$PROJECT_YML"; then
        echo "WARNING: version-bump marker '# release-version $APP' not found in project.yml — bump skipped."
        echo "The release itself is complete; fix the marker line by hand."
    else
        if command -v xcodegen >/dev/null 2>&1; then
            ( cd "$PROJECT_ROOT" && xcodegen generate >/dev/null )
            echo "    project.yml bumped + .xcodeproj regenerated"
        else
            echo "WARNING: xcodegen not installed — project.yml bumped, but the"
            echo ".xcodeproj is stale until the next 'xcodegen generate'."
        fi

        # Auto-commit + push so the source tree stays in sync with what shipped.
        # Only stages the version files — any unrelated in-progress edits in the
        # working tree stay put (Todd was warned about a dirty tree at the
        # sanity-check step and chose to proceed).
        if ! ( cd "$PROJECT_ROOT" && git diff --quiet -- "$PROJECT_YML" "$PBXPROJ" ); then
            echo
            echo "==> Committing version bump"
            ( cd "$PROJECT_ROOT" \
                && git add "$PROJECT_YML" "$PBXPROJ" \
                && git commit -m "Project: bump $APP default MARKETING_VERSION to $VERSION (post-release sync)" \
                && git push )
        fi
    fi
fi

# -------- done --------

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$APP.zip"
echo
echo "==> Done."
echo
echo "    Release: https://github.com/$REPO/releases/tag/$TAG"
echo "    Download: $DOWNLOAD_URL"
if [[ "$BETA" == 0 ]]; then
    echo "    Site updated: $(grep -oE 'baseURL = "[^"]*"' "$HUGO_DIR/hugo.toml" | sed 's|baseURL = ||; s|"||g')"
fi
echo
if [[ "$BETA" == 1 ]]; then
    # Private repo: anonymous curl 404s, and the whole point of the beta test
    # is installing like a stranger — browser download so the quarantine bit
    # is real, then Finder unzip + drag to /Applications (A6 acceptance,
    # BETA_PLAN.md phase 2).
    echo "Test it like a stranger (fresh macOS account is best):"
    echo "    open \"https://github.com/$REPO/releases/tag/$TAG\""
    echo "    download $APP.zip IN THE BROWSER, unzip in Finder, drag to"
    echo "    /Applications, first-launch through the Gatekeeper dialogs."
else
    # `unzip` here is deliberate: it loses ditto's codesign-friendly metadata,
    # so a `spctl -a` on the result fails with "sealed resource missing or
    # invalid". That's the canary -- if you ever run this snippet and the app
    # DOES open clean, something has changed about how the zip was built and
    # you should re-validate the release with `ditto -x -k` + `spctl`. End
    # users get the app via Finder / Archive Utility (ditto-equivalent), so
    # they're fine; this hint is for the release operator only.
    echo "Test the download:"
    echo "    curl -L -o /tmp/test.zip \"$DOWNLOAD_URL\" && \\"
    echo "    unzip /tmp/test.zip -d /tmp/test && \\"
    echo "    open /tmp/test/$PRODUCT_NAME.app"
fi
