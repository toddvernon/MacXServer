# Status 2026-07-15 (second session, other Mac)

## Headline: the Add Machine wizard shipped. + now walks name -> host ->
proven login -> xterm launcher -> Create, nothing touches the registry
until the end, and the whole telnet login-proof chain got honest about
real-world prompts (Todd field-tested against SWS2 and the 4.1.4 box
all afternoon; every fix below came out of a live repro).

## What happened this session

**Machine name moved to the detail header** (45b37c1). Todd's field
test: a new machine's typed name silently reverted because the Settings
draft refused to commit while Host was empty (canCommit's external-host
gate) and leaving the pane dropped the whole draft. The header title is
now a plain-style TextField committing straight to the registry on
Return / focus loss; Settings has no Name row and adopts the live name
at commit. Fresh external hosts open on the Settings tab (host is the
one required field).

**New external machines default to telnet, not helios** (736bf52). A
just-added box has never had an agent found on it. Persisted-JSON
convention untouched: absent transport still decodes helios (bundled
fixtures).

**Add Machine wizard** (6a9976f; DECISIONS 2026-07-15 entry). + opens
AddMachineWizardView, the one and only add path; Cancel leaves no
"New Machine" zombie. External: name -> host + OS -> login proved with
the Change Login probe machinery via new onProbeLoginEndpoint (no
registry id yet; same rejection-vs-unreachable split and Continue
Without Checking hatch) -> pre-filled xterm launcher -> summary.
Emulated VM: one fast fork (existing disk image w/ OS detection +
claim check, vs download starter -> kicks onDownload after Create).
Telnet passwords go to the launcher-read Keychain slot, never
machines.json. onAddNew + the short-lived pendingNameEntry machinery
retired. Ran xcodegen for the new file.

**Login probe rewritten around real prompts** (e1b2adf, 9c08cc2,
7c4993e, e92ea17, 25af3e6). The arc, each step from a live failure:

- *Silence means yes* (e1b2adf): the probe demanded positive prompt
  recognition, so the 4.1.4 box's custom prompt turned a CORRECT
  password into shellPromptTimeout. Probe mode now: rejection is
  authoritative ("Login incorrect" markers + a re-presented login
  prompt, suffix match on "ogin:" with a "Last login:" carve-out);
  recognized prompt = instant success; otherwise output that goes
  quiet 2.5s with no rejection = login proven. Both 4.1.4 and 2.6
  print "Login incorrect" AND re-prompt (Todd verified), so every
  real rejection announces itself.
- *Suspected-prompt capture* (9c08cc2): probe passes but xterm launch
  still needs the needle. The probe captures the last visible line;
  the wizard shows it for validation and stores the confirmed text as
  Machine.shellPrompt (exactly what Machine.resolved threads into
  launches).
- *NUL is RFC 854 padding* (7c4993e): SWS2 showed the prompt question
  with an EMPTY field. Root cause: telnetd sends bare CR as CR NUL and
  stripTelnetCommands passed NULs through -- invisible "\0 lines" beat
  the sigil detection AND became the suspected prompt. NULs now die at
  the protocol layer; capture filters remaining control chars.
- *Always confirm, never silently decide* (e92ea17): the bracket-prompt
  rule that then "recognized" SWS2 is our own fleet's dotfile prompt
  echoed back -- Todd: invalid basis for skipping the question on a
  stranger's box. The guess is now captured on EVERY telnet success
  with output; recognition only improves the prefill. Every wizard
  machine carries a human-confirmed needle. Saved to memory as the
  general principle (fleet heuristics prefill, never decide).
- *Polish* (25af3e6): caption teaches trimming the needle to the last
  few unique characters (contains-match, tail is all that matters);
  stripANSI grew the missing ECMA-48 two-char escape branch (ESC ( B,
  ESC = / ESC >) so charset/keypad tails can't leak into the guess.

## What's working / what's broken

- swift build clean; swift test 1579 / 0 failures (32 skipped). Six
  new fake-telnetd probe tests pin the whole prompt story.
- Wizard field-verified end to end on SWS2 (bracket prompt, instant
  prefilled confirm) and the powered-off / custom-prompt paths.
- Ledgered (SHORTCUTS "Telnet launch"): pre-wizard machines and the
  Change Login sheet still gather no prompt needle; type-ahead
  launching (send the command right after the password, drop the
  prompt wait) is the real fleet-wide fix, its own decision with a
  live repro. Prober transport-port aliveness check still open too.
- SourceKit still shows stale diagnostics (phantom "no member" errors
  in the new telnet/test code); the compiler disagrees. Ignore or let
  Xcode reindex.

## What's next

1. Try the xterm launcher end-to-end on a wizard-added custom-prompt
   box (the stored needle should unlock it); consider type-ahead
   launching as the successor to prompt needles entirely.
2. GUI pass remainder: menu-bar reorg, download flow
   (SPARCPLUG_CATALOG_URL), first-run choreography. Change Login ssh
   flavor on the nuc.
3. CanonicalDotfiles DISPLAY decision (SHORTCUTS, carried).
4. Catalog data side: E1 baseline masters -> build-catalog.sh ->
   upload; root-password policy + unique per-box helios secrets.
5. Cut v0.9.9 (A5/A6 release pipeline proof).
6. UserAdmin live test against Solaris 2.6 + 4.1.4; retire orphaned
   DefaultLaunchers.swift (still just the old seed text, still unused).

## Committed / push state

- X repo, all on main, pushed at /eos: 45b37c1 (header name) ->
  736bf52 (telnet default) -> 6a9976f (wizard) -> e1b2adf (probe
  silence-means-yes) -> 5546780 (SHORTCUTS) -> 9c08cc2 (suspected
  prompt) -> 7c4993e (NUL fix) -> e92ea17 (always confirm) ->
  25af3e6 (caption + stripANSI) + the date-fix/STATUS roll.
- SPARCplug / cx repos: no changes this session.

## Switching Macs

- Swift sources + project file changed (xcodegen ran): pull, then
  rebuild in Xcode.
- No VM was running this session; no image locks held.
- One memory file added (fleet-heuristics-confirm-dont-decide); let
  Dropbox finish syncing before opening the other Mac.
