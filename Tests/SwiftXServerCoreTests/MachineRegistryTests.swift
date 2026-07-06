import XCTest
@testable import SwiftXServerCore

@MainActor
final class MachineRegistryTests: XCTestCase {

    private func tempPath(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    func testLoadMigratesBundledMachineOnFirstRun() {
        let path = tempPath("machines")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let registry = MachineRegistry.load(
            path: path,
            launchersPath: "/nonexistent-launchers",   // force the empty-launchers path
            bundledImagePath: "/tmp/bundled.qcow2",
            bundledUser: "tvernon")
        // Migration always seeds a bundled emulated VM, and it's persisted.
        XCTAssertEqual(registry.machines.count, 1)
        let bundled = registry.bundledMachine
        XCTAssertEqual(bundled?.kind, .emulatedVM)
        XCTAssertEqual(bundled?.image?.path, "/tmp/bundled.qcow2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSnapshotDistinguishesEmulatedAndExternal() {
        let registry = MachineRegistry(machines: [
            Machine(name: "Solaris", kind: .emulatedVM, os: .solaris26,
                    host: "127.0.0.1", user: "t", imagePath: "/tmp/s.qcow2"),
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

    func testReconcileSyncsLaunchersAndAddsNewHosts() {
        let bundled = Machine(name: "solaris", kind: .emulatedVM, os: .solaris26,
                              host: "127.0.0.1", user: "t", imagePath: "/img.qcow2")
        let registry = MachineRegistry(machines: [bundled], path: tempPath("recon"))
        registry.reconcile(withMigrated: [
            Machine(name: "solaris", kind: .emulatedVM, os: .solaris26, host: "127.0.0.1",
                    user: "t", imagePath: "/img.qcow2",
                    launchers: [MachineLauncher(name: "xterm", command: "xterm")]),
            Machine(name: "u5", kind: .externalHost, host: "u5.example.com", user: "a",
                    launchers: [MachineLauncher(name: "xterm", command: "xterm")]),
        ])
        // Bundled machine keeps its stable id and gains the launcher.
        XCTAssertEqual(registry.machine(bundled.id)?.launchers.count, 1)
        // The new external host is added.
        XCTAssertEqual(registry.machines.count, 2)
        XCTAssertTrue(registry.machines.contains { $0.name == "u5" && $0.kind == .externalHost })
    }

    func testReconcileNeverRemovesMachines() {
        let ss5 = Machine(name: "ss5", kind: .externalHost, host: "192.168.7.19", user: "t",
                          launchers: [MachineLauncher(name: "x", command: "xterm")])
        let registry = MachineRegistry(machines: [ss5], path: tempPath("recon2"))
        // A migration that doesn't mention ss5 must not drop it (it may hold a secret).
        registry.reconcile(withMigrated: [
            Machine(name: "solaris", kind: .emulatedVM, os: .solaris26,
                    host: "127.0.0.1", user: "t", imagePath: "/i"),
        ])
        XCTAssertTrue(registry.machines.contains { $0.name == "ss5" })
        XCTAssertEqual(registry.machine(ss5.id)?.launchers.count, 1)
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

    func testClonedCopiesConfigButNotImageOrIdentity() {
        let sol = Machine(name: "solaris", kind: .emulatedVM, os: .solaris26,
                          host: "127.0.0.1", user: "t", imagePath: "~/img/solaris.qcow2",
                          macAddress: "02:00:00:00:00:01",
                          launchers: [MachineLauncher(name: "xterm", command: "xterm")])
        let clone = sol.cloned()
        // Fresh identity, "copy" name, image + MAC dropped (not the VM).
        XCTAssertNotEqual(clone.id, sol.id)
        XCTAssertEqual(clone.name, "solaris copy")
        XCTAssertNil(clone.imagePath)
        XCTAssertNil(clone.macAddress)
        // Everything else carries over, including launchers.
        XCTAssertEqual(clone.kind, .emulatedVM)
        XCTAssertEqual(clone.os, .solaris26)
        XCTAssertEqual(clone.user, "t")
        XCTAssertEqual(clone.launchers, sol.launchers)
    }
}
