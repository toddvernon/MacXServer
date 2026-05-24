# Xcode Setup

Step-by-step for wrapping the two SPM executables in `.app`
bundles so they show up as real Mac apps with icons, proper
window activation, and Finder-launchability.

The Swift Package Manager package stays as-is — Xcode just adds
two thin `.app` targets that link the same source files.

## What's already prepared

Everything Xcode needs from me is in the repo:

- **`Xcode/CaptureMain.swift`** — the `@main` entry for the
  capture `.app` target. One-liner that calls
  `SwiftXCaptureApp.main()`.
- **`Xcode/ServerMain.swift`** — the `@main` entry for the
  server `.app` target. One-liner that calls `ServerEntry.run()`.
- **`Xcode/Capture-Info.plist`** — Info.plist for the capture
  `.app`. Bundle ID `com.toddvernon.swiftx.capture`, display
  name "swift-x Capture".
- **`Xcode/Server-Info.plist`** — Info.plist for the server
  `.app`. Bundle ID `com.toddvernon.swiftx.server`, display name
  "MacXServer".
- **`Sources/SwiftXServer/ServerEntry.swift`** — the body of the
  old `main.swift` extracted into `ServerEntry.run()`, callable
  from either the SPM `main.swift` or the Xcode `@main` wrapper.
  `@MainActor` because it touches AppKit.
- **`Icons/AppIcon.appiconset/`** — your existing asset-catalog
  icon set (16×16 through 512×512 at 1× and 2×, all PNGs +
  `Contents.json`).

## What you'll do in Xcode

### 1. Create the workspace

1. Open Xcode.
2. **File → New → Workspace**.
3. Name it **`MacXServer`**, save in the repo root.

You should now have `MacXServer.xcworkspace/` next to
`Package.swift`.

### 2. Add the SPM package to the workspace

1. With the workspace open: **File → Add Package Dependencies…**
2. Click **Add Local…** at the bottom left of the dialog.
3. Pick the repo root (the directory containing `Package.swift`).
4. When prompted to choose package products, **skip / cancel** —
   we want the package in the workspace but products are picked
   per `.app` target later.

The package should appear in the workspace navigator.

### 3. Create the project + first target (capture `.app`)

1. **File → New → Project**.
2. Choose **macOS → App**, click Next.
3. Settings:
   - Product Name: **`swiftx-capture`**
   - Team: your dev team (or "None" for unsigned local builds)
   - Organization Identifier: **`com.toddvernon.swiftx`**
   - Bundle Identifier (auto): `com.toddvernon.swiftx.swiftx-capture`
     — change to **`com.toddvernon.swiftx.capture`** to match
     the prepared Info.plist.
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None**
   - Include Tests: uncheck (SPM owns tests)
4. Save in repo root, name the project **`MacXServer`**. Add to
   the workspace **`MacXServer`**.

Xcode creates `MacXServer.xcodeproj/` and a default target
`swiftx-capture` with stub files (`ContentView.swift`, etc.).

### 4. Wire up the capture target

#### 4a. Delete the stub files Xcode generated

In the project navigator, delete:

- `ContentView.swift`
- `swiftx_captureApp.swift` (or similar — the auto-generated
  `@main App` stub)
- `Assets.xcassets` (we'll use the one in `Icons/`)
- `Preview Content/` directory if present

Choose **"Move to Trash"** when prompted.

#### 4b. Add the real source files

Right-click the `swiftx-capture` group in the navigator →
**Add Files to "MacXServer"…**

Add these (all as **references**, NOT copied — uncheck "Copy
items if needed"):

- `Sources/SwiftXCapture/` — add the directory. When prompted,
  use **"Create folder references"** so it picks up future files
  automatically. Choose **Target: swiftx-capture only**.
- `Xcode/CaptureMain.swift` — single file, **Target: swiftx-capture**.

#### 4c. Exclude `main.swift` from the target

`Sources/SwiftXCapture/main.swift` is the SPM entry — it can't
coexist with `@main` in the `.app` target. Click it in the
navigator → **File Inspector (⌥⌘1)** → uncheck the
`swiftx-capture` checkbox under "Target Membership."

#### 4d. Add the icon asset catalog

Right-click the `swiftx-capture` group → **Add Files…**.

Select `Icons/AppIcon.appiconset/`. Use **folder reference**.
Target: `swiftx-capture`.

#### 4e. Point the build settings at the prepared Info.plist

Select the project (top of navigator) → `swiftx-capture` target
→ **Build Settings** tab.

Search for **"Info.plist File"** under the "Packaging" section.
Set the value to **`Xcode/Capture-Info.plist`**.

Search for **"Generate Info.plist File"** — set to **No** (so it
uses ours instead of generating one from build settings).

Search for **"Asset Catalog App Icon Set Name"** → set to
**`AppIcon`**.

Search for **"Asset Catalog Compiler — Generate Asset Symbol
Extensions"** → No (avoids a generated Assets symbol collision).

Search for **"Asset Catalog Compiler — Generate Asset Symbols"**
→ No.

#### 4f. Link the SPM library products

Same Build Settings tab → scroll to **General** tab → "Frameworks,
Libraries, and Embedded Content" section.

Click **+** → "Add Other..." or pick from the package
dependencies list:

- `SwiftXCaptureCore`
- `Framer`

(The package was added in step 2; its libraries should appear
in the picker.)

### 5. Add the second target (server `.app`)

1. With the project selected → click **+** at the bottom of the
   target list → **macOS App** → Next.
2. Product Name: **`MacXServer`**.
3. Bundle Identifier: **`com.toddvernon.swiftx.server`**.
4. Interface: SwiftUI. Language: Swift. Storage: None.
5. No tests.

Repeat steps **4a–4f** for this target with these differences:

- 4b: Add `Sources/SwiftXServer/` as a folder reference. Add
  `Xcode/ServerMain.swift`. Both with Target: `MacXServer`.
- 4c: Exclude `Sources/SwiftXServer/main.swift` from the
  `MacXServer` target.
- 4e: Info.plist File = **`Xcode/Server-Info.plist`**.
- 4f: Link **`SwiftXServerCore`**, **`SwiftXCaptureCore`**,
  **`Framer`** to this target. (Server needs all three.)

### 6. Build + run

- Pick the `swiftx-capture` scheme (top-left scheme picker) →
  **▶ Run**. Expect the chooser window to appear in front,
  with the X icon in the Dock.
- Pick the `MacXServer` scheme → **▶ Run**. Expect the status
  menu bar item + Dock icon.

Both `.app` bundles end up in
`~/Library/Developer/Xcode/DerivedData/MacXServer-*/Build/Products/Debug/`.
Drag them into `/Applications/` (or wherever) once you're happy
with them.

## What stays the same

- `swift build` keeps producing the SPM binaries
  (`.build/release/swiftx-server`, `.build/release/swiftx-capture`)
  for CLI workflows.
- `swift test` is unchanged.
- All run scripts (`run-server.sh`, `run-capture.sh`,
  `run-all.sh`) keep working — they use the SPM binaries.

The `.app` bundles are additive. CLI usage and `.app` usage are
parallel paths to the same code.

## Troubleshooting

**Asset-symbol collision** ("ambiguous use of 'AppIcon'") — if
this comes up despite the build-setting tweaks in 4e, the
folder reference is creating both `Icons/AppIcon.appiconset` AND
Xcode-synthesised symbols. Confirm "Generate Asset Symbols" is
**No** in both targets' Build Settings.

**`@main` collision** ("ambiguous candidates for `main()`") —
means `main.swift` wasn't excluded from the target. Re-check
target membership of `Sources/SwiftXCapture/main.swift` and
`Sources/SwiftXServer/main.swift`.

**Window still doesn't show** — confirm the activation hook is
firing by checking the app's Dock icon. If the Dock icon shows
up but no window appears, the asset-catalog or Info.plist isn't
being picked up; verify CFBundleExecutable is `$(EXECUTABLE_NAME)`
and NSPrincipalClass is `NSApplication`.

**Linker errors about Framer / SwiftXCaptureCore** — the package
dependency wasn't added to the right target. Project → target →
General → "Frameworks, Libraries, and Embedded Content" →
verify the libraries are listed.
