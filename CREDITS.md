# Credits

MacXServer leans on a lot of prior X11 work, ships some third-party code, and
transcribes a few 30-year-old algorithms straight from the X11R6 reference. This
file is the human-readable record of all of it. The app shows the same list with
full license texts under **MacXServer → Acknowledgements…** (backed by
`Sources/SwiftXServer/Acknowledgements.swift`; license bodies are generated into
`AcknowledgementsLicenseTexts.swift` by `Tools/regen_licenses.py`).

MacXServer itself is Copyright © 2026 Todd Vernon, released under Apache-2.0 (see
`LICENSE`).

## Bundled software

Third-party code we ship inside the app, either compiled in or as a helper
binary.

- **libvterm 0.3.3** (MIT). The terminal-emulator state machine behind the
  SPARCstation serial console. Vendored into `Sources/CVTerm` and compiled as a
  SwiftPM C target. `https://www.leonerd.org.uk/code/libvterm/`
- **QEMU 9.2.4** (GPL-2.0-or-later, some parts LGPL-2.1). The machine emulator
  that runs the bundled SPARCstation (emulated sun4m / SS-5 under Solaris 2.6).
  Shipped as an unmodified, SPARC-only build of the upstream release.
  `https://www.qemu.org`
  - GPL source availability: the complete corresponding source (unmodified
    upstream `qemu-9.2.4.tar.xz`, SHA-256
    `f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a`, plus our
    build scripts) is published as a source bundle on each MacXServer release.
    See `GPL_SOURCE.md` for the exact location and contents.
- **libslirp 4.9.3** (BSD-3-Clause). User-mode networking for the guest. Built
  into qemu-system-sparc as a meson subproject.
  `https://gitlab.freedesktop.org/slirp/libslirp`
- **Berkeley SoftFloat 3e** (BSD-3-Clause). IEEE floating-point emulation for
  QEMU's SPARC FPU. `http://www.jhauser.us/arithmetic/SoftFloat.html`
- **keycodemapdb** (BSD-3-Clause, also offered under GPL-2.0). Keycode-mapping
  tables QEMU compiles in. `https://gitlab.com/qemu-project/keycodemapdb`
- **OpenBIOS sparc32 1.1** (GPL-2.0). The Open Firmware the emulated
  SPARCstation boots from; prebuilt blob shipped in the bundle.
  `https://openbios.org`
- **GLib 2.x** (LGPL-2.1-or-later). QEMU's core utility library; dynamically
  linked and relinked into the bundle at packaging time.
  `https://gitlab.gnome.org/GNOME/glib`

## Transcribed source

Code we ported into our own tree from a reference implementation, keeping the
original copyright notices in each file header.

- **X Window System, X11R6** (X11 / X Consortium license). We transcribed the
  machine-independent region engine (`Region.swift`, `RegionOp.swift`,
  `RegionExtras.swift`, from `mi/miregion.c`), the SHAPE extension
  (`ShapeExtension.swift`, from `Xext/shape.c`), the RGB color database
  (`XColorDatabase.swift`, from `programs/rgb/rgb.txt`), the keysym tables
  (`Keysyms.generated.swift`, from `keysymdef.h`), and numerous wire-protocol
  struct layouts in `Framer` (from the X11R6 extension headers). The Swift ports
  are Apache-2.0; the X11R6-derived portions stay under the X Consortium license
  (and, where present, the matching Digital Equipment Corporation notice).
  `https://www.x.org`

## References studied

Prior art and specifications that shaped the design. No source from these is
copied into MacXServer.

- **XQuartz** — the most relevant prior art for an X server on macOS. Studied
  `hw/xquartz/` for NSEvent / NSWindow / NSPasteboard integration and rootless
  drag routing. `https://www.xquartz.org`
- **X11 Protocol Specification, ICCCM, and modern X.Org** — the wire format and
  inter-client conventions we implement against, cross-checked against modern
  libX11 and xproto. `https://www.x.org/releases/current/doc/`
- **OSF/Motif and CDE** — studied mwm decoration policy and Xt/Xm widget sizing
  so real dt-apps and quickplot render correctly.
  `https://sourceforge.net/projects/motif/`
