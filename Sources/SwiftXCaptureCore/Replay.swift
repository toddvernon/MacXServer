import Foundation
import Darwin

public struct ReplayArgs: Equatable, Sendable {
    public var inputPath: String
    public var targetHost: String
    public var targetPort: UInt16

    public init(inputPath: String, targetHost: String, targetPort: UInt16) {
        self.inputPath = inputPath
        self.targetHost = targetHost
        self.targetPort = targetPort
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
        for frame in frames where frame.direction == .clientToServer {
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
