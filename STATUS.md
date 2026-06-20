# Status 2026-06-20 (end of day)

Built **L1 of the orphan-safety work**: a host-aware image lock that prevents
two qemus from opening the same qcow2 (corruption) and handles the
Xcode-stop / crash orphan footgun. Also fixed the guest backspace mismatch
the right way (erase `^H` in tcsh). Yesterday's shared-folder (TFTP) feature,
Debug code-signing fix, and Preferences-dialog fixes are in and green.

## What landed today

**Image lock (PLUGIN_V1_PUNCHLIST L1).** `ImageLock` / `ImageLockManager` in
SwiftXServerCore: an advisory, **host-aware** lock written next to the qcow2.
It sits beside the image (not Application Support) so both Macs sharing it via
Dropbox see the same lock, and it records the **hostname** because a pid from
the other Mac is meaningless here. `QemuEngine` acquires it (with the qemu
pid) on start, releases on clean exit. `AppDelegate.launchSparcStation`
pre-flights via `evaluate()`:

- free → boot
- staleSameHost (our host, dead pid) → reclaim + boot
- remoteLocked (other host) → **hard stop**, Reveal-Lock-in-Finder (user
  deletes it; we never touch another Mac's lock)
- localOrphan (our host, live pid verified as our qemu) → dialog:
  **Try to Shut It Down** (best-effort `init 5` over the 2123 telnet hostfwd,
  success = the pid dying, ~35s timeout → manual fallback), **Force Quit**
  (re-verifies `proc_pidpath` before SIGKILL so a recycled pid is never
  killed), **Show Me How** (manual telnet steps), **Cancel**.

10 unit tests pin the decision tree + parse/serialize + release-by-host.
Committed `770566c`.

**Guest backspace fix (done right).** The Mac's Delete key sends `^H`; the
guest's tty erase was stuck on the Solaris default (DEL) because **tcsh never
reads `/etc/profile`** (where the baseline sets `erase ^H`). Fix: `stty erase
'^H'` in the seed `tftproot/dot.tcshrc`, where tcsh actually reads it — both
the Mac terminal and the Sun's xterm send `^H`, so no conditional needed.
Lesson logged: two independent input layers (kernel cooked-mode tty erase vs.
the shell's own editor), so the shell is always fine and only cooked-mode
programs like `tftp>` need the erase char to match the key.

**OpenSSH on the 2.6 image.** Got OpenSSH 5.1p1 running on SUN40G.qcow2 ->
`scp -P 2222` file-out (retires the FTP-volume workaround) + remote shell.
Verified from the Mac: `SSH-2.0-OpenSSH_5.1` banner, full crypto
negotiation, sshd offering auth. The fiddly parts are scripted in `guest/`:
`get-openssh.sh` (wget the matched set on the guest), `add-openssl098-libs.sh`
(coexist the required 0.9.8 libs beside the installed OpenSSL 1.0.0 -- soname
trap), `sshd-init.sh` (prngd + sshd boot rc), plus `check-tools.sh` (the
Helios tool inventory). Mac-side `~/.ssh/config` got a `Host sparcplug` block
with the legacy algorithms modern macOS needs. Full writeup in
SPARCSTATION_PLUGIN.md; recipe saved to memory.

**SSH key auth + a password gotcha that became a decision.** Passwordless
key auth now works (dedicated `~/.ssh/sparcplug_rsa`, installed into the
guest via tftp — modern macOS `scp` *push* fails to the 2008 sshd, needs
`-O`). `ssh sparkplug` / `scp sparkplug:/path .` are passwordless and
verified. But setting a root password (needed earlier for ssh, before key
auth) **broke macXserver's console auto-login** — `QemuEngine` types `root`
with no password step, so a cold boot would stall at `Password:` and the
console-driven `init 5` shutdown would break with it. Tactical fix:
`passwd -d root` (passwordless console restored; verified `root::` in
/etc/shadow over key auth). Strategic fix logged as **DECISIONS 2026-06-20**:
the console is observation-only; control (shutdown) moves to ssh-key now /
the Helios agent later, and the console auto-login gets dropped. Tracked as
**L0** in the punch list. Switchover-to-the-Studio checklist saved to memory.

## What's working / verified

- macXserver app + X server + bundled engine: green. `swift build` +
  `swift test` clean (20 SwiftXServerCore tests incl. 10 new lock tests; 2
  live engine tests skipped by design).
- Shared folder (TFTP): verified moving `set-hostname.sh` and the dotfiles
  into the guest. Backspace now works in `tftp>` after the seed fix.
- Image lock: unit-tested. NOT yet exercised live (Todd to test: Run →
  stop debugger to orphan qemu → Run again → expect the orphan dialog).
- OpenSSH: key auth (ssh + scp) verified passwordless from the Mac; root
  console passwordless again so macXserver auto-login still works.

## What to do next (orphan-safety continued)

- **L0 — drop console auto-login** (DECISIONS 2026-06-20). Move graceful
  shutdown to ssh-key / the Helios agent; delete the `login:`-scraping so the
  console is a pure glass-TTY. Decouples macXserver from the guest password
  policy. Pairs with L3.
- **L2 polish.** Progress feedback during the ~35s telnet-shutdown poll
  (currently silent), and a **Reconnect** action for a live orphan — the
  latter needs L3.
- **L3 — console + control on unix sockets.** Move off the `-nographic`
  stdio pipe (`-serial unix:`, `-qmp unix:`) so a relaunch can re-attach an
  orphan's console and drive `init 5` reliably (telnet often can't auth root
  on 2.6). Unlocks L2's Reconnect.
- **L4 (optional) — kqueue watchdog.** True prevention of the orphan
  (survives parent SIGKILL); new helper binary, needs maintainer sign-off.

Plus deferred polish: wrap all Preferences tabs in ScrollView (only
SPARCstation done); final text/sizing sweep; `tvernon`'s `.tcshrc` still
needs the `stty erase '^H'` line if Todd admins from that account.

## Pointers

- Orphan-safety tracker: `PLUGIN_V1_PUNCHLIST.md` (Lifecycle → L1–L4).
- Lock file lives at `<image>.macxserver-lock`, next to the qcow2 (Dropbox).
- Shared folder default: `~/macXserverTFTP`. Guest pull: `tftp 10.0.2.2`,
  `binary`, `get <file>`.
- Image + autobackup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ dated sibling).
