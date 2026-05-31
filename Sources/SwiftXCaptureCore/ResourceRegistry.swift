// Session-wide registry of X11 resources (windows, pixmaps, GCs, fonts,
// cursors, colormaps). Populated by `dump()` as it walks the request
// stream — Create* and Free* requests register and clear entries. The
// data feeds two consumers today:
//
//   1. Session-end summary landmark: a one-liner "# resources: 47 pixmaps
//      (3 freed, 44 leaked), 12 GCs (12 freed)" emitted after the
//      existing requests/events tally.
//
//   2. XError correlation in LandmarkDetector: when a request fails with
//      a resource-bearing error code (BadDrawable, BadGC, BadFont,
//      BadCursor, BadColor, BadWindow), the landmark looks up the bad id
//      in the registry. If it was created and then freed earlier in the
//      session, the landmark says so ("freed at seq=N"). If created and
//      still live, says "created at seq=N". If never seen, falls back to
//      the existing windowName-or-hex rendering.
//
// X11 resource IDs are reusable: a client can FreeFoo then later
// CreateFoo with the same id (per spec — the server has to assume
// recycled). We handle this by overwriting the `entries` slot on
// re-creation, but keep separate `createdTotal` / `freedTotal` counters
// that monotonically increment so the session-end stats stay honest.

import Foundation

public struct ResourceRegistry: Sendable {

    public enum Kind: String, Sendable {
        case window, pixmap, gc, font, cursor, colormap
    }

    public struct Entry: Sendable, Equatable {
        public let kind: Kind
        public let createdAtSeq: UInt16
        public var freedAtSeq: UInt16?

        public var isFreed: Bool { freedAtSeq != nil }
    }

    private var entries: [UInt32: Entry] = [:]
    private var createdTotal: [Kind: Int] = [:]
    private var freedTotal: [Kind: Int] = [:]

    public init() {}

    public mutating func registerCreate(_ id: UInt32, kind: Kind, atSeq seq: UInt16) {
        // Resource id 0 isn't real (it's None / CopyFromParent sentinels);
        // never record it. Spec also reserves the top bit of resource ids
        // for the server's use, but we don't filter on that — the captured
        // CreateFoo request's wire id is what we record.
        guard id != 0 else { return }
        entries[id] = Entry(kind: kind, createdAtSeq: seq, freedAtSeq: nil)
        createdTotal[kind, default: 0] += 1
    }

    public mutating func registerFree(_ id: UInt32, atSeq seq: UInt16) {
        guard id != 0 else { return }
        if var e = entries[id], e.freedAtSeq == nil {
            e.freedAtSeq = seq
            entries[id] = e
            freedTotal[e.kind, default: 0] += 1
        }
        // If the free targets an id we never saw created, don't record
        // anything — could be a legitimate resource from a prior session
        // whose state we missed, or a wire-level bug. The XError correlator
        // will speak up if the server rejects the free.
    }

    public func entry(_ id: UInt32) -> Entry? { entries[id] }

    /// All-time creation count for a kind (does not decrease on free).
    public func createdCount(_ kind: Kind) -> Int { createdTotal[kind] ?? 0 }

    /// All-time free count for a kind.
    public func freedCount(_ kind: Kind) -> Int { freedTotal[kind] ?? 0 }

    /// Created minus freed, by kind. Approximate measure of leaks at
    /// session end — vintage clients commonly leak GCs and pixmaps at
    /// shutdown because the X server cleans up when the connection drops,
    /// so "leaked at session end" doesn't mean "the client had a bug",
    /// just "the client didn't explicitly free."
    public func leakedCount(_ kind: Kind) -> Int {
        max(0, createdCount(kind) - freedCount(kind))
    }

    /// Render a one-line summary suitable for the session-end landmark.
    /// Returns nil if no resources were tracked, so the caller can skip
    /// the line entirely rather than emit "resources: ".
    public func summaryLine() -> String? {
        // Preserve a stable order across runs so diffs against gold are
        // readable. Sorted by kind name (matches enum declaration order
        // alphabetically: colormap < cursor < font < gc < pixmap < window
        // is what `.rawValue` sort gives us — close enough).
        let order: [Kind] = [.window, .pixmap, .gc, .font, .cursor, .colormap]
        var parts: [String] = []
        for kind in order {
            let created = createdCount(kind)
            guard created > 0 else { continue }
            let freed = freedCount(kind)
            let leaked = leakedCount(kind)
            let plural = pluralName(kind, count: created)
            let leakSuffix = leaked > 0 ? ", \(leaked) leaked" : ""
            parts.append("\(created) \(plural) (\(freed) freed\(leakSuffix))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func pluralName(_ kind: Kind, count: Int) -> String {
        switch kind {
        case .window:   return count == 1 ? "window" : "windows"
        case .pixmap:   return count == 1 ? "pixmap" : "pixmaps"
        case .gc:       return count == 1 ? "GC" : "GCs"
        case .font:     return count == 1 ? "font" : "fonts"
        case .cursor:   return count == 1 ? "cursor" : "cursors"
        case .colormap: return count == 1 ? "colormap" : "colormaps"
        }
    }
}
