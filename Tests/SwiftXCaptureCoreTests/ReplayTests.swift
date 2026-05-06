import XCTest
import Foundation
import Darwin
@testable import SwiftXCaptureCore

final class ReplayTests: XCTestCase {

    func testSendsC2SBytesToTargetAndDrainsS2C() throws {
        let path = makeTempFilePath(prefix: "replay-roundtrip")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        // S2C frames in the capture should NOT be sent. Only C2S goes on the wire.
        recorder.record(direction: .clientToServer, bytes: [0x01, 0x02, 0x03, 0x04])
        recorder.record(direction: .serverToClient, bytes: [0xFA, 0xFB])
        recorder.record(direction: .clientToServer, bytes: [0x05, 0x06])
        try recorder.finalize()

        let (serverFd, serverPort) = try makeListener()
        defer { Darwin.close(serverFd) }

        let serverReceived = ThreadSafeBytes()
        let serverDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            do {
                let cfd = try acceptOne(serverFd)
                defer { Darwin.close(cfd) }
                let received = readUntilEOF(cfd)
                serverReceived.set(received)
                writeAll(cfd, [0x99, 0x88, 0x77, 0x66])
                shutdown(cfd, Int32(SHUT_WR))
            } catch {
                XCTFail("server side error: \(error)")
            }
            serverDone.signal()
        }

        let result = try Replay.run(args: ReplayArgs(
            inputPath: path,
            targetHost: "127.0.0.1",
            targetPort: serverPort
        ))

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5.0), .success)

        // Only the C2S bytes from the capture, in order, with no S2C bytes mixed in.
        XCTAssertEqual(serverReceived.get(), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        XCTAssertEqual(result.c2sFramesSent, 2)
        XCTAssertEqual(result.c2sBytesSent, 6)
        XCTAssertEqual(result.s2cBytesReceived, 4)
    }

    func testEmptyCaptureReplaysCleanly() throws {
        let path = makeTempFilePath(prefix: "replay-empty")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        try recorder.finalize()

        let (serverFd, serverPort) = try makeListener()
        defer { Darwin.close(serverFd) }

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let cfd = try acceptOne(serverFd)
                _ = readUntilEOF(cfd)
                Darwin.close(cfd)
            } catch {
                XCTFail("server side error: \(error)")
            }
            serverDone.signal()
        }

        let result = try Replay.run(args: ReplayArgs(
            inputPath: path,
            targetHost: "127.0.0.1",
            targetPort: serverPort
        ))

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(result.c2sFramesSent, 0)
        XCTAssertEqual(result.c2sBytesSent, 0)
    }

    func testThrowsOnConnectFailure() {
        // Port 1 is reliably nothing, so connect refuses.
        XCTAssertThrowsError(try Replay.run(args: ReplayArgs(
            inputPath: "/dev/null",
            targetHost: "127.0.0.1",
            targetPort: 1
        )))
    }

    // MARK: - CLI parsing

    func testParseReplayDefaultsToLocalhost6000() throws {
        let args = try CLI.parseReplay(["session.xtap"])
        XCTAssertEqual(args.inputPath, "session.xtap")
        XCTAssertEqual(args.targetHost, "127.0.0.1")
        XCTAssertEqual(args.targetPort, 6000)
        XCTAssertFalse(args.hold)
        XCTAssertFalse(args.realtime)
    }

    func testParseReplayHoldFlag() throws {
        let args = try CLI.parseReplay(["session.xtap", "--hold"])
        XCTAssertTrue(args.hold)
    }

    func testParseReplayHoldFlagBeforePath() throws {
        let args = try CLI.parseReplay(["--hold", "--target", "u5:6000", "session.xtap"])
        XCTAssertTrue(args.hold)
        XCTAssertEqual(args.targetHost, "u5")
        XCTAssertEqual(args.inputPath, "session.xtap")
    }

    func testParseReplayRealtimeFlag() throws {
        let args = try CLI.parseReplay(["session.xtap", "--realtime"])
        XCTAssertTrue(args.realtime)
        XCTAssertFalse(args.hold)
    }

    func testParseReplayRealtimeAndHoldTogether() throws {
        let args = try CLI.parseReplay(["session.xtap", "--realtime", "--hold"])
        XCTAssertTrue(args.realtime)
        XCTAssertTrue(args.hold)
    }

    func testRealtimePacingHonorsTimestamps() throws {
        // Record three frames spaced ~150ms apart so the .xtap timestamps reflect
        // that, then verify --realtime replay takes at least that long.
        let path = makeTempFilePath(prefix: "replay-realtime")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .clientToServer, bytes: [0xAA])
        Thread.sleep(forTimeInterval: 0.15)
        recorder.record(direction: .clientToServer, bytes: [0xBB])
        Thread.sleep(forTimeInterval: 0.15)
        recorder.record(direction: .clientToServer, bytes: [0xCC])
        try recorder.finalize()

        let (serverFd, serverPort) = try makeListener()
        defer { Darwin.close(serverFd) }

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let cfd = try acceptOne(serverFd)
                _ = readUntilEOF(cfd)
                Darwin.close(cfd)
            } catch {
                XCTFail("server side error: \(error)")
            }
            serverDone.signal()
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = try Replay.run(args: ReplayArgs(
            inputPath: path,
            targetHost: "127.0.0.1",
            targetPort: serverPort,
            realtime: true
        ))
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(result.c2sFramesSent, 3)
        // Realtime replay should take roughly as long as the original ~300ms
        // gap. Allow 250ms floor for measurement noise.
        XCTAssertGreaterThanOrEqual(elapsedNs, 250_000_000)
    }

    func testFastReplayIgnoresTimestamps() throws {
        // Same recording, but without --realtime the replay should pump in <50ms
        // even though the original spanned ~300ms.
        let path = makeTempFilePath(prefix: "replay-fast")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .clientToServer, bytes: [0xAA])
        Thread.sleep(forTimeInterval: 0.15)
        recorder.record(direction: .clientToServer, bytes: [0xBB])
        Thread.sleep(forTimeInterval: 0.15)
        recorder.record(direction: .clientToServer, bytes: [0xCC])
        try recorder.finalize()

        let (serverFd, serverPort) = try makeListener()
        defer { Darwin.close(serverFd) }

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let cfd = try acceptOne(serverFd)
                _ = readUntilEOF(cfd)
                Darwin.close(cfd)
            } catch {
                XCTFail("server side error: \(error)")
            }
            serverDone.signal()
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try Replay.run(args: ReplayArgs(
            inputPath: path,
            targetHost: "127.0.0.1",
            targetPort: serverPort
        ))
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5.0), .success)
        // Generous: well under the 300ms the realtime replay would take.
        XCTAssertLessThan(elapsedNs, 100_000_000)
    }

    func testParseReplayWithExplicitTarget() throws {
        let args = try CLI.parseReplay(["session.xtap", "--target", "10.0.0.1:6001"])
        XCTAssertEqual(args.inputPath, "session.xtap")
        XCTAssertEqual(args.targetHost, "10.0.0.1")
        XCTAssertEqual(args.targetPort, 6001)
    }

    func testParseReplayTargetBeforePath() throws {
        let args = try CLI.parseReplay(["--target", "host:7000", "session.xtap"])
        XCTAssertEqual(args.inputPath, "session.xtap")
        XCTAssertEqual(args.targetHost, "host")
        XCTAssertEqual(args.targetPort, 7000)
    }

    func testParseReplayMissingPath() {
        XCTAssertThrowsError(try CLI.parseReplay(["--target", "host:6000"])) { err in
            XCTAssertEqual(err as? CLIError, .missingFlag("<path>"))
        }
    }

    func testParseReplayMissingTargetValue() {
        XCTAssertThrowsError(try CLI.parseReplay(["session.xtap", "--target"])) { err in
            XCTAssertEqual(err as? CLIError, .missingValue(flag: "--target"))
        }
    }

    func testParseReplayUnknownFlag() {
        XCTAssertThrowsError(try CLI.parseReplay(["session.xtap", "--bogus", "x"])) { err in
            XCTAssertEqual(err as? CLIError, .unknownFlag("--bogus"))
        }
    }
}
