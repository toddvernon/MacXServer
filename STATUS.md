# Status 2026-07-06

## Headline: P2 concurrency SHIPPED. N machines run at once with per-machine engines, consoles, sticky ports, and derived MACs. Plus a big UI polish pass from live testing, a state-vs-editability audit, and the image-download design settled.

One long session, one theme: the multi-VM runtime (the refactor doc's P2,
deferred milestone #6) went from open question to shipped and polished. Todd
live-tested all three guests booting concurrently on this Mac during the
session.

## What's working / done this session

### P2 concurrency (swift-x -- the big one, ab998ea)
- Every emulated VM has full lifecycle; any number run at once. Fresh
  MachineController per start built from machine.makeEngineConfig() (image /
  memory / ports / MAC / OS all off the machine; makeSparcConfig and the
  Preferences image sync are deleted; sparcplug.diskImagePath is
  migration-read-only legacy now).
- Per-machine console windows keyed by machine id -- the console follow/steal
  bug is structurally gone. Per-machine DNS admin windows too.
- **Sticky port assignment** (Todd's call: "dynamic by assignment time, not by
  invocation"). User VMs get ImagePorts.block(n>=5) = 21n3/22n2/21n5 assigned
  ONCE by the registry and persisted; bundled fixtures keep deriving their
  well-known per-OS blocks 2-4; clones get fresh blocks; start-time
  portConflict guard covers hand-edited JSON.
- Guest MAC derives from machine id (02: + five id bytes) -- the shared
  DE:AD:BE:EF:F3:E5 duplicate-MAC latent bug is dead.
- **/tmp/sparkplug is retired** (toggle + Config window + plumbing deleted).
  The image lock now records heliosPort next to the secret, so the lock is
  the complete reach-the-daemon handle and the interim Claude channel until
  the MCP bridge. HeliosClient requires an explicit port. snapshot() carries
  heliosPort as bridge groundwork.
- Whole-fleet flows: launch orphan scan per machine, quit dialog covers N
  running guests, per-machine autoBackup (was the global pref).
- DECISIONS.md 2026-07-06 entry; SHORTCUTS P1-transitional entries closed;
  MACHINE_MANAGER_REFACTOR.md "Shipped 2026-07-06" section.

### UI polish rounds (Todd live-testing, ~9 commits)
- Runtime section (ports + MAC, monospace, selectable) + Machine DNS section
  (Edit gated on ready) in Settings; DNS button removed from Overview.
- DNS window: titled per machine, Apply dismisses on success, explicit
  Dismiss button (Esc). Todd's dialog conventions saved to memory.
- Section headers: dark blue, title3 semibold, air above; machine-name title
  outranks them (title2). Content inset 16pt under every section header;
  transport pickers left-aligned (frame-centering bug).
- Menu bar "Server" -> "X11Server". Overview states capitalized. Status dot
  dropped from Overview; boot/shutdown **thermometer** added instead (yellow
  while moving, green at ready, recedes through shutdown).
- **No console auto-pop** on start/stop/reconnect (consoles are created
  silently so they record from byte one; boot-stalled still pops). Launch
  reconnect is ONE dialog for all orphans; reconnected consoles get an
  injected "** reconnected to console **" banner with the lock's instance
  facts (the old diagnostic went down a path the terminal never rendered --
  that was the black-window mystery).
- "X11 Launchers" section name; Overview byline has a blue Edit link that
  hops to Settings.
- Bundled fixtures seed the seven-color xterm palette (from the ipc set, no
  passwords); Todd's live machines.json seeded by hand in the same change
  (backup at ~/.macxserver-machines.json.bak-xterm-seed).

### State-vs-editability audit (pre-test-phase deep dive, 524a310)
Seven findings, all fixed: kind/OS frozen while live; host locked on all
emulated VMs; the stale-draft race closed (commit() drops runtime-frozen
edits -- a Return could previously swap the image under a running qemu and
poison the termination auto-backup); ALL launcher transports gate on ready
for emulated machines; kind flip emulated->external sheds the port block;
removing a machine closes its console/DNS windows. Matrix recorded in
SHORTCUTS under "Machine editor: validation gaps".

### Fool-proof image attach + download design (af8cd85, 4dd181c)
- Bundled fixtures now REFUSE a picked image whose detected OS mismatches
  (used to silently mutate the fixture's OS).
- IMAGE_DOWNLOAD_PLAN.md: per-OS catalog on **oldsilicon.com** (settled: all
  three OSes ship -- Todd already distributes them there for ZuluSCSI),
  zero-choice bundled download (only knob is a global images dir),
  identity-derived filenames so a user can download a second copy and run
  two NetBSDs, three-layer verification (gz sha256, raw sha256, banner
  check). Build after the test phase (~a day + SPARCplug build-catalog.sh).

### SPARCplug: emu-script port preflight (ef32e68)
emu/portcheck.sh (sourced like imagelock.sh) refuses to launch when the OS
block's ports are already bound (the same-OS-different-image clash the image
lock can't catch), naming the holder. Verified against a live listener.

## What's broken / open
- Nothing known-broken. swift build clean, **swift test 1482 pass**.
- Rebuild in Xcode to pick up everything (many UI changes since the last
  rebuild).
- SHORTCUTS still tracks: image collision warns-not-blocks at pick time,
  networkMode not editable (only slirp wired), external-host reachability
  dot, BSD cleanHaltMarkers best-effort.

## What's next
- **Todd's test phase** on the P2 build (the audit matrix in SHORTCUTS is the
  checklist).
- **MCP bridge** (next lead): consume MachineRegistry.snapshot() (already
  carries heliosPort) + hand Claude per-machine secrets.
- Image download implementation per IMAGE_DOWNLOAD_PLAN.md (after testing).
- Deferred daemon items unchanged (-b bind-addr, accept() backoff, NUL
  truncation in cx/process).

## Committed this session (all pushed to origin/main)
- swift-x: ab998ea (P2), 87b4d20, fe36496, ea23102, 2a05b16, 26750f9,
  7a83c81, c1df852, f7c74bf, e579c3f, 4d2da5c, 07a44e2 (xterm seed),
  524a310 (audit), af8cd85 (mismatch guard + download plan), 4dd181c.
- SPARCplug: ef32e68 (port preflight).

## Switching Macs
- git pull on the other Mac; rebuild macXserver in Xcode there.
- Let Dropbox finish syncing the memory dir before opening the other Mac
  (memory got: machine-manager P2 update, /tmp/sparkplug retirement,
  dialog-conventions feedback).
- All guests are powered off; no image locks. Todd's machines.json has the
  seeded xterm launchers (pre-seed backup sits next to it).
- The real SS5 on the LAN still runs the 4.1.4 image with the fixed agent
  (secret "test"); leave its /etc/helios/helios.json alone on any redeploy.
