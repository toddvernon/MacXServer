import Foundation

/// Turn a macOS filename into one that's pleasant to use from a 1998 Solaris
/// shell. Solaris 2.6 UFS allows almost any byte in a name (only '/' and NUL are
/// illegal), so a literal "my report (final).txt" would *store* fine -- but it's
/// miserable to type, tab-complete, glob, or script against in the era's Bourne
/// shell, and high (non-ASCII) bytes confuse the period's non-UTF-8 tools. So
/// when uploading we map anything outside a conservative portable set to '_',
/// collapse runs of unsafe characters, and defuse a leading '-' (which old
/// commands read as an option). This is cosmetic safety, not a correctness
/// requirement -- the daemon would accept the raw name -- but it keeps files
/// usable on the box.
public enum SolarisFilename {

    /// POSIX "portable filename character set" plus nothing else: letters,
    /// digits, dot, underscore, hyphen.
    private static let safe = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Sanitize one path *component* (a bare filename, never a path with '/').
    /// Idempotent: a name that's already safe comes back unchanged.
    public static func sanitize(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        var lastWasFill = false
        for ch in name {
            if safe.contains(ch) {
                out.append(ch)
                lastWasFill = false
            } else if !lastWasFill {
                // Collapse a run of unsafe chars (spaces, quotes, globs, accented
                // letters, ...) into a single '_'.
                out.append("_")
                lastWasFill = true
            }
        }
        // A leading '-' is read as an option by old tools (`rm -foo`); prefix it.
        if out.hasPrefix("-") { out = "_" + out }
        // Never hand back something empty or a directory reference.
        if out.isEmpty || out == "." || out == ".." { out = "_" + out }
        // UFS component limit is 255 bytes; the result is ASCII, so chars == bytes.
        if out.count > 255 { out = String(out.prefix(255)) }
        return out
    }
}
