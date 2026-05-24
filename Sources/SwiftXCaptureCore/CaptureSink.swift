import Foundation

// CaptureSink decouples "what consumes wire bytes" from "what writes a
// `.xtap` file from a proxy session." Recorder is one implementation
// (the proxy/CLI path); swiftx-server's per-session capture queue will
// be another.
//
// The protocol intentionally matches the existing Recorder's API
// exactly so this extraction is a non-breaking refactor: every place
// that holds a `Recorder?` becomes a `CaptureSink?` and keeps working.
// Forward-looking signature changes (zero-copy bytes, explicit
// timestamp) belong with the server-side wiring in step 2 of the
// capture v2 plan, not here.
//
// `record(direction:bytes:)` is synchronous and must be cheap — Proxy's
// pump calls it on the hot path between socket read and socket write.
// Recorder buffers in memory and only hits disk in `finalize()` for
// exactly this reason; see the comment in Recorder.swift for the
// pre-2026-05-09 incident where synchronous I/O under lock broke
// Motif clients via TCP retransmission.

public protocol CaptureSink: AnyObject, Sendable {
    /// Append one direction-tagged frame to the capture. Cheap; must
    /// not block on disk I/O. Timestamps are assigned by the
    /// implementation at call time.
    func record(direction: Direction, bytes: [UInt8])

    /// Close out the capture: flush buffered frames to disk, write
    /// any sidecar metadata. Called once at end of session.
    func finalize() throws
}
