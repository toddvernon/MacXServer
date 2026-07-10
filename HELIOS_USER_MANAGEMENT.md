# Helios-driven user management (add / delete user)

Status: **designed 2026-07-10, decision points open, not built.** Needed for
the first-run experience: published images can't ship with Todd's account as
the only login, so a stranger's first boot has to mint their own user. Also
the tool that strips `tvernon` from the masters at publish time, and a
general Users panel for the fleet.

## Why now

The image downloader shipped 2026-07-10. The next gap in the stranger's
path is: image boots, guest is ready... and every login on it is Todd's.
The launchers need a real account on the guest (`machine.user` drives
telnet/ssh/helios launches), and we are not shipping images with a
documented developer password as the only way in (guest-config README
release note flags exactly this).

## What already exists (the design builds on all of it)

- **The agent is ready.** heliosAgent runs as root on every guest and real
  Sun, authenticated fail-closed, with `run_command` (cmd/cwd/timeout_ms,
  returns exit_code+output), atomic `write_file` (temp + rename, preserves
  mode AND owner on overwrite -- exactly right for /etc/passwd),
  `read_file`, and the HeliosPrivGuard run-as-user drop. No new verbs are
  strictly required.
- **The images are pre-staged for this.** The 2026-07-04 convergence baked
  the account scheme into all three guests (guest-config/README.md):
  group `users` (gid 100) for every human account, uid 1001+ reserved for
  macXserver-created users, `/home/<user>` uniform on all three (Solaris
  via the /home -> /export/home symlink), and a **`template` account
  (uid 1999, locked password, canonical dotfiles)** that exists precisely
  so add-user can `cp -r /home/template` + copy a known-good passwd line
  instead of synthesizing one per OS.
- **Host-driven guest edits have precedent.** The DNS admin panel is
  read_file -> edit -> write_file against /etc/resolv.conf, over
  `HeliosClient`. The launchers are single `run_command`s with a `user`.
- **Per-OS host knowledge has a home.** The `MachineOS` guest profile
  (Machine.swift) with exhaustive switches is the established forcing
  function for per-OS divergence.

## The core decision: where does the logic live?

Two candidate shapes. **Recommendation: host-driven (option B).** Todd to
ratify.

**A. First-class agent verbs** (`add_user` / `delete_user` in heliosAgent).
One round trip, one ok/error, guest-side C++ per OS (the agent already
builds per-OS binaries). Cons: the agent has stayed a set of *generic
primitives* (run, files, sysinfo) and this would be its first policy-heavy
verb (uid allocation, passwd formats, GECOS); it needs an agent redeploy
across the whole fleet plus version gating in the app (older agents answer
"unknown verb"); and the logic is only testable against live guests.

**B. Host-driven orchestration** over the existing verbs: a `UserAdmin`
module in SwiftXServerCore composes per-OS sequences of read_file /
run_command / write_file, with the per-OS knowledge in pure, unit-testable
builder functions keyed by `MachineOS` (exhaustive switches, same forcing
function as the profile). Pros: works against every agent already deployed
today (including the real-hardware fleet -- no redeploy, no version skew),
the sequences are visible/debuggable (a transcript window like the launch
progress panel), and the fiddly parts are plain Swift with plain tests.
Con: multi-step, so partial failure is possible -- addressed by ordering
(below) so the login-enabling write is the last, atomic step.

Why B wins here: the transactional risk it carries is small and
manageable, while A's costs (fleet redeploy, version gating, policy in the
agent, guest-only testability) are permanent. And B matches how DNS admin
and the launchers already work. A remains available later if a genuinely
atomic guest-side operation ever becomes necessary.

## Password handling

The cleartext password never leaves the Mac. All three guests use
traditional DES crypt (13-char hash, 2-char salt), and macOS libc still
computes it (verified 2026-07-10: `crypt("...", "ab")` returns a 13-char
DES hash). So:

- The app computes the hash host-side (salt from SystemRandomNumberGenerator
  over the crypt alphabet) and only the hash crosses the wire, inside the
  passwd/shadow line.
- DES crypt only uses the first 8 characters. The add-user sheet says so
  ("vintage Unix reads only the first 8 characters") rather than silently
  truncating -- normalize-at-the-edit-boundary doctrine.
- Username rules enforced in the sheet: `[a-z][a-z0-9]*`, max 8 chars
  (the 4.1.4-era limit), refuse names already in /etc/passwd.
- Optionally (default on): store the password in the Keychain under the
  existing per-machine telnet slot and set `machine.user`, so launchers
  work immediately.

## Per-OS mechanics

Uniform parts (all three): uid = next free >= 1001, gid 100, home
`/home/<user>`, shell `/usr/local/bin/tcsh`, home seeded by
`cp -r /home/template /home/<user>` + `chown -R`. Per-OS parts:

| step | Solaris 2.6 | SunOS 4.1.4 | NetBSD 9.2 |
|---|---|---|---|
| account record | append `/etc/passwd` line (`x` in field 2) + `/etc/shadow` line (hash) | append `/etc/passwd` line (hash in field 2) | append `/etc/master.passwd` line (hash) |
| activate | nothing (files are live) | nothing | `pwd_mkdb -p /etc/master.passwd` via run_command |
| home physical path | `/export/home/<user>` (write the passwd line as `/home/<user>`; the symlink resolves) | `/home/<user>` | `/home/<user>` |
| delete | remove both lines | remove line | remove line + pwd_mkdb |

Notes:
- All file edits go read_file -> transform host-side -> write_file. The
  atomic rename + preserve-mode/owner semantics of write_file were built
  for exactly this class of edit (HELIOS_PLAN B5).
- No NIS/yp anywhere on our images; local files only.
- Nothing else on these guests edits passwd concurrently; the classic
  vipw race is accepted and noted.

## Ordering (the transactional story)

Do everything fallible BEFORE the step that makes the account real:

1. read_file passwd (+shadow / master.passwd): parse, validate name free,
   pick uid.
2. run_command: `cp -r /home/template /home/<user>` (on Solaris the
   physical `/export/home` path), `chown -R <uid>:100`.
3. **Commit point:** write_file the passwd file(s), atomically. Solaris
   order: shadow first, passwd last (a passwd entry whose shadow line is
   missing can't log in; the reverse is a dangling hash -- harmless).
4. NetBSD finisher: run_command pwd_mkdb. If it fails, master.passwd is
   correct and the panel surfaces "run pwd_mkdb again" retry -- the one
   non-atomic seam, and it's idempotent.
5. Verify: read_file back, run_command `ls -ld /home/<user>`.

Worst-case partial failure before the commit point: an orphaned
`/home/<user>` copy of template, no login. Delete-user (or a retry)
cleans it up. After the commit point the account exists and every later
step is retryable.

Delete-user runs the same shape in reverse: remove the record line(s)
(+pwd_mkdb), then optionally `rm -rf` the home behind an explicit
checkbox (default OFF -- removing a login shouldn't silently destroy
files). Refusals: root, template, any uid < 100, and any system account;
deleting the account `machine.user` points at warns and clears the field.

## UI surface

A **Users** chip in the Overview's Helios Admin Agents section, next to
File Transfer and DNS, gated the same way (agent answering; OS known --
this IS an OS-sensitive verb, unlike DNS). The panel:

- Lists accounts parsed from /etc/passwd (system accounts uid < 100
  dimmed/hidden behind a toggle; template shown dimmed as "template").
- **Add User...**: username, full name (GECOS), password x2, the 8-char
  note, and "Use for this machine's launchers" (default on -> sets
  `machine.user` + Keychain). Runs the pipeline with a compact progress
  transcript; explicit Dismiss on completion (dialog doctrine).
- **Delete...**: confirm dialog naming the account, optional
  "also delete /home/<user>" checkbox (default off).

## The first-run hook

The reason this exists. Proposed flow, to settle in the first-launch
design session:

1. Published masters carry root + template + the helios daemon ONLY
   (tvernon stripped at publish prep, below). Bundled fixtures seed
   `machine.user = ""` -- which requires changing the current seeding
   (`bundledUser` falls back to `NSUserName()` today; a stranger's Mac
   login name isn't on the guest, so that fallback writes a lie).
2. First Start after an image download boots to ready. The app notices
   ready + empty `machine.user` and presents the add-user sheet framed as
   "Create your login on <machine>", username pre-filled with the Mac
   short name lowercased/truncated to 8.
3. On success `machine.user` is set, launchers go live, and the user
   clicks xterm. That's the end-to-end first-run path.
4. Dismissing is allowed (it's an invitation, not a gate); the empty-user
   state re-prompts on next ready, and the Users panel is always there.

## Publish-prep tie-in

- Before build-catalog.sh runs against the masters (PLUGIN_V1_PUNCHLIST
  E1), delete-user strips `tvernon` from each (home included). The same
  feature, pointed at the masters.
- Open with it: the **root password** on published images (currently a
  documented dev password, flagged in guest-config/README.md). Options
  live in the first-launch discussion: ship it documented ("the appliance
  has a known root password; it only listens on loopback hostfwds"), or
  rotate at publish, or fold a root-password-set into first-run. The
  slirp/loopback posture (DECISIONS 2026-07-09: hostfwds bind 127.0.0.1)
  bounds the exposure to the user's own Mac.

## Build shape (when ratified)

- `UserAdmin` in SwiftXServerCore: pure per-OS line builders + parsers
  (passwd/shadow/master.passwd), DES crypt wrapper, the orchestration
  over HeliosClient. Unit tests for every builder/parser per OS; the
  pipeline testable against a mock client transcript.
- `UsersPanel` (SwiftXServer): the panel + sheets, modeled on
  DnsAdminPanelView.
- AppDelegate: chip wiring + the first-ready empty-user prompt + the
  `bundledUser` seeding change.
- No agent or protocol changes. No SPARCplug changes beyond publish-prep
  usage.

## Open decisions (Todd)

1. Ratify host-driven (option B) vs agent verbs (option A).
2. The first-run frame: prompt-on-first-ready (proposed) vs make user
   creation a step of the download flow vs leave it purely manual in the
   Users panel.
3. Published masters: strip tvernon only, or root password policy too
   (ties into first-launch discussion).
4. Fixture seeding change to `machine.user = ""` (required for the
   first-ready prompt signal to fire for strangers).
