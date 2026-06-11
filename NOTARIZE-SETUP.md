# Code signing + notarization setup

One-time setup so `./release.sh` can build, sign, notarize, and ship a release
without prompting. Each Mac that's going to cut a release needs to go through
this once.

This setup is for distributing apps from the project's own website (and GitHub
Releases), NOT through the Mac App Store. The Apple Developer Program enrollment
covers both paths, but the cert types and tooling are different.

## What you'll end up with

After the steps below, the Mac running `release.sh` will have:

1. A **Developer ID Application certificate** in Login Keychain. Used to sign the
   binary. Apple-issued, valid for ~5 years.
2. A **notarytool keychain profile** named `notary`. Holds the App Store Connect
   API key credentials so `xcrun notarytool submit --keychain-profile notary`
   works without prompts.
3. An **Apple Development cert** (already present on this Mac for normal Xcode
   debug builds — different cert, used for development, not distribution).

End user experience: download → unzip → double-click → app opens. No Gatekeeper
warning, no "unidentified developer" dialog.

**Important: only `release.sh` produces a notarized build.** The Xcode project
signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`,
`CODE_SIGN_STYLE = Automatic`) so anyone can clone and run locally without a
Developer ID. That means a build you make in Xcode — Run *or* Archive — is NOT
notarized and will trigger Gatekeeper's "could not verify … free of malware"
dialog if you hand it to someone else. Developer ID + hardened runtime +
notarization are injected only by `release.sh` via xcodebuild flags. Never
distribute an Xcode-built `.app`; ship the GitHub-release artifact `release.sh`
produces.

## Step 1 — Developer ID Application certificate

The Apple Developer portal needs to issue you a Developer ID Application cert.
This is separate from the Apple Development certs you already have for debug
builds.

### Generate a Certificate Signing Request (CSR)

1. Open **Keychain Access** (`/Applications/Utilities/Keychain Access.app`).
2. Menu: **Keychain Access → Certificate Assistant → Request a Certificate From
   a Certificate Authority…**
3. Fill in:
   - User Email Address: your Apple ID email
   - Common Name: your name
   - CA Email Address: leave blank
   - Request is: **Saved to disk**
4. Save the `.certSigningRequest` file somewhere temporary.

### Request the cert on developer.apple.com

1. https://developer.apple.com/account → Certificates, Identifiers & Profiles
   → Certificates → **+**
2. Under **Software**, pick **Developer ID Application**. Continue.
3. Upload the `.certSigningRequest` from the previous step.
4. Download the issued `.cer` file.
5. Double-click the `.cer` to install it in Login Keychain.

Verify it's installed:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see one line like:

```
1) <40-char hash> "Developer ID Application: Your Name (TEAMID)"
```

If you see that, signing is set up.

### Sharing the cert across Macs

If you'll run releases from BOTH the laptop AND the desktop, export the cert
once and import on the other Mac:

1. In Keychain Access on the Mac that has the cert: find your "Developer ID
   Application: …" certificate under My Certificates, right-click →
   **Export…**. Choose `.p12` format, set a password you'll remember.
2. Copy the `.p12` to the other Mac (Dropbox is fine — `.p12` is password-protected).
3. On the other Mac, double-click the `.p12` to import. Enter the password.
4. Verify with the same `security find-identity` command above.

If you're importing over SSH / headless (no GUI Keychain Access), do it from
the command line instead of double-clicking — and you MUST set the key
partition list afterward, or codesign fails with `errSecInternalComponent`
the first time it tries to use the key in a non-GUI session:

```sh
# Unlock the login keychain (its password is your macOS login password)
security unlock-keychain -p '<login-password>' ~/Library/Keychains/login.keychain-db

# Import cert+key, pre-authorizing codesign
security import /path/to/DevID.p12 \
    -k ~/Library/Keychains/login.keychain-db \
    -P '<p12-export-password>' \
    -T /usr/bin/codesign

# REQUIRED for imported keys: let apple tools / codesign use the key without a GUI prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s \
    -k '<login-password>' \
    ~/Library/Keychains/login.keychain-db
```

A key created locally by a CSR doesn't need the partition-list step — only
imported `.p12` keys do. Verify codesign actually works (not just that the
identity lists) by signing a throwaway Mach-O:
`cp /usr/bin/true /tmp/t && codesign -s "Developer ID Application: <your identity>" --timestamp -f /tmp/t && codesign -dvv /tmp/t`.

## Step 2 — Notarization credentials (App Store Connect API key)

`notarytool` needs credentials to talk to Apple. The recommended way is an App
Store Connect API key (vs. an app-specific password) because it doesn't expire.

### Create the API key

1. https://appstoreconnect.apple.com/access/api/keys-no-team → **Generate API
   Key** (or use Team Keys if you have a team — same flow).
2. Name it `notary`. Role: **Developer**.
3. Click **Generate**.
4. **Download the `.p8` file immediately.** Apple only lets you download it
   ONCE. Lose this file and you have to revoke the key and start over.
5. Note the **Key ID** (shown on the Keys page, ~10 chars).
6. Note the **Issuer ID** (shown at the top of the Keys page, UUID format).

### Store the credentials in Keychain

`notarytool` can stash the credentials in your Keychain under a profile name
so future calls don't need to re-enter them.

```sh
xcrun notarytool store-credentials notary \
    --key /path/to/AuthKey_XXXXX.p8 \
    --key-id <KEY_ID> \
    --issuer <ISSUER_ID>
```

It'll prompt for the Login Keychain password to authorize the storage. After
that, `xcrun notarytool submit --keychain-profile notary` works without
prompts.

Verify:

```sh
xcrun notarytool history --keychain-profile notary
```

If that returns (even with an empty history), the profile is configured.

### Where to keep the .p8 file

The `.p8` file is the private key. After `store-credentials` it's been copied
into your Keychain, but you may want to keep a backup somewhere:

- **Good**: 1Password / Bitwarden / encrypted disk image.
- **Acceptable**: encrypted `.dmg` in iCloud Drive.
- **Bad**: plain Dropbox / iCloud Drive (`.p8` is a private key — protect it
  like an SSH private key).

If you do keep a backup, also note the Key ID and Issuer ID alongside it; both
are needed to re-run `store-credentials` on another Mac.

## Step 3 — Verify everything works

Smoke test by running a release with a low-stakes version number. The version
must be strict semver `X.Y.Z` — no `-suffix` (the script's regex rejects it), so
use something like `0.0.1`:

```sh
cd ~/dev/X
./release.sh MacXCapture 0.0.1
```

The script will sanity-check:

- Developer ID Application cert is in Keychain
- notarytool keychain profile `notary` is configured
- `gh` CLI is authenticated
- The Hugo site exists for the app

It then archives, signs, notarizes (takes 1-3 minutes), staples the ticket,
zips the result, creates a GitHub release, and deploys the Hugo site.

If notarization fails, the script prints the submission ID and Apple's reason
will be visible via:

```sh
xcrun notarytool log <submission-id> --keychain-profile notary
```

Common notarization failures:

- **Missing `--options=runtime`** — the script passes this via `OTHER_CODE_SIGN_FLAGS`.
- **Unsigned helper tool** — every executable inside the .app bundle must be
  signed. `--deep` covers the common cases.
- **Missing entitlements** — apps that use hardened runtime need explicit
  entitlements for things like JIT, debugging, network. Add them in the Xcode
  project Capabilities tab.
- **Bundle ID conflict** — the bundle ID in the Info.plist must match the
  Provisioning Profile (we don't use a profile for Developer ID, so this is
  rarely an issue).

## Step 4 — Subsequent releases

Once the setup is done, releases are just:

```sh
cd ~/dev/X
./release.sh MacXServer 1.0.1
# or
./release.sh MacXCapture 1.0.1
```

The script does the whole loop: archive, sign, notarize, staple, zip, GH
release, Hugo site version bump, site deploy. Idempotent if you re-run with
the same version (overwrites the release).

## Reference

- Apple's official [Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- `xcrun notarytool --help` — the man pages aren't great; this is more accurate.
- `man codesign`, `man stapler` — the signing tooling.
