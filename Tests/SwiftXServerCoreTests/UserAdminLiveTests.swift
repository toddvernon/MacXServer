import XCTest
@testable import SwiftXServerCore

/// Live UserAdmin validation against a RUNNING guest, gated like the other
/// SPARCplug live tests. Runs the full cycle -- add a scratch user, prove the
/// guest's own getpwnam resolves it (run_command with `user:` drops privileges
/// through it), then delete it and prove it's gone. Cleans up after itself;
/// the scratch account never survives the test.
///
/// Run with a guest booted (any of the three OSes):
///   SPARCPLUG_LIVE_TEST=1 \
///   SPARCPLUG_LIVE_LOCK=~/Dropbox/dev/SPARCplug/images/netbsd/netbsd-boot.qcow2.macxserver-lock \
///   swift test --filter UserAdminLiveTests
final class UserAdminLiveTests: XCTestCase {

    private static let scratchUser = "uatest"

    func testLiveAddRunAsDeleteCycle() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SPARCPLUG_LIVE_TEST"] != nil,
              let lockPath = env["SPARCPLUG_LIVE_LOCK"], !lockPath.isEmpty
        else { throw XCTSkip("set SPARCPLUG_LIVE_TEST=1 and SPARCPLUG_LIVE_LOCK to run") }

        // The lock next to a running image carries the per-boot secret and the
        // helios hostfwd -- exactly what a different macXserver process would
        // use to reach the orphan's daemon.
        let expanded = (lockPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8),
              let lock = ImageLock.parse(text),
              let port = lock.heliosPort, let secret = lock.secret else {
            throw XCTSkip("no parseable lock with secret+heliosPort at \(expanded)")
        }
        // Infer the guest OS from the canonical image filename (<os>-boot.qcow2).
        guard let os = MachineOS.allCases.first(where: {
            lock.imagePath.contains("\($0.rawValue)-") }) else {
            throw XCTSkip("can't infer guest OS from \(lock.imagePath)")
        }

        let client = HeliosClient(port: port, timeout: 15, secret: secret)
        try client.connect()
        defer { client.close() }
        _ = try client.hello()

        // A previous aborted run may have left the scratch user; sweep it.
        try? UserAdmin.deleteUser(name: Self.scratchUser, os: os,
                                  removeHome: true, transport: client)

        // Plan first (what the Add sheet previews), then add with it.
        let plan = try UserAdmin.planAddUser(os: os, transport: client)
        var transcript: [String] = []
        let uid = try UserAdmin.addUser(
            .init(name: Self.scratchUser, gecos: "UserAdmin live test",
                  hash: UserAdmin.desHash(password: "livetest")),
            os: os, transport: client, plan: plan,
            progress: { transcript.append($0) })
        XCTAssertGreaterThanOrEqual(uid, UserAdmin.firstUserUID)

        // The guest itself must resolve the account: run_command with `user:`
        // getpwnam-validates and euid-drops to it. `id` printing the name is
        // end-to-end proof the record + database are live.
        let idResult = try client.runCommand("id", cwd: nil, timeoutMs: 15_000,
                                             user: Self.scratchUser)
        XCTAssertEqual(idResult.exitCode, 0, idResult.output)
        XCTAssertTrue(idResult.output.contains(Self.scratchUser),
                      "id said: \(idResult.output)")

        // The home was staged from the app-side dotfiles, owned by the new
        // uid, where the plan said it would be.
        let home = plan.homePhysicalPath(name: Self.scratchUser)
        let ls = try client.runCommand("ls -ld \(home)", cwd: nil,
                                       timeoutMs: 15_000, user: nil)
        XCTAssertEqual(ls.exitCode, 0, ls.output)
        let dot = try client.readFile("\(home)/.cshrc", user: nil)
        XCTAssertEqual(dot.data, CanonicalDotfiles.cshrc)

        // Delete (home included) and prove it's gone: getpwnam now fails, so
        // the daemon refuses the run-as before anything executes.
        try UserAdmin.deleteUser(name: Self.scratchUser, os: os,
                                 removeHome: true, transport: client)
        XCTAssertThrowsError(try client.runCommand("id", cwd: nil,
                                                   timeoutMs: 15_000,
                                                   user: Self.scratchUser))
        let users = try UserAdmin.listUsers(transport: client)
        XCTAssertFalse(users.contains { $0.name == Self.scratchUser })
    }
}
