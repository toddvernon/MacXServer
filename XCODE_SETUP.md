# Xcode Setup

The Xcode workspace wraps the two SPM executables in `.app`
bundles so they launch from Finder with proper icons, dock
activation, and Xcode debugging.

The SPM `Package.swift` is the canonical source of truth for
sources and dependencies. The Xcode project is generated from
`project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and reads the same files in `Sources/`. The `.app` bundles are
purely additive — `swift build` and `swift test` keep working.

## TL;DR

```sh
brew install xcodegen          # one-time, if not already installed
xcodegen generate              # rewrites MacXServer.xcodeproj
open MacXserver.xcworkspace    # workspace pulls in both the
                               # xcodeproj and Package.swift
```

Pick the scheme (`macxcapture` or `MacXServer`) and hit ▶.

## What's where

- `project.yml` — XcodeGen declaration of the project. **Edit
  this**, not the `.xcodeproj`. Rerun `xcodegen generate` after
  any change.
- `MacXServer.xcodeproj/` — generated. Committed for
  clone-and-open convenience, but treat it as a build artifact:
  don't edit settings in Xcode's UI, change `project.yml` and
  regenerate.
- `MacXserver.xcworkspace/` — workspace that holds the
  `.xcodeproj` and references `Package.swift` side-by-side so
  you can run the apps from Xcode and still browse / edit the
  SPM targets in the same window.
- `Xcode/CaptureMain.swift`, `Xcode/ServerMain.swift` — the
  `@main` entry points for the `.app` targets. Each is a
  one-liner that calls into the shared code.
- `Xcode/Capture-Info.plist`, `Xcode/Server-Info.plist` — Info.plists
  for the two app bundles.
- `Xcode/Assets.xcassets/` — asset catalog with `AppIcon`. The
  icon files themselves still live in `Icons/AppIcon.appiconset/`
  — `Xcode/Assets.xcassets/AppIcon.appiconset/` is a copy.

## Targets

Three frameworks + two apps, all wired in `project.yml`:

| Target              | Type        | Sources                        |
|---------------------|-------------|--------------------------------|
| `Framer`            | framework   | `Sources/Framer/`              |
| `SwiftXCaptureCore` | framework   | `Sources/SwiftXCaptureCore/`   |
| `SwiftXServerCore`  | framework   | `Sources/SwiftXServerCore/`    |
| `macxcapture`    | application | `Sources/SwiftXCapture/` (minus `main.swift`) + `Xcode/CaptureMain.swift` |
| `MacXServer`        | application | `Sources/SwiftXServer/` (minus `main.swift`) + `Xcode/ServerMain.swift` |

`main.swift` is excluded from each app because `@main` can't
coexist with a top-level `main.swift` in the same module. The
SPM executable target still uses `main.swift` — both entry
points are kept in sync because they delegate to the same
shared functions (`SwiftXCaptureApp.main()` and
`ServerEntry.run()`).

## What stays the same

- `swift build` → the SPM CLI binaries
  (`.build/release/macxcapture`, `.build/release/macxserver`).
- `swift test` is unchanged.
- All `run-*.sh` scripts work as before — they use the SPM
  binaries, not the `.app` bundles.

The `.app` bundles end up in
`~/Library/Developer/Xcode/DerivedData/MacXServer-*/Build/Products/Debug/`.
Drag them into `/Applications/` once they're working the way
you want.

## When to regenerate

Run `xcodegen generate` after any of:

- Edits to `project.yml`
- New source files added under `Sources/` (XcodeGen picks them
  up from the directory; you don't have to list them, but the
  project does need to be regenerated to see them)
- Adding/removing Info.plist keys (edit the plists, regenerate
  to pick up changes the build settings reference)

If you add files via Xcode's UI by mistake, they'll be wiped
out on the next regenerate. Add via the filesystem instead.

## Troubleshooting

**"bundle format unrecognized" during codesign of a framework**
— the framework is missing its Info.plist. Confirm the
framework target has `GENERATE_INFOPLIST_FILE: YES` in
`project.yml`.

**Empty `Contents/Resources/` in the .app** — the asset
catalog wasn't found. Confirm `Xcode/Assets.xcassets/AppIcon.appiconset/`
is a real directory (not a symlink — `actool` silently skips
symlinked appiconsets).

**`@main` collision ("ambiguous candidates for `main()`")** —
`main.swift` wasn't excluded from the app target. Check the
`excludes:` lines in `project.yml`.

**"Library not loaded" at runtime** — framework wasn't embedded.
Check the `dependencies:` lines for `embed: true`.
