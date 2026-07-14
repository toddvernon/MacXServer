# Status 2026-07-14 (evening roll, Mac Studio)

## Headline: the active user is now changeable everywhere, tiered by
what the box supports. Change… on the Overview opens the Users panel
when the agent answers (unchanged), or a new lightweight Change Login
sheet when it can't serve -- proven against the box's OWN login channel
before anything is adopted. The nuc (Linux, sshd-only) drove the second
half: ssh-transport machines prove with a BatchMode key check and no
password field at all. Settings' User field is declare-at-birth: free
typed only until a user exists, then read-only pointing at the Overview.
Suite 1574 green. NOT yet eyeballed in the running app.

## What happened this session

**Tiered Change… + Change Login sheet** (fa88f42; DECISIONS 2026-07-14).
Rationalized the two-fields-two-pages problem: the Overview is the one
place the active user changes. Agent answering = Users panel; external
box the panel can't serve = Change Login sheet (username + password,
verified by a live telnet login via TelnetLauncher probe mode: reach a
shell, run nothing, exit); agent exists but can't serve (VM stopped,
wrong secret) = dead button with the reason in the tooltip. Settings'
User field locks once a user is declared.

Three real bugs fell out of the probe's tests (loopback fake telnetd):
- looksLikeShellPrompt never matched bracket prompts on CRLF streams --
  Swift's "\r\n" is one grapheme, so split(separator: "\n") never broke
  telnetd lines. The fleet only worked because machines carry an
  explicit shellPrompt needle. Fixed + CRLF regression tests.
- A refused/unreachable telnet connect hung forever (NWConnection parks
  in .waiting, which nothing handled, and no timeout is armed until
  .ready). Now fails fast; fixes the real launch path too.
- adoptMachineLogin left a stale cleartext machine.password on user
  switch (it outranks the Keychain at launch, so launchers would send
  the OLD password). Now follows the switch.

**ssh proof channel for the nuc** (9d9e1ea; DECISIONS same-day
addendum). The nuc firewall-DROPs the helios port (reads "unreachable"
-- REFUSED-proves-alive is a Sun-fleet fact, not a Linux fact) and runs
only sshd, so the telnet proof could never fire. Proof now keys off
machine.transport: ssh = SSHLauncher.loginProbe (BatchMode, remote
command `true`, exit 0 = the key logs in as that user -- the trust
level ssh launchers already run at), telnet/helios = the telnet probe.
Gate widened to "the panel can't serve it" including unreachable;
unauthorized still stays dead on purpose. adoptMachineLogin takes an
optional password; the ssh path touches no stored credential.

**Also this morning:** cleared the stale solaris26 + sunos414 image
locks (leftovers from the laptop's 07-13 unclean quit; verified no qemu
on either Mac first -- the laptop answers ssh at 2024-macbook-pro.local,
saved to memory).

## What's working / what's broken

- swift build clean; swift test 1574 / 0 failures.
- NOT eyeballed in the app yet: the Change Login sheet (both telnet and
  ssh flavors), the locked User field in Settings, plus the standing
  list (Overview titled sections, identity-first header, menu-bar
  reorg, download flow, first-run choreography).
- Ledgered residue (SHORTCUTS "Change Login proof channel"):
  helios-transport boxes prove over telnet (fine, fleet all runs
  telnetd); a DROP-firewalled box's dot still says "unreachable" while
  its ssh launchers work -- honest fix is folding a transport-port TCP
  check into the prober's aliveness verdict.

## What's next

1. **Todd's manual GUI pass** (carried, grew again): Change Login sheet
   on the nuc (ssh, username-only) and on a real Sun with the agent
   stopped (telnet + password), locked User field in Settings, plus the
   standing items (Overview sections, identity-first header, menu-bar
   reorg, download flow via SPARCPLUG_CATALOG_URL, first-run).
2. CanonicalDotfiles DISPLAY decision (SHORTCUTS, carried).
3. Catalog data side: E1 baseline masters -> build-catalog.sh ->
   upload; root-password policy for published masters.
4. Cut v0.9.9 (A5/A6 release pipeline proof).
5. UserAdmin live test against Solaris 2.6 + 4.1.4; retire orphaned
   DefaultLaunchers.swift. Maybe the prober transport-port aliveness
   check (gives the nuc an honest dot).

## Committed / push state

- X repo: today's arc is fa88f42 (tiered Change… + Change Login sheet +
  the three telnet bugs) -> 9d9e1ea (ssh proof channel) -> this STATUS
  roll, all pushed to origin/main at /eos.
- SPARCplug / cx repos: no changes this session (SPARCplug pulled
  build-catalog.sh from the laptop this morning, nothing new here).

## Switching Macs

- Swift sources changed: pull, then rebuild in Xcode.
- No VMs running on this Mac; NO image locks outstanding (the stale
  solaris26/sunos414 ones were verified dead and cleared today).
- Memory got a new entry (laptop ssh check) -- let Dropbox finish
  syncing before opening the other Mac.
