# Status 2026-07-10 (afternoon roll)

## Headline: release-blocker day. A readiness audit this morning found four
launch blockers; by afternoon the two engineering ones are closed — the
release pipeline now embeds + signs the SPARCplug engine and attaches the
GPL source bundle (punchlist A5/A4), and the curated image downloader is
built end-to-end (Track C / IMAGE_DOWNLOAD_PLAN.md). Suite 1516 green.
What's left before a public v0.9.9 is data + design: publish the catalog
(E1 gate), architect Helios-driven user management (shipped images can't
carry Todd's account as the only login), and settle the first-launch
experience. (Morning entry: menu-bar reorg — see git log for the previous
roll.)

## What happened this session

**1. Release-readiness audit** (subagent, full-tree). Verdict: closer than
expected — 11 signed/notarized releases already shipped, pipeline proven,
first-run clean, secrets hygiene clean, licensing thorough. Four blockers:
(a) Release bundle ships without the qemu engine (A5 never wired), (b) GPL
source bundle promised but never attached, (c) image downloader missing,
(d) public v0.9.8 is a month stale and predates the 2026-07-06 remote-DoS
fix. Should-fix list: Gatekeeper first-launch walkthrough for the site,
MARKETING_VERSION clobbered by xcodegen regen, no update check, a
user-facing known-limitations page, duplicate OPCODE_STATUS rows (3, 22).

**2. Blockers (a)+(b) closed — release.sh** (commit bcc423b). MacXServer
releases now hard-fail without a sane SPARCplug dist/ (relink audit via
otool, binary version cross-checked against qemu.lock); after export the
engine is embedded (Contents/Helpers + Resources/qemu-firmware, the layout
QemuEngine.defaultConfig resolves) and signed inside-out (dylibs → helper
with qemu.entitlements → outer re-seal) before the unchanged notarize
tail; the GPL corresponding-source bundle is assembled per release and
attached to the GitHub release. Signing recipe re-validated on a scratch
bundle with the real Developer ID (verify clean, JIT entitlements present,
helper boots and loads bundled dylibs). Version-bump fix: the old sed hit
only the framework targets' MARKETING_VERSION; both app targets now carry
real defaults in project.yml behind "# release-version <App>" markers that
release.sh bumps + regenerates. Remaining proof: the first real release
run + A6 clean-Mac acceptance.

**3. Blocker (c) closed — curated image downloader** (commit 70343d6, X;
0e7690c, SPARCplug). ImageCatalog + ImageDownloader in SwiftXServerCore:
catalog fetch-on-click keyed by MachineOS (wrong-image-to-wrong-machine
impossible by construction), then stream-with-progress → sha256(gz) →
gunzip → sha256(image) → GuestOSDetector banner check → atomic move into
~/Library/Application Support/macXserver/Images/. Download Image… on the
Overview of any imageless emulated VM with a known OS; the welcome
window's dead stub routes into the same flow; row thermometer does
download duty with per-phase status + Cancel; on success the image
attaches and Start goes live. Catalog pinned to
https://macxserver.com/images/catalog.json (Todd's call — DECISIONS
2026-07-10; the plan had said oldsilicon.com), SPARCPLUG_CATALOG_URL dev
override. SPARCplug's build-catalog.sh emits the upload-ready staging dir.
13 new tests, all file:// fixtures. Ledgered in SHORTCUTS: images dir has
no preference UI yet, no factory-reset re-download, catalog not hosted
yet.

## What's working / what's broken

- swift build clean, swift test: **1516 tests, 0 failures** (was 1503;
  +13 new for catalog/downloader, one name fix).
- xcodegen re-run; the .xcodeproj carries the new core files + app-target
  versions (0.9.8 / 0.9.1).
- The Download button fails cleanly until the catalog is uploaded (by
  design — SHORTCUTS has the exit plan). Test the full flow any time with
  SPARCPLUG_CATALOG_URL=file:///…/catalog.json against build-catalog.sh
  output.
- NOT yet verified in the real app: the download UI (needs the Xcode
  rebuild + a local catalog), plus yesterday's menu-bar work — the manual
  GUI checklist from the morning roll still stands.

## User management + first run (this session, afternoon/evening)

- **Designed + ratified.** HELIOS_USER_MANAGEMENT.md (host-driven over the
  existing verbs) + FIRST_RUN_EXPERIENCE.md (Todd's in-window guided flow:
  "just getting started" bubble, blue Download, "one more thing -- add a
  user" popup on download completion, Enter boots + applies the login at
  ready). DECISIONS 2026-07-10. One decision still open: root-password
  policy for published masters.
- **UserAdmin core BUILT** (commit 5f160c8). Per-OS record builders
  (Solaris passwd+shadow, 4.1.4 hash-in-passwd, NetBSD master.passwd +
  pwd_mkdb), crypt(3) DES hash host-side, commit-point ordering, rm-guard.
  21 unit tests + a live add->run-as->delete cycle **passed on the running
  NetBSD guest**.
- **Users panel BUILT** (this commit). UsersPanelView + UsersWindowController
  (modeled on DNS admin): account list, Add sheet, Delete confirm with
  optional home removal. Overview "Users" chip (gated on answering + known
  OS) + Machines-menu Admin item. "Use for launchers" adopts the account as
  machine.user + telnet Keychain (adoptMachineLogin, shared with first run).

## What's next

1. **First-run choreography** (FIRST_RUN_EXPERIENCE.md): the bubble +
   blue-button state in MachinesWindowView, the "one more thing" sheet,
   deferred-apply-at-ready plumbing, and the `machine.user = ""` fixture
   seeding change. The last code piece before the stranger's path is whole.
2. Data side of the catalog: E1 (baseline masters with current heliosAgent
   baked in) → build-catalog.sh → upload to macxserver.com/images/. Also
   settle the root-password policy here.
3. Todd's manual GUI pass (menu bar + download flow + Users panel), then
   v0.9.9 — which also proves A5/A6 end-to-end.
4. Run the UserAdmin live test against Solaris 2.6 + 4.1.4 too (one env var
   each when those guests are booted).

## Committed / push state

- X repo: 16 commits UNPUSHED on this Mac (11 from 07-09/07-10 morning +
  bcc423b release pipeline + 70343d6 image downloader + fc3ca77 status/user
  docs + 79f22dc first-run docs + 5f160c8 UserAdmin core + this Users-panel
  commit). **Push before switching machines.**
- SPARCplug: 1 commit unpushed (0e7690c build-catalog.sh).
- cx repos: no changes.

## Switching Macs

- Code + project.yml + .xcodeproj changed: rebuild in Xcode on the other
  Mac after pulling.
- A netbsd guest was live under the Xcode debug build most of the day
  (lock held at images/netbsd/…); shut it down before /eos if wrapping up.
