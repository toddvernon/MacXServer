# Status 2026-07-10

## Headline: menu-bar reorganization day. The macOS menu bar went from
macXserver / Edit / X11Server / Machines / Window to **macXserver /
Machines / Edit / X11Server** (Window deleted). The app menu was trimmed to
the macOS-standard minimum; server config editors and capture actions moved
to the X11Server menu where they belong. The TFTP "Shared Folder" feature
was removed entirely (menu, UI, prefs, and the VM launch wiring). The
Machines menu is now a dynamic live-launch surface -- only reachable
machines show. And the Helios prober sweep was parallelized. Suite green,
1503 tests. Earlier today: the prober aliveness-oracle work (see the
2026-07-10 DECISIONS entry).

## What happened this session (menu-bar work)

Three logical changes, all landed and building clean:

1. **Menu reorg.** New bar: macXserver / Machines / Edit / X11Server.
   - **macXserver** trimmed to standard (About, Acknowledgements /
     Preferences / Hide-Others-Show / Quit). The server config editors and
     capture items that used to clutter it are gone from here.
   - **Machines** promoted to the "File" slot (first app-specific menu) --
     it's the meat of the app, so it reads as primary.
   - **X11Server** absorbed the strays: status line / Drop All Clients /
     Edit Resources / Edit Font Mappings / **Capture** submenu (Open,
     Reveal Folder, Discard All -- captures are recordings of the X
     protocol stream, so they're server-adjacent).
   - **Window** deleted. With it went Cmd-M / Cmd-W (the X clients aren't
     documents; the standard window list added nothing here).

2. **Shared Folder (TFTP) removed, root and branch.** It was slirp's
   built-in TFTP server (guest pulls with `tftp 10.0.2.2`) -- useless for
   real files, and the Helios file browser is the daily path now. Deleted:
   the menu item, both UI files (`SparcConfigWindows.swift` +
   `SparcConfigModel.swift`, 225 lines, existed only for this), the
   Preferences keys / accessors / default dir, the `QemuEngine.tftpDirectory`
   capability + the `,tftp=` nic append + the `SPARCPLUG_TFTP_DIR` dev
   override, the `makeEngineConfig(tftpDirectory:)` param, the VM launch
   wiring in `engineConfig(for:)`, and the 3 covering tests. Net ~455 lines
   removed.

3. **Machines menu is dynamic.** New `machineReachableForMenu` gate: an
   emulated VM shows only when running AND ready; an external host shows
   unless the prober confirmed it unreachable (up / unknown / unauthorized /
   noAgent all still show -- a box you can reach some way). Stopped VMs and
   dead hosts drop off; start or add machines from the Machines window. If
   the registry is non-empty but nothing's reachable, a disabled "No
   machines reachable" line shows instead of a bare menu. Fixed a latent
   bug while here: the probe completion refreshed only the window
   (`refreshMachines`), not the menu -- promoted it to `refreshSparcMenu`
   so external-host visibility tracks probes live.

4. **Prober sweep parallelized.** `probeQueue` is now concurrent; a pass
   fans every job out at once (DispatchGroup + a lock-guarded
   `ProbeResultCollector`, `@unchecked Sendable`), and `group.notify` posts
   the batch on main when the slowest probe returns. A pass's wall-clock
   dropped from ~3s x hosts (up to ~30s+ with several dead boxes on the
   11-machine fleet) to ~one 3s timeout. Cadence unchanged (3 min + the
   event-driven immediate passes); only per-pass latency improved.

## What's working / what's broken

- swift build + swift test both green: 1503 tests, 0 failures (was 1506;
  the 3 removed tests were exactly the TFTP ones).
- **xcodegen was re-run** after deleting the two SparcConfig files -- the
  regenerated `.xcodeproj` has zero SparcConfig references, so Xcode opens
  clean.
- NOT yet verified in the real app: this is menu UI + deleted files, none
  of which `swift build` can visually confirm. Needs an Xcode rebuild +
  eyeball (see checklist below).

## Manual pass checklist (needs a human on the GUI)

- Rebuild in Xcode (model + UI changed; `MacXServer.xcodeproj`, not swift
  build).
- Eyeball the new menu bar: macXserver / Machines / Edit / X11Server, no
  Window menu. Confirm the app menu is trimmed and X11Server holds the
  config editors + Capture submenu.
- Confirm the Machines menu shows only reachable machines: boot a fixture
  VM and watch it appear once ready; stop it and watch it drop. Point at a
  live external host (ipc/ss5) and a dead one -- only the live one shows.
- Sanity-check that removing Shared Folder didn't break VM launch (boot a
  guest, launch an xterm).

## What's next

1. Todd's manual pass per the checklist above; fix anything it surfaces.
2. Back to X11 land: MCP bridge is the standing lead; image download per
   IMAGE_DOWNLOAD_PLAN.md behind it; CLIPBOARD/editres gaps in the feature
   matrix as the protocol-side alternative.

## Committed / push state

- This session's menu-bar work is committed on top of the 10 still-UNPUSHED
  commits from 2026-07-09 / the morning of 2026-07-10 (settings cleanup +
  prober aliveness oracle). **Nothing has been pushed from this Mac** --
  push before switching machines or the work is stranded here.
- SPARCplug, cx repos: no changes.

## Switching Macs

- Code + model + `.xcodeproj` changed: rebuild in Xcode on the other Mac
  before running (and it'll `git pull` the regenerated project).
- No VMs running, no image locks.
