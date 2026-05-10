import Foundation

// Diagnostic probe for the read/write/main-thread race on the outbound path.
// When enabled, every `outbound.append(...)` (origin = whichever thread
// produced the message — read-thread for replies, main-thread for Cocoa-bridge
// events) and every actual socket `writeAll` (origin = read or write thread)
// emits a single line to stderr.
//
// Rip out once the race is either confirmed-and-fixed or ruled out.
//
// Enable with: SWIFTX_WIRE_TRACE=1
//
// Output line format:
//   WIRE <us> tid=<tag> APPEND  kind=<name>     seqLE=<u16> len=<n>
//   WIRE <us> tid=<tag> WRITE   bytes=<n>       peek=<hex>
//
// Wire-order inversion is visible as APPEND-from-read (a reply) followed by
// WRITE-from-write-thread (which carries an event drained earlier) before the
// matching WRITE-from-read-thread (the reply). That's the smoking gun for
// the Motif click-dispatch theory.

public final class WireTrace: @unchecked Sendable {
    private nonisolated(unsafe) static var _shared: WireTrace?
    private nonisolated(unsafe) static var installAttempted = false
    private static let installLock = NSLock()

    public static var shared: WireTrace? {
        installLock.lock()
        defer { installLock.unlock() }
        if !installAttempted {
            installAttempted = true
            let env = ProcessInfo.processInfo.environment["SWIFTX_WIRE_TRACE"] ?? ""
            if !env.isEmpty, env != "0", env.lowercased() != "false" {
                _shared = WireTrace(sink: StderrLogSink())
            }
        }
        return _shared
    }

    private let sink: ServerLogSink
    private let lock = NSLock()
    private let startNanos: UInt64

    public init(sink: ServerLogSink) {
        self.sink = sink
        self.startNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// No-op now (auto-install on first access). Kept for callers that want
    /// to force install at a known point.
    public static func installFromEnvironment() { _ = shared }

    public func appended(_ bytes: [UInt8]) {
        let kind = bytes.first.map(WireTrace.kindName) ?? "?"
        // Full 32-byte hex dump for input events (ButtonPress/Release/Key/Motion)
        // and crossings — those are what clients gate dispatch on, and we want
        // to byte-diff them against gold captures.
        let kindByte = bytes.first ?? 0
        let isInputish = (kindByte & 0x7F) >= 2 && (kindByte & 0x7F) <= 8
        let dump = isInputish && bytes.count >= 32
            ? " full=\(bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: ""))"
            : ""
        emit("APPEND  kind=\(pad(kind, 18)) \(seqString(bytes)) len=\(bytes.count)\(dump)")
    }

    public func wrote(byteCount: Int, peek: [UInt8]) {
        let hex = peek.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let kind = peek.first.map(WireTrace.kindName) ?? "?"
        emit("WRITE   kind=\(pad(kind, 18)) \(seqString(peek)) bytes=\(byteCount) peek=\(hex)")
    }

    /// Emit both byte-order interpretations of bytes 2..3 so the reader doesn't
    /// have to know the client's byte order to spot inversions.
    private func seqString(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 4 else { return "seq=?" }
        let le = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let be = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        return "seq(LE=\(le) BE=\(be))"
    }

    // MARK: - internals

    private func emit(_ body: String) {
        let us = (DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000
        let tid = WireTrace.threadTag()
        let line = String(format: "WIRE %10llu tid=%@ %@", us, pad(tid, 22), body)
        lock.lock()
        sink.log(line)
        lock.unlock()
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private static func threadTag() -> String {
        if Thread.isMainThread { return "main" }
        if let name = Thread.current.name, !name.isEmpty { return name }
        return "tid?"
    }

    private static func kindName(_ b: UInt8) -> String {
        let synth = b & 0x80 != 0
        let mark = synth ? "*" : ""
        let code = b & 0x7F
        switch code {
        case 0: return "Error"
        case 1: return "Reply"
        case 2: return "KeyPress" + mark
        case 3: return "KeyRelease" + mark
        case 4: return "ButtonPress" + mark
        case 5: return "ButtonRelease" + mark
        case 6: return "MotionNotify" + mark
        case 7: return "EnterNotify" + mark
        case 8: return "LeaveNotify" + mark
        case 9: return "FocusIn" + mark
        case 10: return "FocusOut" + mark
        case 11: return "KeymapNotify" + mark
        case 12: return "Expose" + mark
        case 13: return "GraphicsExposure" + mark
        case 14: return "NoExposure" + mark
        case 15: return "VisibilityNotify" + mark
        case 16: return "CreateNotify" + mark
        case 17: return "DestroyNotify" + mark
        case 18: return "UnmapNotify" + mark
        case 19: return "MapNotify" + mark
        case 20: return "MapRequest" + mark
        case 21: return "ReparentNotify" + mark
        case 22: return "ConfigureNotify" + mark
        case 23: return "ConfigureRequest" + mark
        case 24: return "GravityNotify" + mark
        case 25: return "ResizeRequest" + mark
        case 26: return "CirculateNotify" + mark
        case 27: return "CirculateRequest" + mark
        case 28: return "PropertyNotify" + mark
        case 29: return "SelectionClear" + mark
        case 30: return "SelectionRequest" + mark
        case 31: return "SelectionNotify" + mark
        case 32: return "ColormapNotify" + mark
        case 33: return "ClientMessage" + mark
        case 34: return "MappingNotify" + mark
        default: return "ev\(code)" + mark
        }
    }
}
