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

    func testUpdateIgnoresUnknownId() {
        let registry = MachineRegistry(machines: [
            Machine(name: "a", kind: .externalHost, host: "h", user: "u"),
        ], path: tempPath("noop"))
        let stranger = Machine(name: "b", kind: .externalHost, host: "h2", user: "u2")
        registry.update(stranger)   // id not in the registry
        XCTAssertEqual(registry.machines.count, 1)
        XCTAssertEqual(registry.machines[0].name, "a")
    }
}
