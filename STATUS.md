# Status 2026-06-23 (end of day)

Helios C2 (bake the daemon into the image build) is done and validated on the
live image. The auth loop from yesterday's hand-off is closed and verified
end-to-end. Phase C now has only C6 (guided sysadmin GUI) left.

## Headline: C2 complete + auth loop verified

- **Auth loop closed (verified live).** macXserver generates a per-boot secret,
  passes it via `-prom-env helios-secret`, and (with "Claude development" ON)
  writes it `0600` to `/tmp/sparkplug`. The guest reads it via `eeprom`, the
  daemon locks to it. Verified: wrong secret -> `unauthorized`, correct -> ok,
  fully hands-off (CLI auto-reads the file), run-as-user -> `uid=1000(tvernon)`.
- **C2 done -- `guest/get-helios.sh`.** Mac-side orchestrator that bakes the
  daemon into the image: build cx source tars (top-level cx makefile) -> ship to
  guest (helios `put_file` if the daemon's up, else `scp`) -> build cx libs +
  agent on the guest under g++ 2.95 -> `deploy.sh` (binary + S98/K30 rc links +
  restart). Build/install drive over `ssh sparcplug`, not helios, so the
  daemon's self-restart can't sever the connection. Validated end-to-end twice;
  final clean-first run came up locked straight from deploy.
- **Boot marker (C2 follow-on 1).** Init script echoes `heliosAgent started` to
  the boot console on a successful start -- a late-boot landmark coinciding with
  when `hello` first answers.
- The QemuEngine half of C2 (`hostfwd=tcp::2125-:2125` + `-prom-env` secret) was
  already in place from the 2026-06-22 work.

## Two bugs caught during validation (both fixed)

- **eeprom-on-PATH.** The deploy-time restart needs `/usr/sbin` on PATH or the
  init script can't read the secret and the daemon comes up silently UNLOCKED
  (only a one-line `eeprom: not found`). Fixed: `get-helios.sh` exports
  `/usr/sbin:/sbin`. Boot rc env already has it, so a real reboot was never
  affected -- only the deploy-time restart.
- **Stale `.o` on re-run.** Untarred source carries its Mac mtime (older than a
  prior run's guest `.o`), so `make` would skip the rebuild and redeploy a stale
  binary. Fixed with Todd's clean-first pattern: clean libs, build all, clean
  agent, build agent. `make` (no target) is correct -- the cx makefile is
  platform-aware and skips what g++ 2.95 can't compile (tz/cctz/regex/thread).

## What's working

- macXserver: auth loop live; daemon locked + enforcing on the running guest.
- `get-helios.sh`: full from-scratch / upgrade path, validated on the image.
- `~/dev/SPARCplug/helios` CLI: hands-off auth via `/tmp/sparkplug`.

## What's broken / rough edges

- Testing lock state: the python client falls back to reading `/tmp/sparkplug`
  when `HELIOS_SECRET` is unset/empty, so "no-secret hello" silently sends the
  file's secret once Claude-dev is ON. The honest negative test is a WRONG
  `HELIOS_SECRET` (env beats the file). Bit me once this session.
- Self-deploy's final ACK can still be lost when the daemon restarts itself
  (cosmetic; verify with a fresh `hello`). Auth's plaintext-on-wire is a
  loopback speed-bump, not crypto (HMAC/TLS is the documented upgrade).

## What's next

- **C6:** the guided-sysadmin GUI (Phase 0.5) -- the last Phase C item.
- **B6** (daemon `make test` on Solaris) + the 2 daemon hardening items
  (orphan-reap on client-vanish, shutdown euid-check + exit-status logging).
- Real-Sun secret provisioning (prom-env is emulator-only) -- later.
- Bake `get-helios.sh` into the documented image-prep runbook order alongside
  get-openssh.sh / get-grep.sh (it's documented in SPARCSTATION_PLUGIN.md now).

## What's committed (this roll)

- `~/dev/SPARCplug` f8ffc5f: `guest/get-helios.sh`.
- `cx/heliosAgent` 6e9b969: init-script boot marker.
- `~/dev/X` d245a44: SPARCSTATION_PLUGIN.md ("Helios daemon on the image"
  section) + HELIOS_PLAN.md (C2 + follow-on(1) marked done).
- All three committed to main, **not yet pushed** (run `/eos` or push manually;
  let Dropbox finish syncing the cx tree).
- NOT in git: the validated-daemon memory was updated (Dropbox-synced).

## Pointers

- Image-bake: `~/dev/SPARCplug/guest/get-helios.sh`; sequence + gotchas in
  `SPARCSTATION_PLUGIN.md` "Helios daemon on the image".
- Daemon: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, init/, deploy.sh).
- Mac bridge: `~/dev/SPARCplug/helios/` (`./helios hello|run --user|put|get`).
- Plan: HELIOS_PLAN.md C2 (done), C6 (open).
