# Status 2026-06-24 (end of day)

Built a new feature end to end and then hardened it against everything the live
test surfaced: a **per-launcher Helios file browser** for the bundled
SPARCstation. A launcher entry with `filebrowser = true` (helios transport)
becomes a "Files…" menu item that opens a single-pane browser of that launcher
`user`'s home directory on the Sun, with drag-to/from-Finder transfer. All
browse + transfer runs AS the launcher's user, not root.

Live-tested today: browse + both-way transfer work, and the daemon with the
file-verb run-as change is **deployed to the live Solaris image and verified** --
a `write_file` as tvernon landed owned by tvernon (uid 1000), not root, and a
file verb with a bogus user is rejected ("unknown user"). C8 is done.

## Headline (this session)

- **File browser shipped** (`FileBrowserWindowController`/`PanelView`/`Model`,
  DNS-editor shape). Single remote pane: folder/doc icons, dirs-first, `..` row,
  double-click navigation, path header, busy/error banner. Drag a file row out
  to Finder = lazy `get_file` download (file-promise callback); drag files in =
  `put_file` upload into the current dir. Opens at the user's `$HOME` (resolved
  via `run_command echo $HOME`). Menu wiring in `AppDelegate` (one cached window
  per launcher key).

- **Daemon: run-as-user on every file verb.** Lifted `run_command`'s privilege
  drop into `read_file`/`write_file`/`stat`/`list_dir`/`get_file`/`put_file` via
  a scoped `HeliosPrivGuard` (reversible `seteuid`/`setegid` + `initgroups`,
  restore root after). fork-per-connection makes the process-wide euid change
  safe. Fails closed -- unknown user or an incomplete drop is `ok:false`, never
  silently root. So a browse sees the user's own view and an upload lands owned
  by the user. `PROTOCOL.md` + `Verbs.h` updated. **131 daemon tests pass.**

- **HeliosClient: streaming transfer + user passthrough.** Swift
  `getFile(_:toLocalURL:user:)` / `putFile(fromLocalURL:toRemotePath:mode:user:)`
  mirroring the python streaming protocol (raw 64KB chunks), plus optional
  `user` on the line verbs. Factored `call()` into `sendRequest`/`readEnvelope`.

- **Launcher `filebrowser = true` flag.** New `LauncherEntry.fileBrowser`; a
  filebrowser entry needs no `command` (its item opens the browser). Three-edit
  rule done (parser + seed doc + Todd's dotfile).

### Fixes from the live test (same session)

- **Crash opening the browser** (`_dispatch_assert_queue_fail`): the pure static
  helpers (`sorted`/`join`/`parent`/`describe`) on the `@MainActor` model were
  called off-main from `load()`/`uploadAll()`. Marked them `nonisolated`.
- **Orphan "shutdown tried telnet to root":** it didn't -- both shutdown paths
  use Helios -- but the orphan call passed **no secret** (failed auth on the
  authed daemon) and the failure panel's copy still said "telnet root login."
  Fixes: **persist the per-boot secret in the lock file** (`ImageLock.secret`,
  backward-compatible) so a later process / the other Mac can authenticate to an
  orphan's daemon over Helios; reworded the panel + by-hand instructions (telnet
  as a user then `su`, since 2.6 refuses root telnet).
- **Upload overwrite warning:** dragging in now checks the in-memory listing and
  prompts Replace / Skip Existing / Cancel before clobbering. (Download stays
  Finder-native: Finder auto-renames to "file 2", never overwrites -- which is
  the safe behavior, left as-is.)
- **Solaris filename munge on upload:** `SolarisFilename.sanitize` maps spaces /
  shell metacharacters / non-ASCII to `_`, defuses a leading `-`, caps at 255.
  Banner reports renames ("Uploaded \u{201C}my file.txt\u{201D} as
  \u{201C}my_file.txt\u{201D}").
- **filebrowser on a non-helios key** (e.g. a `[u5/Files]` under telnet) used to
  silently fall through to a bogus empty-command telnet launch. Now it always
  wires to the browser action, and on a non-helios transport shows a clear
  wrong-transport config-error dialog (per-key; a sibling helios launcher
  doesn't make a telnet key browsable). Message is honest about real-box Helios
  being a future capability, not a bundle-only limit.

## What's working

- `swift build` clean; **full suite green: 1395 tests, 0 failures** (was 1381).
- Daemon builds clean on the Mac (`darwin_arm64`), 131 tests pass.
- Browser + both-way transfer validated live today.
- Xcode project regenerated (`xcodegen`) -- the new files are in the `.app` build.

## What's broken / not yet verified

- (Daemon redeploy DONE + verified live -- see above. No longer an open item.)
- v1 scope (deliberate): files only (no folder download/upload), no in-place ops
  (rename/delete/mkdir/chmod).
- Real-box Helios (a real Sun running the agent) is captured as **HELIOS_PLAN
  C9** -- blocked on a static per-launcher secret field + agent deployment to a
  real box. Not started.

## What's next

- Optional follow-ons: in-place file ops (rename/delete/mkdir/chmod), a
  size/permission column, folder download (tar-on-the-fly).
- HELIOS_PLAN C9 (real-box Helios: static launcher secret + agent deploy) and
  B6 hardening remain open.

## What's committed (recent)

- `~/dev/X`: file browser + daemon run-as (Swift side) + all the live-test
  fixes, STATUS, HELIOS_PLAN C8/C9. See the eos commit below.
- `~/Dropbox/dev/cx` (`cx_apps/heliosAgent`): file-verb run-as drop
  (`Verbs.cpp`/`Verbs.h`), `PROTOCOL.md`, daemon test. See the eos commit below.
- `~/dev/SPARCplug`: unchanged this session.

## Switching to the other Mac

- Let Dropbox finish syncing the memory dir + the cx tree before opening the
  other Mac (the qcow2 didn't change this session).
- `git pull` X **and** the cx tree (heliosAgent changed this session).
- VM is shut down, no image lock held by a live process.
- `/sos` first.

## Pointers

- Browser: `FileBrowserPanelModel.swift` (I/O + drag/drop + overwrite +
  filename munge), `FileBrowserPanelView.swift`, `FileBrowserWindowController.swift`,
  `AppDelegate.openFileBrowser` + `launcherMenuItem` + `validateMenuItem`.
- Daemon run-as: `cx_apps/heliosAgent/Verbs.cpp` (`HeliosPrivGuard` +
  `parseUserField`). Redeploy: `guest/get-helios.sh`.
- Swift transfer: `HeliosClient.swift` (`getFile`/`putFile`/`readBody`).
- Filename munge: `SolarisFilename.swift`. Lock secret: `ImageLock.swift`.
- Flag: `LauncherEntry.fileBrowser`, parsed in `LauncherFile.parse`.
