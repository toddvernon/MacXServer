import XCTest
@testable import SwiftXServerCore

@MainActor
final class MachineRegistryTests: XCTestCase {

    private func tempPath(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    func testLoadSeedsBundledFixturesOnFirstRun() {
        let path = tempPath("machines")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let registry = MachineRegistry.load(
            path: path,
            launchersPath: "/nonexistent-launchers",   // force the empty-launchers path
            bundledImagePath: "/tmp/bundled.qcow2")
        // First run seeds one imageless bundled fixture per emulatable guest
        // OS, persisted (external-only OSes like IRIX have no fixture).
        let emulatable = MachineOS.allCases.filter { $0.emulatable }
        XCTAssertEqual(registry.machines.count, emulatable.count)
        XCTAssertTrue(registry.machines.allSatisfy { $0.bundled && $0.image == nil })
        XCTAssertEqual(Set(registry.machines.compactMap { $0.os }), Set(emulatable))
        // Bundled fixtures keep deriving their well-known per-OS port blocks --
        // the load-time sticky assignment must not materialize blocks on them.
        XCTAssertTrue(registry.machines.allSatisfy { $0.ports == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSnapshotDistinguishesEmulatedAndExternal() throws {
        // installed is filesystem-honest (a deleted image un-installs the
        // machine), so the fixture image must really exist.
        let image = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).qcow2")
        try Data("qcow2-stub".utf8).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let registry = MachineRegistry(machines: [
            Machine(name: "Solaris", kind: .emulatedVM, os: .solaris26,
                    host: "127.0.0.1", user: "t", imagePath: image.path),
            Machine(name: "ss5", kind: .externalHost, host: "192.168.7.19", user: "t"),
        ], path: tempPath("snap"))
        let snap = registry.snapshot()
        let emulated = snap.first { $0.kind == .emulatedVM }
        let external = snap.first { $0.kind == .externalHost }
        // No controller yet: emulated reports not-running/not-ready but installed.
        XCTAssertEqual(emulated?.running, false)
        XCTAssertEqual(emulated?.ready, false)
        XCTAssertEqual(emulated?.installed, true)
        // External has no lifecycle we own -> nils.
        XCTAssertNil(external?.running)
        XCTAssertNil(external?.ready)
    }

    func testDeletingTheImageUninstallsTheMachine() throws {
        // The 2026-07-26 wizard-retest find: imagePath stays set in
        // machines.json after an install, so the check must be about the
        // FILE, not the field -- rm the qcow2 and the machine honestly
        // returns to imageless (hero pane / "Not installed").
        let image = FileManager.default.temporaryDirectory
            .appendingPathComponent("uninstall-\(UUID().uuidString).qcow2")
        try Data("qcow2-stub".utf8).write(to: image)
        let m = Machine(name: "NetBSD", kind: .emulatedVM, os: .netbsd,
                        host: "127.0.0.1", user: "t", imagePath: image.path)
        XCTAssertTrue(m.isInstalledEmulatedVM)
        try FileManager.default.removeItem(at: image)
        XCTAssertFalse(m.isInstalledEmulatedVM)
    }

    func testUpdatePersistsAndReloads() throws {
        let path = tempPath("update")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let machine = Machine(name: "box", kind: .externalHost, host: "10.0.0.5", user: "a")
        let registry = MachineRegistry(machines: [machine], path: path)

        var edited = machine
        edited.name = "renamed"
        registry.update(edited)

        // The change round-trips through the on-disk JSON.
        let reloaded = try MachinesFile.decode(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(reloaded.machines.count, 1)
        XCTAssertEqual(reloaded.machines[0].name, "renamed")
        XCTAssertEqual(reloaded.machines[0].id, machine.id)
    }

    // (The reconcile(withMigrated:) tests died with the API on 2026-07-28:
    // the legacy launchers file is one-shot migration input, deleted after
    // import -- there is nothing to reconcile from anymore.)

    func testMigrationDeletesLegacyLaunchersFile() throws {
        let machinesPath = tempPath("kill-migrate")
        let launchersPath = tempPath("kill-migrate-launchers")
        defer {
            try? FileManager.default.removeItem(atPath: machinesPath)
            try? FileManager.default.removeItem(atPath: launchersPath)
        }
        try """
        [host:u5]
        host = u5.example.com
        user = alice

        [u5/xterm]
        command = xterm
        """.write(toFile: launchersPath, atomically: true, encoding: .utf8)

        let file = MachinesFileLoader.loadOrMigrate(
            path: machinesPath, launchersPath: launchersPath, bundledImagePath: "")
        // The launchers made it into machines.json...
        XCTAssertTrue(file.machines.contains { $0.name == "u5" })
        // ...and the legacy file is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchersPath))
    }

    func testLoadSweepsLingeringLaunchersFileAfterEarlierMigration() throws {
        // An install migrated before 2026-07-28 has machines.json AND the
        // stale launchers file. A normal load removes the stale file and
        // leaves the registry untouched.
        let machinesPath = tempPath("kill-sweep")
        let launchersPath = tempPath("kill-sweep-launchers")
        defer {
            try? FileManager.default.removeItem(atPath: machinesPath)
            try? FileManager.default.removeItem(atPath: launchersPath)
        }
        let existing = MachinesFile(machines: MachineMigrator.bundledFixtures())
        try existing.encoded().write(toFile: machinesPath, atomically: true, encoding: .utf8)
        try "[host:u5]\nhost = u5.example.com\nuser = a\n"
            .write(toFile: launchersPath, atomically: true, encoding: .utf8)

        let file = MachinesFileLoader.loadOrMigrate(
            path: machinesPath, launchersPath: launchersPath, bundledImagePath: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchersPath))
        // The stale file's content did NOT leak into the registry.
        XCTAssertFalse(file.machines.contains { $0.name == "u5" })
    }

    // MARK: - Images-folder move (2026-07-28)

    private func makeImageDir(_ name: String, files: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: tempPath(name), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            try Data("qcow2-stub".utf8).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    func testMoveImagesMovesReferencedFilesAndRewritesPaths() throws {
        let old = try makeImageDir("mv-old", files: ["a.qcow2", "b.qcow2", "unrelated.txt"])
        let new = URL(fileURLWithPath: tempPath("mv-new"), isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        let a = Machine(name: "a", kind: .emulatedVM, os: .solaris26, host: "127.0.0.1",
                        user: "t", imagePath: old.appendingPathComponent("a.qcow2").path)
        let b = Machine(name: "b", kind: .emulatedVM, os: .netbsd, host: "127.0.0.1",
                        user: "t", imagePath: old.appendingPathComponent("b.qcow2").path)
        // An external host and a machine with an image elsewhere are untouched.
        let ext = Machine(name: "ext", kind: .externalHost, host: "h", user: "u")
        let path = tempPath("mv-registry")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let registry = MachineRegistry(machines: [a, b, ext], path: path)

        XCTAssertEqual(registry.machinesWithImages(in: old).map(\.name), ["a", "b"])
        let moved = try registry.moveImages(from: old, to: new)
        XCTAssertEqual(moved, 2)

        // Files moved; unrelated file stayed; machine paths follow.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("a.qcow2").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: old.appendingPathComponent("a.qcow2").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: old.appendingPathComponent("unrelated.txt").path))
        XCTAssertEqual(registry.machine(a.id)?.imagePath,
                       new.appendingPathComponent("a.qcow2").path)
        XCTAssertTrue(registry.machine(a.id)!.isInstalledEmulatedVM)

        // The rewrite persisted.
        let reloaded = try MachinesFile.decode(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(reloaded.machines.first { $0.name == "a" }?.imagePath,
                       new.appendingPathComponent("a.qcow2").path)
    }

    func testMoveImagesRefusesOccupiedDestinationBeforeMovingAnything() throws {
        let old = try makeImageDir("mv-occ-old", files: ["a.qcow2", "b.qcow2"])
        // Destination already holds b.qcow2 -- the up-front check must refuse
        // before ANY file moves, so a.qcow2 stays put too.
        let new = try makeImageDir("mv-occ-new", files: ["b.qcow2"])
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        let a = Machine(name: "a", kind: .emulatedVM, os: .solaris26, host: "127.0.0.1",
                        user: "t", imagePath: old.appendingPathComponent("a.qcow2").path)
        let b = Machine(name: "b", kind: .emulatedVM, os: .netbsd, host: "127.0.0.1",
                        user: "t", imagePath: old.appendingPathComponent("b.qcow2").path)
        let registry = MachineRegistry(machines: [a, b], path: tempPath("mv-occ-reg"))
        defer { try? FileManager.default.removeItem(atPath: tempPath("mv-occ-reg")) }

        XCTAssertThrowsError(try registry.moveImages(from: old, to: new)) { error in
            guard case MachineRegistry.ImageMoveError.destinationOccupied = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: old.appendingPathComponent("a.qcow2").path))
        XCTAssertEqual(registry.machine(a.id)?.imagePath,
                       old.appendingPathComponent("a.qcow2").path)
    }

    func testMoveImagesNoOpWhenNothingReferenced() throws {
        let old = try makeImageDir("mv-none", files: ["stray.qcow2"])
        let new = URL(fileURLWithPath: tempPath("mv-none-new"), isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        let registry = MachineRegistry(
            machines: [Machine(name: "x", kind: .externalHost, host: "h", user: "u")],
            path: tempPath("mv-none-reg"))
        XCTAssertEqual(try registry.moveImages(from: old, to: new), 0)
        // Unreferenced files never move.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: old.appendingPathComponent("stray.qcow2").path))
    }

    func testUpdateIgnoresUnknownId() {
        let registry = MachineRegistry(machines: [
            Machine(name: "a", kind: .externalHost, host: "h", user: "u"),
        ], path: tempPath("noop"))
        let stranger = Machine(name: "b", kind: .externalHost, host: "h2", user: "u2")
        registry.update(stranger)   // id not in the registry
        XCTAssertEqual(registry.machines.count, 1)
        XCTAssertEqual(registry.machines[0].name, "a")
    }

    // MARK: - add / remove / clone / imageClaimant (P1c editor)

    func testAddPersistsAndReloads() throws {
        let path = tempPath("add")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let registry = MachineRegistry(machines: [], path: path)
        let m = Machine(name: "u5", kind: .externalHost, host: "u5.example.com", user: "a")
        registry.add(m)
        XCTAssertEqual(registry.machines.count, 1)
        let reloaded = try MachinesFile.decode(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(reloaded.machines.map(\.id), [m.id])
    }

    func testRemovePersistsAndDropsController() throws {
        let path = tempPath("remove")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = Machine(name: "a", kind: .externalHost, host: "h1", user: "u")
        let b = Machine(name: "b", kind: .externalHost, host: "h2", user: "u")
        let registry = MachineRegistry(machines: [a, b], path: path)

        XCTAssertTrue(registry.remove(a.id))
        XCTAssertEqual(registry.machines.map(\.name), ["b"])
        // Removing an unknown id is a no-op that reports false.
        XCTAssertFalse(registry.remove(a.id))

        let reloaded = try MachinesFile.decode(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(reloaded.machines.map(\.id), [b.id])
    }

    func testImageClaimantDetectsCollisionAndIgnoresSelf() {
        let sol = Machine(name: "solaris", kind: .emulatedVM, os: .solaris26,
                          host: "127.0.0.1", user: "t", imagePath: "~/img/solaris.qcow2")
        let ext = Machine(name: "ss5", kind: .externalHost, host: "h", user: "t")
        let registry = MachineRegistry(machines: [sol, ext], path: tempPath("claim"))

        // A different machine claiming the same image (tilde-normalized) is found.
        let expanded = ("~/img/solaris.qcow2" as NSString).expandingTildeInPath
        XCTAssertEqual(registry.imageClaimant(imagePath: expanded, excluding: nil)?.name, "solaris")
        // Excluding the owner itself reports no collision (editing your own image).
        XCTAssertNil(registry.imageClaimant(imagePath: "~/img/solaris.qcow2", excluding: sol.id))
        // An unclaimed path is free; an external host never claims an image.
        XCTAssertNil(registry.imageClaimant(imagePath: "~/img/other.qcow2", excluding: nil))
    }

    /// The Settings ports editor's commit-time collision check (audit F1):
    /// another emulated VM holding an overlapping block is named, editing your
    /// own block is not a collision, and externals never participate (they're
    /// dialed at their own host's real ports).
    func testPortBlockClaimantDetectsOverlapAndIgnoresSelfAndExternals() {
        let sol = Machine(name: "solaris", kind: .emulatedVM, os: .solaris26,
                          host: "127.0.0.1", user: "t")
        let ext = Machine(name: "ss5", kind: .externalHost, host: "h", user: "t",
                          ports: ImagePorts(telnet: 23, ssh: 22, helios: 9125))
        let registry = MachineRegistry(machines: [sol, ext], path: tempPath("portclaim"))

        // Overlapping any port of solaris's derived block names it.
        XCTAssertEqual(registry.portBlockClaimant(
            ports: ImagePorts(telnet: 2123, ssh: 9922, helios: 9925),
            excluding: nil)?.name, "solaris")
        // Excluding the owner itself reports no collision (editing your own).
        XCTAssertNil(registry.portBlockClaimant(ports: sol.resolvedPorts,
                                                excluding: sol.id))
        // A free block is free; the external's ports are never claimed.
        XCTAssertNil(registry.portBlockClaimant(ports: ImagePorts.block(9),
                                                excluding: nil))
        XCTAssertNil(registry.portBlockClaimant(
            ports: ImagePorts(telnet: 23, ssh: 22, helios: 9125),
            excluding: nil))
    }

    func testClonedCopiesConfigButNotImageOrIdentity() {
        let sol = Machine(name: "solaris", kind: .emulatedVM, os: .solaris26,
                          host: "127.0.0.1", user: "t",
                          ports: ImagePorts.block(5), imagePath: "~/img/solaris.qcow2",
                          macAddress: "02:00:00:00:00:01",
                          launchers: [MachineLauncher(name: "xterm", command: "xterm")])
        let clone = sol.cloned()
        // Fresh identity, "copy" name, image + MAC + port block dropped (not the
        // VM, and never a shared block -- the registry assigns the clone its own).
        XCTAssertNotEqual(clone.id, sol.id)
        XCTAssertEqual(clone.name, "solaris copy")
        XCTAssertNil(clone.imagePath)
        XCTAssertNil(clone.macAddress)
        XCTAssertNil(clone.ports)
        // Everything else carries over, including launchers.
        XCTAssertEqual(clone.kind, .emulatedVM)
        XCTAssertEqual(clone.os, .solaris26)
        XCTAssertEqual(clone.user, "t")
        XCTAssertEqual(clone.launchers, sol.launchers)
    }

    func testClonedExternalHostKeepsExplicitPorts() {
        let ext = Machine(name: "ss5", kind: .externalHost, host: "192.168.7.19", user: "t",
                          ports: ImagePorts(telnet: 23, ssh: 22, helios: 2125))
        // External ports are the box's REAL LAN ports, not an allocation; a
        // clone points at the same class of box, so they carry over.
        XCTAssertEqual(ext.cloned().ports, ext.ports)
    }

    // MARK: - Sticky port assignment (P2)

    func testAddAssignsNextFreeBlockToUserVM() {
        let registry = MachineRegistry(machines: [
            Machine(name: "Solaris 2.6", kind: .emulatedVM, os: .solaris26,
                    bundled: true, host: "127.0.0.1", user: "t"),
        ], path: tempPath("ports"))
        let a = Machine(name: "my solaris", kind: .emulatedVM, os: .solaris26,
                        host: "127.0.0.1", user: "t")
        let b = Machine(name: "another", kind: .emulatedVM, os: .netbsd,
                        host: "127.0.0.1", user: "t")
        registry.add(a)
        registry.add(b)
        // Blocks 2-4 belong to the per-OS bundled fixtures; user VMs get 5, 6, ...
        // regardless of their OS (two Solaris VMs must not share a block).
        XCTAssertEqual(registry.machine(a.id)?.ports, ImagePorts.block(5))
        XCTAssertEqual(registry.machine(b.id)?.ports, ImagePorts.block(6))
        XCTAssertEqual(ImagePorts.block(5),
                       ImagePorts(telnet: 2153, ssh: 2252, helios: 2155))
    }

    func testAddNeverAssignsPortsToBundledOrExternal() {
        let registry = MachineRegistry(machines: [], path: tempPath("ports2"))
        let bundled = Machine(name: "NetBSD", kind: .emulatedVM, os: .netbsd,
                              bundled: true, host: "127.0.0.1", user: "t")
        let ext = Machine(name: "ss5", kind: .externalHost, host: "h", user: "t")
        registry.add(bundled)
        registry.add(ext)
        XCTAssertNil(registry.machine(bundled.id)?.ports)   // derives the OS block
        XCTAssertNil(registry.machine(ext.id)?.ports)       // real LAN ports
    }

    func testUpdateAssignsPortsWhenKindFlipsToEmulated() {
        let m = Machine(name: "box", kind: .externalHost, host: "h", user: "t")
        let registry = MachineRegistry(machines: [m], path: tempPath("flip"))
        var edited = m
        edited.kind = .emulatedVM
        registry.update(edited)
        XCTAssertEqual(registry.machine(m.id)?.ports, ImagePorts.block(5))
    }

    func testUpdateShedsPortBlockWhenKindFlipsToExternal() {
        // The reverse flip: an external host is dialed at its REAL ports, so
        // the loopback hostfwd block must not survive the kind change (it
        // would send launchers to 2153/2252/2155 instead of 23/22/2125).
        let registry = MachineRegistry(machines: [], path: tempPath("unflip"))
        let vm = Machine(name: "vm", kind: .emulatedVM, os: .solaris26,
                         host: "127.0.0.1", user: "t")
        registry.add(vm)
        XCTAssertNotNil(registry.machine(vm.id)?.ports)   // got its block
        var edited = registry.machine(vm.id)!
        edited.kind = .externalHost
        edited.host = "192.168.7.19"
        registry.update(edited)
        XCTAssertNil(registry.machine(vm.id)?.ports)
        XCTAssertEqual(registry.machine(vm.id)?.resolvedPorts,
                       ImagePorts(telnet: 23, ssh: 22, helios: 2125))
    }

    func testAssignmentIsStickyAcrossUpdates() {
        let registry = MachineRegistry(machines: [], path: tempPath("sticky"))
        let m = Machine(name: "vm", kind: .emulatedVM, os: .solaris26,
                        host: "127.0.0.1", user: "t")
        registry.add(m)
        let assigned = registry.machine(m.id)?.ports
        var edited = registry.machine(m.id)!
        edited.name = "renamed"
        registry.update(edited)
        XCTAssertEqual(registry.machine(m.id)?.ports, assigned)
    }

    func testLoadAssignsBlocksToLegacyUserVMs() throws {
        let path = tempPath("legacy")
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A pre-P2 file: a non-bundled emulated VM with no explicit ports (it
        // was silently deriving the Solaris block that the fixture owns).
        let legacy = Machine(name: "my vm", kind: .emulatedVM, os: .solaris26,
                             host: "127.0.0.1", user: "t")
        try MachinesFile(machines: [legacy]).encoded()
            .write(toFile: path, atomically: true, encoding: .utf8)
        let registry = MachineRegistry.load(
            path: path, launchersPath: "/nonexistent-launchers",
            bundledImagePath: "")
        XCTAssertEqual(registry.machine(legacy.id)?.ports, ImagePorts.block(5))
    }

    func testBlockPatternNeverOverlaps() {
        // Distinct block indices can never collide with each other or the
        // per-OS blocks (which ARE blocks 2/3/4 in the same pattern).
        let blocks = (2...20).map { ImagePorts.block($0) }
        for (i, a) in blocks.enumerated() {
            for b in blocks[(i + 1)...] {
                XCTAssertFalse(a.overlaps(b), "\(a) overlaps \(b)")
            }
        }
        XCTAssertEqual(ImagePorts.block(2), .solaris26)
        XCTAssertEqual(ImagePorts.block(3), .sunos414)
        XCTAssertEqual(ImagePorts.block(4), .netbsd)
    }

    // MARK: - Per-machine MAC (P2)

    func testDerivedMacIsStableUniqueAndLocallyAdministered() {
        let a = Machine(name: "a", kind: .emulatedVM, host: "127.0.0.1", user: "t")
        let b = Machine(name: "b", kind: .emulatedVM, host: "127.0.0.1", user: "t")
        // Deterministic per machine (stable guest identity across boots)...
        XCTAssertEqual(a.resolvedMacAddress, a.resolvedMacAddress)
        // ...unique across machines (concurrent guests must not collide)...
        XCTAssertNotEqual(a.resolvedMacAddress, b.resolvedMacAddress)
        // ...in the locally-administered range, and an explicit MAC still wins.
        XCTAssertTrue(a.resolvedMacAddress.hasPrefix("02:"))
        var pinned = a
        pinned.macAddress = "02:AA:BB:CC:DD:EE"
        XCTAssertEqual(pinned.resolvedMacAddress, "02:AA:BB:CC:DD:EE")
    }

    func testEngineConfigCarriesMachineMacAndPorts() throws {
        let m = Machine(name: "vm", kind: .emulatedVM, os: .netbsd,
                        host: "127.0.0.1", user: "t",
                        ports: ImagePorts.block(7), imagePath: "/tmp/x.qcow2")
        let config = try XCTUnwrap(m.makeEngineConfig())
        XCTAssertEqual(config.macAddress, m.resolvedMacAddress)
        XCTAssertEqual(config.ports, ImagePorts.block(7))
        XCTAssertEqual(config.memoryMB, 256)
        let args = QemuEngine.buildArguments(config: config)
        let nic = try XCTUnwrap(args.first { $0.hasPrefix("user,model=lance") })
        XCTAssertTrue(nic.contains("mac=\(m.resolvedMacAddress)"))
        XCTAssertTrue(nic.contains("hostfwd=tcp:127.0.0.1:\(ImagePorts.block(7).helios)-:2125"))
    }
}
