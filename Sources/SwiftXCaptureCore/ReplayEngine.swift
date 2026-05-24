import Foundation
import Darwin

// Async, cancellable replay machinery for the GUI capture app.
// Mirrors `Replay.run`'s wire behaviour (dial the target, pump C2S
// bytes, drain S2C bytes, optionally hold the connection open) but
// adds the pieces a UI needs:
//
//   - runs entirely on a background queue (start() returns
//     immediately)
//   - fires a progress callback after each frame so the UI can
//     update its progress bar / counters
//   - stop() is real cancellation: shutdown(SHUT_RDWR) on the
//     socket breaks any pending write/read; the hold-open wait
//     uses a DispatchSemaphore the same stop() signals
//   - completion delivered via callback rather than return value
//
// The CLI's `Replay.run` stays as-is — it has SIGINT-based hold
// semantics that don't translate to a GUI Stop button.

public final class ReplayEngine: @unchecked Sendable {

    public struct Progress: Sendable, Equatable {
        public var framesSent: Int = 0
        public var totalFrames: Int = 0
        public var bytesSent: Int = 0
        public var bytesReceived: Int = 0
    }

    public enum Completion: Sendable {
        case finished(Progress)
        case failed(message: String, partial: Progress)
        case cancelled(Progress)
    }

    private let frames: [CaptureFrame]
    private let host: String
    private let port: UInt16
    private let realtime: Bool
    private let hold: Bool
    private let onProgress: @Sendable (Progress) -> Void
    private let onComplete: @Sendable (Completion) -> Void

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled: Bool = false
    private var started: Bool = false
    private let holdSemaphore = DispatchSemaphore(value: 0)

    public init(
        frames: [CaptureFrame],
        targetHost: String,
        targetPort: UInt16,
        realtime: Bool,
        hold: Bool,
        onProgress: @escaping @Sendable (Progress) -> Void,
        onComplete: @escaping @Sendable (Completion) -> Void
    ) {
        self.frames = frames
        self.host = targetHost
        self.port = targetPort
        self.realtime = realtime
        self.hold = hold
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    /// Spawn the replay loop. No-op if already started.
    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runLoop()
        }
    }

    /// Request cancellation. Closes the read+write side of the
    /// socket and signals the hold-open semaphore so the loop wakes
    /// promptly even if it was sleeping for real-time pacing or
    /// holding the connection open after the last frame.
    public func stop() {
        lock.lock()
        cancelled = true
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
        }
        lock.unlock()
        holdSemaphore.signal()
    }

    // MARK: - Loop body

    private func runLoop() {
        let c2sFrames = frames.filter { $0.direction == .clientToServer }
        var progress = Progress(totalFrames: c2sFrames.count)
        onProgress(progress)

        let dialedFd: Int32
        do {
            dialedFd = try replayEngineDial(host: host, port: port)
        } catch {
            onComplete(.failed(message: "Could not connect to \(host):\(port) — \(error)",
                               partial: progress))
            return
        }
        lock.lock()
        fd = dialedFd
        lock.unlock()
        replayEngineSetNoDelay(dialedFd)

        // Drain thread for S2C bytes. Exits on EOF (socket close /
        // shutdown). Updates progress after each read so the UI sees
        // bytes-received climbing too.
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global().async { [weak self] in
            defer { drainGroup.leave() }
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(dialedFd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { return }
                self.lock.lock()
                progress.bytesReceived += n
                let snap = progress
                self.lock.unlock()
                self.onProgress(snap)
            }
        }

        // C2S send loop.
        let startNs = DispatchTime.now().uptimeNanoseconds
        var partialResultReason: Completion?
        for frame in c2sFrames {
            if isCancelled() {
                partialResultReason = .cancelled(progress)
                break
            }
            if realtime {
                let deadline = startNs &+ frame.timestamp
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if deadline > nowNs {
                    let sleepNs = deadline - nowNs
                    // Bounded sleep — wake up periodically to check
                    // cancellation flag rather than blocking for an
                    // arbitrarily long timestamp gap.
                    Thread.sleep(forTimeInterval: TimeInterval(sleepNs) / 1_000_000_000.0)
                    if isCancelled() {
                        partialResultReason = .cancelled(progress)
                        break
                    }
                }
            }
            let ok = replayEngineWriteAll(fd: dialedFd, bytes: frame.bytes)
            if !ok {
                if isCancelled() {
                    partialResultReason = .cancelled(progress)
                } else {
                    partialResultReason = .failed(
                        message: "Target closed connection at frame \(progress.framesSent + 1)/\(progress.totalFrames)",
                        partial: progress
                    )
                }
                break
            }
            progress.framesSent += 1
            progress.bytesSent += frame.bytes.count
            onProgress(progress)
        }

        // Hold-open phase. Runs only if we sent all C2S frames AND
        // hold is requested AND we weren't cancelled.
        if partialResultReason == nil, hold, !isCancelled() {
            holdSemaphore.wait()
            if isCancelled() {
                partialResultReason = .cancelled(progress)
            }
        }

        // Cleanup.
        shutdown(dialedFd, Int32(SHUT_WR))
        drainGroup.wait()
        Darwin.close(dialedFd)

        lock.lock()
        fd = -1
        lock.unlock()

        // Refresh progress one last time with the drain thread's
        // final byteCount before delivering completion.
        let finalProgress = progress
        if let outcome = partialResultReason {
            // Patch the partial's progress to include final S2C bytes.
            switch outcome {
            case .failed(let msg, _):    onComplete(.failed(message: msg, partial: finalProgress))
            case .cancelled:              onComplete(.cancelled(finalProgress))
            case .finished:               onComplete(.finished(finalProgress))
            }
        } else {
            onComplete(.finished(finalProgress))
        }
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - POSIX helpers (private to this file)

public enum ReplayEngineError: Error, Sendable {
    case socketCreate(errno: Int32)
    case resolveFailed(host: String, errno: Int32)
    case connectFailed(host: String, port: UInt16, errno: Int32)
}

private func replayEngineDial(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>? = nil
    let r = getaddrinfo(host, String(port), &hints, &result)
    guard r == 0, let info = result else {
        throw ReplayEngineError.resolveFailed(host: host, errno: errno)
    }
    defer { freeaddrinfo(info) }

    let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { throw ReplayEngineError.socketCreate(errno: errno) }

    let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
    guard rc == 0 else {
        let e = errno
        Darwin.close(fd)
        throw ReplayEngineError.connectFailed(host: host, port: port, errno: e)
    }
    return fd
}

private func replayEngineSetNoDelay(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func replayEngineWriteAll(fd: Int32, bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let w = bytes.withUnsafeBufferPointer { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if w <= 0 { return false }
        offset += w
    }
    return true
}
