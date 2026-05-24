import Foundation
import Framer

// Tee sink for live capture UIs. Wraps a Recorder (or any
// CaptureSink) and additionally tracks:
//
//   - cumulative C2S byte count
//   - cumulative S2C byte count
//   - a sliding window of the most recent decoded request opcodes
//
// The opcode names are derived from a streaming parser that walks
// the C2S byte stream packet-by-packet. We don't fully decode each
// request — Record mode just shows a scrolling list of "what's
// going by on the wire." Examine mode (step 7) is where full per-
// packet decode lives.
//
// All state is lock-guarded so the model's polling timer (on main)
// and the proxy's pump thread can both touch it safely.

public final class RecentRequestSink: CaptureSink, @unchecked Sendable {

    /// Snapshot of progress the UI consumes. Plain struct so the
    /// model can compare against the previous snapshot and decide
    /// whether to publish.
    public struct Snapshot: Equatable, Sendable {
        public var bytesIn: Int = 0
        public var bytesOut: Int = 0
        public var recent: [String] = []
    }

    private let wrapped: CaptureSink
    private let maxRecent: Int

    private let lock = NSLock()
    private var bytesIn: Int = 0
    private var bytesOut: Int = 0
    private var recent: [String] = []
    private var stream = C2SOpcodeStream()

    public init(wrapping: CaptureSink, maxRecent: Int = 24) {
        self.wrapped = wrapping
        self.maxRecent = maxRecent
    }

    public func record(direction: Direction, bytes: [UInt8]) {
        wrapped.record(direction: direction, bytes: bytes)
        lock.lock()
        defer { lock.unlock() }
        switch direction {
        case .clientToServer:
            bytesIn += bytes.count
            let names = stream.feed(bytes)
            for name in names {
                recent.append(name)
            }
            if recent.count > maxRecent {
                recent.removeFirst(recent.count - maxRecent)
            }
        case .serverToClient:
            bytesOut += bytes.count
        }
    }

    public func finalize() throws {
        try wrapped.finalize()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(bytesIn: bytesIn, bytesOut: bytesOut, recent: recent)
    }
}

// MARK: - Streaming opcode parser

/// Walks a continuous C2S byte stream, packet by packet, and returns
/// opcode names as it crosses each packet boundary. Holds enough
/// state across feed() calls to handle bytes arriving in arbitrary
/// chunks.
///
/// The stream starts with X11's SetupRequest (variable length per
/// the auth-name/auth-data fields in its header). Once that's past,
/// every subsequent packet starts with a 4-byte fixed header:
///
///   byte 0: major opcode
///   byte 1: data byte (opcode-specific arg)
///   bytes 2-3: length in 4-byte units (UInt16 in negotiated byte order)
///
/// A length of 0 indicates BIG-REQUESTS-style extended length in the
/// next 4 bytes — we don't decode that today (server doesn't ship
/// the extension); if we hit one we stop reporting names but don't
/// crash. The proxy's byte-pump keeps working regardless; only the
/// UI feed pauses.
public struct C2SOpcodeStream {

    private var buffer: [UInt8] = []
    private var cursor: Int = 0
    private var byteOrder: ByteOrder = .lsbFirst
    private var pastSetup: Bool = false
    private var giveUp: Bool = false

    public init() {}

    /// Append new bytes and return any newly-decoded opcode names.
    /// Trims the buffer behind the cursor once it gets large enough
    /// to matter — we never need to look backwards.
    public mutating func feed(_ bytes: [UInt8]) -> [String] {
        guard !giveUp else { return [] }
        buffer.append(contentsOf: bytes)
        var names: [String] = []

        if !pastSetup {
            guard buffer.count >= 12 else { return names }
            // Byte 0: 'B' (0x42) = MSB-first, 'l' (0x6c) = LSB-first.
            byteOrder = (buffer[0] == 0x42) ? .msbFirst : .lsbFirst
            let nbAuthName = readUInt16(at: 6)
            let nbAuthData = readUInt16(at: 8)
            let setupLen = 12
                + paddedLen(Int(nbAuthName))
                + paddedLen(Int(nbAuthData))
            guard buffer.count >= setupLen else { return names }
            cursor = setupLen
            pastSetup = true
        }

        while cursor + 4 <= buffer.count {
            let op = buffer[cursor]
            let lenIn4 = readUInt16(at: cursor + 2)
            guard lenIn4 > 0 else {
                // BIG-REQUESTS extended length: we don't support it.
                // Stop reporting names so we don't desync. The wire
                // pump (Proxy.pump) is unaffected.
                giveUp = true
                return names
            }
            let packetLen = Int(lenIn4) * 4
            guard cursor + packetLen <= buffer.count else { break }
            names.append(opcodeName(op) ?? "op(\(op))")
            cursor += packetLen
        }

        // Compact the buffer if we've crossed past a lot of bytes.
        // Cap discard threshold at 64 KB so we don't reallocate on
        // every packet.
        if cursor >= 65536 {
            buffer.removeFirst(cursor)
            cursor = 0
        }

        return names
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        let lo = UInt16(buffer[offset])
        let hi = UInt16(buffer[offset + 1])
        switch byteOrder {
        case .lsbFirst: return lo | (hi << 8)
        case .msbFirst: return (lo << 8) | hi
        }
    }

    /// Pad a byte count to the next multiple of 4.
    private func paddedLen(_ n: Int) -> Int {
        let m = n % 4
        return m == 0 ? n : n + (4 - m)
    }
}
