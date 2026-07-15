# Status 2026-07-15 (evening roll)

## Headline: a Settings + Overview polish day driven by Todd using the
app live. The Settings Connection section is retired, the Change Login
sheet got honest plain-English errors plus an explicit unverified-save
path for boxes that are off the network, and the Overview's Active User
line grew into a labeled read-only field with password dots.

## What happened this session

**Settings: Connection section retired** (af5644a; DECISIONS 2026-07-14
next-day addendum). The User row was redundant once the Overview became
the one place the active user changes -- and declare-at-birth was too:
fresh VMs get the FirstLogin window (re-offered every boot while
user-less), fresh external boxes get the Change Login sheet. Host moved
up into the Machine section. Real hazard closed: Settings commits its
whole draft, so a pane open through an Overview user switch would have
written the OLD user+password back; commit() now adopts the live user
(and password unless the Telnet/SSH field edited it).

**Change Login: unreachable boxes get an explicit escape hatch**
(ff39e35 -> 353573f -> 1737020; second DECISIONS addendum). Field
experience: powered-off ipx made its login permanently uneditable and
the sheet showed raw NWError ("-65554 NoSuchRecord"). Probe failures now
split by whether the box ANSWERED: a real rejection stays authoritative
(retype only), while a proof that couldn't run shows "The machine isn't
reachable right now to validate the username and password." (Todd's
wording) and the Change button relabels to **Change Without Checking**
(one affirmative button, two meanings -- a third button read as a
duplicate). Warned, never silent; Force Set shape. ssh machines store no
password on the unverified path either.

**Overview Active User line, iterated live with Todd** (ff39e35,
5a9c675, 5e772f1, dc7f57f): now "User:" at status-line size + the value
("tvernon / ••••••••", fixed eight dots only when a password is actually
on file -- cleartext field or telnet Keychain slot, existence never
length) in a read-only field-look box (selectable, not editable), then
Change…. MachineRow gained hasStoredPassword.

**Small fixes:** OS picker sits flush left (fe4b9a7 -- bare width frame
centered it); ~20% more air before the Target Machine / X11 Launchers /
Admin Agents headers (e7c0837).

**Design question settled in conversation (no code):** should first
admin-agent use ask for the root password? No -- the helios secret IS
the admin credential (the agent runs as root; a root-password gate is
either unverified theater or verified by the same agent the secret
already controls). The real completeness gap is the fleet-wide dev
secret "test" -> unique per-box secrets, which belongs with the open
root-password-policy decision for published masters.

## What's working / what's broken

- swift build clean; swift test 1574 / 0 failures (32 skipped).
- Todd exercised the new Overview + Change Login live against real
  boxes today (that's what drove the iterations), including the
  unreachable path against powered-off machines. Remaining GUI-pass
  items: Change Login ssh flavor on the nuc, menu-bar reorg, download
  flow (SPARCPLUG_CATALOG_URL), first-run choreography.
- Ledgered residue (SHORTCUTS "Change Login proof channel"): a
  DROP-firewalled box's dot still says "unreachable" while ssh works;
  honest fix is a transport-port TCP check in the prober's verdict.
- SourceKit shows stale "no member loginProbe" diagnostics in
  AppDelegate; the compiler disagrees (builds fine). Ignore or let
  Xcode reindex.

## What's next

1. GUI pass remainder: Change Login on the nuc (ssh flavor), menu-bar
   reorg, download flow, first-run choreography.
2. CanonicalDotfiles DISPLAY decision (SHORTCUTS, carried).
3. Catalog data side: E1 baseline masters -> build-catalog.sh ->
   upload; root-password policy for published masters -- now explicitly
   including unique per-box helios secrets (today's design talk).
4. Cut v0.9.9 (A5/A6 release pipeline proof).
5. UserAdmin live test against Solaris 2.6 + 4.1.4; retire orphaned
   DefaultLaunchers.swift. Maybe the prober transport-port aliveness
   check.

## Committed / push state

- X repo, all on main and pushed at /eos: af5644a (Connection retired)
  -> 67f4cb0 (morning STATUS) -> fe4b9a7 (OS picker) -> ff39e35 ->
  353573f -> 1737020 (Change Login arc) -> 5a9c675 -> 5e772f1 ->
  dc7f57f (Active User line arc) -> e7c0837 (section air) + this roll.
- SPARCplug / cx repos: no changes this session.

## Switching Macs

- Swift sources changed: pull, then rebuild in Xcode.
- The solaris26 guest was running under this Mac's Xcode debug build at
  /eos (lock held). If it's still up when you open the other Mac, that
  machine will see remoteLocked -- shut it down here first if you need
  it there.
