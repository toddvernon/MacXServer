import Foundation

// Thread-safe FIFO of bytes the server should write back to the client.
//
// Two producers append to this:
//   - the read thread, after dispatching a request that produces a reply
//   - the main thread (Cocoa bridge), after window lifecycle events
//
// One consumer drains it:
//   - the write thread, which blocks on `waitForData()` until something arrives
//
// We don't try to be clever about per-message boundaries — the X11 wire allows
// concatenated replies/events as long as each one is internally well-framed,
// which the encoders guarantee.

public final class OutboundQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer: [UInt8] = []
    private var stopped = false

    public init() {}

    public func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        condition.lock()
        buffer.append(contentsOf: bytes)
        condition.signal()
        condition.unlock()
    }

    public func append(_ contiguous: ArraySlice<UInt8>) {
        guard !contiguous.isEmpty else { return }
        condition.lock()
        buffer.append(contentsOf: contiguous)
        condition.signal()
        condition.unlock()
    }

    /// Block until bytes are available or `stop()` is called. Returns drained
    /// bytes (possibly empty if stopped).
    public func waitAndDrain() -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty && !stopped {
            condition.wait()
        }
        let out = buffer
        buffer = []
        return out
    }

    /// Non-blocking; returns whatever is currently buffered.
    public func drain() -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        let out = buffer
        buffer = []
        return out
    }

    public var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return buffer.isEmpty
    }

    public func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}
