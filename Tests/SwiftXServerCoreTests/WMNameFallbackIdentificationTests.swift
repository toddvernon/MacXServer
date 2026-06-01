import XCTest
@testable import SwiftXServerCore
import Framer

// WM_NAME fallback identification.
//
// Many vintage X11R6 demos (ico, xmaze, xev, puzzle, ...) never set
// WM_CLASS — they call XStoreName / XSetWMName but not XSetClassHint.
// Without a fallback, the server's capture-naming logic leaves their
// .xtap files as `<ts>-unidentified-<N>.xtap`. The corpus had 4 of 10
// `unidentified-*` captures land that way until this work.
//
// Contract:
//   - First WM_NAME arrival fires onIdentified(name, "") if no WM_CLASS
//     has been seen yet.
//   - WM_CLASS arrival overrides — fires onIdentified(instance, class)
//     again so downstream renames switch to the canonical name.
//   - WM_NAME after WM_CLASS does NOT re-fire (xterm rewriting
//     WM_NAME to the shell prompt mustn't clobber the rename).
//   - Repeat WM_NAME (no WM_CLASS) does NOT re-fire.
//   - WM_ICON_NAME (atom 37) does NOT fire; it's the iconified title,
//     not the proper name.

private final class IdentificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: [(String, String)] = []
    func append(_ instance: String, _ cls: String) {
        lock.lock(); defer { lock.unlock() }
        fired.append((instance, cls))
    }
    var snapshot: [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

final class WMNameFallbackIdentificationTests: XCTestCase {

    private static let wmNameAtom: UInt32 = 39
    private static let wmIconNameAtom: UInt32 = 37
    private static let wmClassAtom: UInt32 = 67

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    private func createTopLevel(_ session: ServerSession, wid: UInt32, byteOrder: ByteOrder = .lsbFirst) {
        let create = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(create.encode(byteOrder: byteOrder))
        _ = session.outbound.drain()
    }

    private func sendChangeProperty(_ session: ServerSession, wid: UInt32, property: UInt32, data: [UInt8], byteOrder: ByteOrder = .lsbFirst) {
        let change = Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: property, type: 31,
            format: .format8, data: data
        ))
        _ = session.feed(change.encode(byteOrder: byteOrder))
        _ = session.outbound.drain()
    }

    func testWMNameFiresOnIdentifiedAsFallback() throws {
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createTopLevel(session, wid: wid)

        let recorder = IdentificationRecorder()
        session.onIdentified = { inst, cls in recorder.append(inst, cls) }
        var fired: [(String, String)] { recorder.snapshot }

        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: Array("Ico".utf8))

        XCTAssertEqual(fired.count, 1, "WM_NAME should fire onIdentified once")
        XCTAssertEqual(fired.first?.0, "Ico")
        XCTAssertEqual(fired.first?.1, "", "class is empty for WM_NAME-derived identification")
    }

    func testWMClassOverridesPriorWMName() throws {
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createTopLevel(session, wid: wid)

        let recorder = IdentificationRecorder()
        session.onIdentified = { inst, cls in recorder.append(inst, cls) }
        var fired: [(String, String)] { recorder.snapshot }

        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: Array("xterm: ~/dev".utf8))

        // WM_CLASS payload: two null-terminated strings (instance, class).
        var wmClassData: [UInt8] = Array("xterm".utf8) + [0] + Array("XTerm".utf8) + [0]
        sendChangeProperty(session, wid: wid, property: Self.wmClassAtom, data: wmClassData)
        _ = wmClassData

        XCTAssertEqual(fired.count, 2, "WM_CLASS should fire a second time, overriding the WM_NAME fallback")
        XCTAssertEqual(fired[0].0, "xterm: ~/dev")
        XCTAssertEqual(fired[0].1, "")
        XCTAssertEqual(fired[1].0, "xterm")
        XCTAssertEqual(fired[1].1, "XTerm")
    }

    func testWMNameAfterWMClassDoesNotRefire() throws {
        // xterm rewrites WM_NAME to the current shell prompt every time
        // the cwd changes. That mustn't re-fire onIdentified.
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createTopLevel(session, wid: wid)

        let recorder = IdentificationRecorder()
        session.onIdentified = { inst, cls in recorder.append(inst, cls) }
        var fired: [(String, String)] { recorder.snapshot }

        let wmClassData: [UInt8] = Array("xterm".utf8) + [0] + Array("XTerm".utf8) + [0]
        sendChangeProperty(session, wid: wid, property: Self.wmClassAtom, data: wmClassData)
        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: Array("xterm: ~/Pictures".utf8))
        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: Array("xterm: ~/Downloads".utf8))

        XCTAssertEqual(fired.count, 1, "only WM_CLASS should have fired")
        XCTAssertEqual(fired.first?.0, "xterm")
    }

    func testRepeatWMNameDoesNotRefire() throws {
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createTopLevel(session, wid: wid)

        let recorder = IdentificationRecorder()
        session.onIdentified = { inst, cls in recorder.append(inst, cls) }
        var fired: [(String, String)] { recorder.snapshot }

        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: Array("puzzle".utf8))
        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: Array("puzzle solved!".utf8))

        XCTAssertEqual(fired.count, 1, "only first WM_NAME fires; later writes are title updates")
        XCTAssertEqual(fired.first?.0, "puzzle")
    }

    func testWMIconNameDoesNotFire() throws {
        // WM_ICON_NAME (atom 37) is the iconified title — useful for the
        // dock label but not for app identification.
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createTopLevel(session, wid: wid)

        let recorder = IdentificationRecorder()
        session.onIdentified = { inst, cls in recorder.append(inst, cls) }
        var fired: [(String, String)] { recorder.snapshot }

        sendChangeProperty(session, wid: wid, property: Self.wmIconNameAtom, data: Array("xterm-min".utf8))

        XCTAssertEqual(fired.count, 0, "WM_ICON_NAME must not fire identification")
    }

    func testEmptyWMNameDoesNotFire() throws {
        // Some Xt apps write an empty string to WM_NAME during init
        // before the real title is set. Sanitize would collapse to ""
        // and the rename would be a no-op anyway; suppress the callback
        // so downstream loggers don't see a spurious "" identification.
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createTopLevel(session, wid: wid)

        let recorder = IdentificationRecorder()
        session.onIdentified = { inst, cls in recorder.append(inst, cls) }
        var fired: [(String, String)] { recorder.snapshot }

        sendChangeProperty(session, wid: wid, property: Self.wmNameAtom, data: [])

        XCTAssertEqual(fired.count, 0)
    }
}
