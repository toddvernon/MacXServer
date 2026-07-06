# Curated image download — design plan

Status: **designed 2026-07-06, not built.** The Track C download machinery from
SPARCSTATION_PLUGIN.md ("code ships, data downloads") updated for the P2
machine-manager world: three bundled fixtures, per-machine images, sticky
ports, guest-OS detection. Todd's requirements from the 2026-07-06 session are
the spine of this doc. Build it after the P2 test phase.

## Requirements (Todd, 2026-07-06)

1. **Bundled must be fool-proof.** The user selects at most the *images
   directory*; the path autosets from there. It must be impossible to attach
   the wrong image to the wrong machine.
2. **Second copies are legitimate.** A user may add a NEW machine, download
   another copy of a curated image, give it its own name, and run two NetBSD
   machines side by side.

The "can't attach the wrong image" half is partly shipped already: the
Settings form refuses a picked image whose detected OS contradicts a bundled
fixture's fixed OS (2026-07-06, `MachineDetailForm.runOSDetection` — it used
to silently mutate the fixture's OS instead). The catalog flow below makes
mismatch impossible by construction rather than by rejection.

## What Track C already settled (still holds)

- **Code ships in the app, data downloads on demand.** Engine (qemu + dylibs
  + ROM) is inside the signed/notarized app; the image is pure data,
  removable with one `rm`. No downloaded-executable trust problem.
- **Manifest + checksum + stream + atomic move.** A small JSON manifest
  hosted with the payload; NSURLSession streams with progress; sha256
  verified; decompress; atomic move into place. Fetch-on-click only — no
  background polling, no telemetry. ~200 lines, deliberately not Sparkle.
- ~250 MB gzipped / ~1.3 GB decompressed per image.

Superseded bits: the single `SS5-cde-ready.qcow2` + `savevm` instant-boot
snapshot (current images cold-boot), and writing the image path into
Preferences (it goes on the `Machine` now).

## The catalog

One `catalog.json` at a pinned URL on **oldsilicon.com** (settled 2026-07-06
— Todd already distributes these images there for the ZuluSCSI workflow; only
the exact path is still open), one entry per curated OS:

```json
{ "formatVersion": 1,
  "images": [
    { "os": "solaris26",
      "version": "2026.07",
      "url": "https://.../solaris26-boot.qcow2.gz",
      "sizeGz": 262144000, "sha256Gz": "…",
      "size": 1395864371, "sha256": "…",
      "notes": "Solaris 2.6 + CDE, helios agent installed" },
    { "os": "sunos414", … },
    { "os": "netbsd", … } ] }
```

- Keyed by `MachineOS` raw value — the same key the fixtures carry, which is
  what makes wrong-image-to-wrong-machine impossible in the download path:
  the button on the Solaris fixture can only ever fetch the `solaris26` entry.
- Both checksums on purpose: `sha256Gz` catches a corrupt download before we
  spend the decompress; `sha256` catches a truncated/bad gunzip (the
  2026-07-04 NAS lesson: size-correct files can still be silently corrupt —
  never trust size).
- An OS absent from the catalog simply has no Download button (BYO-image
  only) — the shape supports it, but it's not needed: **all three OSes ship
  (Todd, 2026-07-06).** He already distributes these images publicly on
  oldsilicon.com for the ZuluSCSI workflow; 30-year-old OSes, nobody cares.

SPARCplug side: a `build-catalog.sh` that gzips the three `<os>-boot.qcow2`
images, computes both sha256s, and emits `catalog.json`, so publishing an
image update is one script run + one upload.

## Where images land (the "images directory")

One **global images directory** preference, default
`~/Library/Application Support/macXserver/Images/`. It's the ONLY thing the
user can change about a bundled download, and even that is optional (the
default just works). Created on first download.

Filenames are never user-chosen:

- **Bundled fixture** → `<imagesDir>/<os>-boot.qcow2` (the canonical name the
  whole tooling ecosystem already knows).
- **User-created machine** → `<imagesDir>/<os>-<shortid>.qcow2`, where
  `shortid` is the first 8 hex digits of the machine's UUID. Derived from the
  machine's *identity*, not its name, so renaming the machine never orphans
  or collides the file, and two same-OS machines can never fight over a
  filename.

The `imageClaimant` one-machine-per-image invariant stays as the backstop,
but auto-naming means the collision can't arise in the download path.

## UI flows

**Bundled fixture, no image (the fool-proof path):**

1. Overview of an imageless fixture shows **Download…** next to Start (and
   the welcome window's stub becomes this same flow). No path picker.
2. Confirm sheet: "Downloads the <OS> starter image (~250 MB, ~1.3 GB on
   disk) from <host>. It becomes this machine's disk." Disk-space preflight
   (need gz + decompressed headroom).
3. Fetch catalog → stream the payload with progress on the row's
   **thermometer** (the boot bar does download duty, yellow, with a
   "Downloading…" status) → verify gz sha → gunzip to a temp sibling →
   verify raw sha → **banner check** (`GuestOSDetector` must report the
   fixture's OS — third verification, essentially free) → atomic move to the
   canonical path → `registry.update(imagePath:)`.
4. Row flips to Stopped, Start goes live, launchers already seeded.

The user made zero choices (one, if they ever change the images directory in
Preferences). There is no step where a wrong image can reach a wrong machine.

**Second copy of a curated OS (requirement 2):**

1. `+` a new machine → kind Emulated VM → pick the OS in the free picker
   (say netbsd) → name it "NetBSD scratch".
2. Because the machine is emulated + imageless + its OS is in the catalog,
   the same **Download…** appears on its Overview. Same pipeline, but the
   destination is `netbsd-<shortid>.qcow2` — its own private copy.
3. Everything else P2 already handles: the machine got its own sticky port
   block at creation, derives its own MAC, so the bundled NetBSD and "NetBSD
   scratch" boot and run **concurrently** with zero extra design.

So the answer to "how do two NetBSDs work" is: they already do — the download
plan's only job is giving the second machine its own copy of the bits under
an identity-derived filename.

**Re-download over an existing image (factory reset):**

The qcow2 IS the user's disk state, so this is destructive and treated like
it: only offered while the machine is stopped, behind an explicit
"this replaces the machine's disk — its current state is lost" confirm, and
the old image is renamed to a dated `factory-reset` backup sibling first
(the SparcBackup naming machinery already exists). Not in v1 unless it's
cheap; "delete the image file in Finder, then Download again" is the honest
v0.

## Verification chain (summary)

1. `sha256Gz` on the downloaded stream (transport corruption).
2. `sha256` on the decompressed image (gunzip truncation, the NAS lesson).
3. `GuestOSDetector` banner match against the target machine's OS
   (wrong-payload-in-catalog, human upload error).
4. Existing start-time guards unchanged (image lock, port conflict).

## Build shape (when we get there)

- `ImageCatalog` (fetch + decode + entry-for-OS) and `ImageDownloader`
  (stream, progress callback, verify, gunzip, atomic install) in
  SwiftXServerCore — both testable against `file://` URLs with tiny fixture
  payloads, no network in tests.
- AppDelegate: a download state per machine id (progress → row thermometer),
  Download button wiring in Overview + welcome window.
- SPARCplug: `build-catalog.sh` + upload.
- Estimate: roughly a day of app work + the publishing script.

## Open questions

1. The exact pinned catalog URL. Hosting is oldsilicon.com (Todd already
   distributes these images there for ZuluSCSI); just needs the final path
   picked when `build-catalog.sh` lands.
2. ~~Which OSes ship~~ — settled 2026-07-06: **all three** (Solaris 2.6,
   SunOS 4.1.4, NetBSD).
3. Resume of interrupted downloads: v1 = restart from zero (250 MB is small
   enough), revisit if it annoys.
4. Catalog `version` → update UX (the old "Manage Plugins…" sketch).
   Deferred; v1 has no update checking at all.
