import Foundation

// Buffer the session is currently filling with reply / event bytes that
// should reach the client. Pre-refactor this was a producer/consumer FIFO
// with a condition variable: read thread + AppKit main thread both appended
// from different threads, a write thread drained on its own. After the
// single-thread refactor (see SERVER_CONCURRENCY.md) every append + drain
// happens on `ServerSession.protocolQueue`, so no synchronization is needed
// here. The class stays as a typed handle so existing call sites
// (`outbound.append(reply.encode(...))`) keep compiling unchanged.

public final class OutboundQueue: @unchecked Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        WireTrace.shared?.appended(bytes)
        buffer.append(contentsOf: bytes)
    }

    public func append(_ contiguous: ArraySlice<UInt8>) {
        guard !contiguous.isEmpty else { return }
        WireTrace.shared?.appended(Array(contiguous))
        buffer.append(contentsOf: contiguous)
    }

    public func drain() -> [UInt8] {
        let out = buffer
        buffer = []
        return out
    }

    public var isEmpty: Bool { buffer.isEmpty }
}
