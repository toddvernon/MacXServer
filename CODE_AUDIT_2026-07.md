# Code audit — 2026-07-06

Pre-release cleanup sweep. Five detection agents (duplication, structure,
stale-scaffolding, compiler-hygiene) over swift-x + a SPARCplug script pass,
plus a Periphery dead-symbol scan. Read-only detection; every DELETE/latent-bug
claim was spot-verified against source. This file is the ledger: findings graded
for Todd to bless, then execution in tested batches.

Grades: **DELETE** (dead, safe to remove), **DEDUP** (repeated code worth one
home), **BUG** (latent behavioral bug the audit surfaced), **DEFER** (structural,
findings-only per Todd's call), **LEDGER** (doc/comment drift).

---

## 0. RELEASE-BLOCKER — client can crash the server — ✅ FIXED 2026-07-06

**Malformed value-list request traps the process.** The framer request structs
enforce `precondition(valueList.count/4 == valueMask.nonzeroBitCount)` in their
initializers, but `decode(...)` derives the value-list length from the client's
request-length word alone, independent of the mask. A client sending a length
word and mask popcount that disagree trips the precondition — which is a **trap,
active in release `-O` builds**, not a throwable error. The dispatch loop
(`ServerSession.swift:4297`) wraps decode in `do/catch`, but traps aren't
catchable. Result: any X client kills the server and every session in the
process. Trivial remote DoS. Violates the project's P0 "a client must not crash
the server" rule.

Affected decoders (opcode): CreateWindow (1), ChangeWindowAttributes (2),
ConfigureWindow (12), CreateGC (55), ChangeGC (56), ChangeKeyboardControl (102),
ChangeKeyboardMapping (100, the `keysymsPerKeycode == 0` variant). RENDER/XKB
payload decoders share the pattern (RenderGlyphPayload, XkbMapPayload) — same
class if those extension opcodes reach these decoders.

Fix: decoders validate `(length-derived count) == valueMask.nonzeroBitCount`
(and `keysymsPerKeycode > 0`) and `throw FramerError.length/.value` on mismatch
instead of feeding a mismatch into the precondition-bearing init. Add negative
tests that feed each malformed request and assert a BadLength/BadValue on the
wire rather than a trap (the tests currently only build well-formed pairs, which
is why this was never caught — the error-path test would itself crash today).

**FIX (shipped):** added `FramerError.malformedRequest` + a shared
`validateValueList(byteCount:maskPopcount:request:)` in FramerError.swift;
guarded all six server-reachable decoders (CreateWindow, ChangeWindowAttributes,
ConfigureWindow, CreateGC, ChangeGC, ChangeKeyboardControl) before `readBytes`,
plus a `keysymsPerKeycode > 0` guard in ChangeKeyboardMapping. The decode loop's
existing catch maps the throw to BadValue on the wire and stays synchronized.
New `Tests/FramerTests/MalformedValueListTests.swift` (8 tests) feeds each
malformed request and asserts a throw, not a trap — these would have crashed the
suite before the fix. Full suite green at 1490.

**RENDER/XKB note:** the payload decoders with similar preconditions
(RenderGlyphPayload, XkbMapPayload) are reached only by the capture-side dumper,
never the server's request loop (zero dispatch references), and their
preconditions are mostly encode-side construction invariants. Not a live-client
crash vector, so not a blocker. Left as-is.

---

## 1. Latent bugs the audit surfaced (verified, small, high-value)

These are DEDUP findings where the copies already **diverged** — i.e. real bugs,
not style. Each is a small, targeted fix.

- **BUG — GetGeometry reports depth 8.** `ServerSession.swift:7285,7303` answer
  depth 8 for root / depth-0 windows while SetupAccepted, GetImage, PutImage,
  CopyPlane all say 24 (TrueColor since 2026-06-13). A client sizing an XImage
  from GetGeometry then hitting PutImage gets BadMatch. Fix: one
  `drawableDepth(id)` helper, kill both `8`s.
- **BUG — console xterm launch reintroduces the open-in-`/` bug.**
  `QemuEngine.swift:279` is a stale copy of `HeliosLauncher.remoteCommand` that
  omits the `cd "$HOME"` fix, hardcodes `DISPLAY=10.0.2.2:0` and `user:root`.
  Comment claims "same shape as HeliosLauncher" — untrue. Fix: call the shared
  pure function.
- **BUG — NetBSD fsck-stall never detected.** `QemuEngine.swift:154` marker
  `"RUN fsck MANUALLY"` is a Solaris literal; NetBSD prints `RUN fsck_ffs
  MANUALLY`, no substring match, so stall detection silently no-ops and boot
  waits out the full 240s. Same class as the 2026-07-06 shutdown bug. Fix:
  `fsckStallMarkers: [String]` on MachineOS (exhaustive switch), add to the
  GUEST_OS_PROFILE matrix.
- **BUG — file-browser windows survive machine deletion.**
  `AppDelegate.swift:249` cleanup evicts consoles + DNS windows but not
  `fileBrowserControllers`; deleting a machine leaves its file-browser windows
  live holding the dead machine's host/port/user. Fix: prefix-match eviction +
  `setMachineName` on DnsAdminWindowController (rename doesn't update DNS titles
  either).
- **BUG — FontMappings revert destroys edits with no backup.**
  `FontMappingsPanelView.swift:144` writes directly; the Resources and
  Preferences editors both reseed via a `.bak`-first path. Fix: route revert
  through the backup-first path. (Also: Resources + FontMappings editors lack
  the Dismiss/Esc the dialogs-explicit-dismiss convention requires — DnsAdmin
  has it.)
- **BUG — 0.0.0.0 host takes the wrong secret branch.**
  `AppDelegate.swift:1106` inlines a loopback check missing `0.0.0.0` that
  `MachinesFile.isLoopback` has; an emulated machine with host 0.0.0.0 uses the
  external Keychain secret instead of the engine's per-boot secret, so helios
  auth fails. Fix: call `MachinesFile.isLoopback`.
- **BUG — zero-delta ConfigureNotify on live-resize out-and-back.**
  `CocoaWindowBridge.swift:3306` (DidEndLiveResize) fires unconditionally; its
  sibling handleNSWindowResize guards zero-delta, with a comment documenting the
  fire as harmful to xterm. Fix: share the guarded body.

Adjacent cosmetic divergences (fix alongside, not standalone): shutdown dialogs
hardcode "init 5" for every OS while the daemon runs per-OS `HELIOS_SHUTDOWN_CMD`
(`Machine.swift:80`, `SparcShutdownProgressWindowController.swift:142`,
`AppDelegate.swift:1719`); CopyPlane ignores the GC clip-mask pixmap that CopyArea
honors (`ServerSession.swift:3829` — log/SHORTCUTS it rather than change behavior
pre-release); ssh launcher gets no per-OS PATH prepend that telnet/helios get
(`SSHLauncher.swift:140` — a bare `xterm` can fail over ssh only).

---

## 2. DELETE — dead code (Periphery scan pending; these are the semantic finds)

- **`_unused_blitWindowRegion`** — `CocoaWindowBridge.swift:3085`, ~110 lines.
  Superseded by `blitWindowRegion` (shipped default-ON 2026-06-04), which
  documents that this version had a latent Cartesian-flip bug. Private, zero
  callers, keep-rationale consumed. Delete.
- **`CDEResourceManagerFixture.swift`** (145 lines) + its test — retired CDE
  impersonation data (2026-05-18); zero runtime refs; the test only checks the
  literal matches a git-tracked `.bin`. Provenance survives in the .bin +
  SHORTCUTS + DECISIONS. Delete file + test.
- **SelectionMediator stub-owner machinery** — `SelectionMediator.swift:53-87`
  + the `.stubOwnerReplyEmpty` branch (`ServerSession.swift:7142`). The sealed
  RETIRED block stays (deliberate anti-revive banner), but the still-compiled
  stub-owner scaffolding is semantically unreachable (only the sealed block
  registered a stub selection owner) and kept warm by one test. Reduce to
  `replyNoOwner`, delete the trap rather than fence it. **needs-Todd** — touches
  ConvertSelection dispatch; MEDIUM risk, tests updated deliberately.
- **`scripts/gatekeeper-probe.sh`** — one-shot diagnostic, closed
  investigation, referenced by nothing. Delete or move to archive/.
- **`x11perf-survey.sh`** (repo root) — campaign closed 2026-05-22; plausible
  regression tool, so move to scripts/ rather than delete.
- Local gitignored scratch: `connection.json`, `capture_screen_ui` — personal
  working files, delete locally when convenient.
- Trivial: `LauncherTokenizer.swift:16` `var pos` written never read;
  `ServerSession.swift:4370` `var backPixel` should be `let`.

## 2a. Migration leftovers — needs-Todd (deliberate legacy vs zombie)

- **`~/.macxserver-launchers` reseeded on every launch.** `loadOrSeed`
  (`LauncherFile.swift:240`) rewrites the legacy dotfile whenever absent, every
  startup, in a format the app never reads again post-migration. The seed's
  survival is deliberate (one-shot migration); the unconditional-every-launch
  write probably isn't. Gate the seed on "machines.json absent."
- **`SPARCPLUG_DISK_IMAGE` / `SPARCPLUG_TFTP_DIR` neutered in-app.**
  `makeEngineConfig` (`Machine.swift:311`) overwrites what the env reads set, so
  these two dev overrides can never win on the app path (only via tests /
  `SPARCPLUG_ENGINE_DIR` still works). Docs still present them as live. Either
  fix makeEngineConfig to honor them or annotate test-only.
- **`sparcplug.diskImagePath`** — correctly migration-read-only, but still in
  `defaults.register` and has no stated removal horizon. Note a horizon in
  SHORTCUTS.

---

## 3. DEDUP — repeated code worth one home (no divergence found yet)

Ordered by drift-cost. All LOW risk unless noted.

- **`opcodeOf` 121-case switch** duplicated verbatim in Dumper.swift:304 and
  ChronoDumper.swift:1317 (~125 lines x2). Replace with a computed `opcode`
  property on Framer's Request enum; deletes ~250 lines.
- **Text rendering pipeline** quadruplicated (ImageText8/16, PolyText8/16) in
  CocoaWindowBridge.swift:2504-2826, incl. the load-bearing AA/smoothing block
  x4. 16-bit variants rarely exercised → a missed edit fails silently. Shared
  `imageTextCore`/`polyTextCore` + `applyGlyphRenderingSettings(ctx)`.
- **Paint-region-bg + emit-Expose cascade** x4 (`ServerSession.swift` 2339,
  2707, 5328, 5564), with `1 << 15` exposure-mask literals mixed against the
  named constant. MEDIUM — most regression-prone code in the file; needs
  rendering tests + dtpad/quickplot resize eyeball.
- **Dumper stream walk** reimplements ChronoDumper's StreamWalker with a
  diverged framing strategy (decode-re-encode byte count vs wire length field) —
  Dumper desyncs on any non-length-preserving decoder. MEDIUM; rewrite Dumper on
  StreamWalker+ChronoContext.
- **Window-cache create/show pattern** x9 in AppDelegate (`showOrCreate` helper).
- **Machine state-gating** computed independently on 3 UI surfaces
  (`AppDelegate.swift` 305, 459, 739) — comments promise they "mirror exactly,"
  hand-enforced. One `MachineGates` pure function.
- **13-way bridge handler register/fan-out/remove boilerplate**
  (`CocoaWindowBridge.swift` 83-559) — a `HandlerList<Args>` struct so handler
  #14 can't forget the removeHandlers line (that omission = the pre-2026-05-14
  dead-closure leak).
- **X-root ↔ NSScreen placement formula** tripled + backing-scale source
  diverged (main-screen vs window-screen) — the ICCCM synthetic ConfigureNotify
  gets wrong-scale coords on mixed-DPI. MEDIUM; one forward/reverse pair, verify
  on Studio + laptop. Fixes together with the pointer-coordinate copies
  (`CocoaWindowBridge.swift` 3603-3705, same root cause).
- **CGBitmapContext + y-flip CTM setup** duplicated PixelBuffer vs FlippedXView
  (comment-enforced keep-in-sync of GRAPHICS_Y_FLIP-critical code) + bitmapInfo
  constant x3. MEDIUM; asymmetric-orientation tests gate it.
- **Config-editor chrome** x3 (Resources/FontMappings/DnsAdmin panels), **text
  draw-preamble** x12, **CopyArea/CopyPlane skeleton**, **per-OS port triple**
  encoded 3x, **read32** hand-rolled 6x despite Framer's ByteReader, **`hex()`**
  copied into 6 dumpers with mixed case in one dump (user-visible). Lower value;
  batch opportunistically.

Framer's ~11k lines of per-request decode repetition is deliberate codegen-style
in the house voice — **leave as is**.

---

## 4. DEFER — structure (findings only, per Todd; no splits pre-release)

Good news first: **the module graph is healthier than the file sizes suggest.**
Framer is perfectly pure (127 files, zero imports — can't regress into UI/net
without a visible one-line diff). Capture/server separation holds. And the
**machine manager is already symbol-isolated** inside SwiftXServerCore: zero
symbol references in either direction between the ~4,900 lines of machine code
and the X11 code. The MCP bridge's prerequisite — extract machine manager to its
own headless module — is one Package.swift edit + file moves, no code changes.
The only wrinkles: TerminalView imports AppKit and TerminalEmulator imports
CVTerm (console UI rides with manager logic).

God files (all split mechanically along existing MARKs; do post-release, gated
by the full suite):
- **ServerSession.swift (7,755)** — `dispatch()` is a single ~3,400-line switch
  (264 arms). Extension-per-MARK split (Windows/Drawing/Colormap/Grabs/SHAPE).
  The one genuinely **tangled** part: the xterm scrollbar-skin hack (~790 lines)
  is cross-cutting state written from draw ops, read from focus handlers, gated
  on `wmClass=="XTerm"` — extension split works, type extraction does not.
- **CocoaWindowBridge.swift (3,863)** — the ~1,830-line Drawing block is a clean
  extension split; the drag-monitor + 13-way handler fan-out state is tangled
  across shared locks — leave it.
- **AppDelegate.swift (1,806)** — @MainActor UI glue, logic already in Core;
  low-urgency cosmetic extension split.
- **ChronoDumper.swift (1,642)** — safest split in the audit (free functions +
  value structs, no shared mutable state); three-file move. Only gets worse as
  decoder coverage grows.
- **QemuEngine.swift (1,191)** — healthiest; at most a `+Args` extension.

Other DEFER: over-public habit in SwiftXServerCore (~1,274 `public`, consumed
only in-package; tests use `@testable`) — Periphery redundant-public pass
post-release. AppKit implementations live in Core not the app target (semi-
deliberate: tests construct CocoaWindowBridge directly) — either document Core
as "Mac library" in ARCHITECTURE.md or add a SwiftXServerAppKit target later.
Guest-admin flows (DNS, file transfer) live in SwiftUI view models the MCP
bridge can't reach — extract to Core when the bridge starts, not speculatively.
SwiftXCaptureUI declares Package deps it never imports (one-line manifest fix).

---

## 5. LEDGER — doc/comment drift (cheap, do in the cleanup batches)

- SHORTCUTS.md:211 says the ColorTable CDE palette is "still in code but
  dormant" — deleted 2026-06-13 (TrueColor rewrite); same entry says the
  impersonation fixes are in ServerSession — they're in SelectionMediator now.
- `blitWindowRegion` comments (`CocoaWindowBridge.swift:3012`,
  `WindowBridge.swift:588`) say "default OFF until validated" — default ON since
  2026-06-04. SHORTCUTS Step F "still validating" a month on.
- AppDelegate comments describe deleted UI: launchers file-watcher (:153) and
  the three-section Config window (:41).
- `ServerSession.swift:68` cites "SHORTCUTS:32" by line number (rotted — switch
  to the entry-title convention every other comment uses).
- GPL_SOURCE.md doesn't point at `Tools/make-gpl-source-bundle.sh` that
  fulfills it.
- **SPARCplug:** `helios/README.md:11` documents the pre-per-OS single port
  block (MEDIUM — will misdirect new-guest wiring); `build414/gold.sha256`
  checksums archived images; `expand_414_fs*.md` executed runbooks sit at repo
  root (move to docs/); `build414/` one-shot tools need a 5-line README pointer.

---

## Suggested execution order (each = one commit to main, tests green + Xcode build)

1. **Release-blocker** (section 0) + its negative tests. Own commit, own review.
2. **Latent bugs** (section 1) — small, verified, each a clean fix. Group the
   server-side and app-side into 2-3 commits.
3. **Dead code deletes** (section 2) — after Periphery lands to catch the
   mechanical unreferenced-symbol tail. Shrinks everything downstream.
4. **Migration-leftover decisions** (2a) — needs Todd's calls first.
5. **Dedup** (section 3) — LOW-risk first (opcodeOf, text pipeline, window
   cache, MachineGates, HandlerList); MEDIUM ones (paint-cascade, placement/
   pointer scale, Dumper walk, y-flip factory) each own commit with the named
   verification.
6. **Ledger fixes** (section 5) — fold into whichever batch touches the file.
7. **Structure** (section 4) — post-release, one god-file at a time.
