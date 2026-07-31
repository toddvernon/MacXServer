# Guest OS profile

macXserver drives three emulated guest OSes — Solaris 2.6, SunOS 4.1.4,
NetBSD/sparc — plus IRIX 6.5 on real SGI hardware (external hosts only;
qemu-system-sparc can't emulate a MIPS SGI), and a lot of what the host does
*differs by OS*. This doc is the single place that enumerates those
differences, and the rule that keeps them from drifting.

## Why this exists

On 2026-07-05 a shutdown request against a SunOS 4.1.4 guest silently did nothing.
Root cause: the Helios daemon hardcoded the **Solaris** halt (`/usr/sbin/init 5`),
which doesn't exist on BSD SunOS, so `system()` returned 127 and no-op'd — and
nothing surfaced the failure. The deeper problem wasn't that one command; it was
that per-OS behavior lived as **scattered string literals** with no forcing
function, so fixing the boot path (disk unit, boot-command, ports) didn't make
anyone look at shutdown. These are three genuinely different operating systems;
"assume Solaris" is a bug, not a default.

## The rule

**Every host behavior that differs by guest OS is a property on `MachineOS`
(`Sources/SwiftXServerCore/Machine.swift`), computed with an exhaustive `switch`.**

Swift refuses to compile a non-exhaustive `switch`, so:
- adding an OS won't build until every property has a case for it, and
- adding a new divergent behavior forces you to answer it for every OS.

IRIX (2026-07-31) proved the forcing function works: adding `.irix65` walked
the compiler through every per-OS behavior in one pass. It also added the
`emulatable` flag — an external-host-only OS answers the emulation-only
properties (boot disk, boot command, console markers, progress transcripts)
with clearly-commented inert values, and `emulatable` gates the surfaces that
must never see it (bundled fixtures, starter-image download, the emulated-VM
OS pickers).

That converts a silent runtime gap into a compile error. Do **not** reintroduce a
hardcoded Solaris path/command/marker on a guest-interaction path; add a property
to the profile and switch on it. `QemuEngineConfig` carries a single `os` and
derives everything from it (`config.profile`), so the engine has one per-OS input.

## The matrix (current values)

| Behavior (`MachineOS`)      | Solaris 2.6            | SunOS 4.1.4            | NetBSD                 | IRIX 6.5               |
|-----------------------------|------------------------|------------------------|------------------------|------------------------|
| `emulatable`                | yes                    | yes                    | yes                    | **no** (real SGI only) |
| `displayName`               | Solaris 2.6            | SunOS 4.1.4            | NetBSD                 | IRIX 6.5               |
| `bootDiskUnit` (ESP target) | 0                      | **3** (target↔sd swap) | 0                      | *(inert)*              |
| `bootCommand`               | *(default auto-boot)*  | `boot …esp/sd@3,0`     | `boot …esp/sd@0,0`     | *(inert)*              |
| `ports` (telnet/ssh/helios) | 2123/2222/2125         | 2133/2232/2135         | 2143/2242/2145         | 23/22/2125 (real LAN)  |
| `shutdownCommand`           | `/usr/sbin/init 5`     | `/usr/etc/halt`        | `/sbin/halt`           | `/etc/shutdown -y -g0 -i0` |
| `cleanHaltMarkers`          | "syncing file systems" | +"halted" *(guess)*    | "syncing disks"… *(guess)* | *(inert)*          |
| `fsckStallMarkers`          | "RUN fsck MANUALLY"    | "RUN fsck MANUALLY"    | +"RUN fsck_ffs MANUALLY" | *(inert)*            |
| `xBinDirs` (X PATH)         | openwin:dt:X11         | openwin:X11 (no CDE)   | /usr/X11R7/bin         | /usr/bin/X11           |
| progress transcripts        | 2026-06-23 capture     | 2026-07-07 capture     | 2026-07-07 capture     | *(inert, empty)*       |

The per-OS admin tables ride the same forcing function outside `MachineOS`:
`ClockAdmin` (IRIX: `/sbin/date`, SVR4 grammar — both set forms verified live
on the Indigo 2026-07-31) and `UserAdmin` (IRIX: unshadowed `/etc/passwd`
4.1.4-style, homes in `/usr/people`, SGI reserved names; all probed on the
Indigo 2026-07-31 over helios).

Notes:
- *(inert)* = IRIX is never emulated, so the value can't be consumed; the
  case exists only to satisfy the exhaustive switch and says so at the
  call site. `detect()` maps both `IRIX` and `IRIX64` kernels to `.irix65`
  (64-bit kernels report IRIX64; same 6.5 userland).
- `shutdownCommand` is consumed **guest-side** by the daemon via `HELIOS_SHUTDOWN_CMD`
  (set per-OS in the guest-config deploy). The profile is the host-side source of
  truth the deploy must match; see SHORTCUTS "Helios shutdown per-OS".
- `cleanHaltMarkers` only *labels* a stop clean-vs-crash; qemu exiting is the
  authoritative stop signal. The BSD phrases are best-effort — verify against real
  console output and tighten. A miss mislabels; it never hangs.
- The boot/shutdown progress-bar transcripts live in `ProgressReference`
  (`BootProgressReference.swift`), not on `MachineOS` — they're multi-line
  pastes, not one-liners — but they switch exhaustively on `MachineOS`, so the
  forcing function is the same: a 4th OS won't compile until it brings its own
  capture. Retuning a bar is pasting a fresh capture (trim variable lines:
  dates, MACs, memory sizes, pids; NetBSD `[ n.nnn]` kernel timestamps are
  stripped by the parser). Before 2026-07-07 only the Solaris transcript
  existed, so a BSD boot moved the bar through the shared OpenBIOS prelude and
  then parked it for the whole kernel + userland bring-up.
- Guest MAC derives from the machine id as of P2 (2026-07-06) — per-machine,
  no longer the shared `DE:AD:BE:EF:F3:E5` hardcode.

## The audit (run it when adding an OS, or periodically)

Detective pass — grep the guest-interaction surface for Solaris literals that
should be profile properties:

```sh
grep -rnE "init 5|/usr/sbin|/usr/openwin|/usr/dt|/usr/etc|syncing file systems|SUNW" \
  Sources/SwiftXServerCore Sources/SwiftXServer
# and the daemon:
grep -rnE "init 5|/usr/sbin|uname|halt" ~/Dropbox/dev/cx/cx_apps/heliosAgent/*.cpp
```

Any hit on a runtime path that isn't already `config.profile.<x>` / a `MachineOS`
property is a candidate gap. The preventive pass is structural: is the behavior a
profile property with an exhaustive switch? If not, make it one.

## Companion: no silent guest-command failures

The other half of the 2026-07-05 bug was silence. Two guards:
- **macXserver** — the shutdown path has a watchdog (`shutdownBudget`): if the
  guest hasn't gone down within the budget after an ACK'd shutdown, it surfaces
  "guest didn't halt — use Force Quit" instead of hanging (mirrors the boot
  readiness budget).
- **Daemon** — `performShutdown` should check `system()`'s exit and log a failed
  halt (cx follow-up; tracked in SHORTCUTS).
