import Foundation
import Darwin

public struct ReplayArgs: Equatable, Sendable {
    public var inputPath: String
    public var targetHost: String
    public var targetPort: UInt16
    public var hold: Bool
    public var realtime: Bool

    public init(inputPath: String, targetHost: String, targetPort: UInt16, hold: Bool = false, realtime: Bool = false) {
        self.inputPath = inputPath
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.hold = hold
        self.realtime = realtime
    }
}

public struct ReplayResult: Equatable, Sendable {
    public var c2sFramesSent: Int
    public var c2sBytesSent: Int
    public var s2cBytesReceived: Int

    public init(c2sFramesSent: Int, c2sBytesSent: Int, s2cBytesReceived: Int) {
        self.c2sFramesSent = c2sFramesSent
        self.c2sBytesSent = c2sBytesSent
        self.s2cBytesReceived = s2cBytesReceived
    }
}

public enum ReplayError: Error, Sendable {
    case socketCreate(errno: Int32)
    case resolveFailed(host: String, errno: Int32)
    case connectFailed(host: String, port: UInt16, errno: Int32)
    case targetClosedEarly(framesSent: Int, bytesSent: Int)
}

public enum Replay {
    public static func run(args: ReplayArgs) throws -> ReplayResult {
        let frames = try CaptureReader.read(from: args.inputPath)
        let fd = try replayDial(host: args.targetHost, port: args.targetPort)
        replaySetNoDelay(fd)

        let s2c = S2CCounter()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global().async {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                s2c.add(n)
            }
            drainGroup.leave()
        }

        var c2sFrames = 0
        var c2sBytes = 0
        let startNs = DispatchTime.now().uptimeNanoseconds
        for frame in frames where frame.direction == .clientToServer {
            if args.realtime {
                let deadline = startNs &+ frame.timestamp
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if deadline > nowNs {
                    let sleepNs = deadline - nowNs
                    Thread.sleep(forTimeInterval: TimeInterval(sleepNs) / 1_000_000_000.0)
                }
            }
            let ok = writeAllReplay(fd: fd, bytes: frame.bytes)
            if !ok {
                shutdown(fd, Int32(SHUT_RDWR))
                drainGroup.wait()
                Darwin.close(fd)
                throw ReplayError.targetClosedEarly(framesSent: c2sFrames, bytesSent: c2sBytes)
            }
            c2sFrames += 1
            c2sBytes += frame.bytes.count
        }

        if args.hold {
            // Don't half-close: keep the connection alive so the server doesn't
            // tear down our windows. Most C2S streams complete in milliseconds,
            // way before a window manager has time to reparent and expose. Wait
            // for SIGINT, then close cleanly.
            FileHandle.standardError.write(Data("holding connection — Ctrl-C to disconnect\n".utf8))
            waitForSIGINT()
        }

        // Half-close the write side so the target sees EOF, finishes any pending
        // work, and closes its own write side. The drain thread exits on that EOF.
        shutdown(fd, Int32(SHUT_WR))
        drainGroup.wait()
        Darwin.close(fd)

        return ReplayResult(
            c2sFramesSent: c2sFrames,
            c2sBytesSent: c2sBytes,
            s2cBytesReceived: s2c.value
        )
    }
}

private final class S2CCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func add(_ n: Int) { lock.lock(); bytes += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

private func writeAllReplay(fd: Int32, bytes: [UInt8]) -> Bool {
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

private func replaySetNoDelay(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func waitForSIGINT() {
    let semaphore = DispatchSemaphore(value: 0)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { semaphore.signal() }
    source.resume()
    // Suppress the default handler (which terminates the process) so the
    // dispatch source actually fires.
    signal(SIGINT, SIG_IGN)
    semaphore.wait()
    source.cancel()
    signal(SIGINT, SIG_DFL)
}

private func replayDial(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>? = nil
    let r = getaddrinfo(host, String(port), &hints, &result)
    guard r == 0, let info = result else {
        throw ReplayError.resolveFailed(host: host, errno: errno)
    }
    defer { freeaddrinfo(info) }

    let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { throw ReplayError.socketCreate(errno: errno) }

    let connectResult = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
    guard connectResult == 0 else {
        let e = errno
        Darwin.close(fd)
        throw ReplayError.connectFailed(host: host, port: port, errno: e)
    }
    return fd
}
