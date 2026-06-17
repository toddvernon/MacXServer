import XCTest
@testable import SwiftXServerCore

final class SparcBackupTests: XCTestCase {

    // MARK: - Naming

    func testBackupNameNoCollision() {
        let name = SparcBackup.backupName(base: "SUN40G", ext: "qcow2",
                                          marker: SparcBackup.autoMarker,
                                          stamp: "2026-06-17", existing: [])
        XCTAssertEqual(name, "SUN40G autobackup 2026-06-17.qcow2")
    }

    func testBackupNameSameDaySuffixes() {
        var existing: Set<String> = ["SUN40G autobackup 2026-06-17.qcow2"]
        let second = SparcBackup.backupName(base: "SUN40G", ext: "qcow2",
                                            marker: SparcBackup.autoMarker,
                                            stamp: "2026-06-17", existing: existing)
        XCTAssertEqual(second, "SUN40G autobackup 2026-06-17 (2).qcow2")
        existing.insert(second)
        let third = SparcBackup.backupName(base: "SUN40G", ext: "qcow2",
                                           marker: SparcBackup.autoMarker,
                                           stamp: "2026-06-17", existing: existing)
        XCTAssertEqual(third, "SUN40G autobackup 2026-06-17 (3).qcow2")
    }

    func testManualAndAutoMarkersDistinct() {
        let manual = SparcBackup.backupName(base: "SUN40G", ext: "qcow2",
                                            marker: SparcBackup.manualMarker,
                                            stamp: "2026-06-17", existing: [])
        XCTAssertEqual(manual, "SUN40G backup 2026-06-17.qcow2")
        // A manual name is NOT an auto-backup -- the safety boundary.
        XCTAssertFalse(SparcBackup.isAutoBackup(name: manual, base: "SUN40G", ext: "qcow2"))
    }

    // MARK: - isAutoBackup boundary

    func testIsAutoBackupOnlyMatchesAutoMarker() {
        let base = "SUN40G", ext = "qcow2"
        XCTAssertTrue(SparcBackup.isAutoBackup(name: "SUN40G autobackup 2026-06-17.qcow2", base: base, ext: ext))
        // Master image
        XCTAssertFalse(SparcBackup.isAutoBackup(name: "SUN40G.qcow2", base: base, ext: ext))
        // Manual backup
        XCTAssertFalse(SparcBackup.isAutoBackup(name: "SUN40G backup 2026-06-17.qcow2", base: base, ext: ext))
        // Different image's auto-backup
        XCTAssertFalse(SparcBackup.isAutoBackup(name: "OTHER autobackup 2026-06-17.qcow2", base: base, ext: ext))
        // Right name, wrong extension
        XCTAssertFalse(SparcBackup.isAutoBackup(name: "SUN40G autobackup 2026-06-17.img", base: base, ext: ext))
    }

    // MARK: - Rotation

    private func d(_ day: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(day) * 86_400) }

    func testPruneKeepsNewestN() {
        let entries: [(name: String, created: Date)] = [
            ("SUN40G autobackup 2026-06-10.qcow2", d(10)),
            ("SUN40G autobackup 2026-06-11.qcow2", d(11)),
            ("SUN40G autobackup 2026-06-12.qcow2", d(12)),
            ("SUN40G autobackup 2026-06-13.qcow2", d(13)),
        ]
        let doomed = SparcBackup.autoBackupsToPrune(entries: entries, base: "SUN40G", ext: "qcow2", keep: 2)
        // Keep the two newest (12, 13); delete the two oldest (10, 11).
        XCTAssertEqual(Set(doomed), [
            "SUN40G autobackup 2026-06-10.qcow2",
            "SUN40G autobackup 2026-06-11.qcow2",
        ])
    }

    func testPruneNothingWhenUnderLimit() {
        let entries: [(name: String, created: Date)] = [
            ("SUN40G autobackup 2026-06-12.qcow2", d(12)),
            ("SUN40G autobackup 2026-06-13.qcow2", d(13)),
        ]
        XCTAssertTrue(SparcBackup.autoBackupsToPrune(entries: entries, base: "SUN40G", ext: "qcow2", keep: 5).isEmpty)
    }

    /// The load-bearing safety test: rotation must never select the master
    /// image or a manual backup, even when they're the oldest files present.
    func testPruneNeverTouchesMasterOrManualBackups() {
        let entries: [(name: String, created: Date)] = [
            ("SUN40G.qcow2", d(1)),                              // master, oldest
            ("SUN40G backup 2026-06-02.qcow2", d(2)),            // manual, old
            ("SUN40G autobackup 2026-06-10.qcow2", d(10)),
            ("SUN40G autobackup 2026-06-11.qcow2", d(11)),
            ("SUN40G autobackup 2026-06-12.qcow2", d(12)),
        ]
        let doomed = SparcBackup.autoBackupsToPrune(entries: entries, base: "SUN40G", ext: "qcow2", keep: 1)
        // keep=1 -> delete the two oldest AUTO-backups only; master + manual untouched.
        XCTAssertEqual(Set(doomed), [
            "SUN40G autobackup 2026-06-10.qcow2",
            "SUN40G autobackup 2026-06-11.qcow2",
        ])
        XCTAssertFalse(doomed.contains("SUN40G.qcow2"))
        XCTAssertFalse(doomed.contains("SUN40G backup 2026-06-02.qcow2"))
    }
}
