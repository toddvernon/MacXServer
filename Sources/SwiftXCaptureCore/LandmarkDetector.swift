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
        // Additional identity properties harvested from ChangeProperty by
        // afterRequest. Populated as the toolkit sets each property at
        // realize time (Xt typically sets WM_CLASS / WM_COMMAND /
        // WM_CLIENT_MACHINE before WM_NAME, so they're available when
        // the identify landmark fires).
        var wmClassClass: String?          // the `class` field of WM_CLASS
        var wmClientMachine: String?       // hostname
        var wmCommand: [String]?           // argv elements
        // _MOTIF_WM_HINTS.inputMode if the client set the INPUT_MODE flag.
        // Values per MwmUtil.h: 0=MODELESS, 1=PRIMARY_APPLICATION_MODAL,
        // 2=SYSTEM_MODAL, 3=FULL_APPLICATION_MODAL.
        var motifInputMode: UInt32?
    }

    private struct PendingPress {
        var button: UInt8
        var time: UInt32
        var eventX: Int16
        var eventY: Int16
        var state: UInt16       // modifier mask at press time
    }

    // Windows created with parent == root, by wid.
    private var topLevels: [UInt32: TopLevel] = [:]
    // Parent map for every CreateWindow we observe (including non-top-level
    // children). Used to walk up the hierarchy from a clicked / affected
    // window to find the nearest named ancestor — the central abstraction
    // that gates whether any state-change landmark gets emitted at all.
    private var parents: [UInt32: UInt32] = [:]
    // Per-window size from CreateWindow. Useful for sizing intuition in
    // child references ("on its 60×26 child of 'Command Window'").
    private var windowSizes: [UInt32: (UInt16, UInt16)] = [:]
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
    // Set of windows we've already emitted a "was hidden / was dismissed"
    // landmark for. Used to suppress a redundant "was closed" landmark
    // when the client follows the hide with a destroy (the common Motif
    // pattern: unmap dialog, then destroy its resources).
    private var hideEmittedFor: Set<UInt32> = []
    // Latest text drawn into each window via ImageText8 / PolyText8 /
    // ImageText16 / PolyText16. Used to attach a button label to click
    // landmarks: the toolkit draws each widget's label directly into the
    // widget's window, so the latest text on the clicked window is almost
    // always its label (vintage Motif/Xaw aren't double-buffered).
    private var windowText: [UInt32: String] = [:]
    // Length cap above which we don't treat captured text as a label.
    // Long strings are typically text-area contents (xterm output,
    // editor buffers), not widget labels.
    private let labelLengthCap = 24

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
            parents[r.wid] = r.parent
            windowSizes[r.wid] = (r.width, r.height)
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
                    width: top.width, height: top.height, isPrimary: isPrimary,
                    wmClass: top.wmClassClass,
                    wmHost: top.wmClientMachine,
                    wmCommand: top.wmCommand
                )))
            }
            if let parent = transientFor[r.window] {
                let size = topLevels[r.window].map { "\($0.width)×\($0.height)" } ?? "size unknown"
                let parentName = topLevels[parent]?.name
                let above = parentName.map { "\"\($0)\"" } ?? "window \(hexId(parent))"
                // Inputmode 1=PRIMARY_APP_MODAL, 2=SYSTEM_MODAL,
                // 3=FULL_APP_MODAL all warrant the "modal " prefix.
                // 0=MODELESS is the explicit "non-modal" declaration.
                let modalPrefix: String
                switch topLevels[r.window]?.motifInputMode {
                case 1, 2, 3: modalPrefix = "modal "
                default: modalPrefix = ""
                }
                out.append(Landmark(
                    "# A \(modalPrefix)dialog opens above \(above) " +
                    "(\(hexId(r.window)), \(size))"
                ))
            }
            return out

        case .unmapWindow(let r):
            // Only landmark the unmap if the window was actually mapped
            // and we can name what it is to the user. Children unmap
            // routinely (Motif re-parenting, scroll-down menu hide) and
            // would just be noise.
            guard mappedWindows.contains(r.window) else { return [] }
            mappedWindows.remove(r.window)
            guard let top = topLevels[r.window] else { return [] }
            // Allow a future re-map to re-announce the appearance, since
            // hide-then-show is a meaningful user journey to surface.
            topLevels[r.window]?.emittedMapLandmark = false
            hideEmittedFor.insert(r.window)
            return [Landmark(hideOrCloseText(
                action: .hidden, windowId: r.window, name: top.name,
                width: top.width, height: top.height,
                transientParentName: transientForParentName(r.window)
            ))]

        case .destroyWindow(let r):
            // Resolve any landmark text BEFORE we wipe state, since the
            // destroy path needs the window's name and transient context.
            var emitted: [Landmark] = []
            // Suppress the "was closed" landmark if we already announced
            // the hide for this window — the destroy is the routine
            // resource cleanup the client does after dismissing, and
            // narrating both reads as duplicate.
            if let top = topLevels[r.window], !hideEmittedFor.contains(r.window) {
                emitted.append(Landmark(hideOrCloseText(
                    action: .closed, windowId: r.window, name: top.name,
                    width: top.width, height: top.height,
                    transientParentName: transientForParentName(r.window)
                )))
            }
            // Tear down all tracking for this window id. Resource ids in
            // X can be recycled, so leaving stale entries around could
            // mis-attribute future activity. (Note: real X servers also
            // destroy all subwindows recursively. We don't walk children
            // here since DestroyWindow is rare enough on top-levels that
            // a leaked child entry is harmless until the next CreateWindow
            // reuses the id, at which point our state gets overwritten.)
            topLevels.removeValue(forKey: r.window)
            parents.removeValue(forKey: r.window)
            windowSizes.removeValue(forKey: r.window)
            mappedWindows.remove(r.window)
            transientFor.removeValue(forKey: r.window)
            hideEmittedFor.remove(r.window)
            return emitted

        case .changeProperty(let r):
            // WM_NAME (atom 39) — identify a top-level. Only the request's
            // property atom matters; we match by atom name from the resolver
            // so app-interned WM_NAME variants also work in principle (in
            // practice WM_NAME is the predefined atom 39 always).
            let propName = atomToName[r.property] ?? predefinedAtomName(r.property)
            if propName == "WM_NAME", let top = topLevels[r.window],
               top.emittedNameLandmark != true {
                let name = decodeWMName(r.data, format: r.format.rawValue)
                topLevels[r.window]?.name = name
                topLevels[r.window]?.emittedNameLandmark = true
                let alreadyMapped = mappedWindows.contains(r.window)
                let isFirst = !firstIdentifyEmitted
                firstIdentifyEmitted = true
                // The identify landmark fires here at WM_NAME time. Most
                // Xt toolkits set WM_NAME *before* WM_CLASS / WM_COMMAND /
                // WM_CLIENT_MACHINE, so by-design those aren't available
                // yet; we surface them in the map landmark instead, which
                // fires after the toolkit's full property burst has landed.
                return [Landmark(identifyLandmarkText(
                    windowId: r.window, name: name,
                    width: top.width, height: top.height,
                    isFirst: isFirst, alreadyMapped: alreadyMapped
                ))]
            }
            // WM_TRANSIENT_FOR (atom 68) — record for the eventual MapWindow.
            // Data is a 32-bit WINDOW id (4 bytes), format=32.
            if propName == "WM_TRANSIENT_FOR" && r.data.count >= 4 && r.format.rawValue == 32 {
                let parent = readUInt32LE(r.data, byteOrder: byteOrder)
                transientFor[r.window] = parent
            }
            // Identity-enriching properties for top-levels. Each gets
            // tucked onto the TopLevel entry if one exists, so the
            // identify landmark can pick them up when WM_NAME fires.
            // Order-tolerant: clients set these in varying sequence.
            if propName == "WM_CLASS" && r.format.rawValue == 8 && topLevels[r.window] != nil {
                let parts = parseWMClassPair(r.data)
                topLevels[r.window]?.wmClassClass = parts.cls
            }
            if propName == "WM_CLIENT_MACHINE" && r.format.rawValue == 8 && topLevels[r.window] != nil {
                let host = String(bytes: r.data.prefix(while: { $0 != 0 }), encoding: .isoLatin1) ?? ""
                if !host.isEmpty { topLevels[r.window]?.wmClientMachine = host }
            }
            if propName == "WM_COMMAND" && r.format.rawValue == 8 && topLevels[r.window] != nil {
                let argv = parseNULSeparatedStrings(r.data)
                if !argv.isEmpty { topLevels[r.window]?.wmCommand = argv }
            }
            if (propName == "_MOTIF_WM_HINTS" || propName == "_MWM_HINTS")
                && r.format.rawValue == 32 && r.data.count >= 20
                && topLevels[r.window] != nil {
                // Layout per MwmUtil.h: flags, functions, decorations,
                // inputMode, status — 5 CARD32s. Only honor inputMode
                // when the INPUT_MODE flag bit (0x4) is set.
                let flags = readCARD32(r.data, offset: 0, byteOrder: byteOrder)
                if flags & 0x4 != 0 {
                    topLevels[r.window]?.motifInputMode = readCARD32(r.data, offset: 12, byteOrder: byteOrder)
                }
            }
            return []

        // Text-drawing requests: cache the most recent text drawn into
        // each window for the click landmark's button-label lookup. We
        // only watch direct draws to a known window — pixmap-targeted
        // text belongs to a different flow (double-buffered widgets are
        // rare in vintage X anyway).
        case .imageText8(let r):
            captureWindowText(drawableId: r.drawable,
                              text: String(bytes: r.string, encoding: .isoLatin1) ?? "")
            return []
        case .polyText8(let r):
            captureWindowText(drawableId: r.drawable,
                              text: extractPolyText8(items: r.items))
            return []
        case .imageText16(let r):
            captureWindowText(drawableId: r.drawable,
                              text: decodeChars16(r.characters))
            return []
        case .polyText16(let r):
            captureWindowText(drawableId: r.drawable,
                              text: extractPolyText16(items: r.items, byteOrder: byteOrder))
            return []

        default:
            return []
        }
    }

    /// Update the per-window text cache when we see a text-drawing
    /// request. Drops the entry when the drawable isn't a known window
    /// (it's a pixmap, or a window we never observed CreateWindow on).
    /// Idle no-op for empty strings.
    private mutating func captureWindowText(drawableId: UInt32, text: String) {
        guard !text.isEmpty else { return }
        guard parents[drawableId] != nil || topLevels[drawableId] != nil else { return }
        windowText[drawableId] = text
    }

    /// Feed a decoded server-to-client message to the detector. Currently
    /// observes ButtonPress / ButtonRelease (click landmarks) and XError
    /// (error-correlation landmarks). Takes `screenRoots` so click
    /// contextualization can recognize when the click target is the root
    /// itself, and `extensionMajorToName` so XError landmarks can name an
    /// extension request that triggered the error.
    public mutating func afterServerMessage(_ msg: ServerMessage, byteOrder: ByteOrder,
                                             screenRoots: Set<UInt32> = [],
                                             extensionMajorToName: [UInt8: String] = [:],
                                             resources: ResourceRegistry = ResourceRegistry()) -> [Landmark] {
        if case .xError(let err) = msg {
            return errorLandmark(err, byteOrder: byteOrder,
                                  screenRoots: screenRoots,
                                  extensionMajorToName: extensionMajorToName,
                                  resources: resources)
        }
        guard case .event(let e) = msg else { return [] }
        switch e.code {
        case 4:  // ButtonPress
            guard let ie = try? InputEvent.decode(from: e.bytes, byteOrder: byteOrder) else {
                return []
            }
            pendingPresses[ie.event] = PendingPress(
                button: ie.detail, time: ie.time,
                eventX: ie.eventX, eventY: ie.eventY,
                state: ie.state
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
            // Resolve the clicked window to something the reader can
            // identify. Per the namability rule: emit only if we can name
            // the target window, a named top-level ancestor, or recognize
            // it as the root (desktop). Otherwise skip — a bare hex id
            // isn't actionable.
            guard let ref = resolveReference(for: ie.event, screenRoots: screenRoots) else {
                return []
            }
            let label = windowText[ie.event].flatMap { text -> String? in
                guard !text.isEmpty, text.count <= labelLengthCap else { return nil }
                // Trim and collapse whitespace so multi-line strings on a
                // single window don't read as awkward labels.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return [Landmark(clickLandmarkText(
                ref: ref, button: pp.button,
                x: pp.eventX, y: pp.eventY,
                clickedWindowId: ie.event,
                modifiers: pp.state,
                buttonLabel: label
            ))]
        default:
            return []
        }
    }

    /// If `id` has a WM_TRANSIENT_FOR set, return the name of the
    /// transient parent (or nil if the parent itself is unnamed).
    /// Used to render dialog-dismissed / dialog-closed landmarks.
    func transientForParentName(_ id: UInt32) -> String? {
        guard let parent = transientFor[id] else { return nil }
        return topLevels[parent]?.name
    }

    // MARK: - Error correlation

    private func errorLandmark(_ err: XError, byteOrder: ByteOrder,
                                screenRoots: Set<UInt32>,
                                extensionMajorToName: [UInt8: String],
                                resources: ResourceRegistry) -> [Landmark] {
        let errName = errorName(err.errorCode) ?? "Error#\(err.errorCode)"
        let seq = err.sequenceNumber(byteOrder: byteOrder)
        // Failing-request name: core opcode if < 128, else look up the
        // extension by major opcode. Minor opcode goes alongside the
        // extension name since that's how X11 identifies sub-requests.
        let major = err.majorOpcode
        let minor = err.minorOpcode(byteOrder: byteOrder)
        let requestPhrase: String
        if major < 128 {
            requestPhrase = opcodeName(major) ?? "request opcode \(major)"
        } else if let extName = extensionMajorToName[major] {
            requestPhrase = "\(extName) request (minor=\(minor))"
        } else {
            requestPhrase = "extension request major=\(major) minor=\(minor)"
        }
        // Resource clause: only meaningful for resource-bearing errors.
        // Try to resolve to a named window; otherwise quote the raw id.
        let badId = err.badResourceId(byteOrder: byteOrder)
        let resourcePhrase = resourcePhraseForError(
            code: err.errorCode, badId: badId, screenRoots: screenRoots
        )
        // Lineage suffix: when the registry has seen this id, append
        // "(created at seq=X)" or "(freed at seq=Y, created at seq=X)".
        // The freed annotation is the textbook use-after-free signal —
        // the request blew up because the client referenced a resource
        // it had already freed. Only annotate for resource-bearing
        // errors; BadValue gets nothing extra.
        let lineage = lineageSuffix(forErrorCode: err.errorCode,
                                     badId: badId, resources: resources)
        let text: String
        switch (resourcePhrase, lineage) {
        case (.some(let phrase), .some(let lin)):
            text = "# \(errName) at seq=\(seq) from \(requestPhrase) \(phrase) \(lin)"
        case (.some(let phrase), .none):
            text = "# \(errName) at seq=\(seq) from \(requestPhrase) \(phrase)"
        case (.none, .some(let lin)):
            text = "# \(errName) at seq=\(seq) from \(requestPhrase) \(lin)"
        case (.none, .none):
            text = "# \(errName) at seq=\(seq) from \(requestPhrase)"
        }
        return [Landmark(text)]
    }

    /// Lineage annotation for a bad-resource error. Returns
    /// `(freed at seq=Y, created at seq=X)` when the id was seen freed,
    /// `(created at seq=X)` when it was created but not freed, nil when
    /// we never saw the id (capture started mid-session, server-side id,
    /// or BadValue / non-resource error).
    private func lineageSuffix(forErrorCode code: UInt8, badId: UInt32,
                                resources: ResourceRegistry) -> String? {
        let resourceCodes: Set<UInt8> = [3, 4, 5, 6, 7, 9, 12, 13, 14]
        guard resourceCodes.contains(code), badId != 0 else { return nil }
        guard let entry = resources.entry(badId) else { return nil }
        if let freedAt = entry.freedAtSeq {
            return "(freed at seq=\(freedAt), created at seq=\(entry.createdAtSeq))"
        }
        return "(created at seq=\(entry.createdAtSeq))"
    }

    private func resourcePhraseForError(code: UInt8, badId: UInt32,
                                         screenRoots: Set<UInt32>) -> String? {
        // BadValue's "bad resource" slot actually holds the offending
        // value, not a resource id. Render as "(bad value=N)" to keep
        // the semantics honest. Errors that don't carry a resource id
        // (BadMatch, BadAccess, BadAlloc, BadName, BadLength,
        // BadImplementation, BadRequest) get no resource phrase at all.
        if code == 2 { // BadValue
            return "(bad value=\(badId))"
        }
        // Resource-bearing error codes: BadWindow=3, BadPixmap=4,
        // BadAtom=5, BadCursor=6, BadFont=7, BadDrawable=9, BadColor=12,
        // BadGC=13, BadIDChoice=14.
        let resourceCodes: Set<UInt8> = [3, 4, 5, 6, 7, 9, 12, 13, 14]
        guard resourceCodes.contains(code), badId != 0 else { return nil }
        // Try to resolve. If the bad id is itself a known top-level or
        // descends from one, frame as "on 'X'". Otherwise quote the id.
        if let ref = resolveReference(for: badId, screenRoots: screenRoots) {
            switch ref {
            case .root:
                return "on the desktop"
            case .topLevel(let id, let name, _, _):
                if let n = name { return "on \"\(n)\"" }
                return "on an unnamed top-level (\(hexId(id)))"
            case .child(_, let topName, _, _, _):
                if let n = topName { return "on a child of \"\(n)\"" }
                return "on a child of an unnamed top-level"
            }
        }
        return "(bad resource \(hexId(badId)))"
    }

    // MARK: - Hierarchy + name resolution

    /// What a window resolves to for landmark text purposes.
    enum WindowReference {
        /// The clicked / affected window is the screen root.
        case root
        /// The clicked / affected window is a tracked top-level. Carries
        /// its name (nil if WM_NAME never set) and size for reader context.
        case topLevel(id: UInt32, name: String?, width: UInt16, height: UInt16)
        /// The clicked / affected window is a descendant of a tracked
        /// top-level. Carries the top-level's name (nil if unnamed) and
        /// the immediate clicked child's size for reader context.
        case child(topLevelId: UInt32, topLevelName: String?,
                   childId: UInt32, childWidth: UInt16, childHeight: UInt16)
    }

    /// Walk up the parent chain from `id` looking for a recognizable
    /// landmark anchor (root window, tracked top-level, or simply the
    /// nearest top-level we know about). Returns nil if no anchor is
    /// reachable (the click landed on a window we never observed, e.g.
    /// pre-existing root subwindows or windows from a capture truncated
    /// before their CreateWindow).
    func resolveReference(for id: UInt32, screenRoots: Set<UInt32>) -> WindowReference? {
        if screenRoots.contains(id) { return .root }
        if let top = topLevels[id] {
            return .topLevel(id: id, name: top.name, width: top.width, height: top.height)
        }
        // Walk parents until we hit a top-level or the root.
        let (childW, childH) = windowSizes[id] ?? (0, 0)
        var cursor = id
        while let parent = parents[cursor] {
            if screenRoots.contains(parent) {
                // Our cursor is a top-level we somehow didn't register
                // (CreateWindow with parent=root that bypassed the
                // top-level path — shouldn't happen but be defensive).
                return .topLevel(id: cursor, name: topLevels[cursor]?.name,
                                 width: windowSizes[cursor]?.0 ?? 0,
                                 height: windowSizes[cursor]?.1 ?? 0)
            }
            if let top = topLevels[parent] {
                return .child(topLevelId: parent, topLevelName: top.name,
                              childId: id, childWidth: childW, childHeight: childH)
            }
            cursor = parent
        }
        return nil
    }
}

// MARK: - Helpers (file-private; mirror the chrono dumper's conventions)

private func hexId(_ v: UInt32) -> String { String(format: "0x%X", v) }

// Story-form narration for a click. The window reference resolved by
// the hierarchy walk decides which of four variants gets rendered:
//
//   - root: clicked the desktop ("on the desktop")
//   - topLevel + name: clicked the top-level directly ("on 'Command Window'")
//   - topLevel + no name: clicked a known but unnamed top-level
//   - child of top-level: clicked something inside a (named or not) top-level
//
// The button verb varies on button==1 ("clicks") vs 2-5 ("clicks button N");
// buttons 4/5 are scroll wheel up/down on most systems but the protocol
// can't tell from outside, so we treat them as clicks.
enum HideOrCloseAction {
    case hidden    // UnmapWindow — window still exists, may reappear
    case closed    // DestroyWindow — window is gone
}

// Text for the hide/close family of landmarks. Six variants emerge from
// the cross-product of (hidden / closed) × (named top-level / unnamed
// top-level / transient with named parent). When a transient parent is
// known we lead with "the dialog" framing since that's how a user
// remembers it; the underlying window may have its own name too, in
// which case both appear ('Save Warning' dialog above 'xmeditor').
private func hideOrCloseText(action: HideOrCloseAction,
                              windowId: UInt32, name: String?,
                              width: UInt16, height: UInt16,
                              transientParentName: String?) -> String {
    let verb: String
    switch action {
    case .hidden: verb = transientParentName != nil ? "was dismissed" : "was hidden"
    case .closed: verb = "was closed"
    }
    // Empty WM_NAME is a real protocol act (see the empty-name case in
    // identifyLandmarkText) but it's not a useful label here. Fall back
    // to the unnamed framing so the output doesn't render literal "".
    let usableName: String? = (name?.isEmpty == false) ? name : nil
    if let parentName = transientParentName {
        // Dialog framing — parent name is the load-bearing reference.
        if let n = usableName {
            return "# The \"\(n)\" dialog above \"\(parentName)\" \(verb)"
        }
        return "# The dialog above \"\(parentName)\" \(verb) " +
            "(\(hexId(windowId)), \(width)×\(height))"
    }
    // Non-dialog top-level
    if let n = usableName {
        return "# The \"\(n)\" window \(verb)"
    }
    return "# An unnamed top-level \(verb) (\(hexId(windowId)), \(width)×\(height))"
}

private func clickLandmarkText(ref: LandmarkDetector.WindowReference,
                                button: UInt8, x: Int16, y: Int16,
                                clickedWindowId: UInt32,
                                modifiers: UInt16 = 0,
                                buttonLabel: String? = nil) -> String {
    // Modifier prefix: "Shift-", "Ctrl-", "Shift+Ctrl-" etc. The keyboard
    // bits we care about live in the low 8 bits (Shift/Lock/Ctrl/Mod1..5);
    // pointer-button bits (Button1..5 at 0x100..0x1000) are noise here
    // since the originating ButtonPress always has its own button bit set.
    let keyboardBits = modifiers & 0x00FF
    let modPrefix: String
    if keyboardBits == 0 {
        modPrefix = ""
    } else {
        // Reuse the dumper's symbolic decoder, then transform "Shift|Ctrl"
        // into "Shift+Ctrl-" hyphen-suffix form ("Ctrl-click" reads better
        // than "Ctrl|clicks").
        let hyphenated = modifierMaskString(keyboardBits).replacingOccurrences(of: "|", with: "+")
        modPrefix = "\(hyphenated)-"
    }
    let verb = button == 1 ? "\(modPrefix)clicks" : "\(modPrefix)clicks button \(button)"
    // Label phrase: when the clicked window has a recently-drawn short
    // text, prefer it to the bare hex id ("on \"OK\"" instead of "on a
    // child"). Falls through to the existing phrasing otherwise.
    let labelPhrase = buttonLabel.map { "\"\($0)\"" }
    switch ref {
    case .root:
        return "# The user \(verb) on the desktop at (\(x),\(y))"
    case .topLevel(let id, let name, _, _):
        if let n = name {
            return "# The user \(verb) on \"\(n)\" at (\(x),\(y))"
        }
        return "# The user \(verb) on an unnamed top-level (\(hexId(id))) at (\(x),\(y))"
    case .child(_, let topName, _, let cw, let ch):
        // Prefer the label when available — "clicks on \"OK\" in
        // \"Save?\"" reads as a workflow event, not a geometry note.
        if let label = labelPhrase, let n = topName {
            return "# The user \(verb) on \(label) in \"\(n)\" at (\(x),\(y))"
        }
        if let label = labelPhrase {
            return "# The user \(verb) on \(label) inside an unnamed top-level at (\(x),\(y))"
        }
        let sizePhrase: String
        if cw > 0 && ch > 0 {
            sizePhrase = "a \(cw)×\(ch) child"
        } else {
            sizePhrase = "a child"
        }
        if let n = topName {
            return "# The user \(verb) inside \"\(n)\" on \(sizePhrase) " +
                "\(hexId(clickedWindowId)) at (\(x),\(y))"
        }
        // Top-level is known but unnamed — still namable enough to surface.
        return "# The user \(verb) inside an unnamed top-level on \(sizePhrase) " +
            "\(hexId(clickedWindowId)) at (\(x),\(y))"
    }
}

// Story-form narration for a top-level window appearing on screen. We
// vary the wording on (name known?) × (primary?) so the reader can walk
// the dump as a sequence of events: the first named window appears, then
// another window appears, then a dialog opens, etc.
//
// The window id and size always come along for technical reference — the
// reader needs them to correlate the landmark with the actual protocol
// lines around it.
// Story-form narration for a WM_NAME landmark. The action being narrated
// is "the client just told the server (and any WM) what to call this
// window," but for a reader walking the capture as a story the more
// useful framing is "a new window with this name is being set up" or
// (in the rare WM_NAME-after-map case) "this window has been renamed."
//
// We always note "Not yet visible on screen" when the window hasn't been
// mapped yet — that's the load-bearing fact for the user who's trying to
// understand whether they would have seen this window when the capture
// was running.
private func identifyLandmarkText(windowId: UInt32, name: String,
                                   width: UInt16, height: UInt16,
                                   isFirst: Bool, alreadyMapped: Bool) -> String {
    // An empty WM_NAME is a real protocol act (the client wrote zero
    // bytes for the name). Some toolkits (Motif/Xt boot path) do this on
    // hidden helper windows the user never sees. Surface them — the
    // reader needs to know they exist — but render the name field as
    // "no name set" rather than literal "".
    let nameStr = name.isEmpty ? "no name set" : "\"\(name)\""
    if alreadyMapped {
        if name.isEmpty {
            return "# Window \(hexId(windowId)) had its name cleared (WM_NAME set to empty)"
        }
        return "# Window \(hexId(windowId)) is renamed to \(nameStr)"
    }
    let size = "\(width)×\(height)"
    if isFirst {
        return "# The client creates its first top-level window (\(nameStr), " +
            "\(size), \(hexId(windowId))). Not yet visible on screen."
    }
    return "# Another top-level window is created (\(nameStr), " +
        "\(size), \(hexId(windowId))). Not yet visible on screen."
}

/// Build the comma-separated provenance clause appended to the identify
/// landmark. Empty when nothing is known. Each fragment is gated on its
/// own data being present, so a client that sets only WM_CLASS still
/// gets `(XTerm class)` without us inventing a host or argv.
private func provenanceSuffix(wmClass: String?, wmHost: String?, wmCommand: [String]?) -> String {
    var parts: [String] = []
    if let cls = wmClass, !cls.isEmpty { parts.append("\(cls) class") }
    if let host = wmHost, !host.isEmpty { parts.append("host \"\(host)\"") }
    if let argv = wmCommand, !argv.isEmpty {
        let joined = argv.joined(separator: " ")
        // Cap the argv preview at ~60 chars to keep landmark lines from
        // bloating when a vintage app launched with a long path.
        let preview = joined.count > 60 ? String(joined.prefix(57)) + "…" : joined
        parts.append("launched as `\(preview)`")
    }
    return parts.isEmpty ? "" : ", \(parts.joined(separator: ", "))"
}

private func mapLandmarkText(windowId: UInt32, name: String?,
                              width: UInt16, height: UInt16,
                              isPrimary: Bool,
                              wmClass: String? = nil,
                              wmHost: String? = nil,
                              wmCommand: [String]? = nil) -> String {
    let size = "\(width)×\(height)"
    // Provenance suffix lands here (rather than on identify) because Xt
    // sets WM_NAME first in its property-burst; the class / host / argv
    // properties arrive *after* WM_NAME but before MapWindow, so the
    // map landmark is the first emission point where they're all known.
    let provenance = provenanceSuffix(wmClass: wmClass, wmHost: wmHost, wmCommand: wmCommand)
    if let n = name {
        return "# The \"\(n)\" window appears on screen (\(hexId(windowId)), \(size)\(provenance))"
    }
    if isPrimary {
        return "# A top-level window appears on screen (\(hexId(windowId)), \(size)\(provenance))"
    }
    return "# Another top-level window appears on screen (\(hexId(windowId)), \(size)\(provenance))"
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

/// Read a CARD32 at the given offset in `b`, respecting connection byte
/// order. Caller must ensure offset+4 ≤ b.count.
private func readCARD32(_ b: [UInt8], offset: Int, byteOrder: ByteOrder) -> UInt32 {
    let a = UInt32(b[offset])
    let c = UInt32(b[offset + 1])
    let d = UInt32(b[offset + 2])
    let e = UInt32(b[offset + 3])
    switch byteOrder {
    case .lsbFirst: return (e << 24) | (d << 16) | (c << 8) | a
    case .msbFirst: return (a << 24) | (c << 16) | (d << 8) | e
    }
}

/// Parse a WM_CLASS pair: two NUL-terminated 8-bit strings, instance
/// then class. Tolerant of a missing trailing NUL on the class field —
/// some clients omit it. Returns nil for either field when not present.
private struct WMClassPair { let instance: String?; let cls: String? }
private func parseWMClassPair(_ data: [UInt8]) -> WMClassPair {
    var pieces: [String] = []
    var current: [UInt8] = []
    for b in data {
        if b == 0 {
            pieces.append(String(bytes: current, encoding: .isoLatin1) ?? "")
            current.removeAll(keepingCapacity: true)
            if pieces.count == 2 { break }
        } else if b >= 0x20 {
            current.append(b)
        }
    }
    if !current.isEmpty, pieces.count < 2 {
        pieces.append(String(bytes: current, encoding: .isoLatin1) ?? "")
    }
    let instance = pieces.indices.contains(0) && !pieces[0].isEmpty ? pieces[0] : nil
    let cls = pieces.indices.contains(1) && !pieces[1].isEmpty ? pieces[1] : nil
    return WMClassPair(instance: instance, cls: cls)
}

/// Split a NUL-terminated argv-style blob into Latin-1 strings. Used for
/// WM_COMMAND.
private func parseNULSeparatedStrings(_ data: [UInt8]) -> [String] {
    var out: [String] = []
    var current: [UInt8] = []
    for b in data {
        if b == 0 {
            if !current.isEmpty {
                out.append(String(bytes: current, encoding: .isoLatin1) ?? "")
                current.removeAll(keepingCapacity: true)
            }
        } else {
            current.append(b)
        }
    }
    if !current.isEmpty {
        out.append(String(bytes: current, encoding: .isoLatin1) ?? "")
    }
    return out
}

/// Walk a PolyText8 `items` buffer per X11 §8.7.6 and concatenate the
/// glyph-run bytes into a Latin-1 string. Skips font-set indicators
/// (length byte == 0xFF) since they don't carry visible text. Tolerant
/// of a truncated final record — bails out cleanly.
private func extractPolyText8(items: [UInt8]) -> String {
    var i = 0
    var bytes: [UInt8] = []
    while i < items.count {
        let n = items[i]
        if n == 0xFF {
            // Font-set indicator: 1 marker byte + 4 font-id bytes.
            i += 5
            continue
        }
        if n == 0 {
            // Empty run: zero glyphs follow. Length byte alone moves us
            // forward (no delta, no glyph bytes per spec ambiguity —
            // most encoders skip emitting these entirely).
            i += 1
            continue
        }
        let count = Int(n)
        // 1 length byte + 1 delta byte + count glyph bytes.
        if i + 2 + count > items.count { break }
        bytes.append(contentsOf: items[(i + 2)..<(i + 2 + count)])
        i += 2 + count
    }
    return String(bytes: bytes, encoding: .isoLatin1) ?? ""
}

/// PolyText16 variant: each glyph is 2 bytes (CHAR2B, always MSB-first
/// on the wire regardless of connection byte order — but the count byte
/// gives glyph count, not byte count). Returns a Latin-1 string of the
/// low byte of each CHAR2B (good enough for English-text widget labels).
private func extractPolyText16(items: [UInt8], byteOrder: ByteOrder) -> String {
    var i = 0
    var bytes: [UInt8] = []
    while i < items.count {
        let n = items[i]
        if n == 0xFF {
            i += 5
            continue
        }
        if n == 0 {
            i += 1
            continue
        }
        let glyphCount = Int(n)
        let payloadBytes = glyphCount * 2
        if i + 2 + payloadBytes > items.count { break }
        // Take the LSB of each CHAR2B as a rough Latin-1 approximation.
        // The high byte indexes the font's row; row=0 is the dominant
        // case for ISO-8859-1 fonts (which is what vintage Motif uses).
        var j = i + 2
        for _ in 0..<glyphCount {
            bytes.append(items[j + 1])
            j += 2
        }
        i += 2 + payloadBytes
    }
    return String(bytes: bytes, encoding: .isoLatin1) ?? ""
}

/// ImageText16 carries a flat `[UInt16]`. Take the low byte of each
/// for the Latin-1 approximation.
private func decodeChars16(_ chars: [UInt16]) -> String {
    let bytes = chars.map { UInt8($0 & 0xFF) }
    return String(bytes: bytes, encoding: .isoLatin1) ?? ""
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
    case 34: return "WM_COMMAND"
    case 36: return "WM_CLIENT_MACHINE"
    case 39: return "WM_NAME"
    case 67: return "WM_CLASS"
    case 68: return "WM_TRANSIENT_FOR"
    default: return nil
    }
}
