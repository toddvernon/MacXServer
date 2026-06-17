# Validating cx on Solaris 2.6 (pre-seed-daemon sanity check)

Goal: prove the cx libraries the Helios seed daemon will be built from
(`net`, `json`, `log`, plus process spawning) build cleanly and pass
their own test suite on the same Solaris 2.6 image SparkPlug ships.

One-time validation. On success, the seed-daemon design can proceed
against a known-working substrate. This is **not** Helios code — it's
substrate sanity. Stays inside the "talk only until plugin v1 ships"
rule.

## Prereqs

These must be present and working on the target Sun. Re-run
`Tools/helios-tool-survey.sh` if uncertain.

- g++ 2.95.3 (the version cx already targets via `_SOLARIS6_`)
- GNU make at `/usr/local/bin/make` (or `gmake`)
- `ar`, `ld`, `ranlib` (Sun's `/usr/ccs/bin`)
- `-lsocket -lnsl` link sanity (verified by the survey's socket probe)
- A user-writable workspace dir (`/export/home/$USER` works)

If any of these are red in the survey, fix that before going further.

## Get the cx source onto the Sun

cx ships a pre-built unix tarball at `~/Dropbox/dev/cx/cxlibs-unix.tar`
containing the library side (no Mac/iOS code). Tests live separately
in `~/Dropbox/dev/cx/cx_tests/`. You want both.

Pick the transfer that fits your setup:

**Option A — HTTP from the Mac.** Works in the bundled SparkPlug guest
via slirp's `10.0.2.2` alias and on any LAN-reachable real Sun. On the
Mac:

```sh
cd ~/Dropbox/dev/cx
tar cf cxtests-unix.tar cx_tests
python3 -m http.server 8000
```

On the Sun:

```sh
cd $HOME && mkdir -p cxbuild && cd cxbuild
wget http://10.0.2.2:8000/cxlibs-unix.tar       # slirp: 10.0.2.2; real Sun: Mac's LAN IP
wget http://10.0.2.2:8000/cxtests-unix.tar
tar xf cxlibs-unix.tar
tar xf cxtests-unix.tar
```

**Option B — rsync.** If you have rsync daemon on the Mac, the Sun's
rsync 3.0.7 (sunfreeware) will pull directly. Skip if not already
configured.

**Option C — FTP.** Solaris 2.6 has `ftp` client and server. Stand up
a local FTP from the Mac, fetch the tars from the Sun. Untar same as
Option A.

## Build cx libraries

```sh
cd $HOME/cxbuild/cx
make 2>&1 | tee build.log
```

Expected: every library (`base`, `net`, `log`, `json`, `process`,
`thread`, `b64`, ...) compiles. Archives land at
`../lib/sunos_sparc/lib<name>.a`. Warnings about 15-char ar filename
truncation are cosmetic per cx's `PLATFORM_SUPPORT.md`. No errors.

### Failure-mode guide

- **`/usr/ucb/cc: language optional software`** — the Makefile picked
  up Sun's K&R stub. Re-invoke with `CC=gcc CXX=g++ make`.
- **`make: command not found`** — `/usr/local/bin` not on PATH.
  `PATH=/usr/local/bin:$PATH make`.
- **`<sstream> not found`** — the `_SOLARIS6_` branch isn't being
  taken. Check `uname -r` returns `5.6` and that the top-level
  makefile's `ifeq ($(UNAME_R), 5.6)` clause is being hit.
- **`undefined symbol __socket` (or similar)** — link line missing
  `-lsocket -lnsl`. Should be in `net/sunos/makefile`; confirm it's
  intact after the tar extract.

## Build and run the four critical tests

The seed daemon will lean on `net`, `json`, `log`, and process spawning
(`cxstar`). Build them:

```sh
cd $HOME/cxbuild/cx_tests
for t in cxnet cxjson cxlog cxstar; do
  echo "=== Building $t ==="
  (cd $t && make 2>&1)
done
```

Run them (each test's binary is under `sunos_sparc/`):

```sh
for t in cxnet cxjson cxlog cxstar; do
  bin=`ls $t/sunos_sparc/* 2>/dev/null | head -1`
  if [ -x "$bin" ]; then
    echo "=== Running $bin ==="
    $bin
    echo "exit: $?"
  else
    echo "=== $t: no binary built ==="
  fi
done
```

Expected: each test prints its own pass/fail markers and exits 0.
cx's test framework uses `cxhandle`-style assertions; failures abort
with a printed diagnostic.

## What success looks like

All four pass, exit 0, no errors in build.log. That means:

- **cxnet PASS** → the seed's TCP listener will work
- **cxjson PASS** → wire-protocol parse/emit works
- **cxlog PASS** → daemon logging works
- **cxstar PASS** → the `run` verb can fork/exec/wait/capture

That covers the full set of cx subsystems the seed depends on. cx's
`base/file.h` (used for `read_file`/`write_file` verbs) is boring
enough that it doesn't need a separate gate; if `base` built, file I/O
works.

## What this does NOT do

This is **not** Helios bring-up. No daemon is written, no port is
opened, no protocol exists yet. The cx substrate is verified, full
stop. The Helios-Mission.md "do-not-implement-until-plugin-v1" rule
is unchanged.

## After this

If everything passes, the next concrete step (when the gate opens) is
seed-daemon design + hand-build, using exactly the cx libraries this
validation exercised. If anything failed, copy the build/test output
back to the Mac and we diagnose before any seed code gets written.
