import XCTest
@testable import SwiftXServerCore

final class MachineFileTests: XCTestCase {

    // MARK: - Parse

    func testParsesEmulatedMachineWithLauncher() {
        let file = MachinesFile.parse("""
        [machine:solaris]
        name      = Solaris 2.6
        kind      = emulatedVM
        os        = solaris26
        image     = /tmp/solaris-2.6.qcow2
        host      = 127.0.0.1
        user      = tvernon
        transport = helios

        [solaris/xterm cyan]
        command   = xterm -fg cyan -bg black
        """)
        XCTAssertEqual(file.machines.count, 1)
        let m = file.machines[0]
        XCTAssertEqual(m.key, "solaris")
        XCTAssertEqual(m.name, "Solaris 2.6")
        XCTAssertEqual(m.kind, .emulatedVM)
        XCTAssertEqual(m.os, .solaris26)
        XCTAssertEqual(m.image?.path, "/tmp/solaris-2.6.qcow2")
        XCTAssertEqual(m.connection.host, "127.0.0.1")
        XCTAssertEqual(m.connection.user, "tvernon")
        XCTAssertEqual(m.connection.transport, .helios)
        // emulated Solaris inherits the 2.6 port block
        XCTAssertEqual(m.connection.ports, .solaris26)
        XCTAssertEqual(m.launchers.count, 1)
        XCTAssertEqual(m.launchers[0].name, "xterm cyan")
        XCTAssertEqual(m.launchers[0].group, "solaris")
        XCTAssertEqual(m.launchers[0].command, "xterm -fg cyan -bg black")
    }

    func testLauncherInheritsMachineConnection() {
        // The launcher item sets only a command; host/user/transport/port come
        // from the machine block.
        let file = MachinesFile.parse("""
        [machine:ss5]
        kind      = externalHost
        host      = 192.168.7.19
        user      = tvernon
        transport = helios

        [ss5/xterm]
        command   = xterm
        """)
        let e = file.machines[0].launchers[0]
        XCTAssertEqual(e.host, "192.168.7.19")
        XCTAssertEqual(e.user, "tvernon")
        XCTAssertEqual(e.transport, .helios)
        XCTAssertEqual(e.port, 2125)   // helios default, inherited
    }

    func testKindInferredFromImageWhenUnset() {
        let file = MachinesFile.parse("""
        [machine:foo]
        image = /tmp/x.qcow2
        host  = 127.0.0.1
        user  = a
        """)
        XCTAssertEqual(file.machines[0].kind, .emulatedVM)

        let ext = MachinesFile.parse("""
        [machine:bar]
        host = 10.0.0.5
        user = a
        """)
        XCTAssertEqual(ext.machines[0].kind, .externalHost)
    }

    func testExternalPortOverrideOnTransport() {
        let file = MachinesFile.parse("""
        [machine:pi]
        kind      = externalHost
        host      = 10.0.0.9
        user      = pi
        transport = ssh
        port      = 2020
        """)
        // `port` drops onto the ssh plane; telnet/helios keep defaults.
        XCTAssertEqual(file.machines[0].connection.ports.ssh, 2020)
        XCTAssertEqual(file.machines[0].connection.ports.telnet, 23)
        XCTAssertEqual(file.machines[0].connection.ports.helios, 2125)
    }

    func testIndividualPortOverrides() {
        let file = MachinesFile.parse("""
        [machine:m]
        kind        = emulatedVM
        os          = sunos414
        image       = /tmp/x.qcow2
        helios_port = 9999
        """)
        XCTAssertEqual(file.machines[0].connection.ports.helios, 9999)
        // the other two keep the sunos414 block
        XCTAssertEqual(file.machines[0].connection.ports.telnet, ImagePorts.sunos414.telnet)
        XCTAssertEqual(file.machines[0].connection.ports.ssh, ImagePorts.sunos414.ssh)
    }

    // MARK: - makeEngineConfig

    func testEngineConfigForEmulatedVM() {
        let file = MachinesFile.parse("""
        [machine:solaris]
        kind   = emulatedVM
        os     = solaris26
        image  = /tmp/disk.qcow2
        memory = 256
        """)
        let cfg = file.machines[0].makeEngineConfig(tftpDirectory: "/tmp/tftp")
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.diskImage.path, "/tmp/disk.qcow2")
        XCTAssertEqual(cfg?.memoryMB, 256)
        XCTAssertEqual(cfg?.ports, .solaris26)
        XCTAssertEqual(cfg?.tftpDirectory, "/tmp/tftp")
    }

    func testEngineConfigNilForExternalAndImageless() {
        let ext = MachinesFile.parse("[machine:x]\nkind=externalHost\nhost=1.2.3.4\nuser=a\n")
        XCTAssertNil(ext.machines[0].makeEngineConfig())

        let imageless = MachinesFile.parse("[machine:y]\nkind=emulatedVM\nos=netbsd\n")
        XCTAssertNil(imageless.machines[0].makeEngineConfig())
        XCTAssertFalse(imageless.machines[0].isInstalledEmulatedVM)
    }

    // MARK: - Round-trip

    func testSerializeParseIdempotent() {
        let original = MachinesFile.parse("""
        [machine:solaris]
        name      = Solaris 2.6
        kind      = emulatedVM
        os        = solaris26
        image     = /tmp/solaris-2.6.qcow2
        host      = 127.0.0.1
        user      = tvernon
        transport = helios
        display   = 10.0.2.2:0

        [solaris/xterm cyan]
        command   = xterm -fg cyan

        [solaris/Files]
        filebrowser = true

        [machine:ss5]
        kind      = externalHost
        host      = 192.168.7.19
        user      = tvernon
        transport = helios
        """).machines

        let reparsed = MachinesFile.parse(MachinesFile.serialize(original)).machines
        XCTAssertEqual(reparsed, original)
    }

    func testIdPersistsAcrossRoundTrip() {
        let m = MachinesFile.parse("""
        [machine:a]
        id    = 11111111-2222-3333-4444-555555555555
        kind  = externalHost
        host  = 1.2.3.4
        user  = a
        """).machines[0]
        XCTAssertEqual(m.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let round = MachinesFile.parse(MachinesFile.serialize([m])).machines[0]
        XCTAssertEqual(round.id, m.id)
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
        let solaris = machines.first { $0.key == "solaris" }
        let u5 = machines.first { $0.key == "u5" }
        XCTAssertEqual(solaris?.kind, .emulatedVM)
        XCTAssertEqual(solaris?.image?.path, "/tmp/bundled.qcow2")
        XCTAssertEqual(solaris?.os, .solaris26)
        XCTAssertEqual(u5?.kind, .externalHost)
        XCTAssertNil(u5?.image)
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
        // A bundled emulated machine is inserted first even though no launcher
        // group targeted the loopback.
        XCTAssertEqual(machines.first?.kind, .emulatedVM)
        XCTAssertEqual(machines.first?.image?.path, "/tmp/b.qcow2")
        XCTAssertEqual(machines.first?.connection.user, "tvernon")
        XCTAssertTrue(machines.contains { $0.key == "u5" && $0.kind == .externalHost })
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
