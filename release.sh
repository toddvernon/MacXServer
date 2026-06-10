#!/bin/bash
# release.sh — build, sign, notarize, and ship a release of MacXServer or MacXCapture.
#
# Usage:
#   ./release.sh <MacXServer|MacXCapture> <version>
#
# Examples:
#   ./release.sh MacXServer 1.0.0
#   ./release.sh MacXCapture 1.0.0
#
# Prereqs (see NOTARIZE-SETUP.md):
#   1. Apple Developer Program enrollment.
#   2. "Developer ID Application" certificate installed in Keychain.
#   3. notarytool keychain profile named "notary" (xcrun notarytool store-credentials notary ...).
#   4. gh CLI authenticated (gh auth status).
#
# What this does, end to end:
#   1. Sanity: validate args, check tools, confirm Developer ID cert is in Keychain.
#   2. xcodebuild archive — Release config, signed with Developer ID Application, manual style.
#      Version is passed in via MARKETING_VERSION/CURRENT_PROJECT_VERSION build settings
#      so no project.pbxproj edit is needed.
#   3. xcodebuild -exportArchive — extracts the .app from the .xcarchive using
#      a developer-id export options plist generated on the fly.
#   4. ditto-zip the .app for notarization (preserves codesign metadata).
#   5. xcrun notarytool submit ... --wait — uploads to Apple, blocks until done.
#      Typical wait: 1-3 minutes. If notarization fails, the script aborts and
#      tells you to run `xcrun notarytool log <submission-id>` for the reason.
#   6. xcrun stapler staple — embeds the notarization ticket into the .app so
#      first-launch verification works offline.
#   7. Re-zip the stapled .app into the final shippable artifact.
#   8. Update appVersion in the corresponding Hugo site's hugo.toml.
#   9. gh release create — tag <App>-v<Version>, attach the zip as <App>.zip.
#  10. cd to the Hugo site and run ./deploy.sh so the download button points
#      at the new release immediately.
#
# Why tags include the app name: both apps live in toddvernon/MacXServer, so
# /releases/latest/download/ would be ambiguous. We use stable per-version
# URLs constructed from the Hugo appVersion param instead.

set -euo pipefail

# -------- args --------

APP="${1:-}"
VERSION="${2:-}"

if [[ -z "$APP" || -z "$VERSION" ]]; then
    echo "Usage: $0 <MacXServer|MacXCapture> <version>"
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

# -------- config --------

# Team ID. The Developer ID Application cert was issued under the "CarePenguin,
# inc" team (X478U667PR) on 2026-06-10 — the personal "Todd Vernon" team
# (NXNG297DL6) was inaccessible (covey@ Apple ID login blocked), so we signed
# under CarePenguin instead. The signer string is visible only via
# `codesign -dvv` / `spctl`; no user-facing Gatekeeper dialog shows it.
TEAM_ID="X478U667PR"

# Keychain profile name created via `xcrun notarytool store-credentials`.
# Stays consistent across releases of both apps.
NOTARY_PROFILE="notary"

# Project layout
PROJECT_ROOT="$HOME/dev/X"
PROJECT_FILE="$PROJECT_ROOT/MacXServer.xcodeproj"

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

# Hugo site exists?
if [[ ! -f "$HUGO_DIR/hugo.toml" ]]; then
    echo "ERROR: Hugo site not found at $HUGO_DIR"
    exit 1
fi
echo "    hugo site: $HUGO_DIR"

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

# -------- Hugo site update --------

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

# -------- GitHub release --------

TAG="$APP-v$VERSION"
echo
echo "==> Creating GitHub release: $TAG (repo: $REPO)"

RELEASE_NOTES_FILE="$BUILD_DIR/release-notes.md"
cat > "$RELEASE_NOTES_FILE" <<EOF
$APP v$VERSION

Signed and notarized for macOS. Download below, unzip, drag the .app to
Applications. First-launch should be clean — no Gatekeeper warnings.

System requirements: macOS 14.0 (Sonoma) or later.
EOF

gh release create "$TAG" \
    --repo "$REPO" \
    --title "$APP v$VERSION" \
    --notes-file "$RELEASE_NOTES_FILE" \
    "$FINAL_ZIP#$APP.zip"

# -------- deploy Hugo site --------

echo
echo "==> Deploying Hugo site so the download button picks up the new version"
( cd "$HUGO_DIR" && ./deploy.sh )

# -------- done --------

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$APP.zip"
echo
echo "==> Done."
echo
echo "    Release: https://github.com/$REPO/releases/tag/$TAG"
echo "    Download: $DOWNLOAD_URL"
echo "    Site updated: $(grep -oE 'baseURL = "[^"]*"' "$HUGO_DIR/hugo.toml" | sed 's|baseURL = ||; s|"||g')"
echo
echo "Test the download:"
echo "    curl -L -o /tmp/test.zip \"$DOWNLOAD_URL\" && \\"
echo "    unzip /tmp/test.zip -d /tmp/test && \\"
echo "    open /tmp/test/$PRODUCT_NAME.app"
