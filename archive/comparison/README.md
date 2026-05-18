# swift-x vs xorg vs XQuartz comparison

Three-way comparison study. Goal: surface where swift-x is weakest and where
we'll find problems, using xorg and XQuartz as data points (not as ground truth
— the X11 protocol spec is authority, X11R6 is era-correct intent, swift-x
targets the R6 era).

**All 11 forks complete as of 2026-05-14. See [SYNTHESIS.md](SYNTHESIS.md) for
the cross-cutting executive summary and top-priority items.**

## How this is organized

Each dimension produces two files:

- `risk_<dim>.md` — risk register. Three severity buckets: actively bleeding
  now, will bleed when X happens, theoretical/spec-only. This is the prime
  deliverable.
- `comparison_<dim>.md` — narrative three-way comparison. Spec, R6, xorg/XQuartz
  collapsed, swift-x, surprises, blog hooks. This is blog raw material.

Extensions and architecture are special cases (see manifest).

## Dimensions

1. **Extensions** — survey only. `comparison_extensions.md` only (no risk file).
   One-line-per-extension table of what xorg/XQuartz advertise, what each does,
   would-we-want-it.
2. **Input** — keyboard/modifier maps, grabs, focus model, pointer warping,
   EnterNotify/LeaveNotify, KeymapNotify, button/motion events.
3. **Window semantics** — substructure redirect, override-redirect, save-under,
   backing-store, visibility tracking, stacking, gravity, map/unmap/reparent
   notifies.
4. **Drawing + GCs** — full GC component coverage, regions/clipping, line
   styles, cap/join, arcs, fill rules.
5. **Pixmaps + drawables** — pixmap allocation, cross-drawable CopyArea,
   CopyPlane, GetImage/PutImage byte/bit format variants.
6. **Visuals + colormaps** — visual classes,
   AllocColor/AllocColorCells/AllocColorPlanes, StoreColors, virtual cell
   emulation.
7. **Selections + properties** — PRIMARY/SECONDARY/CLIPBOARD, ConvertSelection
   with correct time, MULTIPLE, INCR, property modes, root window props, atoms.
8. **Errors on the wire** — every Bad* code, when emitted, sequence number
   tagging, error format.
9. **Connection setup + auth** — initial bytes, byte-order swap, auth schemes,
   connection-info reply, multi-client, max request length, resource ID
   base/mask.
10. **SHM / transport / large requests** — Unix/TCP/abstract sockets,
    BIG-REQUESTS, write buffering.
11. **Architecture overview** — `comparison_architecture.md` (+ optional risk
    file). Layering, dispatch, resource model, event pipeline, threading,
    genealogy, quartz-wm structural note. Ends with plain-language "how alike
    are the three."

## Rules each fork was given

- Authority order: spec > X11R6 > xorg+XQuartz > swift-x. xorg is not
  automatically right.
- Era target: X11R6. Post-R6 xorg features (RANDR 1.2+, Composite, Damage,
  XFIXES, GLX) get flagged but don't count against swift-x in the risk register.
- xorg ≈ XQuartz collapse: present as one column when they share code, call out
  XQuartz overrides under `hw/xquartz/` explicitly.
- Forks do NOT read `OPCODE_STATUS.md`, `SHORTCUTS.md`, or `DECISIONS.md`. The
  point is fresh eyes, not anchoring on our self-assessment.
- Forks DO read `PROJECT.md` for goals + non-goals.
- Forks are read-only on swift-x source. They only write into `comparison/`.

## Reference paths

- Spec: `reference/x11-protocol-spec/x11protocol.html`
- Era intent: `reference/X11R6/`
- xorg + XQuartz: `reference/xquartz-xserver/` (core in `dix/ mi/ miext/ fb/ os/
  include/`, XQuartz DDX in `hw/xquartz/`)
- Apple WM: `reference/quartz-wm/`
- swift-x source: `Sources/`
