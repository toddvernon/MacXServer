# Corresponding source for GPL / LGPL components

MacXServer bundles a few components covered by the GNU GPL and LGPL. This file
is the canonical source-availability statement the app's Acknowledgements screen
points to. It satisfies our obligation, under GPLv2 section 3(a), to make the
complete corresponding source available alongside the binary.

The app menu **MacXServer → Acknowledgements…** shows the full license texts;
this file is the "where to get the source" companion.

The corresponding-source bundle this statement promises is assembled by
`Tools/make-gpl-source-bundle.sh`.

## QEMU 9.2.4 (GPL-2.0-or-later)

MacXServer ships a SPARC-only build of QEMU as a helper binary
(`qemu-system-sparc`) to run the bundled SPARCstation. QEMU is **unmodified
upstream**: it is the public release `qemu-9.2.4.tar.xz`,

    https://download.qemu.org/qemu-9.2.4.tar.xz
    sha256  f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a

The only change to the vendored tree is that the `roms/` directory (firmware
source for non-SPARC targets, which a SPARC-only build never compiles) is
pruned. No QEMU source is edited.

The **complete corresponding source** — the upstream tarball above plus the
scripts we use to control its compilation — is published as a source bundle
attached to each MacXServer release:

    https://github.com/toddvernon/MacXServer/releases

The bundle contains:

- `qemu-9.2.4.tar.xz` (byte-identical to the upstream release; verify the
  SHA-256 above)
- the SPARCplug build scripts that drive the SPARC-only configure/compile
  (`build-qemu.sh` and the meson configuration it passes)

That is everything needed to reproduce `qemu-system-sparc` from source.

## OpenBIOS sparc32 (GPL-2.0)

The emulated SPARCstation boots the prebuilt `openbios-sparc32` Open Firmware
blob from QEMU's `pc-bios` set; MacXServer does not build it. Its corresponding
source is the OpenBIOS project,

    https://openbios.org   (source: https://github.com/openbios/openbios)

mirrored in the same release source bundle as the QEMU source, above.

## GLib (LGPL-2.1-or-later)

QEMU links GLib dynamically; the unmodified dylib is relinked into the app
bundle at packaging time. As an LGPL library it may be replaced with a modified
version: the corresponding object code and relink instructions are available in
the same release source bundle.

---

Questions about source availability: todd@toddvernon.com
