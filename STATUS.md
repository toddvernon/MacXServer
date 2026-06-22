# Status 2026-06-22 (end of day)

Big day on Helios. The whole macXserver control plane (Phase C) is done, and
the daemon grew three real capabilities -- run-as-user, streaming bulk
transfer, and shared-secret auth -- all built under g++ 2.95 and validated live
on the real Solaris 2.6 image. The daemon can now ship its own replacement over
its own protocol.

## Headline: Phase C complete + daemon hardened

- **Phase C (control plane) done:** C1 `HeliosClient` (Swift), C3 readiness via
  `hello` poll (+ fsck-stall detection), C4 graceful shutdown via the daemon, C5
  console is observation-only (auto-login deleted), C7 `helios` launcher
  transport. C2 (bake into the image build) + C6 (guided sysadmin GUI) remain.
- **Run-as-validated-user:** `run_command` gained a `user` field; the daemon
  (root) `getpwnam`-validates and drops privileges in the child
  (`initgroups`+`setgid`+`setuid`, failed drop exits 127). `HeliosLauncher` runs
  X clients as `entry.user`, not root. Live: `id --user tvernon` -> tvernon.
- **Streaming put_file / get_file:** `write_file` choked on a 4.7MB tar (55s
  timeout); new verbs stream a raw length-prefixed body to/from disk, no base64,
  no buffering. Live: 4.7MB round-trip byte-identical, ~0.2s each.
- **Shared-secret auth (B7 closed):** every request needs a matching `auth`
  (dispatch-layer, constant-time, require-if-configured). Key delivery is the
  firmware trick: macXserver picks a random secret per launch, passes it via
  qemu `-prom-env 'helios-secret=S'`; the guest reads it with `eeprom`, the
  daemon requires it. Validated: the custom OBP var is readable AND never
  persists to the qcow2 (disk-free). "Claude development" pref writes the key
  0600 to /tmp/sparkplug for agentic access.
- **B6 closed:** the 122-test daemon suite passes on Solaris under g++ 2.95.

## What's working

- macXserver: Phase C green; `helios` launcher runs X clients as the user.
- Daemon on the guest (auth build) is installed + running (open this boot, since
  macXserver hasn't passed a secret yet -- require-if-configured).
- `~/dev/SPARCplug/helios` CLI: `put`/`get` (streaming), `run --user`, auto-auth
  from `HELIOS_SECRET` env or /tmp/sparkplug.
- Daemon self-deploy proven: scp-bootstrapped the first build, then redeployed
  via helios (`put_file` + `run_command` + deploy.sh, surviving its own restart).
- sshd boot warning fixed (Protocol 2 on the image; get-openssh.sh carries it).

## What's broken / rough edges

- Self-deploy's final "done" ACK can be lost when the daemon restarts itself
  (the connection-child doesn't always survive to reply). The deploy completes;
  verify with a fresh `hello` after. Cosmetic, noted.
- Auth's plaintext-secret-on-the-wire is a speed-bump, not crypto -- fine on the
  loopback hostfwd, sniffable on a real LAN. HMAC/TLS is the documented upgrade.

## What's next

- **Todd: close the auth loop.** Rebuild macXserver in Xcode, turn ON "Claude
  development" (SPARCstation prefs), relaunch the VM. That boot passes a real
  per-boot secret -> daemon locks -> key written to /tmp/sparkplug -> my CLI
  reads it. Then re-verify end-to-end with the live secret. NOTE: with the daemon
  locked, agentic access needs "Claude development" left ON (that's the key file).
- **C2:** bake the daemon install + boot integration into the image *build* (not
  just the working qcow2), plus the deferred boot-marker / self-announce items.
- **C6:** the guided-sysadmin GUI (Phase 0.5).
- Real-Sun secret provisioning (prom-env is emulator-only) -- later.

## What's committed (this roll)

- `~/dev/X`: HeliosClient + HeliosLauncher (+ tests), QemuEngine (readiness,
  fsck, shutdown-via-daemon, secret-gen + prom-env), C3/C5 console changes,
  helios launcher transport + Preferences "Claude development", DECISIONS +
  HELIOS_PLAN + SHORTCUTS.
- `cx/cx`: `CxProcess` run-as-user (additive 4-arg `run`, portable LCD drop).
- `cx/heliosAgent`: `user` field, streaming put_file/get_file, shared-secret
  auth, PROTOCOL.md, init script (eeprom read), 122 tests.
- `~/dev/SPARCplug`: `helios` CLI (`put`/`get`/`run --user`/auto-auth),
  get-openssh.sh (Protocol 2).
- NOT in git (intentionally): `~/.macxserver-launchers` (Todd's dotfile, edited
  this session -- SPARCplug + SPARCplug-helios entries).

## Switching to the laptop

- The guest daemon source/build tree lives at `/export/home/tvernon/cx` ON THE
  IMAGE (built there with g++ 2.95). The auth-daemon binary is baked into the
  working qcow2, which rides Dropbox -- let the image finish syncing.
- Let Dropbox finish syncing the cx tree + memory before opening the laptop.
- On the laptop, `/sos` first.

## Pointers

- Daemon: `~/Dropbox/dev/cx/cx_apps/heliosAgent` (PROTOCOL.md, init/, deploy.sh).
  Built on the guest at `/export/home/tvernon/cx`; installed `/usr/local/bin/heliosAgent`.
- Mac bridge: `~/dev/SPARCplug/helios/` (`./helios put|get|run --user|hello`).
- Decisions: DECISIONS.md 2026-06-22 (run-as-user, streaming, auth/firmware-secret).
- Plan: HELIOS_PLAN.md (Phase C, B6/B7 closed).
