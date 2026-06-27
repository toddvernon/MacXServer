# Status 2026-06-27

## Headline: Acknowledgements screen + GPLv2 compliance, then SPARCstation Start/Stop menu fixes

Release-list burn-down. Built the in-app screen that credits every package,
license, and reference MacXServer ships or was built on; settled the GPLv2
source obligation for the bundled QEMU; then fixed the SPARCstation menu's
Start/Stop gating so "Shut Down" can't dead-end during boot and dim/undim
tracks live. All pushed.

## SPARCstation Start/Stop/Force-Quit menu (today, second half)

The bug Todd caught: "Shut Down SPARCstation" was selectable the instant qemu
launched (state goes `.running` immediately), but graceful shutdown is
daemon-only and the Helios daemon isn't up until ~end of boot -- so clicking it
mid-boot dead-ended into a "daemon unreachable, use Force Quit" no-op. Safe (no
corruption) but misleading. Fixed:

- **Shut Down** now gates on `state == .running && sparcReady` -- greyed through
  the whole boot, undims only when the daemon actually answers (same signal
  Admin/DNS use).
- **Force Quit SPARCstation...** promoted to a first-class menu item, enabled for
  `.running || .shuttingDown`, so there's always a stop path during boot or a
  wedge. Its confirm is now 3-button (Force Quit / Show Console / Cancel) and
  the text points at the console first -- "it's a real terminal now, recover by
  hand at the ok prompt or single-user."
- **Live dim/undim while the menu is open:** the SPARCstation submenu now has
  `autoenablesItems = false`; `refreshSparcMenu()` drives each leaf item's
  `isEnabled` directly from the engine callbacks (`onStateChange`, `onReady`,
  console-created). validateMenuItem no longer governs those items. Callbacks
  fire on `DispatchQueue.main` (QemuEngine emitState/onReady) and main-queue
  blocks run during menu tracking, so Shut Down undims under the cursor the
  moment boot completes. Todd verified live ("looks good").

## What's working (Acknowledgements, first half)

- **Acknowledgements screen.** `MacXServer -> Acknowledgements...`. Master/detail
  in an NSPanel via HSplitView (NOT NavigationSplitView -- it collapses the
  sidebar in a bare panel). Left list groups four ways; right pane shows a
  plain-English "how we use it" note, an upstream link, and the **full verbatim
  license text** embedded. Sidebar rows show a compact derived license tag; full
  label in the detail header.
- **License texts generated, not hand-typed.** `Tools/regen_licenses.py` reads
  canonical license files from this repo + the sibling SPARCplug checkout and
  emits `AcknowledgementsLicenseTexts.swift` (strips form-feed/control chars the
  GNU files carry).
- **GPLv2 corresponding-source: self-host (section 3a).** `GPL_SOURCE.md` is the
  canonical statement; screen + CREDITS.md point at it.
  `Tools/make-gpl-source-bundle.sh` assembles the complete corresponding source
  (unmodified `qemu-9.2.4.tar.xz` SHA-verified against `qemu.lock` + build
  scripts) into a ~129MB tarball ready to attach to a release. Tested.
- **CREDITS.md** refreshed to match reality.
- Both builds green throughout: `swift build` and full `xcodebuild`.

## What's working

- **Acknowledgements screen.** `MacXServer -> Acknowledgements...` (app menu,
  under About). Master/detail in an NSPanel via HSplitView, matching the
  ResourcesWindowController idiom. Left list groups components four ways (this
  app / bundled / transcribed / referenced); right pane shows a plain-English
  "how we use it" note, an upstream link, and the **full verbatim license text**
  embedded (works offline; satisfies the MIT/GPL "include this notice" duty).
  13 entries: libvterm, QEMU + its deps (libslirp, SoftFloat, keycodemapdb,
  OpenBIOS, GLib), the X11R6 code we transcribed, and the references we studied
  (XQuartz, X11 spec/ICCCM, Motif/CDE). Sidebar rows show a compact, derived
  license tag (parenthetical dropped, "Reference only..." -> "Reference",
  one line each); the full label stays in the detail header.
- **License texts are generated, not hand-typed.** `Tools/regen_licenses.py`
  reads the canonical license files from this repo and the sibling SPARCplug
  checkout and emits `AcknowledgementsLicenseTexts.swift` (64KB, 8 license
  bodies). Strips form-feed/control chars the GNU files carry so Swift accepts
  them. Re-run if any upstream license changes.
- **GPLv2 corresponding-source: self-host (section 3a).** `GPL_SOURCE.md` is the
  canonical source-availability statement; the screen and CREDITS.md both point
  at it. `Tools/make-gpl-source-bundle.sh` assembles the complete corresponding
  source (unmodified upstream `qemu-9.2.4.tar.xz` SHA-verified against
  `qemu.lock`, plus `build-qemu.sh`) into a ~129MB tarball ready to attach to a
  release. Script tested end-to-end.
- **CREDITS.md** refreshed to match reality (it predated QEMU/libvterm and still
  said "Adaptations: none yet").
- Both builds green: `swift build` and full `xcodebuild` -> BUILD SUCCEEDED.
  Screen visually verified by Todd after the HSplitView fix.

## Known rough edges / gotcha logged

- **NavigationSplitView does not work in the NSPanel-hosted SwiftUI windows** --
  sidebar collapses, content leaks under the titlebar. Use HSplitView. Saved to
  memory (`reference_navigationsplitview_in_nspanel`).
- **libslirp license text is a faithful reconstruction, not a verbatim pull**
  (GitLab blocks scraping; it's fetched at build via a meson wrap so it's not in
  the tree). The prominent upstream link covers the authoritative text. To make
  it verbatim, drop libslirp's COPYRIGHT into the SPARCplug tree and point the
  generator at it.

## What's next

- **MUST DO before any public QEMU-bundling release:** run
  `Tools/make-gpl-source-bundle.sh` and attach the tarball to the MacXServer
  GitHub release. Until it's posted, GPL_SOURCE.md / the screen promise a bundle
  that isn't live, so don't ship the bundled-QEMU build publicly without it.
  (The links light up the moment it's attached.)
- More release-list odds-and-ends (Todd was burning these down).
- **Carryover from session 5 (console terminal, untouched today):** scrollback
  (`sb_pushline`); cm alt-screen `?47->1047` vendored patch if it matters;
  reconcile terminal point-size/scaleFactor with FontResolver/XTERM_FONT_QUALITY;
  prune the unused ConsoleSanitizer.
- **Carryover bug:** xterm ctrl-button menu-orphan -- needs a capture past the
  ButtonRelease to confirm whether the menu window is left mapped.

## What's committed (recent; all pushed)

- `~/dev/X`:
  - (this session, final commit) SPARCstation Start/Shut Down/Force Quit menu
    gating + live `refreshSparcMenu()` enablement + STATUS roll.
  - `a1ed165` Acknowledgements: compact license tag in the sidebar rows.
  - `c47cca4` Acknowledgements screen + GPL_SOURCE.md + generator + bundle
    script + CREDITS refresh.
  - (session 5) `dbeac10`/`839e42c`/... interactive console terminal work.
- `~/dev/SPARCplug`: no changes today (read-only source for the license texts
  and the GPL bundle).

## Pointers

- Screen: `Sources/SwiftXServer/Acknowledgements.swift` (data),
  `AcknowledgementsView.swift` (HSplitView master/detail),
  `AcknowledgementsWindowController.swift`, `AcknowledgementsLicenseTexts.swift`
  (generated). Menu wiring in `AppDelegate.swift` (`openAcknowledgements`).
- License/GPL tooling: `Tools/regen_licenses.py`,
  `Tools/make-gpl-source-bundle.sh`, `GPL_SOURCE.md`, `CREDITS.md`.
- The Xcode project is XcodeGen-generated and committed: new files under a
  globbed source dir need `xcodegen generate` to land in the .xcodeproj.
