import XCTest
@testable import SwiftXServerCore

final class MachineFileTests: XCTestCase {

    // MARK: - Decode

    func testDecodesEmulatedMachineWithLauncher() throws {
        let file = try MachinesFile.decode("""
        {
          "machines": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Solaris 2.6",
              "kind": "emulatedVM",
              "os": "solaris26",
              "image": "/tmp/solaris-2.6.qcow2",
              "host": "127.0.0.1",
              "user": "tvernon",
              "launchers": [
                { "name": "xterm cyan", "command": "xterm -fg cyan -bg black" }
              ]
            }
          ]
        }
        """)
        XCTAssertEqual(file.machines.count, 1)
        let m = file.machines[0]
        XCTAssertEqual(m.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(m.name, "Solaris 2.6")
        XCTAssertEqual(m.kind, .emulatedVM)
        XCTAssertEqual(m.os, .solaris26)
        XCTAssertEqual(m.image?.path, "/tmp/solaris-2.6.qcow2")
        XCTAssertEqual(m.host, "127.0.0.1")
        XCTAssertEqual(m.user, "tvernon")
        XCTAssertEqual(m.transport, .helios)          // defaulted
        XCTAssertEqual(m.resolvedPorts, .solaris26)   // derived from os
        XCTAssertEqual(m.launchers.count, 1)
        XCTAssertEqual(m.launchers[0].name, "xterm cyan")
        XCTAssertEqual(m.launchers[0].command, "xterm -fg cyan -bg black")
    }

    func testForgivingDefaultsOnDecode() throws {
        // Minimal external machine: only kind/name/host/user; everything else defaults.
        let file = try MachinesFile.decode("""
        { "machines": [ { "name": "box", "kind": "externalHost", "host": "10.0.0.5", "user": "a" } ] }
        """)
        let m = file.machines[0]
        XCTAssertEqual(m.transport, .helios)
        XCTAssertEqual(m.memoryMB, 128)
        XCTAssertEqual(m.networkMode, .slirp)
        XCTAssertTrue(m.launchers.isEmpty)
        XCTAssertNil(m.image)
        // an id is generated when omitted
        XCTAssertNotEqual(m.id, UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
    }

    func testResolvedPortsExternalDefaultsAndOverride() throws {
        let file = try MachinesFile.decode("""
        {
          "machines": [
            { "name": "a", "kind": "externalHost", "host": "h", "user": "u" },
            { "name": "b", "kind": "externalHost", "host": "h", "user": "u",
              "ports": { "telnet": 23, "ssh": 2020, "helios": 2125 } }
          ]
        }
        """)
        XCTAssertEqual(file.machines[0].resolvedPorts, ImagePorts(telnet: 23, ssh: 22, helios: 2125))
        XCTAssertEqual(file.machines[1].resolvedPorts.ssh, 2020)
    }

    // MARK: - Launcher resolution

    func testLauncherInheritsMachineConnection() throws {
        let m = try MachinesFile.decode("""
        { "machines": [ { "name": "ss5", "kind": "externalHost", "host": "192.168.7.19",
          "user": "tvernon", "launchers": [ { "name": "xterm", "command": "xterm" } ] } ] }
        """).machines[0]
        let (entries, _) = m.resolvedEntries()
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.host, "192.168.7.19")
        XCTAssertEqual(e.user, "tvernon")
        XCTAssertEqual(e.transport, .helios)
        XCTAssertEqual(e.port, 2125)     // helios default, inherited
        XCTAssertEqual(e.group, "ss5")   // menu group == machine name
    }

    func testLauncherTransportOverrideResolvesPort() throws {
        let m = Machine(name: "m", kind: .externalHost, host: "h", user: "u", transport: .helios,
                        launchers: [MachineLauncher(name: "shell", command: "xterm", transport: .ssh)])
        let e = m.resolvedEntries().entries[0]
        XCTAssertEqual(e.transport, .ssh)
        XCTAssertEqual(e.port, 22)   // ssh default for the overridden transport
    }

    func testFileBrowserLauncherNeedsNoCommand() throws {
        let m = Machine(name: "m", kind: .externalHost, host: "h", user: "u", transport: .helios,
                        launchers: [MachineLauncher(name: "Files", fileBrowser: true)])
        let e = m.resolvedEntries().entries[0]
        XCTAssertTrue(e.fileBrowser)
        XCTAssertEqual(e.command, "")
    }

    // MARK: - makeEngineConfig

    func testEngineConfigForEmulatedVM() {
        let m = Machine(name: "s", kind: .emulatedVM, os: .solaris26,
                        host: "127.0.0.1", user: "t", imagePath: "/tmp/disk.qcow2", memoryMB: 256)
        let cfg = m.makeEngineConfig(tftpDirectory: "/tmp/tftp")
        XCTAssertEqual(cfg?.diskImage.path, "/tmp/disk.qcow2")
        XCTAssertEqual(cfg?.memoryMB, 256)
        XCTAssertEqual(cfg?.ports, .solaris26)
        XCTAssertEqual(cfg?.tftpDirectory, "/tmp/tftp")
    }

    func testEngineConfigNilForExternalAndImageless() {
        XCTAssertNil(Machine(name: "x", kind: .externalHost, host: "h", user: "u").makeEngineConfig())
        let imageless = Machine(name: "y", kind: .emulatedVM, os: .netbsd, host: "127.0.0.1", user: "u")
        XCTAssertNil(imageless.makeEngineConfig())
        XCTAssertFalse(imageless.isInstalledEmulatedVM)
    }

    // MARK: - Round-trip

    func testEncodeDecodeIdempotent() throws {
        let original = try MachinesFile.decode("""
        {
          "machines": [
            { "id": "AAAAAAAA-0000-0000-0000-000000000001", "name": "Solaris 2.6",
              "kind": "emulatedVM", "os": "solaris26", "image": "/tmp/s.qcow2",
              "host": "127.0.0.1", "user": "tvernon", "display": "10.0.2.2:0",
              "launchers": [ { "name": "xterm cyan", "command": "xterm -fg cyan" },
                             { "name": "Files", "fileBrowser": true } ] },
            { "id": "AAAAAAAA-0000-0000-0000-000000000002", "name": "the real SS5",
              "kind": "externalHost", "host": "192.168.7.19", "user": "tvernon" }
          ]
        }
        """)
        let round = try MachinesFile.decode(original.encoded())
        XCTAssertEqual(round, original)
    }

    // MARK: - Migration

    func testMigrationClassifiesLoopbackAndExternal() {
        let launchers = LauncherFile.parse("""
        [host:solaris]
        host      = 127.0.0.1
        user      = tvernon
        transport = helios

        [solaris/xterm]
        command = xterm

        [host:u5]
        host      = u5.example.com
        user      = alice
        transport = telnet

        [u5/xterm]
        command = xterm
        """)
        let machines = MachineMigrator.migrate(launchers: launchers,
                                               bundledImagePath: "/tmp/bundled.qcow2",
                                               bundledUser: "tvernon")
        let solaris = machines.first { $0.name == "solaris" }
        let u5 = machines.first { $0.name == "u5" }
        XCTAssertEqual(solaris?.kind, .emulatedVM)
        XCTAssertEqual(solaris?.image?.path, "/tmp/bundled.qcow2")
        XCTAssertEqual(solaris?.os, .solaris26)
        XCTAssertEqual(solaris?.launchers.first?.command, "xterm")
        XCTAssertEqual(u5?.kind, .externalHost)
        XCTAssertNil(u5?.image)
        XCTAssertEqual(u5?.transport, .telnet)
        XCTAssertEqual(u5?.launchers.count, 1)
    }

    func testMigrationSeedsBundledWhenNoLoopbackGroup() {
        let launchers = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = alice

        [u5/xterm]
        command = xterm
        """)
        let machines = MachineMigrator.migrate(launchers: launchers,
                                               bundledImagePath: "/tmp/b.qcow2",
                                               bundledUser: "tvernon")
        XCTAssertEqual(machines.first?.kind, .emulatedVM)
        XCTAssertEqual(machines.first?.image?.path, "/tmp/b.qcow2")
        XCTAssertEqual(machines.first?.user, "tvernon")
        XCTAssertTrue(machines.contains { $0.name == "u5" && $0.kind == .externalHost })
    }

    func testMigrationBundledNotInstalledWhenNoImagePath() {
        let machines = MachineMigrator.migrate(launchers: LauncherFile(entries: [], warnings: []),
                                               bundledImagePath: "",
                                               bundledUser: "tvernon")
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines[0].kind, .emulatedVM)
        XCTAssertNil(machines[0].image)
        XCTAssertFalse(machines[0].isInstalledEmulatedVM)
    }
}
