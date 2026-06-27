import Foundation

// The data behind the Acknowledgements / Open Source Licenses screen.
//
// Three things every entry carries, per the design Todd asked for:
//   1. the full verbatim license text (embedded, so the screen works offline
//      and satisfies the "include this notice" obligations in MIT / GPL / etc.),
//   2. a link to the upstream project, and
//   3. a plain-English note on how we ACTUALLY used the thing -- whether we
//      bundle and ship it, transcribed its source into our tree, or only
//      studied it as a reference.
//
// License bodies live in AcknowledgementsLicenseTexts.swift (generated from the
// canonical files by Tools/regen_licenses.py). This file is the curated list.

struct Acknowledgement: Identifiable {

    /// How a component relates to MacXServer. Drives the grouping in the UI and
    /// the framing of each entry. Ordered for display.
    enum Kind: Int, CaseIterable {
        case app          // MacXServer itself
        case bundled      // shipped inside the app bundle (compiled in or as a helper)
        case transcribed  // source ported into our tree; upstream notices retained
        case referenced   // studied as prior art / spec; no source incorporated

        var sectionTitle: String {
            switch self {
            case .app:         return "This Application"
            case .bundled:     return "Bundled Software"
            case .transcribed: return "Transcribed Source"
            case .referenced:  return "References Studied"
            }
        }

        /// One line under the section header explaining what the group means.
        var sectionBlurb: String {
            switch self {
            case .app:
                return "MacXServer and its own source."
            case .bundled:
                return "Third-party code we ship inside the app, either compiled in or as a helper binary."
            case .transcribed:
                return "Code we ported into our own tree from a reference implementation, keeping the original copyright notices."
            case .referenced:
                return "Prior art and specifications we studied. No source from these is copied into MacXServer; they are credited because they shaped the design."
            }
        }
    }

    let id: String
    let name: String
    let version: String?
    let kind: Kind
    /// Short license label for the list row, e.g. "MIT", "GPL-2.0-or-later".
    let license: String
    /// Upstream project or repository page.
    let link: String
    /// Plain-English: how we actually used this.
    let usage: String
    /// Full verbatim license text. Empty for `.referenced` entries, where no
    /// source is incorporated and there is no notice obligation.
    let licenseText: String

    var url: URL? { URL(string: link) }
}

extension Acknowledgement {

    static let all: [Acknowledgement] = [

        // MARK: - This application

        Acknowledgement(
            id: "macxserver",
            name: "MacXServer",
            version: nil,
            kind: .app,
            license: "Apache-2.0",
            link: "https://github.com/toddvernon/MacXServer",
            usage: """
            MacXServer is a modern X11 server written in Swift for macOS. \
            Copyright © 2026 Todd Vernon, released under the Apache License 2.0. \
            The full text of every license that covers the third-party code we \
            ship or built on is reproduced in this window.
            """,
            licenseText: LicenseText.apache2),

        // MARK: - Bundled software

        Acknowledgement(
            id: "libvterm",
            name: "libvterm",
            version: "0.3.3",
            kind: .bundled,
            license: "MIT",
            link: "https://www.leonerd.org.uk/code/libvterm/",
            usage: """
            The terminal-emulator state machine behind the captive SPARCstation \
            serial console (the interactive vt100 you type into). We vendor the \
            C source into our tree and compile it as a SwiftPM C target (CVTerm); \
            it is not fetched as a package, not a prebuilt .a/.dylib, and not a \
            separate process. Unmodified upstream.
            """,
            licenseText: LicenseText.mitLibvterm),

        Acknowledgement(
            id: "qemu",
            name: "QEMU",
            version: "9.2.4",
            kind: .bundled,
            license: "GPL-2.0-or-later",
            link: "https://www.qemu.org",
            usage: """
            The machine emulator that runs the bundled SPARCstation (an emulated \
            sun4m / SPARCstation-5 booting Solaris 2.6). We ship a stripped, \
            SPARC-only build of the unmodified upstream 9.2.4 release as a helper \
            binary inside the app bundle.

            QEMU is released under the GNU General Public License, version 2; some \
            components are under the GNU Lesser General Public License (reproduced \
            in the GLib entry) and other GPL-compatible licenses.

            GPL source availability: because we distribute a GPLv2 binary, the \
            complete corresponding source is published. It is the unmodified \
            upstream release qemu-9.2.4.tar.xz (SHA-256 \
            f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a from \
            https://download.qemu.org, with only the unused roms/ directory pruned) \
            plus the scripts we use to build it, attached as a source bundle to \
            each MacXServer release. See GPL_SOURCE.md in the project repository \
            for the exact location and contents.
            """,
            licenseText: LicenseText.gpl2),

        Acknowledgement(
            id: "libslirp",
            name: "libslirp",
            version: "4.9.3",
            kind: .bundled,
            license: "BSD-3-Clause",
            link: "https://gitlab.freedesktop.org/slirp/libslirp",
            usage: """
            User-mode TCP/IP networking for the guest: the whole path that lets \
            the Solaris VM reach the network (and the in-guest Helios daemon over \
            a host-forwarded port) with no tun device and no elevated privileges. \
            Built into qemu-system-sparc as a meson subproject, fetched from \
            upstream at build time.
            """,
            licenseText: LicenseText.bsd3Slirp),

        Acknowledgement(
            id: "berkeley-softfloat",
            name: "Berkeley SoftFloat",
            version: "Release 3e",
            kind: .bundled,
            license: "BSD-3-Clause",
            link: "http://www.jhauser.us/arithmetic/SoftFloat.html",
            usage: """
            IEEE-754 floating-point emulation that QEMU uses for the SPARC FPU. \
            Linked into qemu-system-sparc as a meson subproject. Unmodified.
            """,
            licenseText: LicenseText.bsd3SoftFloat),

        Acknowledgement(
            id: "keycodemapdb",
            name: "keycodemapdb",
            version: nil,
            kind: .bundled,
            license: "BSD-3-Clause (also offered under GPL-2.0)",
            link: "https://gitlab.com/qemu-project/keycodemapdb",
            usage: """
            The keycode-mapping tables QEMU uses to translate host key events into \
            guest scancodes. A build-time code generator whose output is compiled \
            into qemu-system-sparc. Dual-licensed BSD-3-Clause / GPLv2; we use it \
            under BSD-3-Clause.
            """,
            licenseText: LicenseText.bsd3KeycodeMapDB),

        Acknowledgement(
            id: "openbios",
            name: "OpenBIOS (sparc32)",
            version: "1.1",
            kind: .bundled,
            license: "GPL-2.0",
            link: "https://openbios.org",
            usage: """
            The Open Firmware implementation the emulated SPARCstation boots from. \
            We ship the prebuilt openbios-sparc32 blob (from the QEMU pc-bios set) \
            in the app bundle; we do not build it ourselves. Distributed under the \
            GNU General Public License, version 2 (full text in the QEMU entry). \
            Its corresponding source is the OpenBIOS project linked here, mirrored \
            in the same release source bundle as the QEMU source (see \
            GPL_SOURCE.md in the project repository).
            """,
            licenseText: ""),

        Acknowledgement(
            id: "glib",
            name: "GLib",
            version: "2.x",
            kind: .bundled,
            license: "LGPL-2.1-or-later",
            link: "https://gitlab.gnome.org/GNOME/glib",
            usage: """
            QEMU's core utility library (data structures, main event loop). \
            Dynamically linked; the dylib is relinked into the app bundle at \
            packaging time so the helper runs without a system-wide GLib. \
            Unmodified. As an LGPL library it can be replaced: the corresponding \
            object code and relink instructions are published in the same release \
            source bundle as the QEMU source (see GPL_SOURCE.md in the project \
            repository).
            """,
            licenseText: LicenseText.lgpl21),

        // MARK: - Transcribed source

        Acknowledgement(
            id: "x11r6",
            name: "X Window System (X11R6)",
            version: "R6, 1994",
            kind: .transcribed,
            license: "X11 / X Consortium (MIT-style)",
            link: "https://www.x.org",
            usage: """
            A working X server is full of 30-year-old algorithms that are easier \
            to port faithfully than to re-derive. We transcribed several pieces of \
            the X11R6 sample server and its protocol headers directly into Swift, \
            and we keep the original X Consortium (and, where present, Digital \
            Equipment Corporation) copyright notices in each ported file's header, \
            as the license requires.

            What we ported: the machine-independent region engine (Region.swift, \
            RegionOp.swift, RegionExtras.swift, from mi/miregion.c); the SHAPE \
            extension (ShapeExtension.swift, from Xext/shape.c); the RGB color \
            database (XColorDatabase.swift, from programs/rgb/rgb.txt); the keysym \
            tables (Keysyms.generated.swift, from keysymdef.h); and numerous \
            wire-protocol struct layouts in the Framer module, from the X11R6 \
            extension headers (SHAPE, MIT-SHM, XKB, and others).

            The Swift ports are Copyright © 2026 Todd Vernon under Apache-2.0; the \
            portions derived from X11R6 remain governed by the X Consortium license \
            reproduced below.
            """,
            licenseText: LicenseText.x11Consortium),

        // MARK: - References studied

        Acknowledgement(
            id: "xquartz",
            name: "XQuartz",
            version: nil,
            kind: .referenced,
            license: "Reference only — no source incorporated",
            link: "https://www.xquartz.org",
            usage: """
            The most relevant prior art for running an X server on macOS. We \
            studied its hw/xquartz/ layer to understand NSEvent / NSWindow / \
            NSPasteboard integration and rootless cross-window drag routing. No \
            XQuartz source is copied into MacXServer; it is credited here because \
            it shaped the design.
            """,
            licenseText: ""),

        Acknowledgement(
            id: "x11-spec",
            name: "X11 Protocol Specification, ICCCM, and modern X.Org",
            version: nil,
            kind: .referenced,
            license: "Reference only — no source incorporated",
            link: "https://www.x.org/releases/current/doc/",
            usage: """
            The wire format and inter-client conventions come from the X Window \
            System Protocol specification (Scheifler, Gettys, et al.) and the \
            Inter-Client Communication Conventions Manual. We also cross-checked \
            era-correct behavior against modern X.Org libX11 and xproto. These are \
            specifications we implemented against, not code we copied.
            """,
            licenseText: ""),

        Acknowledgement(
            id: "motif-cde",
            name: "OSF/Motif and CDE",
            version: nil,
            kind: .referenced,
            license: "Reference only — no source incorporated",
            link: "https://sourceforge.net/projects/motif/",
            usage: """
            To make real Motif and CDE applications render correctly (dtterm, \
            dtcalc, dthelpview, quickplot) we studied the mwm window-manager \
            decoration policy and the Xt/Xm widget sizing rules in the OSF/Motif \
            and CDE sources. Used purely as a behavioral reference; no Motif or CDE \
            source is included in MacXServer.
            """,
            licenseText: ""),
    ]

    /// Entries for a given section, in declared order.
    static func entries(in kind: Kind) -> [Acknowledgement] {
        all.filter { $0.kind == kind }
    }
}
