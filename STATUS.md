# Status 2026-07-07

## Headline: heliosAgent 0.2.0 (sysinfo verb) shipped + validated on all three guests. macXserver grew the whole admin plane: Admin Agents on the Overview (File Transfer + DNS), a 3-minute helios prober driving external dots + a live System line, OS auto-detect from the box's own uname, and the admin-verb availability rule. Plus a big console/UX day: per-OS boot-progress transcripts, the console-slowness mystery SOLVED (it was never the UART), barber-pole thermometers, launcher-def slimming. ONE PINNED REGRESSION: telnet launchers (see below).

## What's working / done this session

### heliosAgent 0.2.0 (cx repo, commit 12741e7)
- New `sysinfo` verb: uname, hostid, memMB, swap, load, disk fullness, guest
  clock, agent uptime. Fork-free by design (syscalls/libc; nlist + /dev/kmem
  on SunOS 4, the ps/pstat technique). Every field independently optional --
  a failed collector omits its field, verb always ok:true, hello untouched as
  the liveness signal. The agent gates everything, so stats can never make it
  worse; the SunOS bogus-kernel fault drill proves it (fields absent, agent
  fine).
- Built + unit-tested on macOS (155/0), NetBSD (155/0), Solaris 2.6 (151/0),
  SunOS 4.1.4 (151/0); deployed to all three guest images; every number
  cross-checked against native tools. SunOS C++ gotcha recorded: K&R headers
  declare struct statfs/nlist but not the functions -- extern "C" prototypes
  required.
- Todd installed 0.2.0 on the real SS5 (ss1.vernon.com). Secret file is in
  /etc/helios/helios.json; the agent reads it ONCE at startup, so it needs a
  restart after the file lands (/etc/init.d/heliosAgent restart) -- was
  pending at session end, orange dot until then.

### macXserver admin plane (swift-x)
- **Admin Agents section** on the Overview: File Transfer (the helios file
  browser, no launcher config needed anymore) and DNS (moved here from
  Settings). Availability rule (DECISIONS 2026-07-07): admin verbs need the
  box ANSWERING over helios (emulated = ready; external = last probe's hello
  succeeded, which under fail-closed auth also proves the secret), plus a
  known OS for OS-sensitive verbs (DNS).
- **Helios prober**: every 3 min (plus at launch, after mutations, secret
  changes, guest-ready) hellos every candidate box off-main. External dots:
  green = agent answering, orange = agent alive but REFUSED THE SECRET (very
  actionable), hollow red = not responding, gray = never probed. sysinfo
  feeds a monospace System line on the Overview (uname, MB, load, swap %,
  fullest disk, clock drift vs the Mac).
- **OS auto-detect**: an external box's sysinfo uname maps to MachineOS and
  auto-populates + locks the Settings OS picker ("Detected from the machine
  over Helios"); manual picker remains for pre-0.2.0 agents. Stale-draft
  protection so an open form can't clobber it.
- **DNS window works on external hosts now** (was hardcoded loopback +
  emulated-engine secret; host/secret/port providers all read live).
- DISPLAY field placeholder shows what blank actually resolves to (this
  server's address), still editable.

### Launcher definition slimmed + editor safety
- Per-launcher `display` and `fileBrowser` are GONE (machine DISPLAY is the
  only level; File Transfer is automatic). Legacy keys ignored/dropped on
  load; old launcher-file migration skips filebrowser entries. Editor is
  name/command/transport/verbose/password.
- machine-level `shellPrompt` field reintroduced (Settings > Connection >
  Prompt, shown when telnet is in play): the per-launcher shell_prompt key
  died with the old launchers file and the hardcoded "$ " default is sh-only.
  Telnet launcher also auto-detects classic sigils ($ % # >) AND the fleet's
  bracket csh prompt "[host:[user]:/cwd] ".
- Launcher delete now confirms (the minus used to delete instantly).
- Every launch captures a bounded transcript; a failing launch WITHOUT the
  verbose window shows the last ~14 lines in the error dialog.

### Console + boot UX (morning half)
- **Console slowness SOLVED**: never the UART. QemuEngine.ingest was doing an
  8KB tail re-copy + ~55 substring scans PER BYTE (qemu's ESCC delivers
  byte-sized chunks), forever, even after ready. Now: marker work only while
  booting/shutting down, scans only on newline chunks, lazy tail trim,
  shutdown clears the tail. cm/vi in the console is now iTerm2-class.
- **Per-OS boot/shutdown progress transcripts** (was Solaris-only, so BSD
  boots parked the bar after OpenBIOS): ProgressReference switches
  exhaustively on MachineOS; NetBSD kernel timestamps stripped by the parser;
  pid/hostname traps documented in the tables.
- Barber-pole thermometer (yellow/dark diagonal stripes, clock-locked shimmer)
  in the Overview AND console windows while booting/shutting down; console
  "Booting" dot yellow (was blue); "115200 baud" removed from console titles
  (the ESCC doesn't pace); terminal grid got an 8pt black margin; file
  browser is a normal window (was a hide-on-deactivate panel -- couldn't drag
  from Finder).
- Machines-window "Publishing changes from within view updates" fixed
  (deferred List selection binding + deferred commit publish).
- **Memory setting removed entirely**: every VM gets the SS-5's 256MB max
  (qemu sun4m ceiling; DECISIONS 2026-07-07). Legacy memoryMB key ignored.
- Xcode gotcha fixed + noted: deleting a source file needs `xcodegen` in the
  same change (pbxproj is generated + tracked).

## What's broken / open

- **PINNED REGRESSION -- telnet launchers vs the real SS5.** Login + password
  go through (Keychain), but the dialog transcript shows NO prompt bytes
  arriving after the SunOS banner within the 15s window, so "timed out
  waiting for shell prompt" even after the bracket-prompt detection landed.
  Needs a live byte-level look at what follows the banner (telnetd
  negotiation? buffered echo? build staleness?). The transcript-in-dialog
  feature is the tool for the job. Todd: "sort out later."
- SS5 agent restart pending (see above) -- orange dot until done.
- swift test 1500 pass, swift build clean. REBUILD IN XCODE (many UI + model
  changes).

## What's next
- The pinned telnet regression (first, it blocks SS5 launchers).
- SS5: restart agent, watch dot go green + OS auto-populate + System line.
- MCP bridge (still the standing next lead).
- Image download implementation per IMAGE_DOWNLOAD_PLAN.md.
- Console windows are still hide-on-deactivate utility panels (same class as
  the file-browser fix) -- convert if it annoys.

## Committed this session
- swift-x: see git log 2026-07-07 (console/boot UX commit + admin plane
  commit on top of daab448).
- cx heliosAgent: 12741e7 (sysinfo 0.2.0) + SYSINFO_PLAN.md.
- SPARCplug: no changes.

## Switching Macs
- Laptop is synced as of the evening 2026-07-07 session: pulled to ec06df2,
  reran xcodegen (no pbxproj drift), ready to build in Xcode. The desktop was
  already pushed.
- Let Dropbox finish syncing memory + the cx tree (memory got: sysinfo verb,
  launcher-format update).
- All guest VMs are powered off, no image locks. The real SS5 (ss1) runs
  agent 0.2.0 with /etc/helios/helios.json secret "test" -- restart its agent
  if not already done.
