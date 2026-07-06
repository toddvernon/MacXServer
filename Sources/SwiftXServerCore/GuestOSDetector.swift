import Foundation

/// Identifies the guest OS of a qcow2 disk image by reading its *bytes* -- no
/// qemu, no subprocess, pure Swift. `qemu-img` writes uncompressed clusters by
/// default, so every guest data block sits verbatim in the file; a kernel banner
/// like `SunOS Release 5.6` physically exists, contiguous, many times over (kernel
/// banner, /etc/release, package metadata, man pages). We confirm the qcow2 magic,
/// then `memmem`-scan the mmap'd file for a small set of collision-free banner
/// strings. The design (why structural discriminators -- Sun VTOC, UFS magic --
/// can't separate Solaris/SunOS/NetBSD, why the linear scan is robust despite
/// cluster boundaries, and the compression caveat) is in SPARCSTATION_PLUGIN.md.
///
/// Used at image-pick time in the Machine Editor: the OS is queried from the image
/// rather than free-picked, so a config field can't drift out of sync with the
/// actual guest on the disk. Also catches "dropped the wrong file at the image
/// path" for free.
public enum GuestOSDetector {
    /// The collision-free kernel-banner signatures. Order doesn't matter (they're
    /// mutually exclusive), but keep the most-common image first.
    static let signatures: [(banner: String, os: MachineOS)] = [
        ("SunOS Release 5.6",   .solaris26),
        ("SunOS Release 4.1.4", .sunos414),
        ("NetBSD 9.2",          .netbsd),
    ]

    /// Detect the guest OS at `imagePath` (tilde-expanded). Never throws -- a
    /// missing/locked/oversized file returns `.unreadable`, so callers get a clean
    /// result they can act on. The mmap is lazy and the scan touches only the
    /// physically-allocated bytes (a few GB, not the 40 GB virtual size), so it
    /// finishes well under a second on the images we ship.
    public static func detect(imagePath: String) -> GuestOSDetection {
        let path = (imagePath as NSString).expandingTildeInPath
        guard !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: .mappedIfSafe)
        else { return .unreadable }
        return detect(data: data)
    }

    /// The byte-level core, split out so it's testable without a file.
    static func detect(data: Data) -> GuestOSDetection {
        guard data.count > 8, hasQcow2Magic(data) else { return .notQcow2 }

        let hit: (MachineOS, String)? = data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            for (banner, os) in signatures {
                let needle = Array(banner.utf8)
                if memmem(base.baseAddress, base.count, needle, needle.count) != nil {
                    return (os, banner)
                }
            }
            return nil
        }
        if let (os, banner) = hit { return .detected(os, banner: banner) }

        // No banner matched. Explain why rather than guess: a compressed image
        // hides its data from a linear scan (the one real caveat), so say so.
        return hasCompressedCluster(data) ? .compressed : .unrecognized
    }

    // MARK: - qcow2 structure (best-effort, all bounds-checked)

    private static func hasQcow2Magic(_ data: Data) -> Bool {
        let s = data.startIndex
        return data[s] == 0x51 && data[s + 1] == 0x46
            && data[s + 2] == 0x49 && data[s + 3] == 0xFB      // "QFI\xFB"
    }

    /// Walk the first populated L2 table and check the compressed-cluster flag
    /// (bit 62) on its entries. This is the "make `.unknown` explain itself"
    /// defense from the design -- best-effort, not a full L1/L2 traversal. Any
    /// out-of-bounds read aborts safely to `false` (we simply can't tell).
    static func hasCompressedCluster(_ data: Data) -> Bool {
        // qcow2 header, all big-endian: cluster_bits @20 (u32), l1_size @36 (u32),
        // l1_table_offset @40 (u64).
        guard let clusterBits = readBE32(data, 20), clusterBits >= 9, clusterBits <= 30,
              let l1Size = readBE32(data, 36), l1Size > 0,
              let l1Offset = readBE64(data, 40), l1Offset > 0
        else { return false }

        let clusterSize = 1 << Int(clusterBits)
        let l2Entries = clusterSize / 8
        let l1Base = Int(l1Offset)
        let l2Mask: UInt64 = 0x00ff_ffff_ffff_fe00   // offset bits of an L1 entry
        let compressedFlag: UInt64 = 0x4000_0000_0000_0000   // bit 62

        for i in 0..<Int(l1Size) {
            guard let l1e = readBE64(data, l1Base + i * 8) else { return false }
            let l2Offset = Int(l1e & l2Mask)
            if l2Offset == 0 { continue }            // this L1 slot is unallocated
            for j in 0..<l2Entries {
                guard let l2e = readBE64(data, l2Offset + j * 8) else { return false }
                if l2e & compressedFlag != 0 { return true }
            }
            return false   // walked one populated L2 table, nothing compressed
        }
        return false
    }

    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32? {
        let s = data.startIndex + offset
        guard offset >= 0, s + 4 <= data.endIndex else { return nil }
        return (UInt32(data[s]) << 24) | (UInt32(data[s + 1]) << 16)
             | (UInt32(data[s + 2]) << 8) | UInt32(data[s + 3])
    }

    private static func readBE64(_ data: Data, _ offset: Int) -> UInt64? {
        let s = data.startIndex + offset
        guard offset >= 0, s + 8 <= data.endIndex else { return nil }
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(data[s + k]) }
        return v
    }
}

/// The result of a `GuestOSDetector.detect`, designed so a non-detection explains
/// itself (per the SPARCSTATION_PLUGIN.md caveat) rather than collapsing every
/// miss into one opaque "unknown".
public enum GuestOSDetection: Equatable, Sendable {
    /// Matched a known kernel banner. `banner` is the exact signature (logged so
    /// the decision is self-documenting).
    case detected(MachineOS, banner: String)
    /// A valid qcow2 with none of our known banners -- a BYO image or an OS we
    /// don't have a signature for. The user sets the OS manually.
    case unrecognized
    /// A qcow2 whose data clusters are compressed (`qemu-img convert -c`), so the
    /// linear scan can't see the banners. Not our images today, but reported
    /// honestly instead of silently missing.
    case compressed
    /// The file isn't a qcow2 (bad magic or too short).
    case notQcow2
    /// Couldn't open / mmap the file (missing, unreadable, too large to map).
    case unreadable

    /// The detected OS, or nil for every non-detected case (the caller treats nil
    /// as "auto -- let the user pick").
    public var os: MachineOS? {
        if case .detected(let os, _) = self { return os }
        return nil
    }

    /// A short human explanation for the detail form's caption.
    public var explanation: String {
        switch self {
        case .detected(_, let banner): return "Detected \u{201c}\(banner)\u{201d} in the image."
        case .unrecognized: return "No known guest OS banner found \u{2014} set the OS manually."
        case .compressed:   return "Image clusters are compressed \u{2014} can't detect; set the OS manually."
        case .notQcow2:     return "Not a qcow2 disk image."
        case .unreadable:   return "Couldn't read the image file."
        }
    }
}
