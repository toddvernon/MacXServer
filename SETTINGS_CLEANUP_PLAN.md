# Settings cleanup plan (for 2026-07-09)

One focused day to close out MACHINE_SETTINGS_AUDIT.md, then we're out of VM
land and back to X11 land. Everything here is machine-manager UI/model work;
no protocol code is touched. The audit doc has the full evidence and the
caption/rename text; this is the execution order.

Ground rules for the day: work on main as always, commit per phase (each
phase leaves the app working), swift test green before each commit, rebuild
in Xcode not swift build.

## Decisions to confirm at the top of the day

Three of the fixes need a call from Todd before code moves. Recommendations
inline; confirming these first means no mid-day stalls.

1. **F2, networkMode.** Recommend: bind hostfwds to 127.0.0.1 explicitly
   (`hostfwd=tcp:127.0.0.1:PORT-:23`) and DELETE the `networkMode` property
   outright. Nothing reads it, the app is the only thing that dials guest
   ports, and loopback-only is what the doc already claimed. This changes
   wire behavior (guests stop being LAN-reachable), so it gets a DECISIONS
   entry. If a LAN-exposed guest ever becomes a real need, we re-add a knob
   with UI, not a dead enum.
2. **F4, DNS-admin OS gate on externals.** Recommend: drop the `os != nil`
   condition and gate on reach == .up only, matching File Transfer. The DNS
   panel is a constant /etc/resolv.conf and never consults the OS. The
   2026-07-07 "OS-sensitive verbs" doctrine stays correct in general; this
   verb just isn't OS-sensitive. Alternative if the doctrine should hold
   pre-emptively: keep the gate, fix the tooltip to say why.
3. **Ports + MAC row: Overview or Settings.** Recommend: Overview, as a
   quiet monospaced facts line under the system line. Settings then holds
   only things with an edit affordance (and the new ports EDITOR from F1 is
   that affordance).

## Phase 1: the two HIGH findings (morning, before any UI shuffling)

### 1a. networkMode (F2)

- Delete `MachineNetworkMode` + the property, its decode/encode lines
  (Machine.swift:277, 293, 301, 438, 459, 497) and the test assertion.
  Decoding old machines.json files that carry the key: nothing to do,
  Codable ignores unknown keys.
- Change the nic string (QemuEngine.swift:925) to bind each hostfwd to
  127.0.0.1.
- Verify: boot a fixture VM, telnet/helios still work from the app; from
  another LAN box the guest port is now refused.
- DECISIONS.md entry: loopback-only hostfwds, dead knob deleted.

### 1b. Ports editor (F1)

- New editable Ports row: three small numeric fields (Telnet / SSH /
  Helios), placeholders showing the derived defaults, blank = derived.
  Non-blank commits an explicit `ports` override; all-blank clears it back
  to nil. Same commit-on-exit pattern as Host, plus the existing conflict
  check (MachineRegistry.swift:136-156) run at commit so a collision is
  flagged in the form, not at launch.
- Lives in the (new) Connection section for BOTH kinds. External hosts get
  ports visibility for the first time; emulated VMs get the editor the
  conflict dialog already promises. Caption: "How this Mac reaches the
  machine's telnet, SSH, and Helios agent. Leave blank for the usual
  ports." (emulated wording: "...reaches the guest. Assigned when the
  machine was created; override only to resolve a conflict.")
- The read-only Runtime display retires in Phase 2 (facts move to Overview
  per decision 3); until then it can stay, it's just redundant for a day.
- While running: fields disabled (hostfwds are baked into the live qemu),
  same rule as the image path.
- Tests: MachineFileTests round-trip for explicit/partial/nil overrides;
  registry conflict-on-commit case.

## Phase 2: the reorganization + rename + captions pass (one sitting)

All in MachineDetailForm.swift + MachinesWindowView.swift + the Helios
Secret entry point in AppDelegate. Pure UI; the only model-adjacent change
is where the secret dialog is invoked from. Use the caption text drafted in
MACHINE_SETTINGS_AUDIT.md section 3 verbatim.

Section moves:
- Identity -> "Machine": Name, Kind, OS (OS moves in from Connection with
  its lock/provenance behavior unchanged).
- Connection: Host, "Connect with" (Transport renamed, options Telnet /
  SSH / Helios agent), Ports (from Phase 1b), Helios Secret button row
  (external only, moved from Overview; opens the existing dialog).
- New "Login" section: User, Password (telnet only), "Shell prompt"
  (telnet only, renamed from Prompt). Visibility rules unchanged, they just
  fire inside the section that owns them.
- X11 Launchers: gains "Show windows on" (DISPLAY renamed) at the head.
  Live placeholder behavior (AD:250-256) unchanged.
- Disk Image: unchanged.
- Runtime section: deleted. Ports+MAC facts line appears on Overview under
  the system line (monospaced, selectable, tooltip carries the old
  footnote). MAC labeled "Network address (MAC)".
- Overview: Helios Secret button removed; external lifecycle row shows
  nothing.

Caption/tooltip promotions: Prompt, Password, DISPLAY hover-tooltips become
visible helpNote captions; new captions for Kind, User, Connect with, OS,
launcher command; the right-click progress-window hint line under the
launcher list; Helios Secret dialog text rewrite; OS picker shows
displayName not raw values.

Sanity sweep after: the launcher editor sheet's "inherit (helios)" tag and
any string that says "Transport", "Prompt", or "DISPLAY" gets the new
vocabulary. Grep for the old labels before committing.

## Phase 3: small correctness fixes (afternoon)

- **F5, menu parity.** Machines menu externals gain DNS + File Transfer
  (same gates as Overview: reach == .up, plus the F4 decision); emulated
  Admin submenu gains File Transfer (gate: ready). Keep the "menu mirrors
  window" comments true.
- **F9, launcher name uniqueness.** Uniqueness check in the editor sheet's
  canSave (case-sensitive exact match against siblings), with a helpNote
  when blocked. Cheaper than adding an id to MachineLauncher and it fixes
  every keyed-by-name surface at once.
- **F6, telnet Keychain key.** Account becomes `user@host:telnetPort`.
  Lookup falls back to the old `user@host` key once and migrates it forward
  (store under new key; leave the old entry alone rather than deleting
  other apps' lookalikes). Loopback VMs with the same user stop sharing a
  password slot.
- **F4** per the morning decision (either a one-line gate change + tooltip,
  or tooltip-only).

## Phase 4: cleanup, docs, wrap

- **F7**: stop parsing `verbose` in LauncherFile, fix the doc block
  (verbose, login_prompt/password_prompt claims).
- **F8**: stop reading ~/.macxserver-launchers at startup; `bundledUser`
  for fixture injection falls back to NSUserName() (fixtures already exist
  in both live machines.json files, so this is inert in practice).
- STATUS.md roll, DECISIONS.md entries (networkMode/loopback binding,
  section reorg naming, keychain key change), delete or annotate the audit
  doc's now-fixed findings (mark each F# with shipped/deferred).
- Manual pass: one fixture VM (boot, launch xterm, DNS, file transfer,
  backup) and one real host (ipc or ss5: probe dot, DNS, file transfer,
  telnet launch with progress window). Menu vs Overview verb parity spot
  check.

## Explicitly deferred (not tomorrow)

- **F3, configurable login/password prompt needles**: wait until a real
  host actually needs a non-"ogin:" banner; the fix is the shellPrompt
  pattern repeated, better done against a live repro. Log in SHORTCUTS.md
  tomorrow so it's ledgered.
- F10 beyond a caption: the "no xBinDirs over telnet" asymmetry gets a
  sentence in the launcher-command caption at most.
- Duplicated loopback-host constant, discarded parser warnings: fold into
  whatever file we're already touching, zero standalone effort.

## Done means

swift test green, manual pass clean on one VM + one real box, no dialog
references a control that doesn't exist, every visible field either
self-explanatory or captioned, STATUS.md rolled. Then VM land is buttoned
up and the next session opens on X11 work (MCP bridge or the CLIPBOARD/
editres gaps in the feature matrix).
