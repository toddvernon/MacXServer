import Foundation

/// Pure naming + rotation policy for SPARCstation disk-image backups.
///
/// The file I/O (clone, delete, directory listing) lives in the app layer;
/// this is the decision logic, factored out so the destructive part --
/// choosing which files to delete during rotation -- is unit-testable without
/// touching a real filesystem.
///
/// Two kinds of backup sit next to the master image, distinguished by a marker
/// in the filename:
///   `<base> backup <date>[ (n)].<ext>`      -- manual, user-initiated, kept forever
///   `<base> autobackup <date>[ (n)].<ext>`  -- automatic, on clean shutdown, rotated
/// Rotation only ever considers the autobackup marker, so it can never delete
/// the master image or a manual backup.
public enum SparcBackup {

    public static let manualMarker = "backup"
    public static let autoMarker = "autobackup"

    /// A collision-free backup filename for `base`/`ext` with `marker` and the
    /// given date `stamp` (e.g. "2026-06-17"), avoiding any name already in
    /// `existing`. Same-day repeats get a " (2)", " (3)", ... suffix.
    public static func backupName(base: String, ext: String, marker: String,
                                  stamp: String, existing: Set<String>) -> String {
        let first = "\(base) \(marker) \(stamp).\(ext)"
        if !existing.contains(first) { return first }
        var n = 2
        while true {
            let candidate = "\(base) \(marker) \(stamp) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Whether `name` is an auto-backup of the image identified by `base`/`ext`.
    /// Requires the full "`<base> autobackup `" prefix, so a manual
    /// "`<base> backup ...`" never matches (it lacks the "auto").
    public static func isAutoBackup(name: String, base: String, ext: String) -> Bool {
        name.hasPrefix("\(base) \(autoMarker) ") && (name as NSString).pathExtension == ext
    }

    /// Given the directory's entries (filename + creation date) for the image
    /// `base`/`ext`, return the auto-backup filenames to delete so only the
    /// newest `keep` remain. Oldest-first by creation date. Returns only names
    /// that pass `isAutoBackup`, so the master image and manual backups are
    /// never selected. `keep <= 0` would delete all auto-backups; callers pass
    /// a positive keep.
    public static func autoBackupsToPrune(entries: [(name: String, created: Date)],
                                          base: String, ext: String,
                                          keep: Int) -> [String] {
        let autos = entries
            .filter { isAutoBackup(name: $0.name, base: base, ext: ext) }
            .sorted { $0.created < $1.created }   // oldest first
        guard autos.count > keep else { return [] }
        return autos.prefix(autos.count - keep).map(\.name)
    }
}
