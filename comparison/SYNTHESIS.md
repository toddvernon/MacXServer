# Synthesis — swift-x vs xorg vs XQuartz comparison study

Written 2026-05-14 after all 11 parallel forks landed. This is the cross-cutting
read across `risk_*.md` (the prime deliverables) and `comparison_*.md` (the blog
material). For per-dimension detail, read the dimension files; for the top-level
"what should we do next," read on.

## Executive summary

The study landed three categories of finding:

1. **One smoking gun for a real-world parked bug.** The window-semantics fork
   identified the root cause of the parked Motif PushButton chrome rendering
   problem (`INVESTIGATION_MOTIF_INPUT.md` / DECISIONS 2026-05-10).
   VisibilityNotify state derives from the wrong region. Fix is ~10 lines.
2. **A pile of cheap-to-fix gaps that the XError-honesty sweep missed.**
   Multiple dimensions surface opcodes that have no framer decoder at all and
   fall through to BadRequest. The semantically-wrong BadRequest (instead of the
   spec-mandated BadAlloc/BadValue/BadMatch/etc) actively breaks Xt's fallback
   paths in at least one case (colormap opcodes → Xt color converter).
3. **Two genuine architectural strengths.** The byte-order-as-encoder-parameter
   design is structurally cleaner than xorg's in-place swap layer; the
   validator-helper layer (`validateWindow`, `validateGC`, etc) is a better
   factoring than R6's per-handler boilerplate. Both are blog-worthy.

The study also corrected three stale claims I'd carried in my head: swift-x is
multi-client today (not single-client per a stale auto-load), the threading
model is one `protocolQueue` per session (not split read/write threads), and the
Motif chrome bug has a known fix shape now.

## Top priority — fix these first

Ordered by triage value: severity × confidence × cost. Items 1-3 are mechanical
fixes with disproportionate impact. Items 4-7 are systematic gaps with clear fix
shapes. Item 8 is the dormant-trapdoor risk most likely to bite next.

### 1. VisibilityNotify uses the wrong region — unparks Motif chrome

**Source:** `risk_window_semantics.md`, fork ID 2.

`Sources/SwiftXServerCore/ServerSession.swift:emitVisibilityChanges:1680-1714`
derives state from `entry.clipList`. clipList is defined
post-children-subtraction in
`Sources/SwiftXServerCore/Region/ClipList.swift:ClipListEngine.recomputeSubtree:84-110`.
Spec (`x11protocol.html:8584-8602`) is explicit: visibility state is computed
**ignoring all of the window's subwindows**. R6
(`reference/X11R6/.../mi/mivaltree.c:miComputeClips:197-234`) and modern xorg
both compute it from `RECT_IN_REGION(universe, &borderSize)` *before*
subtracting children.

Concrete consequence: every Motif container window whose interior is covered by
its child PushButton/Gadget widgets gets reported as `FullyObscured`. That is
exactly the signal Motif's XmPushButton uses to skip shadow-chrome drawing on
Expose.

**Fix shape:** snapshot `borderClip ∩ borderSize` (or use `parentVisible ∩
borderBox` directly) for the visibility comparison *before* the child loop runs.
The fork rates this ~10 lines.

**Why this matters:** the dt-Motif parking decision (DECISIONS 2026-05-10,
INVESTIGATION_MOTIF_INPUT.md) blamed missing visibility tracking. Region work +
VisibilityNotify shipping (2026-05-13/14) closed all three then-known culprits,
leaving "some Motif gate we still haven't identified" — this is that gate.
Verify on u5 hardware in the next session.

### 2. PolyArc sweep direction is inverted on FlippedXView — xclock bug shipping today

**Source:** `risk_drawing_gcs.md`, fork ID 3.

`Sources/SwiftXServerCore/CocoaWindowBridge.swift:ellipseArcPath` doesn't
compensate for `FlippedXView`'s y-flip CTM. Positive `angle2` (which the spec
defines as counter-clockwise) traces visually clockwise. xclock's second hand is
the likely visible victim.

**Fix shape:** invert the angle convention inside the arc-path builder, or apply
a y-axis reflection to the local arc CTM before adding the arc.

**Why this matters:** this is an actually-shipping rendering bug in M3-complete
territory. Trivial to verify with a PolyArc capture.

### 3. Multiple opcode decoders missing — falling through to BadRequest hits Xt fallback paths

**Source:** cross-cutting across `risk_input.md` (10 opcodes),
`risk_pixmaps_drawables.md` (3), `risk_visuals_colormaps.md` (11),
`risk_connection_setup.md` (3), `risk_drawing_gcs.md` (1).

The framer's `Request.decode` only switches on opcodes it knows; everything else
falls through to `.unknown` and `ServerSession` emits BadRequest (per the
post-2026-05-14 XError-honesty policy). The CLAUDE.md framing of this as
"spec-correct unknown-opcode handling" is **wrong for opcodes that exist in the
spec but have no decoder** — those should return their spec-mandated errors
(BadAlloc, BadValue, BadMatch, BadAccess) or implement, not BadRequest.

Concrete client breakage: **Xt's color converter catches BadAlloc as "fall back
to read-only AllocColor"; BadRequest gets logged as "server is broken."** This
is silent: Motif animations would visibly degrade rather than gracefully fall
back. The semantic difference is load-bearing.

Full list of opcodes missing from the framer:

| Opcode | Name | Spec error if unsupported | Currently emits | Forks that flagged |
|---|---|---|---|---|
| 29 | UngrabButton | (succeeds, no-op acceptable) | BadRequest | input |
| 34 | UngrabKey | (succeeds, no-op acceptable) | BadRequest | input |
| 39 | GetMotionEvents | (returns empty array acceptable) | BadRequest | input |
| 63 | CopyPlane | BadDrawable / BadGC / BadMatch | BadRequest | pixmaps |
| 73 | GetImage | BadDrawable / BadMatch / BadValue | BadRequest | pixmaps |
| 78 | CreateColormap | BadAlloc / BadMatch | BadRequest | visuals |
| 79 | FreeColormap | BadColor | BadRequest | visuals |
| 80 | CopyColormapAndFree | BadAlloc / BadColor | BadRequest | visuals |
| 81 | InstallColormap | BadColor | BadRequest | visuals |
| 82 | UninstallColormap | BadColor | BadRequest | visuals |
| 83 | ListInstalledColormaps | BadWindow | BadRequest | visuals |
| 86 | AllocColorCells | **BadAlloc** ← Xt fallback gate | BadRequest | visuals |
| 87 | AllocColorPlanes | BadAlloc | BadRequest | visuals |
| 88 | FreeColors | BadAccess / BadValue | BadRequest | visuals |
| 89 | StoreColors | BadAccess / BadColor | BadRequest | visuals |
| 90 | StoreNamedColor | BadAccess / BadColor / BadName | BadRequest | visuals |
| 100 | ChangeKeyboardMapping | BadValue | BadRequest | input |
| 102 | ChangeKeyboardControl | BadMatch / BadValue | BadRequest | input |
| 103 | GetKeyboardControl | (returns defaults acceptable) | BadRequest | input |
| 105 | ChangePointerControl | BadValue | BadRequest | input |
| 106 | GetPointerControl | (returns defaults acceptable) | BadRequest | input |
| 114 | SetCloseDownMode | BadValue | BadRequest | connection |
| 115 | KillClient | BadValue | BadRequest | connection |
| 116 | SetPointerMapping | BadValue | BadRequest | input |
| 118 | SetModifierMapping | BadValue / BadMatch | BadRequest | input |
| 122 | NoOperation | (always succeeds) | BadRequest | connection |
| 127 | PolyPoint | BadDrawable / BadGC | BadRequest | drawing |

NoOperation hitting BadRequest is particularly bad — Xt scatters `XNoOp` calls
everywhere as wire flushes. Every Xt-based app on every connection hits this
multiple times per session.

**Fix shape:** add framer decoders. Most are 5-15 line additions. The ones that
need real implementation (AllocColorCells, GetImage, CopyPlane) at minimum get a
spec-correct BadAlloc/BadValue/BadMatch instead of BadRequest until they're
real. Mechanical for the no-op-acceptable cases (UngrabButton, UngrabKey,
GetKeyboardControl, NoOperation).

### 4. Errors-on-the-wire: 8 of 17 Bad* codes still never emitted

**Source:** `risk_errors.md`, fork ID 7.

The encoder (`Framer/ServerMessage.swift:85-152`) and the `emitError` helper
(`ServerSession.swift:2217-2236`) are correct. The validator helpers
(`validateWindow`, `validateAtom`, `validateGC`, `validateDrawTarget` at
1563-1634) are a clean factoring. The gap is opcode handlers that don't
preflight per spec.

Never emitted from anywhere: BadValue, BadMatch, BadAccess, BadAlloc, BadColor,
BadIDChoice, BadName, BadLength.

Worst offenders by spec-error count: CreateWindow
(`ServerSession.swift:2416-2476`) is allowed to emit 8 different error codes per
spec, validates none of them. OpenFont, CreateGC, CreatePixmap, AllocColor are
similar one-liners with no IDChoice/Drawable/Color validation. ConfigureWindow
validates the window but misses BadMatch on stack-mode/sibling combos and
BadValue on enum range. Setup handshake silently disconnects on a bad byte-order
marker; `SetupRefused` is plumbed in the framer but nobody calls it. Request
decode failures at `ServerSession.swift:2402-2407` are explicitly swallowed with
an M1-era "decode is trusted" comment that's outlived the XError-honesty policy.

**Fix shape:** mechanical per-handler validation pass. The infrastructure is
there. This is the next sweep after the validator-helper layer.

### 5. Selections — dormant trapdoors that pass today only because we're under-tested

**Source:** `risk_selections_properties.md`, fork ID 6.

Today the corpus-grounded tests pass because they exercise single-client
patterns. Several real spec violations are latent:

- **SelectionClear never emitted anywhere.** Spec 9.4 mandates it on ownership
  transfer. R6 and xorg both emit it. `grep SelectionClear Sources/` returns
  nothing.
- **No auto-revoke of selection ownership** on window destroy or client
  disconnect. `destroyWindow` (`ServerSession.swift:2519-2547`) deletes
  properties but never touches `coordinator.selectionOwners`. R6's
  `dispatch.c:3720 DeleteWindowFromAnySelections` is the missing piece.
- **GetProperty(delete=True) unconditionally deletes** regardless of
  bytes-after. Spec says delete only when bytes-after==0. This will be the bug
  shape the moment anyone implements INCR (the INCR pattern reads with
  delete=True on every intermediate chunk).
- **GetProperty ignores the type filter** — never compares stored type against
  requested type. Spec mandates returning property's actual type +
  bytes-after=full-length + empty value on mismatch.
- **SetSelectionOwner skips all three spec time rules** (past time = no-op,
  future time = no-op, CurrentTime substitution).

The 2026-05-10 MATCH_SELECT fix and the SelectionMediator refactor are correct
and well-tested. None of these other items have test coverage.

**Fix shape:** five short, independent edits. Each ~10-20 lines. SelectionClear
+ auto-revoke pair should ship together; the trapdoor is "single-client tests
can't catch the missing pair."

### 6. Window semantics — no real sibling chain, several attribute drops

**Source:** `risk_window_semantics.md`, fork ID 2.

`WindowTable` is a `[UInt32: WindowEntry]` dict; Z-order is faked by sorting
children by id (`Region/ClipList.swift:directChildren:126-133`). `CWSibling` and
`CWStackMode` bits in ConfigureWindow are silently dropped. Every
ConfigureNotify's `aboveSibling` is hardcoded to 0.

`ChangeWindowAttributes` reads only
CWEventMask/CWBackPixel/CWBorderPixel/CWCursor. Drops bit-gravity, win-gravity,
backing-store, save-under, override-redirect (mid-life flip), colormap,
do-not-propagate. `GetWindowAttributes` then returns zeros for all of them —
observable lie that survives because no client we've tested cares about
read-back.

DestroyWindow doesn't recurse to inferiors and emits no DestroyNotify for them
(violates spec inferior-first ordering). CirculateWindow has no handler case at
all.

**Fix shape:** sibling chain is a real piece of work (real linked-list or array
+ restacking primitives). Attribute-drop fixes are mechanical extensions of
ChangeWindowAttributes. The lie in GetWindowAttributes is the immediate
XError-honesty violation.

### 7. Pixmaps + drawables — known shortcuts plus three missing decoders

**Source:** `risk_pixmaps_drawables.md`, fork ID 4.

The known-cut items (PutImage silent-drops bits; cross-window CopyArea emits
BadImplementation; NoExpose unconditional regardless of GC.graphicsExposures)
are all in SHORTCUTS already. Per the XError-honesty contract those need either
real implementation, a documented "what real looks like" exit plan, or honest
errors. Current SHORTCUTS entries pass the contract.

New finds:
- **CopyPlane (op 63) has no framer decoder** — used by every Athena/Motif bevel
  and every 1-bit cursor mask
- **GetImage (op 73) has no framer decoder**
- **PutImage decoder exists but PixmapEntry has no pixel storage** —
  `validateDrawTarget:1624` no-ops every draw into pixmaps

Plus structural surprise: swift-x advertises one pixmap format (`{depth=8,
bpp=8, pad=32}`). xorg/XQuartz advertise seven including depth-1 bitmaps. Any
client calling `XCreatePixmap(..., 1)` gets BadValue once depth validation
actually fires. And: we advertise `imageByteOrder: .msbFirst` on a little-endian
Mac — convenient for capture/replay against Sun (also MSBFirst) but xorg's
universal rule is host byte order. Latent: when GetImage/PutImage actually move
bytes we must either flip the advertised order or byte-swap per pixel.

**Fix shape:** decoder additions for CopyPlane/GetImage. Pixel-storage on
PixmapEntry is the genuinely big project gated on this work (multi-commit,
design-load-bearing).

### 8. Multi-client today, leaking handlers, no auth — the most concerning latent surface

**Source:** `risk_connection_setup.md`, fork ID 8.

Three independent issues converge:

- **CLAUDE.md auto-load saying "single-client" is stale.** `main.swift:134`
  calls `runAccepting`. The bridge has explicit multi-client handler fan-out
  comments at `CocoaWindowBridge.swift:35–42`. CDE dt-apps already run as 4-6
  simultaneous clients. The actual gap is test coverage — no integration test
  drives two simultaneous sockets through `runAccepting`.
- **Bridge handler-list leaks across disconnect/reconnect.** `CocoaWindowBridge`
  grows handler arrays unboundedly. Dead-session closures retain the session and
  keep firing (no-op via empty windows table but still firing on every AppKit
  event). Triggered by every disconnect-then-reconnect — happens during routine
  CDE use.
- **TCP listener on `0.0.0.0:6000` with no auth.** Auth-protocol-name and
  auth-protocol-data are parsed off the wire then discarded
  (`ServerSession.swift:2363 _ = try SetupRequest.decode(…)`). `SetupRefused` is
  plumbed in the framer but never produced. Acceptable for LAN-Sun use case; not
  acceptable for the GitHub-publish success criterion.

**Fix shape:** handler-leak fix is small (remove handlers in session teardown).
Auth is medium (Unix socket bind + MIT-MAGIC-COOKIE-1 implementation). The
single-client → multi-client comment in CLAUDE.md auto-load should be corrected.

## Cross-cutting themes

Patterns that show up in multiple dimensions and inform priority.

### Theme A — the framer has gaps the XError-honesty sweep didn't catch

The validator-helper layer at `ServerSession.swift:1563-1634` is a clean
architectural win and is well-applied across the ~55 handlers that route through
it (per SHORTCUTS). But that sweep only touched handlers whose opcode is decoded
by the framer. Opcodes that hit `Request.unknown` because their framer case is
missing get the unknown-opcode dispatcher's BadRequest, which the comment at
`ServerSession.swift:3922` frames as XError-honest — and **it isn't, for
spec-defined opcodes.** This affects 27 opcodes across forks 1, 4, 5, 8, 3 (see
table in #3 above).

The first XError-honesty sweep was "convert silent-drop to BadX." The second
sweep needs to be "add framer decoders for the spec-defined opcodes that
currently fall through, then either implement or emit the spec-mandated error
code." Mechanical, large-fan-out, high impact on real client fallback paths.

### Theme B — visible-failure-fixed-first, silent-failure-shipped

The input fork made this explicit: swift-x's crossing-event algorithm has the
full ancestor/descendant/LCA walking with proper detail-field machinery
(`emitCrossings`, line 964); the focus-event algorithm has identical algorithmic
shape *until* the detail field, which is hard-coded to `Nonlinear`. Likely
because crossing failures are visible (menus stop highlighting) while focus
failures are silent (Motif XmText cursor stays hollow).

This pattern probably explains several gaps. Things that ship correctly are
things whose breakage is visible during M1-M3. Things that ship with shortcuts
(Z-order faked by id-sort, focus detail hard-coded to Nonlinear, AllocColor
monotonic with no recycle, etc.) are things whose breakage doesn't surface in
single-client xclock/xterm/xcalc testing.

The corpus-grounded test suite plus the capture-diff workflow are the right
tools, but they're sensitive to "what got tested." Adding multi-client
integration coverage would catch a large slice of these (handler leak, selection
auto-revoke, atom drift across clients, etc.).

### Theme C — the "no DDX" choice is paying off

The architecture fork is positive on the lack of a DIX/DDX split. xorg's split
was created because the same X server core had to drive cgsix vs Sun3FB vs S3 vs
vesafb. swift-x targets a single backing platform (macOS / AppKit /
CoreGraphics). The DDX split would be ceremony with one ddx implementation;
collapsing it into the session/bridge structure is the right factoring.

The byte-order-as-encoder-parameter design is a structurally cleaner answer to
the same problem xorg solves with 200+ lines of in-place swap helpers
(`dix/swaprep.c:1036+`). swift-x's framer threads `ByteOrder` through
`ByteWriter`/`ByteReader` so `SetupAccepted.encode(byteOrder: .msbFirst)`
produces big-endian bytes from scratch with no swap step. The big-endian-Sun →
little-endian-Mac case (the entire reason this project exists) isn't a code path
at all — it's a session-lifetime parameter. Strong blog material.

### Theme D — corpus-and-replay testing missed a class of bugs

Two of the actively-bleeding-now items (Motif visibility-region, PolyArc sweep
direction) would not surface in corpus-replay tests because the captures encode
"the bytes the Sun client sent" not "the pixels the Sun server rendered." Replay
validates wire-level correctness; it doesn't validate render correctness. The
capture-diff workflow (gold-vs-swiftx) catches output divergence on the wire but
not on the screen.

Adding a visual-regression check at the right granularity (small fixture
screenshots for known apps) would catch these. Probably not worth the
infrastructure for a solo project, but worth knowing the gap exists.

## Known-cut confirmations (no action needed)

The forks confirmed several existing SHORTCUTS entries without surfacing new
info. Listing them here so the synthesis-vs-ledger differential is clean:

- PutImage silent-drops pixel data (SHORTCUTS: "CreatePixmap depth=1 / PutImage
  validate args but don't store pixels")
- Cross-window CopyArea emits BadImplementation (SHORTCUTS: "Cross-window
  CopyArea emits BadImplementation")
- NoExpose unconditional (SHORTCUTS: "NoExpose always emitted after CopyArea")
- WarpPointer doesn't move pointer (SHORTCUTS: "WarpPointer doesn't move the
  macOS pointer")
- SendEvent doesn't propagate (SHORTCUTS: "SendEvent doesn't propagate")
- AllocColor monotonic with no recycle (SHORTCUTS: "AllocColor returns synthetic
  monotonic pixel values")
- Hardcoded CDE customization daemon (SHORTCUTS: "Fake CDE customization daemon
  for dt-apps")
- Phase 1 xlsfonts (SHORTCUTS: "Synthesized xlsfonts is the Phase 1 set")
- Hardcoded SetupAccepted (SHORTCUTS: "SetupAccepted is hardcoded")

All currently-justified per the XError-honesty policy contract.

## Decisions worth revisiting

Three DECISIONS.md entries are due for a check.

### DECISIONS 2026-05-05 — Subset extensions only (SHAPE + BIG-REQUESTS)

Status today: neither shipped. `risk_shm_transport.md` confirms BIG-REQUESTS is
documented in PROJECT.md:111 as a Product 2 deliverable; `grep -r bigreq
Sources/` returns nothing. Server-side cost is ~24 lines
(`reference/X11R6/.../Xext/bigreq.c:62-87`) plus a length=0 → 32-bit-length
branch in the parser.

The extensions survey confirms BIG-REQUESTS and SHAPE are the only two that
matter for the R6/CDE/Motif client mix, validating the 2026-05-05 decision. The
follow-through hasn't happened. Recommend: ship BIG-REQUESTS soon (mechanical,
removes a wedge risk), defer SHAPE until a client we care about hits it (xeyes
round outline is cosmetic).

### DECISIONS 2026-05-05 — 8-bit PseudoColor + 24-bit TrueColor visuals

Status today: only PseudoColor advertised (`ServerConfig.swift:97-126`), and
**it's broken** — whitePixel=`0xFFFFFF` is out of range for a 256-entry
colormap. `ColorTable.swift:27-28` pins both 0 and 0xFFFFFF in the table as a
workaround. Visuals fork found XQuartz's smoking-gun TODO comment at
`hw/xquartz/darwin.c:215`: `// TODO: Make PseudoColor visuals not suck in
TrueColor mode` with the would-have-been-correct body commented out. Never
shipped.

The Sun u5/SS2 R6-era apps assume PseudoColor 8-bit. Modern apps prefer
TrueColor. The 2026-05-05 decision (ship both) is right. The implementation
(ship a broken one) needs follow-through. Recommend: fix the whitePixel
out-of-range issue now (1-line), schedule the TrueColor visual for the next
milestone.

### DECISIONS 2026-05-10 — Park dt-Motif widget chrome

The parking decision says "real visibility tracking is non-trivial; logged in
SHORTCUTS." Region work + VisibilityNotify shipping (2026-05-13/14) closed all
three then-known culprits per the SHORTCUTS update. The remaining suspect was
"some Motif gate we still haven't identified."

The window-semantics fork identifies it: VisibilityNotify state derives from
clipList (post-children-subtraction) when spec mandates ignoring children. ~10
line fix. **This unparks the chrome investigation.** Recommend: ship the fix,
verify on u5 hardware, update DECISIONS with the unpark date and the actual root
cause for the historical record.

## Strengths worth keeping

For context, where swift-x is genuinely doing well per the forks:

- **Byte-order-as-encoder-parameter design** (connection fork) — structurally
  cleaner than xorg's in-place swap layer. Strong blog material.
- **Validator-helper layer** (errors fork) — `validateWindow` / `validateAtom` /
  `validateGC` / `validateDrawTarget` is a better factoring than R6's
  per-handler boilerplate. The handlers that route through it are correct and
  well-tested.
- **GC clip rectangles + dashes shipped 2026-05-14** (drawing fork) — both
  honored via `CocoaWindowBridge.withClip` and `applyDashes`. Good momentum.
- **SelectionMediator + MATCH_SELECT fix** (selections fork) — clean two-tier
  model (coordinator + mediator), well-tested, correctly preserves time field
  per Xt's requirement. The unlock for CDE/Motif.
- **No DIX/DDX split** (architecture fork) — right factoring for a
  single-backing-platform server. Don't add the ceremony.
- **One protocolQueue per session** (architecture/SHM forks) — single-writer
  eliminates the lock-or-race tradeoff that xorg solves with single-threaded
  select. Documented choice in DECISIONS 2026-05-10.

## Blog hook roundup

Forks proposed ~30 blog hooks across 11 dimensions. The strongest threads,
ranked by story potential:

1. **"How a 24-bit-only Mac pretends to be an 8-bit Sun for old apps"** (visuals
   fork). Anchored on the XQuartz `// TODO: Make PseudoColor visuals not suck`
   smoking-gun comment. The architectural question of how to bridge a TrueColor
   framebuffer to a PseudoColor-expecting client is genuinely interesting and
   underdocumented.
2. **"The Cocoa pasteboard is not a clipboard, and three different X servers
   have three different lies about it"** (selections fork). XQuartz runs
   `xpbproxy` as a 1500-line separate-process fake X client. swift-x intercepts
   a property write inside the server in one line. R6 doesn't know macOS exists.
   The asymmetry in what each can elide is the story.
3. **"Half the BadCodes never made it onto the wire"** (errors fork). The
   validator-helper layer is correct; the handlers don't route through it. The
   "encoder was ready before the call sites existed" framing is good.
4. **"Why Core Graphics can't do GXxor"** (drawing fork). Impedance mismatch
   between X raster ops (logical-pixel operations on a frame buffer) and CG
   (compositing with alpha and blend modes). The `CGBlendMode.difference`
   substitution that almost-but-not-quite matches XOR is the concrete handle.
5. **"The byte that fixed everything: Xt MATCH_SELECT and the time field"**
   (selections fork). The one-line MATCH_SELECT fix that unblocked CDE + Motif.
   Cautionary tale about server-generated event fields that look optional.
6. **"Six visuals, one visual, no visual: three X servers decode the colorspace
   question"** (visuals fork). R6 cfb at depth 8 advertises six. XQuartz at
   depth 24 advertises one (TrueColor). swift-x advertises one (broken
   PseudoColor). What the era expected vs what survived.
7. **"The shape of an X server in 2026"** (architecture fork). The
   plain-language closing of the architecture comparison — XQuartz is xorg with
   a Mac DDX swapped in, swift-x is a clean reimplementation that occasionally
   pattern-matched xorg. The three aren't equally similar.
8. **"The y-flip and the arc that ran the wrong way"** (drawing fork). Concrete
   debugging story about FlippedXView vs spec's CCW arc direction. Short and
   pointed.
9. **"X.org's giant ProcVector and what we replaced it with"** (architecture
   fork). Dispatch tables vs Swift enums + switch. Quietly interesting
   language-design angle.
10. **"What 1995 expected vs what we shipped: extensions through the eras"**
    (extensions fork). The era-drift framing — R6 expected SHAPE / MIT-SHM /
    XInput 1.x / XKB. Modern expects RANDR / Composite / XFIXES / RENDER.
    swift-x advertises none. The middle path swift-x targets is itself a topic.

Save the longer-form story angles for the architecture and visuals forks. The
errors and selections forks have the punchier debugging-narrative material.

## What's NOT in this synthesis

- **Per-opcode minutiae** — read the dimension files.
- **Em-dash audit.** All 22 fork outputs include em-dashes despite the CLAUDE.md
  preference. ~580 instances total. Mechanical sweep before publishing any of
  this as blog material; not done in this synthesis pass.
- **Cosmetic / theoretical-bucket items.** The risk registers all include a
  "theoretical / spec-only" bucket. Those are real spec violations but no client
  in our target context cares. Listed in the dimension files; not surfaced here.
- **A second-pass review** of whether the forks themselves are correct. Each
  fork's "what swift-x does" was independently grep-derived; the line-number
  citations look right when spot-checked but a full audit wasn't done.

## How to read this study

For a quick "what should I do next": items 1-3 in the top-priority section. ~30
minutes of code total, large surface-area impact.

For blog material: read `comparison_architecture.md` and
`comparison_visuals_colormaps.md` first, those are the strongest narrative
threads. Then `comparison_selections_properties.md` for the MATCH_SELECT story.

For systematic gap-closing: items 3-7. Mechanical but multi-week work. Probably
the right shape for a "next milestone" after the M3 punchlist.

For a sanity check on architectural direction: theme C and the strengths
section. The forks confirmed (independently of any anchoring) that the major
architectural calls are sound — byte-order design, validator-helper layer,
no-DDX split, single-thread protocol queue. Don't second-guess these.
