import Foundation
import Darwin
@testable import SwiftXCaptureCore

enum TestSocketError: Error {
    case createFailed
    case bindFailed
    case listenFailed
    case acceptFailed
    case dialFailed
    case getsocknameFailed
}

func makeListener(host: String = "127.0.0.1", port: UInt16 = 0) throws -> (fd: Int32, port: UInt16) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestSocketError.createFailed }

    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    _ = inet_aton(host, &addr.sin_addr)

    let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { Darwin.close(fd); throw TestSocketError.bindFailed }
    guard Darwin.listen(fd, 1) == 0 else { Darwin.close(fd); throw TestSocketError.listenFailed }

    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let r = withUnsafeMutablePointer(to: &actual) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &len)
        }
    }
    guard r == 0 else { Darwin.close(fd); throw TestSocketError.getsocknameFailed }
    return (fd, UInt16(bigEndian: actual.sin_port))
}

func acceptOne(_ listenFd: Int32) throws -> Int32 {
    var addr = sockaddr()
    var len = socklen_t(MemoryLayout<sockaddr>.size)
    let cfd = Darwin.accept(listenFd, &addr, &len)
    guard cfd >= 0 else { throw TestSocketError.acceptFailed }
    return cfd
}

func dial(host: String, port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestSocketError.createFailed }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    _ = inet_aton(host, &addr.sin_addr)
    let r = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard r == 0 else { Darwin.close(fd); throw TestSocketError.dialFailed }
    return fd
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let w = bytes.withUnsafeBufferPointer { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if w <= 0 { return }
        offset += w
    }
}

func readUntilEOF(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { return out }
        out.append(contentsOf: buf[0..<n])
    }
}

func makeTempFilePath(prefix: String) -> String {
    let dir = FileManager.default.temporaryDirectory
    let name = "\(prefix)-\(UUID().uuidString).xtap"
    return dir.appendingPathComponent(name).path
}
