# Status 2026-06-21 (end of day)

The Helios daemon went from "validated but inert" to **installed, always-on, and
directly reachable from the Mac with no ssh in the chain.** It now autostarts as
a root boot service on the SPARCplug guest, and the Mac tool talks straight to it
over a qemu hostfwd. That's the simplification we were after: **Mac tool ->
daemon**, nothing in between. (Earlier today: two Macs converged on the
daemon being Mac-complete + Solaris-validated + a CLI bridge -- see the history
below.)

## Headline: the daemon is active and the chain is collapsed

- **Installed via `deploy.sh`** (run as root on the guest): binary ->
  `/usr/local/bin/heliosAgent`, init script -> `/etc/init.d/heliosAgent`, rc
  symlinks (`S98` start at multiuser, `K30` stop). It autostarts on boot --
  **proved it**: after a fresh VM relaunch the daemon came up on its own
  (`uptime` ~50s on a box "up 1 min", nobody started it), running as root.
- **Direct path live.** Added `hostfwd=tcp::2125-:2125` to macXserver's qemu args
  (`QemuEngine.swift`, new `heliosHostPort` constant). After rebuild + relaunch,
  `./helios hello` answers straight through `localhost:2125` with **no ssh
  tunnel**. The ssh `-L` scaffolding is retired.
- **Net effect:** the guest now has an always-on, root, directly-reachable
  control surface. I can read/write its configs and run commands with zero
  scaffolding -- the "help yourself on SPARCplug" capability is live.
- **`deploy.sh` fix:** the makefile names the Solaris build dir `sunos_` (ARCH
  comes out empty -- known make quirk), but deploy.sh expected `sunos_sun4m`. Now
  it globs `${OS}_*/heliosAgent`, so it works regardless. Patched on the Mac and
  the guest.

## Also new this session: /sos and /eos skills

Two project skills in `.claude/skills/` (ride Dropbox, so both Macs get them).
`/sos` = start of session: memory-symlink check, fetch + ff-pull every repo,
**stop on divergence/dirty** instead of plowing ahead, reorient from STATUS.
`/eos` = end of session (this): roll STATUS, selective commit + push every repo,
verify sync, Dropbox reminder, offer VM shutdown. Built because today's two-Mac
divergence came from starting work without pulling first.

## Where the daemon stands (cumulative)

- **All 8 verbs** implemented, 114 Mac tests, and validated on the real 2.6
  image (incl. write_file mode-preservation and a real root `init 5` shutdown).
- **Mac bridge** `~/dev/SPARCplug/helios/` (CLI + survey + client).
- **GNU grep 2.7 + pcre 8.10** installed for the `search` verb.
- **Architecture decided** (DECISIONS 2026-06-20 floor/ceiling, 2026-06-21
  topology peer-not-hub + C6 guided-admin GUI).

## What's committed (this roll pushes the last two)

- `~/dev/X`: `QemuEngine.swift` + test (2125 hostfwd) + this STATUS.
- cx tree `heliosAgent`: `deploy.sh` glob fix.
- Earlier today (already pushed): the merge `1167269`, shutdown 8/8, D1 bridge,
  topology decision; SPARCplug `26891c9`; cx `412b68a` / heliosAgent `a7c72e3` /
  cx-build `f24f4f6`.
- The install is baked into the working qcow2 (survived the reboot). Image rides
  Dropbox, so it syncs to the laptop.

## What's next

- **macXserver cleanup pass (Phase C) -- the next focus.** Now that there's a
  clean always-on daemon, retire the brittle bits: telnet/expect xterm launches
  (-> launcher-over-Helios, C7), console-scrape readiness (-> liveness, C3),
  console/telnet `init 5` shutdown (-> shutdown verb, C4), delete console
  auto-login (C5). Plus Swift `HeliosClient` (C1) over the same hostfwd.
- **Bake the install into the image *build*** (C2) so shipped copies have it,
  not just this working image.
- **Close M-B:** run the 114-test suite on the image (B6).
- **Two daemon hardening items** (HELIOS_PLAN D1): orphan-reap; shutdown
  euid-check + exit-status logging.

## Switching to the laptop (do before leaving)

- **Shut the VM down cleanly** so the image lock releases (laptop won't see
  `remoteLocked`) -- and so the qcow2 with the fresh daemon install flushes.
- **Let Dropbox finish syncing**: the modified **qcow2** (now has the daemon
  installed), the cx tree, and memory. The image sync is the big one.
- On the laptop, `/sos` first -- it'll pull X + the cx tree (heliosAgent's
  deploy.sh fix) before you start.

## Pointers

- Daemon source: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, test/,
  init/, deploy.sh). Installed on the guest at `/usr/local/bin/heliosAgent`,
  logs `/var/log/heliosAgent.log`, pid `/var/run/heliosAgent.pid`.
- Mac bridge: `~/dev/SPARCplug/helios/` -- `./helios hello` now works with no
  tunnel once the VM is up.
- qemu hostfwd: `QemuEngine.swift` (`heliosHostPort = 2125`).
- Plan: `HELIOS_PLAN.md`. Decisions: DECISIONS 2026-06-17 / 06-20 / 06-21.
- Image + backup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ `SUN40G backup
  2026-06-21.qcow2`). Lock: `<image>.macxserver-lock`.
