import Foundation
import Framer

// Watches a decoded X11 request + server-message stream and emits synthetic
// "--- text ---" landmark lines at structurally important moments. Both the
// chrono dumper (post-mortem) and macXserver (live, via ServerLog) call into
// the same detector so the inline annotation vocabulary stays consistent.
//
// v1 detectors — all deterministic, no heuristics:
//
//   1. Top-level window mapped. MapWindow on a window CreateWindow'd with
//      parent == screen root. First one in a session is tagged (primary);
//      subsequent top-levels are tagged (auxiliary). Since server-side
//      capture writes one .xtap per client, the primary tag pinpoints the
//      app's main window vs invisible utility windows.
//
//   2. Window identity established. First ChangeProperty WM_NAME on a
//      top-level emits the human name so later activity attributes to
//      ("editres" instead of 0x4400001).
//
//   3. Transient / dialog mapped. MapWindow on a window with prior
//      ChangeProperty WM_TRANSIENT_FOR set. Surfaces dialog-popup
//      boundaries.
//
//   4. Click. ButtonPress + matching ButtonRelease on the same window
//      within 500ms. Emitted on the release. The most navigation-useful
//      single landmark for replaying "what did the user do."
//
// The detector is a value type. Callers thread it through their decode
// loop and call `afterRequest(...)` / `afterServerMessage(...)` after each
// formatted line; the returned strings are emitted (prefixed with the
// indentation the host wants) immediately after the triggering line.

public struct LandmarkDetector: Sendable {

    /// One-line landmark text, already prefixed with `--- ` and suffixed
    /// with ` ---`. Hosts wrap with their own line / indent style.
    public struct Landmark: Sendable, Equatable {
        public var text: String
        public init(_ text: String) { self.text = text }
    }

    // MARK: - State

    private struct TopLevel {
        var width: UInt16
        var height: UInt16
        var emittedMapLandmark: Bool = false
        var name: String?
        var emittedNameLandmark: Bool = false
    }

    private struct PendingPress {
        var button: UInt8
        var time: UInt32
        var eventX: Int16
        var eventY: Int16
    }

    // Windows created with parent == root, by wid.
    private var topLevels: [UInt32: TopLevel] = [:]
    // Windows that have had WM_TRANSIENT_FOR set, mapped to their transient parent.
    private var transientFor: [UInt32: UInt32] = [:]
    // True once the first top-level MAP landmark has been emitted. Used to
    // decide "A top-level window appears" (first) vs "Another top-level
    // window appears" (subsequent).
    private var primaryEmitted: Bool = false
    // True once ANY WM_NAME identity landmark has been emitted. Tracked
    // separately from primaryEmitted because clients commonly set WM_NAME
    // on several top-levels before mapping any of them — without this
    // separate gate every identify would read as "first top-level."
    private var firstIdentifyEmitted: Bool = false
    // Per-window pending ButtonPress awaiting a matching ButtonRelease.
    private var pendingPresses: [UInt32: PendingPress] = [:]
    // Set once we've seen MapWindow on a window so we don't double-emit if a
    // later MapWindow fires (the X server is forgiving about re-mapping).
    private var mappedWindows: Set<UInt32> = []

    /// Two ButtonPress+ButtonRelease events farther apart than this are NOT
    /// treated as a click. 500ms matches the typical OS double-click threshold
    /// and is comfortably wider than a deliberate UI click.
    private let clickThresholdMs: UInt32 = 500

    public init() {}

    // MARK: - Observation API

    /// Feed a decoded request to the detector. Returns 0 or more landmarks
    /// to emit immediately after the line for this request.
    public mutating func afterRequest(_ req: Request, byteOrder: ByteOrder,
                                       screenRoots: Set<UInt32>,
                                       atomToName: [UInt32: String]) -> [Landmark] {
        switch req {
        case .createWindow(let r):
            if screenRoots.contains(r.parent) {
                topLevels[r.wid] = TopLevel(width: r.width, height: r.height)
            }
            return []

        case .mapWindow(let r):
            guard !mappedWindows.contains(r.window) else { return [] }
            mappedWindows.insert(r.window)
            var out: [Landmark] = []
            if let top = topLevels[r.window], !top.emittedMapLandmark {
                topLevels[r.window]?.emittedMapLandmark = true
                let isPrimary = !primaryEmitted
                primaryEmitted = true
                out.append(Landmark(mapLandmarkText(
                    windowId: r.window, name: top.name,
                    width: top.width, height: top.height, isPrimary: isPrimary
                )))
            }
            if let parent = transientFor[r.window] {
                let size = topLevels[r.window].map { "\($0.width)×\($0.height)" } ?? "size unknown"
                let parentName = topLevels[parent]?.name
                let above = parentName.map { "\"\($0)\"" } ?? "window \(hexId(parent))"
                out.append(Landmark(
                    "# A dialog opens above \(above) " +
                    "(\(hexId(r.window)), \(size))"
                ))
            }
            return out

        case .changeProperty(let r):
            // WM_NAME (atom 39) — identify a top-level. Only the request's
            // property atom matters; we match by atom name from the resolver
            // so app-interned WM_NAME variants also work in principle (in
            // practice WM_NAME is the predefined atom 39 always).
            let propName = atomToName[r.property] ?? predefinedAtomName(r.property)
            if propName == "WM_NAME" && topLevels[r.window] != nil
                && topLevels[r.window]?.emittedNameLandmark != true {
                let name = decodeWMName(r.data, format: r.format.rawValue)
                topLevels[r.window]?.name = name
                topLevels[r.window]?.emittedNameLandmark = true
                let phrase = firstIdentifyEmitted
                    ? "Window \(hexId(r.window)) identifies as \"\(name)\""
                    : "The first top-level window identifies as \"\(name)\""
                firstIdentifyEmitted = true
                return [Landmark("# \(phrase)")]
            }
            // WM_TRANSIENT_FOR (atom 68) — record for the eventual MapWindow.
            // Data is a 32-bit WINDOW id (4 bytes), format=32.
            if propName == "WM_TRANSIENT_FOR" && r.data.count >= 4 && r.format.rawValue == 32 {
                let parent = readUInt32LE(r.data, byteOrder: byteOrder)
                transientFor[r.window] = parent
            }
            return []

        default:
            return []
        }
    }

    /// Feed a decoded server-to-client message to the detector. v1 only
    /// cares about ButtonPress (code 4) + ButtonRelease (code 5) events.
    public mutating func afterServerMessage(_ msg: ServerMessage, byteOrder: ByteOrder) -> [Landmark] {
        guard case .event(let e) = msg else { return [] }
        switch e.code {
        case 4:  // ButtonPress
            guard let ie = try? InputEvent.decode(from: e.bytes, byteOrder: byteOrder) else {
                return []
            }
            pendingPresses[ie.event] = PendingPress(
                button: ie.detail, time: ie.time,
                eventX: ie.eventX, eventY: ie.eventY
            )
            return []
        case 5:  // ButtonRelease
            guard let ie = try? InputEvent.decode(from: e.bytes, byteOrder: byteOrder),
                  let pp = pendingPresses[ie.event],
                  pp.button == ie.detail else {
                return []
            }
            pendingPresses.removeValue(forKey: ie.event)
            let dtMs = ie.time &- pp.time
            guard dtMs <= clickThresholdMs else { return [] }
            // Use natural language for button 1 ("clicks") and explicit
            // number for the rest ("clicks button 2 / 3 / ...") — matches
            // how people actually talk about mouse clicks. Buttons 4/5 are
            // scroll wheel up/down on most systems; we still describe them
            // as clicks because the X protocol can't tell from outside.
            let buttonPhrase = pp.button == 1 ? "clicks"
                : "clicks button \(pp.button)"
            return [Landmark(
                "# The user \(buttonPhrase) at (\(pp.eventX),\(pp.eventY)) " +
                "on window \(hexId(ie.event))"
            )]
        default:
            return []
        }
    }
}

// MARK: - Helpers (file-private; mirror the chrono dumper's conventions)

private func hexId(_ v: UInt32) -> String { String(format: "0x%X", v) }

// Story-form narration for a top-level window appearing on screen. We
// vary the wording on (name known?) × (primary?) so the reader can walk
// the dump as a sequence of events: the first named window appears, then
// another window appears, then a dialog opens, etc.
//
// The window id and size always come along for technical reference — the
// reader needs them to correlate the landmark with the actual protocol
// lines around it.
private func mapLandmarkText(windowId: UInt32, name: String?,
                              width: UInt16, height: UInt16,
                              isPrimary: Bool) -> String {
    let size = "\(width)×\(height)"
    if let n = name {
        return "# The \"\(n)\" window appears on screen (\(hexId(windowId)), \(size))"
    }
    if isPrimary {
        return "# A top-level window appears on screen (\(hexId(windowId)), \(size))"
    }
    return "# Another top-level window appears on screen (\(hexId(windowId)), \(size))"
}

private func readUInt32LE(_ b: [UInt8], byteOrder: ByteOrder) -> UInt32 {
    let a = UInt32(b[0])
    let c = UInt32(b[1])
    let d = UInt32(b[2])
    let e = UInt32(b[3])
    switch byteOrder {
    case .lsbFirst: return (e << 24) | (d << 16) | (c << 8) | a
    case .msbFirst: return (a << 24) | (c << 16) | (d << 8) | e
    }
}

private func decodeWMName(_ data: [UInt8], format: UInt8) -> String {
    // WM_NAME is conventionally STRING (Latin-1) at format=8. UTF8_STRING
    // can also flow through here; UTF-8 decodes as Latin-1 cleanly for
    // ASCII names, which covers virtually every real-world WM_NAME.
    if format == 8 {
        return String(decoding: data, as: UTF8.self)
    }
    return "<format=\(format)>"
}

private func predefinedAtomName(_ atom: UInt32) -> String? {
    // Local copy of the small subset the detector cares about. We avoid
    // pulling in the full predefined-atoms enum here to keep the detector
    // standalone (it's reused server-side).
    switch atom {
    case 39: return "WM_NAME"
    case 68: return "WM_TRANSIENT_FOR"
    default: return nil
    }
}
