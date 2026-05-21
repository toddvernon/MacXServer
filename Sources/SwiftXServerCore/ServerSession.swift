import Foundation
import Framer

// Per-connection state machine. Bytes flow in via `feed(_:)`; reply/event bytes
// the server should send back come out the return value. There is no socket
// in here, deliberately — `Server.swift` glues the session to a real socket;
// tests drive the session directly with bytes from the capture corpus.
//
// Sequence numbers: we increment per parsed request (starting at 1 for the
// first non-Setup request, per the X11 spec) and stamp it on every reply we
// emit. SetupAccepted itself doesn't carry a sequence number.

public final class ServerSession: @unchecked Sendable {
    private enum Phase {
        case awaitingSetup
        case running(byteOrder: ByteOrder)
    }

    /// Set by handlers that detect an unrecoverable wire-protocol state
    /// (e.g., a request length-field of 0 — we can't advance the stream
    /// without knowing how many bytes to consume). The listener checks
    /// this after every feed() and cancels the read source. Per spec,
    /// the server is allowed to close on malformed requests after first
    /// emitting BadLength.
    public private(set) var shouldClose: Bool = false

    public let config: ServerConfig

    /// Cross-session shared state (atoms, selection ownership, ID ranges).
    /// In single-client mode this is a freshly-constructed coordinator the
    /// session owns alone; in multi-client mode the listener hands the same
    /// coordinator to every session so they share atoms + selections.
    public let coordinator: ServerCoordinator

    /// Unique-per-session token threaded into every bridge handler
    /// registration so `cleanupOnDisconnect` can remove this session's
    /// handlers in bulk via `bridge.removeHandlers(token:)`. Pre-2026-05-14
    /// every accepted session permanently grew the bridge's handler lists
    /// (the closures captured `[weak self]` and no-op'd after dealloc, but
    /// the lists themselves kept growing and every closure fired on every
    /// AppKit event).
    public let bridgeHandlerToken: UInt64 = ServerSession.nextBridgeHandlerToken()
    private static let _bridgeHandlerTokenLock = NSLock()
    private nonisolated(unsafe) static var _nextBridgeHandlerToken: UInt64 = 1
    private static func nextBridgeHandlerToken() -> UInt64 {
        _bridgeHandlerTokenLock.lock()
        defer { _bridgeHandlerTokenLock.unlock() }
        let t = _nextBridgeHandlerToken
        _nextBridgeHandlerToken &+= 1
        return t
    }

    /// Atoms — delegated to coordinator so atom IDs stay consistent across
    /// sessions. Kept as a property so call sites read `self.atoms.intern(…)`
    /// the same way they always did.
    public var atoms: AtomTable { coordinator.atoms }

    /// Default colormap — delegated to coordinator. X11 colormaps are
    /// server-global resources; pixel 17 means the same RGB to every
    /// session. Pre-2026-05-19 this lived on the session, which let two
    /// clients allocate the same pixel ID with different RGB values
    /// (SHORTCUTS:32, retired with the coordinator move).
    public var colors: ColorTable { coordinator.colors }

    public let windows = WindowTable()
    public let gcs = GCTable()
    public let pixmaps: PixmapTable
    public let fonts = FontTable()
    public let cursors = CursorTable()
    public let properties = PropertyTable()

    /// Selection-conversion policy: routes ConvertSelection to either
    /// real-client owners (forward as SelectionRequest event) or server-
    /// internal stubs (short-circuit with empty SelectionNotify success).
    /// Owns the CDE customization daemon impersonation setup.
    public let selectionMediator: SelectionMediator

    public let outbound: OutboundQueue
    public let bridge: WindowBridge?

    /// Serial queue that owns all session-state mutation. AppKit-side
    /// callbacks (mouse, key, focus) hop onto this queue before touching
    /// session state, so the read thread + the AppKit main thread never
    /// race on `sequenceNumber`, grab state, focus, etc. Mirrors the
    /// XQuartz pattern of a dedicated server thread separate from the
    /// AppKit runloop (see `reference/xquartz-xserver/hw/xquartz/quartzStartup.c`).
    /// See SERVER_CONCURRENCY.md for the full rationale.
    public let protocolQueue: DispatchQueue

    /// Installed by the Listener once a client socket is set up. Called from
    /// `flushOutbound` whenever the session has bytes to send. Always invoked
    /// on `protocolQueue`, so the callback is the single writer to the
    /// socket — no lock needed. Tests that drive `feed` directly leave this
    /// nil and read bytes via `outbound.drain()` instead.
    public var writeCallback: (@Sendable ([UInt8]) -> Void)?

    /// Live source of cut/paste preferences. Read on every copy round-trip
    /// so a prefs change applies without restarting the server. Defaults to
    /// the static defaults (Mac-style on, never auto-fires).
    public let clipboardPrefs: ClipboardPreferencesProvider

    /// Server-internal pseudo-window used as the requestor in the copy
    /// roundtrip. Outside any client's resource-id range so it never
    /// collides with a client-allocated window. The X spec lets the server
    /// pick any window id for SelectionRequest; the property table accepts
    /// changes against any id without checking it exists.
    private let selectionSinkWindow: UInt32 = 0xFFFE_0001

    /// Atom name we ask the selection owner to write the converted text into
    /// on `selectionSinkWindow`. Interned lazily so we know its atom id when
    /// the ChangeProperty arrives.
    private let selectionSinkPropertyName = "SWIFTX_CLIP_FROM_X"

    /// `WM_CLASS` instance (the first of the two null-terminated strings,
    /// e.g. "xterm" / "xcalc") once the client has set the property. nil
    /// before that arrives. Updated from the changeProperty handler. Used
    /// to rename the per-session log file and to prefix the NSWindow title.
    public private(set) var wmInstance: String?
    public private(set) var wmClass: String?

    /// Fired once when WM_CLASS first becomes known on this session. The
    /// listener wires this up to the FileLogSink (rename) and the bridge
    /// (title prefix). Called from the read thread.
    public var onIdentified: (@Sendable (String, String) -> Void)?

    private var phase: Phase = .awaitingSetup
    private var inbound: [UInt8] = []
    public private(set) var sequenceNumber: UInt16 = 0

    /// WM-emulation placement allocator for regular (non-override-redirect)
    /// top-levels. Per ICCCM 4.2.3, a window manager must tell each client
    /// where it placed the client's top-level via a synthetic ConfigureNotify;
    /// toolkits (Xt/Motif) feed that root coord into XTranslateCoordinates
    /// for things like submenu placement. We're a rootless server with no
    /// separate WM, so we play the WM ourselves: pick a root coord, tell
    /// the client, and place the NSWindow at the NSScreen-equivalent.
    /// Values are in X logical pixels; the bridge converts to NSScreen
    /// points via scale/backingScale.
    private var nextTopLevelPlacement = (x: Int16(100), y: Int16(100))
    private let placementCascadeStep: Int16 = 30
    /// Top-levels we've already assigned a placement to. Sticky across
    /// unmap/remap so a window keeps its position when the client toggles
    /// visibility.
    private var placedTopLevels: Set<UInt32> = []

    /// Which X subwindow currently contains the pointer, per top-level
    /// NSWindow. Updated on every pointer-moved event; consulted to decide
    /// when a crossing-event chain (LeaveNotify on old window, EnterNotify
    /// on new) is needed. Absent key = pointer not currently over the
    /// NSWindow's content area.
    private var currentPointerWindow: [UInt32: UInt32] = [:]

    /// Last reported pointer position in top-level coords + which top-level
    /// it was last seen in. Used by `QueryPointer` to answer the client. nil
    /// before the first pointer event arrives.
    private var lastPointerTopLevel: UInt32?
    private var lastPointerXY: (Int16, Int16)?

    /// Active pointer grab state, or nil if not grabbed. Set by GrabPointer,
    /// cleared by UngrabPointer. While set, button / motion events route to
    /// `grabWindow` instead of the deepest-containing-window — this is what
    /// makes Motif menus work (a click outside the menu but inside the
    /// NSWindow goes to the menu so it can dismiss itself).
    ///
    /// Rootless caveat: clicks ENTIRELY outside the NSWindow are macOS's, so
    /// the X grab can't see them. Real X11 would; we can't (without
    /// app-level event monitoring). For Motif menus posted as children of a
    /// parent NSWindow this is sufficient — clicks "outside the menu but
    /// inside the parent" still flow.
    private struct PointerGrab {
        let window: UInt32
        let eventMask: UInt16
        let ownerEvents: Bool
        let cursor: UInt32     // 0 = no cursor override
    }
    private var pointerGrab: PointerGrab?

    /// Active keyboard grab. While set, key events route to `grabWindow`.
    private struct KeyboardGrab {
        let window: UInt32
        let ownerEvents: Bool
    }
    private var keyboardGrab: KeyboardGrab?

    /// Passive button grabs registered via GrabButton. Stored but not yet
    /// honored on event delivery (see OPCODE_STATUS).
    private struct PassiveButtonGrab {
        let grabWindow: UInt32
        let button: UInt8
        let modifiers: UInt16
        let eventMask: UInt16
        let ownerEvents: Bool
    }
    private var passiveButtonGrabs: [PassiveButtonGrab] = []

    /// Passive key grabs registered via GrabKey. Same caveat: tracked,
    /// not yet honored.
    private struct PassiveKeyGrab {
        let grabWindow: UInt32
        let key: UInt8
        let modifiers: UInt16
        let ownerEvents: Bool
    }
    private var passiveKeyGrabs: [PassiveKeyGrab] = []

    /// Root window's event mask. Root isn't in the `windows` table (it has
    /// no WindowEntry — see RegionStep tradeoffs), but a client can set an
    /// event mask on it via ChangeWindowAttributes(root, ...) and most-often
    /// what they care about is SubstructureNotifyMask (1<<19) for being
    /// notified about new/destroyed top-levels. WMs are the canonical case.
    /// We don't run a WM but the path should be spec-correct.
    private var rootEventMask: UInt32 = 0

    /// Pointer buttons currently held. Used to manage the X11 implicit
    /// pointer grab that activates on the first ButtonPress and ends when
    /// all buttons are released. `implicitGrab` flag distinguishes our
    /// auto-installed grab from a client-issued one — we only auto-clear
    /// the implicit kind.
    private var heldButtons: Set<UInt8> = []
    private var implicitGrab: Bool = false

    /// Current X keyboard focus window, set via SetInputFocus. nil = no
    /// explicit focus (KeyPress falls back to keyTarget — the shallowest
    /// descendant with KeyPressMask, then the top-level). Motif sets focus
    /// when the user clicks an XmText / XmTextField widget; without
    /// honoring that, key events go to the wrong window and the text
    /// widget never sees them.
    private var focusWindow: UInt32?

    /// Monotonic server time in milliseconds since the connection started.
    /// X events carry this in the `time` field; clients use it for double-
    /// click detection, drag thresholds, and "is this event newer than
    /// what I last processed?" tracking. Sending 0 across all events
    /// (which we did before) causes some Xt-based clients to treat events
    /// as duplicates and drop them.
    private let connectionStart = Date()
    private var serverTime: UInt32 {
        UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(connectionStart) * 1000))
    }

    /// Modifier state bits derived from the most recent key event's
    /// modifierFlags. Persisted between events so ButtonPress/Release
    /// carry the right modifier bits even though they don't carry their
    /// own modifier info from the bridge.
    private var currentModifierState: UInt16 = 0

    public private(set) var setupAcceptedSent: Bool = false
    public private(set) var requestsProcessed: Int = 0
    public private(set) var unknownOpcodes: [UInt8] = []
    public private(set) var errorsEmitted: Int = 0

    public weak var log: ServerLogSink?

    public init(
        config: ServerConfig = .default,
        bridge: WindowBridge? = nil,
        outbound: OutboundQueue = OutboundQueue(),
        coordinator: ServerCoordinator = ServerCoordinator(),
        clipboardPrefs: ClipboardPreferencesProvider = StaticClipboardPreferencesProvider(),
        log: ServerLogSink? = nil
    ) {
        self.config = config
        self.bridge = bridge
        self.outbound = outbound
        self.coordinator = coordinator
        self.clipboardPrefs = clipboardPrefs
        self.log = log
        // Pixmaps allocate at the bridge's logical-to-device scale so
        // window↔pixmap CopyArea is pixel-lossless (Motif caret save-under
        // would otherwise erode glyph AA edges every blink — see
        // PixelBuffer.scaleFactor for the full rationale).
        self.pixmaps = PixmapTable(scaleFactor: bridge?.scaleFactor ?? 1)
        self.selectionMediator = SelectionMediator(
            atoms: coordinator.atoms,
            coordinator: coordinator,
            properties: properties,
            windows: windows,
            config: config
        )
        // Serial, target = global userInitiated. Identifier carries the
        // resource-id base so multi-client logs can tell sessions apart.
        self.protocolQueue = DispatchQueue(
            label: "swiftx.session.protocol.\(String(config.resourceIdBase, radix: 16))",
            qos: .userInitiated,
            target: DispatchQueue.global(qos: .userInitiated)
        )
        // Hand the bridge a closure that resolves pixmap ids to PixelBuffers
        // from THIS session's PixmapTable. withDrawContext(.pixmap) uses
        // this to find the CGBitmapContext for pixmap-targeted draws. See
        // setPixmapBufferLookup doc in WindowBridge.swift for the
        // multi-session caveat (most-recently-set lookup wins).
        bridge?.setPixmapBufferLookup { [weak self] id in self?.pixmaps.buffer(for: id) }
        // Hand the bridge a closure that resolves window ids to their
        // current clipList rects (visible region in top-level coords).
        // withDrawContext for window targets uses this to set CGContext.clip
        // to the composite clip = window clipList ∩ GC user clip. Spec
        // ref: mi/migc.c:miComputeCompositeClip. Without this the parent's
        // bg paint bleeds through descendant windows — the dthelpview
        // 2026-05-19 "leftover blue rectangles on expand" bug.
        bridge?.setWindowClipLookup { [weak self] id -> [Framer.Rectangle] in
            guard let self = self, let entry = self.windows.get(id) else { return [] }
            return entry.clipList.rects.map { box in
                Framer.Rectangle(
                    x: Int16(clamping: box.x1),
                    y: Int16(clamping: box.y1),
                    width: UInt16(clamping: box.x2 - box.x1),
                    height: UInt16(clamping: box.y2 - box.y1)
                )
            }
        }
        // All AppKit-side callbacks hop onto protocolQueue, run the handler,
        // and flush any bytes the handler appended to outbound. Since
        // protocolQueue is the only writer, no lock is needed at the socket.
        let queue = self.protocolQueue
        let token = self.bridgeHandlerToken
        bridge?.setOnTopLevelResize(token: token) { [weak self] id, width, height in
            queue.async {
                self?.handleTopLevelResize(id: id, width: width, height: height)
                self?.flushOutbound()
            }
        }
        bridge?.setOnTopLevelMove(token: token) { [weak self] id, x, y in
            queue.async {
                self?.handleTopLevelMove(id: id, x: x, y: y)
                self?.flushOutbound()
            }
        }
        bridge?.setOnKey(token: token) { [weak self] topLevel, macKeyCode, modifierFlags, isDown in
            queue.async {
                self?.handleKeyEvent(
                    topLevel: topLevel, macKeyCode: macKeyCode,
                    modifierFlags: modifierFlags, isDown: isDown
                )
                self?.flushOutbound()
            }
        }
        bridge?.setOnFocus(token: token) { [weak self] topLevel, gained in
            queue.async {
                self?.handleFocusChange(topLevel: topLevel, gained: gained)
                self?.flushOutbound()
            }
        }
        bridge?.setOnMouse(token: token) { [weak self] topLevel, x, y, button, isDown in
            queue.async {
                self?.handleMouseEvent(
                    topLevel: topLevel, x: x, y: y, button: button, isDown: isDown
                )
                self?.flushOutbound()
            }
        }
        bridge?.setOnMouseDragged(token: token) { [weak self] topLevel, x, y, button in
            queue.async {
                self?.handleMouseDragged(topLevel: topLevel, x: x, y: y, button: button)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPointerMoved(token: token) { [weak self] topLevel, x, y in
            queue.async {
                self?.handlePointerMoved(topLevel: topLevel, x: x, y: y)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPointerEnteredView(token: token) { [weak self] topLevel, x, y in
            queue.async {
                self?.handlePointerEnteredView(topLevel: topLevel, x: x, y: y)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPointerExitedView(token: token) { [weak self] topLevel in
            queue.async {
                self?.handlePointerExitedView(topLevel: topLevel)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPaste(token: token) { [weak self] topLevel, text in
            queue.async {
                self?.handlePaste(topLevel: topLevel, text: text)
                self?.flushOutbound()
            }
        }
        bridge?.setOnCopy(token: token) { [weak self] topLevel in
            queue.async {
                self?.handleCopy(topLevel: topLevel)
                self?.flushOutbound()
            }
        }
        bridge?.setOnCloseRequest(token: token) { [weak self] topLevel in
            queue.async {
                self?.handleCloseRequest(topLevel: topLevel)
                self?.flushOutbound()
            }
        }

        // Pre-set _MOTIF_DRAG_WINDOW on the root window. Sun-era Motif on
        // SS2 reads this property during XmDisplay init; if it returns
        // None, Motif tries to BECOME the drag-coordinator itself and the
        // older code path SIGSEGVs (verified 2026-05-09 — quickplot
        // crashes right after our reply to GetProperty(_MOTIF_DRAG_WINDOW)
        // when no value exists). On a real Sun X server, some other Motif
        // app already created a drag-coordinator window and set this
        // property; subsequent apps just read it. Pretending the root
        // window is the coordinator is enough to dodge the crash —
        // Motif will then read _MOTIF_DRAG_ATOM_PAIRS from the root
        // (we return None / empty, which it handles gracefully) and
        // proceed without trying to become coordinator itself.
        let dragWindowAtom = atoms.intern("_MOTIF_DRAG_WINDOW")
        let xaWindowAtom: UInt32 = 33   // predefined XA_WINDOW
        let rootBytes: [UInt8] = {
            let id = config.rootWindowId
            // _MOTIF_DRAG_WINDOW is format=32 (one WINDOW), msbFirst on Sun
            // and lsbFirst on Linux. Use msbFirst here since we mostly
            // serve Sun clients; this is a property — Motif endian-decodes
            // based on its own byteOrder against the property byte order
            // (which is always image-byte-order — same as the server's).
            // Setup tells Sun the server is msbFirst (it's the client
            // byteOrder we mirror), so Motif reads MSB-first. Match.
            return [
                UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF),
                UInt8((id >> 8) & 0xFF),  UInt8(id & 0xFF)
            ]
        }()
        properties.change(
            window: config.rootWindowId,
            property: dragWindowAtom,
            type: xaWindowAtom,
            format: 32,
            mode: 0,             // PropModeReplace
            value: rootBytes
        )

        // Advertise a Motif window manager via _MOTIF_WM_INFO on root.
        // libXm calls XmIsMotifWMRunning during shell init, which reads this
        // property and then verifies that its wmWindow field is a child of
        // root. CDE dt apps (dtcalc/dtterm/etc.) gate code paths on the
        // result. The X spec says apps should still work without an MWM, but
        // in practice older CDE Motif apps render-blank when no MWM is
        // advertised. Format per OpenMotif MwmUtil.h: two CARD32s
        // {flags, wmWindow}; type atom = _MOTIF_WM_INFO itself.
        //
        // We register a server-internal stub window as a real child of root
        // so the XmIsMotifWMRunning child-of-root check passes. The window
        // is InputOnly + unmapped — it never appears on screen, it just
        // exists for property/QueryTree purposes.
        let mwmStubWindow: UInt32 = 0xFFFE_0002
        windows.insert(WindowEntry(
            id: mwmStubWindow,
            parent: config.rootWindowId,
            depth: 0,
            x: -1, y: -1, width: 1, height: 1,
            borderWidth: 0,
            windowClass: .inputOnly,
            visual: 0,
            valueMask: 0,
            valueList: [],
            mapped: false,
            eventMask: 0
        ))
        let motifWmInfoAtom = atoms.intern("_MOTIF_WM_INFO")
        let mwmInfoBytes: [UInt8] = {
            // MWM_INFO_STARTUP_STANDARD = 1
            let flags: UInt32 = 1
            let wmWin: UInt32 = mwmStubWindow
            var b: [UInt8] = []
            b.append(UInt8((flags >> 24) & 0xFF))
            b.append(UInt8((flags >> 16) & 0xFF))
            b.append(UInt8((flags >> 8)  & 0xFF))
            b.append(UInt8( flags        & 0xFF))
            b.append(UInt8((wmWin >> 24) & 0xFF))
            b.append(UInt8((wmWin >> 16) & 0xFF))
            b.append(UInt8((wmWin >> 8)  & 0xFF))
            b.append(UInt8( wmWin        & 0xFF))
            return b
        }()
        properties.change(
            window: config.rootWindowId,
            property: motifWmInfoAtom,
            type: motifWmInfoAtom,   // type is the same atom by convention
            format: 32,
            mode: 0,
            value: mwmInfoBytes
        )

        // RESOURCE_MANAGER on root, populated with our Tier 1 Motif
        // widget-class defaults (Helvetica via FontResolver's substitution
        // table). See MOTIF_TEXT_QUALITY.md → "The control surface:
        // RESOURCE_MANAGER" for why we publish this and what's in it.
        //
        // This replaces the 2026-05-18-retired CDE-flavored fixture.
        // That was about impersonating CDE; this is about steering Motif
        // to request XLFDs that map cleanly to Mac fonts through our
        // resolver. Different purpose, smaller content (~250 bytes vs
        // 3910 bytes), no CDE-specific resources.
        let resourceManagerAtom: UInt32 = 23   // predefined RESOURCE_MANAGER
        let stringAtom: UInt32 = 31            // predefined STRING
        properties.change(
            window: config.rootWindowId,
            property: resourceManagerAtom,
            type: stringAtom,
            format: 8,
            mode: 0,
            value: DefaultMotifResources.bytes
        )
    }

    /// User asked to close one of our NSWindows (red traffic-light button,
    /// Window > Close, or ⌘W). Send the X client a polite ICCCM
    /// WM_DELETE_WINDOW message — well-behaved clients (xterm, xcalc,
    /// xclock, xeyes, every Athena/Motif app of the era) treat that as
    /// "shut down cleanly". The NSWindow is closed by AppKit independently
    /// so the user sees the window vanish immediately; the client process
    /// follows on its own a moment later.
    public func handleCloseRequest(topLevel: UInt32) {
        guard let order = byteOrder else { return }
        guard windows.get(topLevel) != nil else { return }    // not our window
        let wmProtocols = atoms.intern("WM_PROTOCOLS")
        let wmDeleteWindow = atoms.intern("WM_DELETE_WINDOW")
        // ClientMessage data field is exactly 20 bytes. For a 32-bit format
        // ICCCM message we encode 5 UInt32s in connection byte order:
        // [protocol-atom, time, 0, 0, 0]. CurrentTime (0) is fine here —
        // ICCCM doesn't require a real timestamp on this message.
        var w = ByteWriter(byteOrder: order)
        w.writeUInt32(wmDeleteWindow)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0)
        let event = ClientMessageEvent(
            sequenceNumber: sequenceNumber,
            format: .format32,
            window: topLevel,
            type: wmProtocols,
            data: w.bytes
        )
        log?.log("  → ClientMessage(WM_PROTOCOLS, WM_DELETE_WINDOW) target=0x\(String(topLevel, radix: 16))")
        outbound.append(event.encode(byteOrder: order))
    }

    /// User pressed Cmd-C / chose Edit > Copy in the focused X window. If
    /// clipboard mirroring is enabled in prefs, look up the current PRIMARY
    /// selection owner and ask it to convert the selection to STRING into
    /// our `selectionSinkWindow`. The reply lands as a ChangeProperty on
    /// that window which we intercept and push to NSPasteboard.
    public func handleCopy(topLevel: UInt32) {
        let prefs = clipboardPrefs.current
        guard prefs.enabled else {
            log?.log("copy: clipboard mirroring disabled in prefs")
            return
        }
        // PRIMARY (atom 1) is xterm's default. We always pull from PRIMARY
        // regardless of mode — Mac mode just means "wait for Cmd-C", not
        // "use a different selection".
        requestSelectionConversion(selectionAtom: 1)
    }

    /// Emit a SelectionRequest event to the current owner of `selectionAtom`,
    /// asking for STRING into `selectionSinkPropertyName` on
    /// `selectionSinkWindow`. No-op if the selection is unowned.
    private func requestSelectionConversion(selectionAtom: UInt32) {
        guard let order = byteOrder else { return }
        guard let state = coordinator.selectionOwner(selectionAtom) else {
            log?.log("copy: no owner of selection atom=\(selectionAtom) — nothing to copy")
            return
        }
        let propertyAtom = atoms.intern(selectionSinkPropertyName)
        let stringAtom: UInt32 = 31      // predefined STRING
        let event = SelectionRequestEvent(
            sequenceNumber: sequenceNumber,
            time: state.time,
            owner: state.window,
            requestor: selectionSinkWindow,
            selection: selectionAtom,
            target: stringAtom,
            property: propertyAtom
        )
        log?.log("  → SelectionRequest owner=0x\(String(state.window, radix: 16)) sel=\(selectionAtom) target=STRING prop=\(propertyAtom)")
        outbound.append(event.encode(byteOrder: order))
    }

    /// Inject the pasteboard text as if typed: emit a KeyPress / KeyRelease
    /// pair per character, with Shift state set when needed. Characters
    /// without a US-ASCII keymap entry are skipped (better than blasting
    /// random KeyPress events at the client). Pasted "\r\n" or "\n" both
    /// resolve to Return.
    public func handlePaste(topLevel: UInt32, text: String) {
        guard let order = byteOrder else { return }
        guard let target = keyTarget(topLevel: topLevel, eventMaskBit: 1 << 0) else {
            log?.log("paste: no KeyPress target under 0x\(String(topLevel, radix: 16))")
            return
        }
        log?.log("  paste \(text.count) chars → target=0x\(String(target, radix: 16))")
        let shiftMask: UInt16 = 1 << 0
        for ch in text {
            // Treat "\r\n" cleanly — a CR in the pasteboard becomes Return,
            // skipping a redundant LF if it follows. We just let both map
            // to Return separately; the X client will get one Return per
            // line break either way (most line-oriented clients tolerate
            // back-to-back Returns).
            guard let entry = USKeymap.macKeyCode(forCharacter: ch) else { continue }
            let xKey = USKeymap.xKeycode(forMacKeyCode: entry.mac)
            let state: UInt16 = entry.shift ? shiftMask : 0
            let pressTime = serverTime
            let press = InputEvent(
                detail: xKey, sequenceNumber: sequenceNumber,
                time: pressTime, root: config.rootWindowId,
                event: target, child: 0,
                rootX: 0, rootY: 0, eventX: 0, eventY: 0,
                state: state, sameScreen: true
            )
            outbound.append(press.encode(code: 2, byteOrder: order))
            let release = InputEvent(
                detail: xKey, sequenceNumber: sequenceNumber,
                time: serverTime, root: config.rootWindowId,
                event: target, child: 0,
                rootX: 0, rootY: 0, eventX: 0, eventY: 0,
                state: state, sameScreen: true
            )
            outbound.append(release.encode(code: 3, byteOrder: order))
        }
    }

    /// Called by the bridge from main thread when an NSWindow becomes key
    /// (gained=true) or resigns key (gained=false). Emits FocusIn / FocusOut
    /// to the X client. xterm uses the FocusIn to switch from a hollow
    /// outline cursor to a filled cursor (charproc.c:2606 / 2653).
    /// detail=NotifyNonlinear and mode=NotifyNormal match what real Xsun
    /// emits in our captured xterm trace when the WM grants focus.
    public func handleFocusChange(topLevel: UInt32, gained: Bool) {
        guard let order = byteOrder else { return }
        guard windows.get(topLevel) != nil else { return }
        let event = FocusEvent(
            detail: .nonlinear,
            sequenceNumber: sequenceNumber,
            event: topLevel,
            mode: .normal
        )
        let code: UInt8 = gained ? 9 : 10        // FocusIn / FocusOut
        log?.log("  → \(gained ? "FocusIn" : "FocusOut") target=0x\(String(topLevel, radix: 16)) detail=nonlinear mode=normal")
        outbound.append(event.encode(code: code, byteOrder: order))
    }

    /// Called by the bridge from main thread when a keyDown/keyUp NSEvent
    /// arrives. Resolves which X window in the top-level's subtree should
    /// receive the event (the deepest viewable window with KeyPressMask /
    /// KeyReleaseMask in its event mask), translates to X keycode + state,
    /// and queues a KeyPress / KeyRelease event.
    public func handleKeyEvent(
        topLevel: UInt32, macKeyCode: UInt8, modifierFlags: UInt, isDown: Bool
    ) {
        guard let order = byteOrder else { return }
        let mask: UInt32 = isDown ? (1 << 0) : (1 << 1)        // KeyPress / KeyRelease
        let xKeycode = USKeymap.xKeycode(forMacKeyCode: macKeyCode)
        let state = USKeymap.translateModifiers(modifierFlags)
        currentModifierState = state
        // Routing precedence (highest → lowest):
        //   1. Active keyboard grab with ownerEvents=false → grab window.
        //   2. Passive key grab matching this (keycode, modifiers) on the
        //      natural target's ancestor chain → grab window. Quickplot's
        //      accelerator keys (~5 GrabKey at startup) ride this path; if
        //      we route to focus instead, the accelerator action never
        //      fires.
        //   3. Explicit focus window (set via SetInputFocus) — Motif relies
        //      on this for XmText/XmTextField input. Without it, our keys
        //      go to whatever shallow descendant has KeyPressMask, which
        //      isn't necessarily the focused widget.
        //   4. keyTarget fallback (BFS for KeyPressMask in the subtree).
        let target: UInt32
        if let kg = keyboardGrab, !kg.ownerEvents {
            target = kg.window
        } else {
            // Compute the natural target first; passive-grab lookup walks
            // its ancestor chain.
            let natural: UInt32?
            if let focus = focusWindow, windows.get(focus) != nil {
                natural = focus
            } else {
                natural = keyTarget(topLevel: topLevel, eventMaskBit: mask)
            }
            if let n = natural,
               let grab = findActivatablePassiveKeyGrab(key: xKeycode, modifiers: state, naturalTarget: n) {
                target = grab.grabWindow
            } else if let n = natural {
                target = n
            } else {
                log?.log("  keyEvent: no target window with mask 0x\(String(mask, radix: 16)) under 0x\(String(topLevel, radix: 16))")
                return
            }
        }
        // X11 InputEvent shape covers KeyPress / KeyRelease / button / motion.
        // code: 2 = KeyPress, 3 = KeyRelease.
        let code: UInt8 = isDown ? 2 : 3
        let event = InputEvent(
            detail: xKeycode,
            sequenceNumber: sequenceNumber,
            time: serverTime,
            root: config.rootWindowId,
            event: target,
            child: 0,
            rootX: 0, rootY: 0, eventX: 0, eventY: 0,         // pointer position; not relevant for keys
            state: state,
            sameScreen: true
        )
        log?.log("  → \(isDown ? "KeyPress" : "KeyRelease") xKey=0x\(String(xKeycode, radix: 16)) target=0x\(String(target, radix: 16)) state=0x\(String(state, radix: 16))")
        outbound.append(event.encode(code: code, byteOrder: order))
    }

    /// Mask matching any motion-event interest: PointerMotionMask (1<<6),
    /// Button1..5MotionMask (1<<8..1<<12), and ButtonMotionMask (1<<13).
    /// xterm sets at least ButtonMotionMask so it can render a selection
    /// drag; passing the combined mask to mouseTarget routes the event to
    /// any window that opted in to any motion variant.
    private static let motionEventMask: UInt32 =
        (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13)

    /// Mouse moved while a button is held. Emits MotionNotify (code 6) to
    /// the deepest mapped descendant of the top-level whose event mask
    /// includes any motion bit. xterm needs this to keep updating the
    /// inverse-video selection highlight as the user drags through the
    /// terminal grid.
    public func handleMouseDragged(
        topLevel: UInt32, x: Int16, y: Int16, button: UInt8
    ) {
        guard let order = byteOrder else { return }
        guard windows.get(topLevel) != nil else { return }
        // Update last-known pointer position (used by QueryPointer reply)
        // and detect subwindow-boundary crossings during drag. X spec
        // says crossing events fire regardless of button state — without
        // this, menu items don't see EnterNotify when the user drags
        // through them and so they don't highlight (Athena SimpleMenu's
        // SmeBSB items use `<EnterWindow>: highlight()`).
        lastPointerTopLevel = topLevel
        lastPointerXY = (x, y)
        let (rx, ry) = rootCoords(topLevel: topLevel, localX: x, localY: y)
        let pointerWindow = deepestMappedWindow(topLevel: topLevel, x: x, y: y)
        let from = currentPointerWindow[topLevel]
        if from != pointerWindow {
            currentPointerWindow[topLevel] = pointerWindow
            emitCrossings(topLevel: topLevel, from: from, to: pointerWindow, rootX: rx, rootY: ry)
            refreshCursor(topLevel: topLevel)
        }
        // Motion under grab: redirect to grab window if grab eventMask has
        // PointerMotionMask (1<<6) or one of the ButtonNMotion bits.
        let resolved: (UInt32, Int16, Int16)?
        let motionBit16: UInt16 = UInt16(Self.motionEventMask & 0xFFFF)
        if let redirect = grabRedirect(topLevel: topLevel, eventMaskBit16: motionBit16) {
            resolved = redirect
        } else {
            resolved = mouseTarget(topLevel: topLevel, x: x, y: y, eventMaskBit: Self.motionEventMask)
        }
        guard let (target, tx, ty) = resolved else { return }
        // X state field encodes "modifier and button-down bitmask". Button N
        // contributes (1 << (7 + N)) — Button1=0x100, Button2=0x200, etc.
        let buttonStateBit: UInt16 = (button >= 1 && button <= 5) ? (UInt16(1) << (7 + button)) : 0
        let event = InputEvent(
            detail: 0,                                     // 0 = same-pixel; 1 = hint
            sequenceNumber: sequenceNumber,
            time: serverTime,
            root: config.rootWindowId,
            event: target, child: 0,
            rootX: rx, rootY: ry,
            eventX: x &- tx, eventY: y &- ty,
            state: currentModifierState | buttonStateBit,
            sameScreen: true
        )
        outbound.append(event.encode(code: 6, byteOrder: order))
    }

    /// Mouse-down/up at top-level-local logical coords (x, y). Resolves the
    /// deepest mapped descendant containing the click whose event mask has
    /// ButtonPressMask (1<<2) or ButtonReleaseMask (1<<3) set; falls back
    /// to the top-level. Emits ButtonPress (code 4) or ButtonRelease (code 5).
    public func handleMouseEvent(
        topLevel: UInt32, x: Int16, y: Int16, button: UInt8, isDown: Bool
    ) {
        guard let order = byteOrder else { return }
        let mask: UInt32 = isDown ? (1 << 2) : (1 << 3)
        let mask16: UInt16 = UInt16(mask)
        let (rx, ry) = rootCoords(topLevel: topLevel, localX: x, localY: y)
        // Update held-button bookkeeping first; resolve target second; then
        // (after delivery) install or tear down the implicit grab.
        if isDown { heldButtons.insert(button) } else { heldButtons.remove(button) }

        // Compute current modifier state up-front so passive-grab matching
        // can see it. This is the modifier portion only (low 8 bits); the
        // full state including button bits is built later for the event.
        let stateMods: UInt16 = currentModifierState

        let resolved: (UInt32, Int16, Int16)?
        if let redirect = grabRedirect(topLevel: topLevel, eventMaskBit16: mask16) {
            resolved = redirect
        } else if pointerGrab != nil {
            // Grab active with ownerEvents=true. ownerEvents=true means
            // "no redirect" — deliver to the natural target within the
            // grabbing client's window subtree. (Each session sees only
            // its own windows under `topLevel`, so the natural target is
            // by definition owned by this session's client.)
            resolved = mouseTarget(topLevel: topLevel, x: x, y: y, eventMaskBit: mask)
        } else if isDown,
                  let natural = mouseTarget(topLevel: topLevel, x: x, y: y, eventMaskBit: mask),
                  let grab = findActivatablePassiveGrab(
                      button: button, modifiers: stateMods, naturalTarget: natural.0
                  ) {
            // Passive button grab activates: per X spec, the matching button
            // press auto-installs an active pointer grab on the grab-window,
            // and the event is delivered to the grab-window (with eventX/eventY
            // re-computed relative to it). Without this, Motif/Xaw menu posts
            // never fire — XmCascadeButton + XawMenuButton both register
            // GrabButton(Btn1) on the menu title widget so a click anywhere
            // in its subtree posts the menu. Verified 2026-05-10 against
            // xfontsel font-menu (14 GrabButton calls during init); same
            // mechanism unblocks Motif menu posts in quickplot.
            pointerGrab = PointerGrab(
                window: grab.grabWindow,
                eventMask: grab.eventMask == 0 ? 0xFFFF : grab.eventMask,
                ownerEvents: grab.ownerEvents,
                cursor: 0
            )
            implicitGrab = true
            bridge?.startCrossWindowDragTracking()
            let (gx, gy) = absoluteOrigin(of: grab.grabWindow, topLevel: topLevel)
            resolved = (grab.grabWindow, gx, gy)
            log?.log("  passive grab activated: window=0x\(String(grab.grabWindow, radix: 16)) button=\(button) (natural target was 0x\(String(natural.0, radix: 16)))")
            // Per X spec § 11.4 + R6 dix/events.c:761 (ActivatePointerGrab),
            // a grab activation MUST emit a crossing-event chain with
            // mode=Grab from the current pointer window to the grab window.
            // Without this, Xt's menu state machine concludes "I'm not
            // actually grabbed" and dismisses the menu it just posted.
            emitCrossings(
                topLevel: topLevel,
                from: currentPointerWindow[topLevel],
                to: grab.grabWindow,
                rootX: rx, rootY: ry, mode: .grab
            )
        } else {
            resolved = mouseTarget(topLevel: topLevel, x: x, y: y, eventMaskBit: mask)
        }
        guard let (target, tx, ty) = resolved else {
            log?.log("  mouseEvent: no target window with mask 0x\(String(mask, radix: 16)) at (\(x),\(y))")
            return
        }
        let code: UInt8 = isDown ? 4 : 5
        // State bits per X spec: modifier keys + buttons held BEFORE this
        // event. For a press, the new button is NOT in state (0 buttons
        // before press). For a release, the released button IS in state
        // (it was held before the release). Button N occupies bit (7+N).
        var state: UInt16 = currentModifierState
        // heldButtons was just updated; for press, exclude the just-pressed
        // button (state should reflect "before"); for release, include the
        // about-to-release button.
        let buttonStateMask: UInt16 = {
            var m: UInt16 = 0
            if isDown {
                for b in heldButtons where b != button {
                    if b >= 1 && b <= 5 { m |= UInt16(1) << (7 + b) }
                }
            } else {
                // heldButtons no longer contains the just-released button;
                // re-add it because state reflects the moment BEFORE release.
                for b in heldButtons.union([button]) {
                    if b >= 1 && b <= 5 { m |= UInt16(1) << (7 + b) }
                }
            }
            return m
        }()
        state |= buttonStateMask
        let event = InputEvent(
            detail: button,
            sequenceNumber: sequenceNumber,
            time: serverTime,
            root: config.rootWindowId,
            event: target, child: 0,
            rootX: rx, rootY: ry,
            eventX: x &- tx, eventY: y &- ty,
            state: state,
            sameScreen: true
        )
        log?.log("  → \(isDown ? "ButtonPress" : "ButtonRelease") button=\(button) target=0x\(String(target, radix: 16)) at top=(\(x),\(y)) root=(\(rx),\(ry)) local=(\(x &- tx),\(y &- ty)) state=0x\(String(state, radix: 16))")
        outbound.append(event.encode(code: code, byteOrder: order))

        // X11 implicit pointer grab. On the first ButtonPress with no other
        // grab active, install a synthetic grab on the press's target so
        // subsequent motion + the matching release route to the same
        // window. Without this, Motif (and most Xt-based) widgets register
        // ButtonPressMask but not ButtonReleaseMask — releases fall up to
        // the top-level via mouseTarget's mask filter, the click never
        // resolves as a Press+Release pair on one widget, and input is
        // dead. Spec section 9.5 / Xlib programming reference.
        if isDown && heldButtons.count == 1 && pointerGrab == nil {
            pointerGrab = PointerGrab(
                window: target,
                eventMask: 0xFFFF,    // permissive — deliver all pointer events while grabbed
                ownerEvents: false,
                cursor: 0
            )
            implicitGrab = true
            bridge?.startCrossWindowDragTracking()
            // Crossing chain on implicit grab (mode=Grab). Per R6
            // dix/events.c:1194 ActivateGrab calls DoEnterLeaveEvents
            // even for implicit grabs.
            emitCrossings(
                topLevel: topLevel,
                from: currentPointerWindow[topLevel],
                to: target,
                rootX: rx, rootY: ry, mode: .grab
            )
        }
        // End the implicit grab when all buttons are released. Client-issued
        // grabs (implicitGrab=false) are NOT auto-cleared; only UngrabPointer
        // ends those.
        if !isDown && heldButtons.isEmpty && implicitGrab {
            let grabWin = pointerGrab?.window
            pointerGrab = nil
            implicitGrab = false
            bridge?.stopCrossWindowDragTracking()
            // Crossing chain on grab release (mode=Ungrab). Per R6
            // dix/events.c:793 DeactivatePointerGrab.
            if let grabWin = grabWin {
                emitCrossings(
                    topLevel: topLevel,
                    from: grabWin,
                    to: currentPointerWindow[topLevel],
                    rootX: rx, rootY: ry, mode: .ungrab
                )
            }
        }
    }

    /// Pointer moved with no button held. Resolve the deepest mapped
    /// descendant containing the pointer (regardless of event mask — we
    /// want the actual position-window, not the nearest-subscribed-window),
    /// compare to the previously-tracked pointer window for this top-level,
    /// and emit the EnterNotify / LeaveNotify chain if it changed.
    public func handlePointerMoved(topLevel: UInt32, x: Int16, y: Int16) {
        guard let order = byteOrder else { return }
        guard windows.get(topLevel) != nil else { return }
        lastPointerTopLevel = topLevel
        lastPointerXY = (x, y)
        let (rx, ry) = rootCoords(topLevel: topLevel, localX: x, localY: y)
        let target = deepestMappedWindow(topLevel: topLevel, x: x, y: y)
        let from = currentPointerWindow[topLevel]
        if from != target {
            currentPointerWindow[topLevel] = target
            emitCrossings(topLevel: topLevel, from: from, to: target, rootX: rx, rootY: ry)
            refreshCursor(topLevel: topLevel)
        }
        // Per X spec, MotionNotify fires on every pointer movement (subject
        // to mask), not only on subwindow change. Walk from `target` up to
        // top-level looking for the first ancestor with PointerMotionMask
        // set; if found, deliver there. Without this, Motif clients (e.g.
        // quickplot from SS2) don't see hover motion and their translation
        // engine never knows the pointer is over a widget when ButtonPress
        // arrives. Verified 2026-05-09 against gold (Sun→Sun) capture which
        // shows MotionNotify with state=0x0 (no button held) preceding
        // every ButtonPress.
        let pointerMotionMask: UInt32 = 1 << 6
        var motionTarget: UInt32?
        var cur: UInt32? = target
        while let id = cur {
            if let w = windows.get(id), w.eventMask & pointerMotionMask != 0 {
                motionTarget = id
                break
            }
            if id == topLevel { break }
            cur = windows.get(id)?.parent
        }
        guard let mTarget = motionTarget else { return }
        let (tx, ty) = absoluteOrigin(of: mTarget, topLevel: topLevel)
        let event = InputEvent(
            detail: 0,                                  // 0 = no button (hover); 1 = hint
            sequenceNumber: sequenceNumber,
            time: serverTime,
            root: config.rootWindowId,
            event: mTarget, child: 0,
            rootX: rx, rootY: ry,
            eventX: x &- tx, eventY: y &- ty,
            state: currentModifierState,
            sameScreen: true
        )
        outbound.append(event.encode(code: 6, byteOrder: order))   // 6 = MotionNotify
    }

    /// Pointer entered the NSView's content area (came from outside our X
    /// subtree — another macOS window, off-screen, etc.). Treated as a
    /// Nonlinear crossing: the synthetic "from" is no X window at all, so
    /// we only emit the EnterNotify chain.
    public func handlePointerEnteredView(topLevel: UInt32, x: Int16, y: Int16) {
        guard byteOrder != nil else { return }
        guard windows.get(topLevel) != nil else { return }
        // Idempotency: AppKit's tracking-area mouseEntered and the cross-
        // window drag tracker's transition logic can both fire firePointer-
        // EnteredView for the same cursor crossing. The duplicate Enter
        // looks to Motif's submenu state machine like "user left and re-
        // entered the submenu" — exactly the signal it uses to decide
        // "dismiss this submenu." If currentPointerWindow[topLevel] is
        // already set, the X tree already knows the pointer is in this
        // NSView; subsequent motion is handled by handleMouseDragged /
        // handlePointerMoved which emit Leave/Enter for X-child transitions.
        // No-op here to avoid emitting a spurious second Enter.
        if currentPointerWindow[topLevel] != nil { return }
        let (rx, ry) = rootCoords(topLevel: topLevel, localX: x, localY: y)
        let target = deepestMappedWindow(topLevel: topLevel, x: x, y: y)
        currentPointerWindow[topLevel] = target
        emitCrossings(topLevel: topLevel, from: nil, to: target, rootX: rx, rootY: ry)
        refreshCursor(topLevel: topLevel)
    }

    /// Pointer left the NSView's content area. Emit LeaveNotify chain for
    /// whichever X window the pointer was last in, then clear the tracker.
    ///
    /// rootX/rootY use the LAST KNOWN pointer position (lastPointerXY +
    /// rootCoords). Pre-2026-05-21 we hardcoded (0, 0) here — that gave
    /// Motif's submenu-tracking the impression that the cursor had moved
    /// to root (0, 0), which it reads as "cursor left the menu hierarchy"
    /// and the submenu dismisses (verified with quickplot File → Log File).
    /// The last-known position isn't perfect — by definition the cursor
    /// has moved by the time the exit fires — but it's typically within
    /// a few pixels of the boundary, close enough for Motif's
    /// "is-cursor-in-this-rect" tests.
    public func handlePointerExitedView(topLevel: UInt32) {
        guard byteOrder != nil else { return }
        guard let from = currentPointerWindow[topLevel] else { return }
        currentPointerWindow[topLevel] = nil
        let (lx, ly) = lastPointerXY ?? (0, 0)
        let referenceTL = lastPointerTopLevel ?? topLevel
        let (rx, ry) = rootCoords(topLevel: referenceTL, localX: lx, localY: ly)
        emitCrossings(topLevel: topLevel, from: from, to: nil, rootX: rx, rootY: ry)
    }

    /// Walk the mapped X subtree under `topLevel` and return the deepest
    /// window whose absolute rect contains `(x, y)`. Falls back to the
    /// top-level itself. Distinct from `mouseTarget` (which filters by
    /// event-mask interest) — for crossing events we need the actual
    /// containing window so we know when to fire the chain.
    private func deepestMappedWindow(topLevel: UInt32, x: Int16, y: Int16) -> UInt32 {
        var deepestId: UInt32 = topLevel
        var deepestDepth = 0
        func walk(id: UInt32, ox: Int16, oy: Int16, depth: Int) {
            for (cid, w) in windows.windows where w.parent == id && w.mapped {
                let cx = ox &+ w.x
                let cy = oy &+ w.y
                let inside = x >= cx && y >= cy
                              && x < cx &+ Int16(w.width)
                              && y < cy &+ Int16(w.height)
                guard inside else { continue }
                if depth + 1 > deepestDepth {
                    deepestId = cid
                    deepestDepth = depth + 1
                }
                walk(id: cid, ox: cx, oy: cy, depth: depth + 1)
            }
        }
        walk(id: topLevel, ox: 0, oy: 0, depth: 0)
        return deepestId
    }

    /// Emit the EnterNotify / LeaveNotify chain for a pointer crossing
    /// from `from` to `to` (either side may be nil if the pointer was
    /// outside the X subtree). Implements the X11 spec algorithm for the
    /// detail field:
    ///
    ///   - `from` is ancestor of `to` → Leave on from with detail=Inferior;
    ///     Enter on intermediate windows with detail=Virtual; Enter on to
    ///     with detail=Ancestor.
    ///   - `to` is ancestor of `from` → Leave on from with detail=Ancestor;
    ///     Leave on intermediate windows with detail=Virtual; Enter on to
    ///     with detail=Inferior.
    ///   - Otherwise (Nonlinear) → Leave on from with detail=Nonlinear;
    ///     Leave on the from→LCA path with detail=NonlinearVirtual; Enter
    ///     on the LCA→to path with detail=NonlinearVirtual; Enter on to
    ///     with detail=Nonlinear.
    ///   - `from` nil → emit only the Enter chain (Nonlinear / NonlinearVirtual).
    ///   - `to` nil → emit only the Leave chain (Nonlinear / NonlinearVirtual).
    ///
    /// Each event is delivered only if the recipient window's eventMask
    /// has EnterWindowMask (1<<4) for Enter, LeaveWindowMask (1<<5) for
    /// Leave.
    private func emitCrossings(topLevel: UInt32, from: UInt32?, to: UInt32?, rootX: Int16, rootY: Int16, mode: CrossingMode = .normal) {
        guard let order = byteOrder else { return }
        let fromPath = from.map(ancestorPathToTopLevel) ?? []
        let toPath = to.map(ancestorPathToTopLevel) ?? []
        // ancestorPathToTopLevel returns leaf-first list (leaf, parent, ..., topLevel).

        // Find LCA: highest window appearing in both paths.
        let toSet = Set(toPath)
        let lca = fromPath.first(where: { toSet.contains($0) })

        // Classify the relationship.
        let fromIsAncestorOfTo = (from != nil && to != nil) && toPath.contains(from!) && from != to
        let toIsAncestorOfFrom = (from != nil && to != nil) && fromPath.contains(to!) && from != to

        // Build leave list (leaf-first) and enter list (root-first toward leaf).
        var leaves: [(UInt32, CrossingDetail)] = []
        var enters: [(UInt32, CrossingDetail)] = []

        if let from = from, let to = to, from == to { return }

        if let from = from {
            if fromIsAncestorOfTo {
                // Leaving an ancestor; "to" is below "from".
                leaves.append((from, .inferior))
            } else if toIsAncestorOfFrom {
                // Leaving a descendant; "to" is an ancestor.
                leaves.append((from, .ancestor))
                // Walk from's ancestors up to (but not including) to: Leave detail=Virtual.
                for w in fromPath.dropFirst() {
                    if w == to { break }
                    leaves.append((w, .virtual))
                }
            } else {
                // Nonlinear (or to is nil → treat as Nonlinear).
                leaves.append((from, .nonlinear))
                if let lca = lca {
                    for w in fromPath.dropFirst() {
                        if w == lca { break }
                        leaves.append((w, .nonlinearVirtual))
                    }
                } else {
                    // No LCA (to is nil or unrelated tree): walk up to root of fromPath.
                    for w in fromPath.dropFirst() {
                        leaves.append((w, .nonlinearVirtual))
                    }
                }
            }
        }

        if let to = to {
            if fromIsAncestorOfTo, let from = from {
                // Walk from down to to (exclusive of from, exclusive of to): Enter Virtual.
                // toPath is leaf-first, so reverse-iterate from `from`'s child down to to's parent.
                let virtualWindows = toPath.prefix(while: { $0 != from }).dropFirst()
                for w in virtualWindows.reversed() {
                    enters.append((w, .virtual))
                }
                enters.append((to, .ancestor))
            } else if toIsAncestorOfFrom {
                enters.append((to, .inferior))
            } else {
                // Nonlinear (or from is nil → treat as Nonlinear).
                let lcaForChain: UInt32? = lca
                if let lca = lcaForChain {
                    let virtualWindows = toPath.prefix(while: { $0 != lca }).dropFirst()
                    for w in virtualWindows.reversed() {
                        enters.append((w, .nonlinearVirtual))
                    }
                } else {
                    // No LCA: from is nil (entered from outside) — walk full toPath
                    // ancestors above the leaf.
                    for w in toPath.dropFirst().reversed() {
                        enters.append((w, .nonlinearVirtual))
                    }
                }
                enters.append((to, .nonlinear))
            }
        }

        // Emit. Code 7 = EnterNotify, 8 = LeaveNotify.
        let enterMask: UInt32 = 1 << 4
        let leaveMask: UInt32 = 1 << 5

        // Read serverTime once per crossing pass so paired Leave/Enter
        // events share a timestamp, matching what a real X server does
        // when the pointer crosses a boundary atomically.
        let crossingTime = serverTime

        // rootX/rootY are already in X-root coords (the caller translated
        // via rootCoords). To compute eventX/eventY (target-local), subtract
        // the target window's root origin: (top-level root origin) +
        // (target's offset within top-level).
        let topRootX: Int16 = windows.get(topLevel)?.x ?? 0
        let topRootY: Int16 = windows.get(topLevel)?.y ?? 0

        // X11 spec: the `state` field on EnterNotify/LeaveNotify carries
        // the modifier+button mask AT THE TIME of the crossing — same as
        // MotionNotify. We were hard-coding 0, which Motif's submenu state
        // machine reads as "button released between motions" when the user
        // is mid-drag (Button1 held), and dismisses the submenu. Build
        // state from currentModifierState + the heldButtons set, matching
        // handleMouseDragged.
        var crossingState: UInt16 = currentModifierState
        for b in heldButtons where b >= 1 && b <= 5 {
            crossingState |= UInt16(1) << (7 + b)
        }

        for (window, detail) in leaves {
            guard let entry = windows.get(window), entry.eventMask & leaveMask != 0 else { continue }
            let (tlX, tlY) = absoluteOrigin(of: window, topLevel: topLevel)
            let event = CrossingEvent(
                detail: detail,
                sequenceNumber: sequenceNumber,
                time: crossingTime,
                root: config.rootWindowId,
                event: window, child: 0,
                rootX: rootX, rootY: rootY,
                eventX: rootX &- topRootX &- tlX, eventY: rootY &- topRootY &- tlY,
                state: crossingState, mode: mode,
                sameScreen: true, focus: false
            )
            log?.log("  → LeaveNotify target=0x\(String(window, radix: 16)) detail=\(detail) at root=(\(rootX),\(rootY))")
            outbound.append(event.encode(code: 8, byteOrder: order))
        }

        for (window, detail) in enters {
            guard let entry = windows.get(window), entry.eventMask & enterMask != 0 else { continue }
            let (tlX, tlY) = absoluteOrigin(of: window, topLevel: topLevel)
            let event = CrossingEvent(
                detail: detail,
                sequenceNumber: sequenceNumber,
                time: crossingTime,
                root: config.rootWindowId,
                event: window, child: 0,
                rootX: rootX, rootY: rootY,
                eventX: rootX &- topRootX &- tlX, eventY: rootY &- topRootY &- tlY,
                state: crossingState, mode: mode,
                sameScreen: true, focus: false
            )
            log?.log("  → EnterNotify target=0x\(String(window, radix: 16)) detail=\(detail) at root=(\(rootX),\(rootY))")
            outbound.append(event.encode(code: 7, byteOrder: order))
        }
    }

    /// Walk up the parent chain from `window` until we find a window with
    /// a non-None cursor attribute, and return the cursor's source glyph.
    /// Returns nil if no window in the chain declares a cursor — bridge
    /// falls back to the default arrow.
    private func resolveCursorGlyph(for window: UInt32) -> UInt16? {
        var cur: UInt32? = window
        while let id = cur, let entry = windows.get(id) {
            if let cursorId = entry.cursor, let glyph = cursors.glyph(cursorId) {
                return glyph
            }
            if entry.parent == config.rootWindowId || entry.parent == 0 { break }
            cur = entry.parent
        }
        return nil
    }

    /// Find the top-level ancestor of `window` (or `window` itself if it's
    /// a top-level). Returns nil if the chain doesn't reach root.
    private func topLevelAncestor(of window: UInt32) -> UInt32? {
        var cur: UInt32? = window
        while let id = cur, let entry = windows.get(id) {
            if entry.parent == config.rootWindowId { return id }
            if entry.parent == 0 { return nil }
            cur = entry.parent
        }
        return nil
    }

    /// Push the effective cursor for `currentPointerWindow[topLevel]` to the
    /// bridge. Called whenever the pointer's containing window changes (in
    /// emitCrossings) and whenever a window's cursor attribute changes (in
    /// ChangeWindowAttributes).
    private func refreshCursor(topLevel: UInt32) {
        let glyph = currentPointerWindow[topLevel].flatMap(resolveCursorGlyph(for:))
        bridge?.setCursor(topLevel: topLevel, glyph: glyph)
    }

    /// If a ChangeWindowAttributes touched window `w`'s cursor and the
    /// pointer is currently in `w` or any descendant inheriting from it,
    /// the on-screen cursor needs refreshing without waiting for a move.
    /// Cheap conservative version: refresh if `w` is on the current
    /// pointer-window's ancestor chain. (False positives are harmless —
    /// re-pushing the same cursor is a no-op on the bridge side.)
    private func refreshCursorIfPointerAffected(by w: UInt32) {
        guard let topLevel = topLevelAncestor(of: w),
              let pointerWin = currentPointerWindow[topLevel] else { return }
        // Walk pointer-window's chain; if w is on it, the effective cursor
        // could have changed.
        var cur: UInt32? = pointerWin
        while let id = cur, let entry = windows.get(id) {
            if id == w {
                refreshCursor(topLevel: topLevel)
                return
            }
            if entry.parent == config.rootWindowId || entry.parent == 0 { break }
            cur = entry.parent
        }
    }

    /// Ancestor path from `window` (leaf-first) up to and including the
    /// top-level. Stops when reaching a window with no parent or one that
    /// isn't in the table.
    private func ancestorPathToTopLevel(_ window: UInt32) -> [UInt32] {
        var path: [UInt32] = []
        var cur: UInt32? = window
        while let id = cur, let entry = windows.get(id) {
            path.append(id)
            // parent==root means we've reached a top-level; stop here.
            if entry.parent == config.rootWindowId || entry.parent == 0 { break }
            cur = entry.parent
        }
        return path
    }

    /// Absolute (top-level-local) origin of a window by walking up parents.
    /// Returns (x, y) suitable for computing eventX/eventY = rootX - origin.
    /// Find a passive button grab that should activate for this press.
    /// Matches per X11 spec section 12.5 (PassiveButtonGrab):
    /// - grab.button matches the pressed button (or AnyButton = 0)
    /// - grab.modifiers matches the current modifier state (or AnyModifier = 0x8000)
    /// - grab.grabWindow is on the ancestor chain from the natural target up
    ///   to the top-level (so a click anywhere in the grab-window's subtree
    ///   activates the grab).
    /// Returns the matching grab, or nil if no match.
    /// X11 SubstructureNotifyMask bit per xproto X.h.
    static let substructureNotifyMask: UInt32 = 1 << 19

    /// X11 PropertyChangeMask bit per xproto X.h.
    static let propertyChangeMask: UInt32 = 1 << 22

    /// Emit PropertyNotify to a window if its event mask has
    /// PropertyChangeMask. Called from ChangeProperty (state=NewValue) and
    /// DeleteProperty (state=Deleted, only if the property existed). Per
    /// X11 spec section 10.10. Xt's PROPERTY_CHANGE_TIMESTAMP timestamp-
    /// probe path consumes these.
    private func emitPropertyNotify(window: UInt32, atom: UInt32, state: PropertyState, byteOrder: ByteOrder) {
        guard let entry = windows.get(window),
              entry.eventMask & Self.propertyChangeMask != 0 else { return }
        let event = PropertyNotifyEvent(
            sequenceNumber: sequenceNumber,
            window: window, atom: atom,
            time: serverTime, state: state
        )
        outbound.append(event.encode(byteOrder: byteOrder))
    }

    /// If `parent` is a known window (or root) with SubstructureNotifyMask
    /// set, build the notify event with `event = parent` and append it to
    /// outbound. Per X11 spec each Substructure event mirrors the
    /// corresponding Structure event on the affected window: client-relevant
    /// fields are identical, only the `event` field differs (window-itself
    /// vs parent). `build(eventTarget)` returns the encoded bytes for the
    /// event with the event field set to the given target. Root is handled
    /// specially because it has no WindowEntry; its event mask is tracked
    /// separately via `rootEventMask`.
    private func notifySubstructure(
        parent: UInt32,
        build: (UInt32) -> [UInt8]
    ) {
        let parentMask: UInt32
        if parent == config.rootWindowId {
            parentMask = rootEventMask
        } else if let parentEntry = windows.get(parent) {
            parentMask = parentEntry.eventMask
        } else {
            return
        }
        guard parentMask & Self.substructureNotifyMask != 0 else { return }
        outbound.append(build(parent))
    }

    /// Find a passive key grab matching the given (key, modifiers) on the
    /// path from naturalTarget up to root. Mirrors the button-grab match
    /// algorithm: AnyKey (0) and AnyModifier (0x8000) wildcards, modifier
    /// mask in low 8 bits. Used by handleKeyEvent to redirect KeyPress to
    /// the grab window for accelerator-style bindings (quickplot's
    /// XtPopupSpringLoaded / Motif accelerators).
    private func findActivatablePassiveKeyGrab(
        key: UInt8, modifiers: UInt16, naturalTarget: UInt32
    ) -> PassiveKeyGrab? {
        let activeMods = modifiers & 0xFF
        let anyKey: UInt8 = 0
        let anyModifier: UInt16 = 0x8000
        for grab in passiveKeyGrabs {
            guard grab.key == anyKey || grab.key == key else { continue }
            let modsMatch = grab.modifiers == anyModifier
                || (grab.modifiers & 0xFF) == activeMods
            guard modsMatch else { continue }
            var cur: UInt32? = naturalTarget
            var hops = 0
            while let id = cur, hops < 32 {
                if id == grab.grabWindow { return grab }
                cur = windows.get(id)?.parent
                hops += 1
            }
        }
        return nil
    }

    private func findActivatablePassiveGrab(
        button: UInt8, modifiers: UInt16, naturalTarget: UInt32
    ) -> PassiveButtonGrab? {
        let activeMods = modifiers & 0xFF      // bits 0..7 = real modifier mask
        let anyButton: UInt8 = 0               // 0 = AnyButton per X spec
        let anyModifier: UInt16 = 0x8000       // per X spec
        for grab in passiveButtonGrabs {
            // button match
            guard grab.button == anyButton || grab.button == button else { continue }
            // modifier match — exact, with AnyModifier wildcard
            let modsMatch = grab.modifiers == anyModifier
                || (grab.modifiers & 0xFF) == activeMods
            guard modsMatch else { continue }
            // grabWindow must be on the ancestor chain (or be) the natural target
            var cur: UInt32? = naturalTarget
            var found = false
            var hops = 0
            while let id = cur, hops < 32 {
                if id == grab.grabWindow { found = true; break }
                cur = windows.get(id)?.parent
                hops += 1
            }
            if found { return grab }
        }
        return nil
    }

    /// Destroy every descendant of `parent` (recursively). When
    /// `includeRoot` is true, also remove the parent itself. Used by
    /// DestroyWindow (with includeRoot=true) and DestroySubwindows
    /// (with includeRoot=false).
    private func destroySubtree(parentOf parent: UInt32, includeRoot: Bool) {
        // Collect IDs first so we don't mutate during iteration.
        var toRemove: [UInt32] = []
        func walk(_ p: UInt32) {
            for (id, w) in windows.windows where w.parent == p {
                walk(id)
                toRemove.append(id)
            }
        }
        walk(parent)
        // Unlink before removing so the sibling chain stays consistent
        // throughout (each unlink fixes up its own grandparent's chain;
        // by the time we finish, the parent's firstChild/lastChild are
        // correctly nil because all direct children went through unlink).
        for id in toRemove {
            SiblingChain.unlink(id, in: windows)
            windows.remove(id)
        }
        if includeRoot {
            SiblingChain.unlink(parent, in: windows)
            windows.remove(parent)
        }
    }

    private func absoluteOrigin(of window: UInt32, topLevel: UInt32) -> (Int16, Int16) {
        var x: Int16 = 0
        var y: Int16 = 0
        var cur: UInt32? = window
        while let id = cur, id != topLevel, let entry = windows.get(id) {
            x = x &+ entry.x
            y = y &+ entry.y
            cur = entry.parent
        }
        return (x, y)
    }

    /// Translate a top-level-local pointer coord (the bridge hands these to
    /// us in NSWindow-local space) to X-root coords by adding the top-level's
    /// own WindowEntry x/y (which the WM-emulation placement set on map).
    /// Used to fill `root_x` / `root_y` in pointer/crossing events and the
    /// QueryPointer reply — without this Motif/Xt menu-positioning math
    /// computes popup root coords as if the top-level were at (0, 0), and
    /// override-redirect menus land in the screen's upper-left corner
    /// regardless of where the user actually clicked.
    private func rootCoords(topLevel: UInt32, localX x: Int16, localY y: Int16) -> (Int16, Int16) {
        guard let entry = windows.get(topLevel) else { return (x, y) }
        return (entry.x &+ x, entry.y &+ y)
    }

    // MARK: - Grabs

    private func handleGrabPointer(_ r: GrabPointer, byteOrder: ByteOrder) {
        // We always succeed. Real X servers return AlreadyGrabbed when a
        // different client already holds the pointer grab. pointerGrab is
        // session-local and we don't currently coordinate across sessions
        // via the ServerCoordinator, so a cross-session AlreadyGrabbed is
        // a latent multi-client gap (no client we host today exercises
        // cross-session pointer grabs). NotViewable / Frozen aren't
        // produced because we don't enforce window-viewable preconditions.
        let alreadyGrabbed = (pointerGrab != nil)
        pointerGrab = PointerGrab(
            window: r.grabWindow,
            eventMask: r.eventMask,
            ownerEvents: r.ownerEvents,
            cursor: r.cursor
        )
        if !alreadyGrabbed { bridge?.startCrossWindowDragTracking() }
        log?.log("  GrabPointer window=0x\(String(r.grabWindow, radix: 16)) mask=0x\(String(r.eventMask, radix: 16)) ownerEvents=\(r.ownerEvents) cursor=0x\(String(r.cursor, radix: 16))")
        // Push the grab cursor immediately; restored on Ungrab via refreshCursor.
        if r.cursor != 0, let topLevel = topLevelAncestor(of: r.grabWindow) {
            bridge?.setCursor(topLevel: topLevel, glyph: cursors.glyph(r.cursor))
        }
        // Per X spec § 11.4 + R6 dix/events.c:761 (ActivatePointerGrab),
        // emit crossing chain with mode=Grab from current pointer window
        // to grab window. Xt/Motif rely on this to know "grab is on me."
        if let topLevel = topLevelAncestor(of: r.grabWindow) {
            let (px, py) = lastPointerXY ?? (0, 0)
            let (rx, ry) = rootCoords(topLevel: topLevel, localX: px, localY: py)
            emitCrossings(
                topLevel: topLevel,
                from: currentPointerWindow[topLevel],
                to: r.grabWindow,
                rootX: rx, rootY: ry, mode: .grab
            )
        }
        let reply = GrabReply(sequenceNumber: sequenceNumber, status: .success)
        outbound.append(reply.encode(byteOrder: byteOrder))
    }

    private func handleUngrabPointer() {
        guard let grab = pointerGrab else { return }
        pointerGrab = nil
        bridge?.stopCrossWindowDragTracking()
        log?.log("  UngrabPointer (was on 0x\(String(grab.window, radix: 16)))")
        // Restore cursor based on the window currently under the pointer.
        if grab.cursor != 0, let topLevel = topLevelAncestor(of: grab.window) {
            refreshCursor(topLevel: topLevel)
        }
        // Per X spec + R6 dix/events.c:793 (DeactivatePointerGrab), emit
        // crossing chain with mode=Ungrab from grab window back to the
        // current pointer window.
        if let topLevel = topLevelAncestor(of: grab.window) {
            let (px, py) = lastPointerXY ?? (0, 0)
            let (rx, ry) = rootCoords(topLevel: topLevel, localX: px, localY: py)
            emitCrossings(
                topLevel: topLevel,
                from: grab.window,
                to: currentPointerWindow[topLevel],
                rootX: rx, rootY: ry, mode: .ungrab
            )
        }
    }

    private func handleGrabKeyboard(_ r: GrabKeyboard, byteOrder: ByteOrder) {
        let oldFocus = focusWindow
        keyboardGrab = KeyboardGrab(window: r.grabWindow, ownerEvents: r.ownerEvents)
        log?.log("  GrabKeyboard window=0x\(String(r.grabWindow, radix: 16)) ownerEvents=\(r.ownerEvents)")
        // Per X spec + R6 dix/events.c:821 (ActivateKeyboardGrab), emit
        // FocusOut on old focus + FocusIn on grab window with mode=Grab.
        // Without these, Xt's keyboard-focus state machine doesn't notice
        // the grab and behaves as if focus stayed where it was.
        emitFocusEventPair(
            from: oldFocus, to: r.grabWindow,
            mode: .grab, byteOrder: byteOrder
        )
        let reply = GrabReply(sequenceNumber: sequenceNumber, status: .success)
        outbound.append(reply.encode(byteOrder: byteOrder))
    }

    private func handleUngrabKeyboard() {
        guard let grab = keyboardGrab else { return }
        keyboardGrab = nil
        // Per X spec + R6 dix/events.c:854 (DeactivateKeyboardGrab),
        // emit FocusOut on grab window + FocusIn on the post-grab focus
        // (the explicit focus window if set, else None) with mode=Ungrab.
        if let bo = byteOrder {
            emitFocusEventPair(
                from: grab.window, to: focusWindow,
                mode: .ungrab, byteOrder: bo
            )
        }
    }

    /// Emit a paired FocusOut(from, mode) + FocusIn(to, mode). Both events
    /// use detail=Nonlinear which is the simplest defensible choice; per
    /// spec the detail depends on the relationship between from/to/pointer
    /// — refining is a separate cleanup once the basic mode=Grab/Ungrab
    /// signals are in place.
    private func emitFocusEventPair(from: UInt32?, to: UInt32?, mode: FocusMode, byteOrder: ByteOrder) {
        let codeFocusOut: UInt8 = 10
        let codeFocusIn: UInt8 = 9
        if let from = from, from != 0, from != 1 {
            let ev = FocusEvent(
                detail: .nonlinear, sequenceNumber: sequenceNumber,
                event: from, mode: mode
            )
            log?.log("  → FocusOut target=0x\(String(from, radix: 16)) detail=nonlinear mode=\(mode)")
            outbound.append(ev.encode(code: codeFocusOut, byteOrder: byteOrder))
        }
        if let to = to, to != 0, to != 1 {
            let ev = FocusEvent(
                detail: .nonlinear, sequenceNumber: sequenceNumber,
                event: to, mode: mode
            )
            log?.log("  → FocusIn target=0x\(String(to, radix: 16)) detail=nonlinear mode=\(mode)")
            outbound.append(ev.encode(code: codeFocusIn, byteOrder: byteOrder))
        }
    }

    /// If a pointer grab is active and ownerEvents=false, route pointer
    /// events to the grab window instead of the natural target. Returns
    /// `nil` when the grab's eventMask doesn't include the requested bit
    /// (the event is dropped per spec). Returns `(grabWindow, originX,
    /// originY)` when the grab redirects.
    ///
    /// `eventMaskBit16` is the 16-bit pointer-event mask (matches GrabPointer
    /// `eventMask` field, not the 32-bit window event_mask). Bit positions
    /// align: ButtonPress=1<<2, ButtonRelease=1<<3, etc.
    private func grabRedirect(topLevel: UInt32, eventMaskBit16: UInt16) -> (UInt32, Int16, Int16)? {
        guard let grab = pointerGrab, !grab.ownerEvents else { return nil }
        // Per spec, the grab's eventMask filters which events get delivered.
        // If the bit isn't in the grab mask, drop the event.
        guard grab.eventMask & eventMaskBit16 != 0 else { return nil }
        let (gx, gy) = absoluteOrigin(of: grab.window, topLevel: topLevel)
        return (grab.window, gx, gy)
    }

    /// Find the deepest mapped descendant containing `(x, y)` (top-level
    /// local logical coords) whose event mask matches `eventMaskBit`. Returns
    /// `(targetId, targetTopLeftX, targetTopLeftY)` so the caller can compute
    /// window-local coords for the event.
    private func mouseTarget(topLevel: UInt32, x: Int16, y: Int16, eventMaskBit: UInt32) -> (UInt32, Int16, Int16)? {
        // Recurse from top-level. Track the deepest matching window.
        var deepestId: UInt32 = topLevel
        var deepestTL: (Int16, Int16) = (0, 0)
        var deepestDepth = 0
        if let top = windows.get(topLevel), top.eventMask & eventMaskBit == 0 {
            // top-level doesn't have the mask — but we'll fall back to it
            // if no descendant matches, just to keep events flowing.
        }
        func walk(id: UInt32, ox: Int16, oy: Int16, depth: Int) {
            for (cid, w) in windows.windows where w.parent == id && w.mapped {
                let cx = ox &+ w.x
                let cy = oy &+ w.y
                let inside = x >= cx && y >= cy
                              && x < cx &+ Int16(w.width)
                              && y < cy &+ Int16(w.height)
                guard inside else { continue }
                if w.eventMask & eventMaskBit != 0 && depth + 1 > deepestDepth {
                    deepestId = cid
                    deepestTL = (cx, cy)
                    deepestDepth = depth + 1
                }
                walk(id: cid, ox: cx, oy: cy, depth: depth + 1)
            }
        }
        walk(id: topLevel, ox: 0, oy: 0, depth: 0)
        return (deepestId, deepestTL.0, deepestTL.1)
    }

    /// Walk the subtree rooted at `topLevel` looking for a viewable window
    /// whose event mask has the given bit set. Per X11 spec, key events
    /// propagate to the smallest enclosing window with the relevant mask.
    /// Phase 1: just find any descendant with the mask; fall back to top-level.
    private func keyTarget(topLevel: UInt32, eventMaskBit: UInt32) -> UInt32? {
        // BFS through the subtree.
        var queue: [UInt32] = [topLevel]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let entry = windows.get(id), entry.eventMask & eventMaskBit != 0 {
                return id
            }
            for (cid, w) in windows.windows where w.parent == id {
                queue.append(cid)
            }
        }
        return windows.get(topLevel) != nil ? topLevel : nil
    }

    /// Called by the bridge from main thread when the user drags an NSWindow
    /// to a new screen position. Updates the X tracking and emits a
    /// SYNTHETIC ConfigureNotify per ICCCM 4.1.5 so toolkits update their
    /// cached widget root coords. Without this, Motif menus pop up at the
    /// window's ORIGINAL placement after a move (the toolkit hit-tests
    /// against stale rectangles cached at realization time).
    ///
    /// Moves don't change pixel content, so we don't repaint, don't recompute
    /// clipLists (those are in top-level-local coords, unaffected by an
    /// outer position change), and don't emit descendant Exposes.
    public func handleTopLevelMove(id: UInt32, x: Int16, y: Int16) {
        guard let entry = windows.get(id), !entry.overrideRedirect else { return }
        guard entry.x != x || entry.y != y else { return }
        guard let result = windows.resize(id, width: nil, height: nil, x: x, y: y) else { return }
        let (_, new) = result
        guard let order = byteOrder else { return }
        log?.log("  → synthetic ConfigureNotify on 0x\(String(id, radix: 16)) at (\(new.x),\(new.y)) (moved, ICCCM 4.1.5)")
        let synth = ConfigureNotifyEvent(
            sequenceNumber: sequenceNumber,
            event: id, window: id, aboveSibling: 0,
            x: new.x, y: new.y,
            width: new.width, height: new.height,
            borderWidth: new.borderWidth,
            overrideRedirect: false
        )
        outbound.append(synth.encode(byteOrder: order, synthetic: true))
    }

    /// Called by the bridge from main thread when the user resizes an
    /// NSWindow. Updates the X tracking and emits ConfigureNotify on the
    /// top-level. The X client (xclock) will respond by re-issuing
    /// ConfigureWindow on its drawing-target descendant; that in turn
    /// triggers the descendant Expose path in `dispatch`.
    public func handleTopLevelResize(id: UInt32, width: UInt16, height: UInt16) {
        guard let result = windows.resize(id, width: width, height: height, x: nil, y: nil) else { return }
        let (old, new) = result
        guard old.width != new.width || old.height != new.height else { return }
        guard let order = byteOrder else { return }
        log?.log("  → emit ConfigureNotify on 0x\(String(id, radix: 16)) \(new.width)x\(new.height) (was \(old.width)x\(old.height))")
        let event = ConfigureNotifyEvent(
            sequenceNumber: sequenceNumber,
            event: id, window: id, aboveSibling: 0,
            x: new.x, y: new.y,
            width: new.width, height: new.height,
            borderWidth: new.borderWidth,
            overrideRedirect: false
        )
        outbound.append(event.encode(byteOrder: order))

        // Top-level dimensions changed — refresh clip regions for the
        // whole subtree BEFORE the bg paint AND before emitting descendant
        // Exposes. paintRectsForWindow keys off entry.clipList (added
        // 2026-05-20 for the dthelpview clipping work); recomputing first
        // means the top-level's paint sees its newly-larger clipList
        // instead of the stale pre-resize value. Descendant geometries
        // are still old at this point (the client hasn't sent
        // ConfigureWindow on them yet — that's handled per-descendant in
        // handleConfigureWindow's grow-paint block).
        ClipListEngine.recomputeClips(forTopLevel: id, in: windows)

        // FlippedXView.resizeBacking allocates a fresh bitmap and fills it
        // with white as a placeholder. For windows whose CWBackPixel isn't
        // white (e.g., xterm with `-bg black`), the newly-exposed pixels
        // around the original content flash white until the client redraws.
        // Paint the top-level + every mapped descendant's bg now so the
        // bitmap matches the X-protocol expectation BEFORE we send Expose.
        let paints = mappedBackgroundPaints(topLevelId: id, byteOrder: order)
        if !paints.isEmpty {
            bridge?.paintWindowRects(topLevel: id, rects: paints)
        }

        emitVisibilityChanges(forTopLevel: id)

        // The outer's resize means descendants' visible region changed
        // too. The bitmap was reallocated and bg-painted (no preserved
        // content for now — see SHORTCUTS "NSWindow resize discards
        // prior pixels"), so each descendant's full visible region needs
        // a redraw signal. Step E2: emit Expose per clipList rect in
        // window-local coords; fully-covered descendants emit nothing.
        let exposureMask: UInt32 = 1 << 15
        for descendant in mappedDescendantSnapshots(of: id) {
            guard descendant.eventMask & exposureMask != 0 else { continue }
            log?.log("  → emit Expose on descendant 0x\(String(descendant.id, radix: 16)) (\(descendant.exposeRects.count) rect(s))")
            MockWindowBridge.emitExposesForRects(
                window: descendant.id, rects: descendant.exposeRects,
                byteOrder: order, sequence: sequenceNumber, outbound: outbound
            )
        }
    }

    /// True if `window` is a known top-level (parent == root). Used to decide
    /// whether a CreateWindow/MapWindow should drive the platform bridge.
    public func isTopLevel(_ id: UInt32) -> Bool {
        windows.get(id)?.parent == config.rootWindowId
    }

    /// Walk parents until we hit a top-level. Returns the top-level id and
    /// True if the drawable ID resolves to anything we track: a known window,
    /// a known pixmap, or the screen's root window. False for IDs that don't
    /// correspond to any resource we've ever heard of — those should trigger
    /// BadDrawable on requests that take a drawable argument.
    public func isKnownDrawable(_ id: UInt32) -> Bool {
        return windows.get(id) != nil
            || pixmaps.get(id) != nil
            || id == config.rootWindowId
    }

    /// True iff `id` is already allocated as a window, pixmap, GC, font,
    /// cursor, or root/default-colormap sentinel. Used to detect the
    /// BadIDChoice case where a client picks an ID already in use.
    ///
    /// Note we deliberately do NOT range-check against the session's
    /// `resourceIdBase|resourceIdMask`. Strictly per spec, IDs outside
    /// the client's range are also BadIDChoice — but the captured-corpus
    /// replay tests feed us C2S byte streams whose IDs came from real
    /// Sun sessions with their own per-client bases (e.g. captured xterm
    /// uses `0x05000000` because it was the second client on gold).
    /// Range-checking would reject every captured ID and break replay.
    /// Collision detection is the more important practical safety
    /// (preventing internal-stub and root/default-colormap clobbers);
    /// per-client range enforcement is a defense-in-depth we skip until
    /// it becomes load-bearing.
    public func isResourceIdInUse(_ id: UInt32) -> Bool {
        if id == config.rootWindowId { return true }
        if id == config.defaultColormapId { return true }
        if windows.get(id) != nil { return true }
        if pixmaps.get(id) != nil { return true }
        if gcs.get(id) != nil { return true }
        if fonts.get(id) != nil { return true }
        if cursors.glyph(id) != nil { return true }
        return false
    }

    /// One-shot BadIDChoice gate for Create* handlers. Returns true and
    /// emits the error when the supplied id collides with an existing
    /// resource. See `isResourceIdInUse` for the rationale on skipping
    /// the per-client range check.
    private func emitBadIDChoiceIfInvalid(_ id: UInt32, majorOpcode: UInt8) -> Bool {
        if isResourceIdInUse(id) {
            emitError(.idChoice, majorOpcode: majorOpcode, badResourceId: id)
            return true
        }
        return false
    }

    /// Validate a window argument. Returns the WindowEntry when the ID
    /// resolves to a known window; nil with a BadWindow emission otherwise.
    /// Used by handlers that take a `window` argument (ClearArea,
    /// GetWindowAttributes, MapWindow, etc.). Root is NOT in the windows
    /// table so calls referencing it return nil; handlers where the spec
    /// allows root as an argument should use validateWindowOrRoot instead.
    func validateWindow(_ window: UInt32, majorOpcode: UInt8) -> WindowEntry? {
        if let entry = windows.get(window) { return entry }
        emitError(.window, majorOpcode: majorOpcode, badResourceId: window)
        return nil
    }

    /// Validate a window argument for handlers where the screen root is a
    /// spec-legal value (GetProperty/ChangeProperty/DeleteProperty on the
    /// root, MapSubwindows on root meaning "map all top-levels", etc.).
    /// Returns true on success; emits BadWindow + returns false on unknown
    /// ID. Doesn't surface a WindowEntry — root has none, and root-aware
    /// handlers typically operate on adjacent tables (properties, child
    /// iteration) rather than the WindowEntry directly.
    func validateWindowOrRoot(_ window: UInt32, majorOpcode: UInt8) -> Bool {
        if windows.get(window) != nil || window == config.rootWindowId {
            return true
        }
        emitError(.window, majorOpcode: majorOpcode, badResourceId: window)
        return false
    }

    /// Validate an atom ID. Returns true when the atom is in the AtomTable
    /// (predefined atoms 1..68 are preseeded, dynamically-interned atoms
    /// from InternAtom requests are tracked). Emits BadAtom and returns
    /// false otherwise. Atom 0 (None sentinel) is the caller's
    /// responsibility — most callers should skip validation for atom==0
    /// since spec uses it as a "no atom" marker on some requests.
    func validateAtom(_ atom: UInt32, majorOpcode: UInt8) -> Bool {
        if atoms.name(for: atom) != nil { return true }
        emitError(.atom, majorOpcode: majorOpcode, badResourceId: atom)
        return false
    }

    /// Validate a graphics context argument. Returns the GCEntry when known;
    /// emits BadGC referencing the bad ID and returns nil otherwise. Used by
    /// every handler that takes a `gc` argument (draw ops, ChangeGC, FreeGC,
    /// SetClipRectangles, SetDashes). Captured Sun streams reference client-
    /// allocated GC IDs only, and our resourceIdBase matches Sun's, so this
    /// validation should never trip on replay; live clients trigger it only
    /// when they pass a freed or never-created GC ID.
    func validateGC(_ gc: UInt32, majorOpcode: UInt8) -> GCEntry? {
        if let entry = gcs.get(gc) { return entry }
        emitError(.gc, majorOpcode: majorOpcode, badResourceId: gc)
        return nil
    }

    /// Validate a drawable for a drawing request and resolve it to a render
    /// target — either a window subtree (with offsets into its top-level)
    /// or a pixmap (with its X-side depth). Unknown drawable id emits
    /// BadDrawable. The root window is still known-but-not-renderable
    /// (we don't render into the root); silent-drop with a log line.
    func validateDrawTarget(_ drawable: UInt32, majorOpcode: UInt8) -> DrawTarget? {
        if !isKnownDrawable(drawable) {
            emitError(.drawable, majorOpcode: majorOpcode, badResourceId: drawable)
            return nil
        }
        if let (top, dx, dy) = topLevelAndOffset(for: drawable) {
            return .window(id: drawable, topLevel: top, offsetX: dx, offsetY: dy)
        }
        if let pix = pixmaps.get(drawable) {
            return .pixmap(id: drawable, depth: pix.depth)
        }
        // Known drawable but neither a window subtree nor a pixmap = root.
        log?.log("validateDrawTarget: drawable 0x\(String(drawable, radix: 16)) is the root (not renderable); dropping op opcode=\(majorOpcode)")
        return nil
    }

    /// the (x, y) offset of `drawable` inside it. nil if the drawable isn't
    /// in a window subtree we own (e.g., a pixmap, the root, or unknown).
    public func topLevelAndOffset(for drawable: UInt32) -> (UInt32, Int16, Int16)? {
        guard windows.get(drawable) != nil else { return nil }
        var id = drawable
        var dx: Int16 = 0
        var dy: Int16 = 0
        // Cap iterations defensively; a malformed parent chain otherwise loops.
        for _ in 0..<32 {
            guard let entry = windows.get(id) else { return nil }
            if entry.parent == config.rootWindowId { return (id, dx, dy) }
            dx = dx &+ entry.x
            dy = dy &+ entry.y
            id = entry.parent
        }
        return nil
    }

    /// X11 VisibilityChangeMask bit per xproto X.h.
    static let visibilityChangeMask: UInt32 = 1 << 16

    /// Recompute clipList + borderClip for the top-level subtree that
    /// contains `windowId`, then emit VisibilityNotify to any window whose
    /// visibility state transitioned. Cheap to call from any tree-mutation
    /// handler after the WindowTable state has been updated. No-op if
    /// `windowId` is unknown or its top-level can't be resolved.
    func recomputeClipsForSubtreeContaining(_ windowId: UInt32) {
        guard let (topId, _, _) = topLevelAndOffset(for: windowId) else { return }
        ClipListEngine.recomputeClips(forTopLevel: topId, in: windows)
        emitVisibilityChanges(forTopLevel: topId)
    }

    /// Walk every window in the subtree rooted at `topId`, derive its
    /// current visibility state, and emit VisibilityNotify when the state
    /// transitioned (and the window has VisibilityChangeMask in its event
    /// mask). Update the stored `lastVisibilityState` either way so future
    /// calls see correct prior state.
    ///
    /// Per X11 spec, visibility state is computed **ignoring this window's
    /// subwindows**. A container fully covered by its child widgets is
    /// Unobscured, not FullyObscured — that distinction is load-bearing
    /// for Motif: PushButton's redraw method gates shadow-chrome drawing
    /// on its parent NOT being FullyObscured. R6's `mi/mivaltree.c`
    /// computes this with `RECT_IN_REGION(universe, &borderSize)` where
    /// universe is parent-visible BEFORE subtracting children.
    ///
    /// Our stored regions: `borderClip` is `parentVisible ∩ borderBox`
    /// (the window's max possible visibility, children-agnostic).
    /// `clipList` is `borderClip ∩ interiorBox − sum(children's borderClips)`
    /// — children-subtracted, which is what we used until 2026-05-14 and
    /// which produced the wrong answer. We now compute `borderClip ∩
    /// interiorBox` on the fly to get the children-agnostic interior
    /// region, then compare its area to `width * height`.
    ///
    /// State derivation:
    ///   - !mapped → nil (window not viewable; spec doesn't emit
    ///     VisibilityNotify for transitions involving unmapped state)
    ///   - mapped + area(borderClip ∩ interiorBox) == 0 → 2 (FullyObscured)
    ///   - mapped + area(borderClip ∩ interiorBox) == width*height → 0 (Unobscured)
    ///   - otherwise → 1 (PartiallyObscured)
    private func emitVisibilityChanges(forTopLevel topId: UInt32) {
        guard let order = byteOrder else { return }
        // Walk every window that resolves to topId.
        let candidates = windows.windows.filter {
            topLevelAndOffset(for: $0.key)?.0 == topId
        }
        for (id, entry) in candidates {
            let newState: UInt8?
            if !entry.mapped {
                newState = nil
            } else {
                let area = regionArea(interiorVisibleRegion(of: id, entry: entry))
                let windowArea = Int64(entry.width) * Int64(entry.height)
                if area == 0 {
                    newState = 2
                } else if area == windowArea {
                    newState = 0
                } else {
                    newState = 1
                }
            }
            if newState != entry.lastVisibilityState {
                if let ns = newState,
                   entry.eventMask & Self.visibilityChangeMask != 0,
                   let state = VisibilityState(rawValue: ns) {
                    let event = VisibilityNotifyEvent(
                        sequenceNumber: sequenceNumber,
                        window: id, state: state
                    )
                    outbound.append(event.encode(byteOrder: order))
                }
                windows.setLastVisibilityState(id, newState)
            }
        }
    }

    /// Children-agnostic visible region for `id`, in top-level coords.
    /// Equals `borderClip ∩ interiorBox`. Used for VisibilityNotify state
    /// derivation per spec ("ignoring all of the window's subwindows").
    /// borderBox includes the border; interiorBox is the client drawing
    /// area only — the spec talks about window contents, so we project
    /// the border-inclusive borderClip back onto the interior.
    private func interiorVisibleRegion(of id: UInt32, entry: WindowEntry) -> Region {
        guard let (_, dx, dy) = topLevelAndOffset(for: id) else { return .empty }
        let interiorBox = BoxRec(
            x1: Int32(dx), y1: Int32(dy),
            x2: Int32(dx) + Int32(entry.width),
            y2: Int32(dy) + Int32(entry.height)
        )
        return entry.borderClip.intersected(with: Region(box: interiorBox))
    }

    private func regionArea(_ region: Region) -> Int64 {
        var sum: Int64 = 0
        for rect in region.rects {
            sum += Int64(rect.width) * Int64(rect.height)
        }
        return sum
    }

    /// Translate a window's clipList from top-level coords to the
    /// window-local coords Expose events expect. For a top-level this is
    /// a no-op (offset is 0,0). Empty result if the window has no
    /// visible rects (fully covered or unmapped).
    func exposeRectsForWindow(_ windowId: UInt32) -> [BoxRec] {
        guard let entry = windows.get(windowId) else { return [] }
        guard let (_, dx, dy) = topLevelAndOffset(for: windowId) else { return [] }
        let dxI = Int32(dx)
        let dyI = Int32(dy)
        return entry.clipList.rects.map {
            BoxRec(x1: $0.x1 - dxI, y1: $0.y1 - dyI,
                   x2: $0.x2 - dxI, y2: $0.y2 - dyI)
        }
    }

    /// E1.5: paint parent's background over the region a descendant just
    /// uncovered, then emit Expose to parent for that region. `uncovered`
    /// is in top-level coords (the same space WindowEntry.borderClip
    /// lives in). Called from configureWindow after a descendant's
    /// move/resize when the resulting parent-visible delta is non-empty.
    func repaintParentOverUncovered(uncovered: Region, parentId: UInt32, byteOrder: ByteOrder) {
        guard let parentEntry = windows.get(parentId) else { return }
        guard let (topLevelId, parentDx, parentDy) = topLevelAndOffset(for: parentId) else { return }

        let parentBg = windowBackground(parentId, byteOrder: byteOrder)
        let paintRects: [WindowBackgroundRect] = uncovered.rects.map {
            WindowBackgroundRect(
                x: Int16(clamping: $0.x1), y: Int16(clamping: $0.y1),
                width: UInt16(clamping: $0.x2 - $0.x1),
                height: UInt16(clamping: $0.y2 - $0.y1),
                color: parentBg
            )
        }
        if !paintRects.isEmpty {
            bridge?.paintWindowRects(topLevel: topLevelId, rects: paintRects)
        }

        if parentEntry.eventMask & MockWindowBridge.exposureMask != 0 {
            let parentLocalRects = uncovered.rects.map {
                BoxRec(
                    x1: $0.x1 - Int32(parentDx), y1: $0.y1 - Int32(parentDy),
                    x2: $0.x2 - Int32(parentDx), y2: $0.y2 - Int32(parentDy)
                )
            }
            MockWindowBridge.emitExposesForRects(
                window: parentId, rects: parentLocalRects,
                byteOrder: byteOrder, sequence: sequenceNumber,
                outbound: outbound
            )
        }
    }

    /// Resolve a foreground/background pixel value to RGB16. Falls back to
    /// black for unknown pixels — better than crashing on a stray reference.
    private func resolveColor(_ pixel: UInt32) -> RGB16 {
        colors.rgb(for: pixel) ?? RGB16(red: 0, green: 0, blue: 0)
    }

    /// Snapshot every already-mapped descendant of `windowId`. Used when a
    /// top-level becomes viewable so the bridge can emit Expose to whichever
    /// descendants have ExposureMask in their event mask. Each snapshot
    /// carries the descendant's visible-rect list (window-local coords)
    /// so Step E1's per-rect Expose emission can skip fully-covered
    /// windows entirely.
    private func mappedDescendantSnapshots(of windowId: UInt32) -> [DescendantSnapshot] {
        var out: [DescendantSnapshot] = []
        var stack: [UInt32] = [windowId]
        while let id = stack.popLast() {
            for (childId, w) in windows.windows where w.parent == id && w.mapped {
                out.append(DescendantSnapshot(
                    id: childId, eventMask: w.eventMask,
                    width: w.width, height: w.height,
                    exposeRects: exposeRectsForWindow(childId)
                ))
                stack.append(childId)
            }
        }
        return out
    }

    /// Walk the mapped subtree under `ancestorId` (exclusive) and return
    /// the clipped bg-paint rect set for each descendant that has a
    /// backPixel or border. Used by the non-top-level MapWindow path to
    /// catch the case where the subtree was mapped before the ancestor
    /// (dthelpview's manBox / DisplayArea / scrollbars all map before
    /// their wrapper shell, then the shell maps and the entire subtree
    /// becomes viewable at once). Mirrors the Expose-cascade shape added
    /// 2026-05-19 — same traversal, different per-window action.
    private func descendantBgPaints(of ancestorId: UInt32, byteOrder: ByteOrder) -> [WindowBackgroundRect] {
        var out: [WindowBackgroundRect] = []
        var queue: [UInt32] = [ancestorId]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for (childId, w) in windows.windows where w.parent == id && w.mapped {
                queue.append(childId)
                guard w.backPixel != nil || (w.borderPixel != nil && w.borderWidth > 0),
                      let (_, dx, dy) = topLevelAndOffset(for: childId) else { continue }
                out.append(contentsOf: paintRectsForWindow(entry: w, dx: dx, dy: dy, byteOrder: byteOrder))
            }
        }
        return out
    }

    /// First-map WM-emulation placement for a regular top-level. If the
    /// client picked a non-zero position via CreateWindow / ConfigureWindow
    /// (e.g., quickplot's command window at (55, 260), plot window at
    /// (500, 20)), we honor it — that's the natural side-by-side layout
    /// the app was designed around. Only when the client asked for (0, 0)
    /// (which means "WM, place me somewhere reasonable") do we apply a
    /// cascade. Sticky per id: remapping after an unmap keeps the same
    /// position. No-op for override-redirect popups — those place
    /// themselves and we honor their requested coords.
    ///
    /// Either way, after this returns the bridge's `emitMapSequence`
    /// emits ConfigureNotify with the now-canonical WindowEntry x/y, and
    /// `handleMapWindow` follows with a SYNTHETIC ConfigureNotify per
    /// ICCCM 4.1.5 so toolkits cache the right root coords.
    private func placeTopLevelIfNeeded(id: UInt32) {
        guard let entry = windows.get(id), !entry.overrideRedirect else { return }
        guard !placedTopLevels.contains(id) else { return }
        placedTopLevels.insert(id)
        if entry.x != 0 || entry.y != 0 {
            log?.log("  → WM-honor 0x\(String(id, radix: 16)) at client-set X-root (\(entry.x),\(entry.y))")
            return
        }
        let px = nextTopLevelPlacement.x
        let py = nextTopLevelPlacement.y
        nextTopLevelPlacement.x &+= placementCascadeStep
        nextTopLevelPlacement.y &+= placementCascadeStep
        if nextTopLevelPlacement.x > 500 || nextTopLevelPlacement.y > 500 {
            nextTopLevelPlacement = (100, 100)
        }
        log?.log("  → WM-place 0x\(String(id, radix: 16)) at X-root (\(px),\(py)) (was (\(entry.x),\(entry.y)))")
        _ = windows.resize(id, width: nil, height: nil, x: px, y: py)
    }

    /// Build the paint list for a newly-mapped top-level: the top-level's own
    /// background fill plus one rect-pair per already-mapped descendant
    /// (border ring + interior bg). Order is parent-then-children so
    /// descendant paints land on top of their parent.
    private func mappedBackgroundPaints(topLevelId: UInt32, byteOrder: ByteOrder) -> [WindowBackgroundRect] {
        guard let top = windows.get(topLevelId) else { return [] }
        var out: [WindowBackgroundRect] = []
        out.append(contentsOf: paintRectsForWindow(entry: top, dx: 0, dy: 0, byteOrder: byteOrder))
        // Walk the subtree breadth-first so a child's paint always follows
        // its parent's. We don't repaint windows without an explicit
        // backPixel/borderPixel — those keep whatever's already on the
        // bitmap (X11 default behaviour for ParentRelative bg).
        var queue: [UInt32] = [topLevelId]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for (childId, w) in windows.windows where w.parent == id && w.mapped {
                queue.append(childId)
                guard w.backPixel != nil || (w.borderPixel != nil && w.borderWidth > 0),
                      let (_, dx, dy) = topLevelAndOffset(for: childId) else { continue }
                out.append(contentsOf: paintRectsForWindow(entry: w, dx: dx, dy: dy, byteOrder: byteOrder))
            }
        }
        return out
    }

    /// Produce the paint rects for a single window. With borderWidth > 0,
    /// emits an OUTER rect (the border ring; size = w + 2*bw, h + 2*bw) drawn
    /// in borderPixel, then a set of INNER rects (the content area, clipped
    /// to the window's visible region) in backPixel. The inner-on-top-of-
    /// outer ordering leaves only the ring visible. With borderWidth == 0,
    /// emits only the clipped bg rects.
    ///
    /// Inner-rect clipping (added 2026-05-20) follows X.org's miPaintWindow
    /// invariant: bg fills only the window's visible interior (clipList).
    /// Without it, a parent's bg paint at MapWindow time bleeds through
    /// descendant windows — the dthelpview "form blue painted over white
    /// DisplayArea" path that produces image 1's all-blue look.
    ///
    /// Border-ring clipping is NOT yet applied — the outer rect still
    /// paints unclipped over the (logical) border area. Almost no Motif
    /// widgets use borders (bw=0 everywhere we've seen), so this hasn't
    /// surfaced visibly. SHORTCUTS entry tracks the gap.
    ///
    /// `(dx, dy)` is the window's content top-left in top-level pixel coords
    /// (already includes any ancestor offsets).
    private func paintRectsForWindow(entry: WindowEntry, dx: Int16, dy: Int16, byteOrder: ByteOrder) -> [WindowBackgroundRect] {
        var out: [WindowBackgroundRect] = []
        let bw = entry.borderWidth
        let hasBorder = bw > 0 && entry.borderPixel != nil
        if hasBorder, let bp = entry.borderPixel {
            out.append(WindowBackgroundRect(
                x: dx &- Int16(bw), y: dy &- Int16(bw),
                width: entry.width &+ 2 * bw, height: entry.height &+ 2 * bw,
                color: resolveColor(bp)
            ))
        }
        if entry.backPixel != nil {
            let bg = windowBackground(entry.id, byteOrder: byteOrder)
            // Clip the bg rect to the window's visible region (clipList).
            // clipList is already in top-level coords. Empty clipList =
            // window fully obscured (or unmapped) — emit no inner rects.
            for box in entry.clipList.rects {
                let w = box.x2 - box.x1
                let h = box.y2 - box.y1
                guard w > 0, h > 0 else { continue }
                out.append(WindowBackgroundRect(
                    x: Int16(clamping: box.x1),
                    y: Int16(clamping: box.y1),
                    width: UInt16(clamping: w),
                    height: UInt16(clamping: h),
                    color: bg
                ))
            }
        }
        return out
    }

    /// Build a QueryFontReply with per-glyph CHARINFO entries from Core
    /// Text bounding boxes. Pre-2026-05-15 this returned the monospace
    /// shortcut (`minBounds == maxBounds`, `charInfos: []`, `allCharsExist:
    /// true`) — correct for Monaco but the wrong answer for proportional
    /// fonts like quickplot's menu `-adobe-helvetica-medium-o-12-...`,
    /// where Xt's LabelWidget reads min/max-bounds to decide whether to
    /// per-string measure or assume uniform-width. Same family of bug as
    /// QueryTextExtents had before its 2026-05-15 fix.
    ///
    /// Strategy:
    ///   - Call FontResolver.measureGlyphMetrics for the encoded range.
    ///   - Compute component-wise min/max for minBounds/maxBounds.
    ///   - Per spec, an empty charInfos[] means "every char has minBounds
    ///     metrics." That's correct iff minBounds == maxBounds, so we
    ///     populate the per-char array only when they differ (proportional
    ///     fonts) and elide it for monospace.
    ///   - Emit a useful subset of FONTPROPS: FONT_ASCENT, FONT_DESCENT,
    ///     DEFAULT_CHAR, AVERAGE_WIDTH. All are integer-valued, so we
    ///     don't need to intern atom-string values.
    private func makeQueryFontReply(resolved: ResolvedFont, sequence: UInt16) -> QueryFontReply {
        // ISO-8859-1 covers 32...255 (224 chars including the 0x80-0x9F
        // C1-control gap rendered as missing-glyph zero CharInfos). This
        // is what Motif's XCreateFontSet expects to find for the C locale
        // — without 224 chars, the FontSet builder rejects the font and
        // widgets end up with no usable font → button labels render blank.
        // Other charsets (adobe-fontspecific, jisx0201, sunolcursor-1,
        // sunolglyph-1) stay at 32...126 ASCII because we don't have real
        // glyphs for those ranges anyway; the CHARSET_REGISTRY/ENCODING
        // FONTPROPS below make XCreateFontSet accept them as the matching
        // variant for their charset, and dt-app text uses iso8859-1 in
        // practice.
        let isISO8859: Bool = (resolved.charsetRegistry == "iso8859")
        let range: ClosedRange<UInt16> = isISO8859 ? 32...255 : 32...126
        let payload = FontResolver.measureGlyphMetrics(resolved, range: range)
        let infos = payload.infos

        // Component-wise min/max. Skip missing-glyph entries (all-zero)
        // when computing min — they'd give false zeros.
        var minBounds = CharInfo(
            leftSideBearing: Int16.max, rightSideBearing: Int16.max,
            characterWidth: Int16.max, ascent: Int16.max, descent: Int16.max,
            attributes: 0
        )
        var maxBounds = CharInfo(
            leftSideBearing: Int16.min, rightSideBearing: Int16.min,
            characterWidth: Int16.min, ascent: Int16.min, descent: Int16.min,
            attributes: 0
        )
        var sawAny = false
        var widthSum = 0
        var widthCount = 0
        for c in infos where c.characterWidth != 0 {
            sawAny = true
            widthSum += Int(c.characterWidth)
            widthCount += 1
            minBounds.leftSideBearing  = min(minBounds.leftSideBearing,  c.leftSideBearing)
            minBounds.rightSideBearing = min(minBounds.rightSideBearing, c.rightSideBearing)
            minBounds.characterWidth   = min(minBounds.characterWidth,   c.characterWidth)
            minBounds.ascent           = min(minBounds.ascent,           c.ascent)
            minBounds.descent          = min(minBounds.descent,          c.descent)
            maxBounds.leftSideBearing  = max(maxBounds.leftSideBearing,  c.leftSideBearing)
            maxBounds.rightSideBearing = max(maxBounds.rightSideBearing, c.rightSideBearing)
            maxBounds.characterWidth   = max(maxBounds.characterWidth,   c.characterWidth)
            maxBounds.ascent           = max(maxBounds.ascent,           c.ascent)
            maxBounds.descent          = max(maxBounds.descent,          c.descent)
        }
        if !sawAny {
            // Pathological no-glyph font; fall back to cell-snapped defaults.
            let b = CharInfo(
                leftSideBearing: 0,
                rightSideBearing: Int16(resolved.cellWidth),
                characterWidth: Int16(resolved.cellWidth),
                ascent: Int16(resolved.ascent),
                descent: Int16(resolved.descent),
                attributes: 0
            )
            minBounds = b
            maxBounds = b
        }

        // charInfos[] is the per-char metrics list. Spec: empty array means
        // "every char has minBounds metrics" — only correct when minBounds
        // == maxBounds. Populate iff they differ (proportional fonts).
        let charInfos: [CharInfo] = (minBounds == maxBounds) ? [] : infos

        // AVERAGE_WIDTH per XLFD spec is the arithmetic mean of glyph
        // advances over the encoded range, in tenths of a pixel. For
        // monospace this equals max (mean == max). For proportional fonts
        // it's well below max. libDtHelp reads this off the default font
        // for its per-column sizing (XUICreate.c:522 → Resize.c:113), so
        // returning max-width for a proportional font over-sizes its
        // dialog by the max/mean ratio (~2× for HelveticaNeue iso8859-1).
        let avgWidthTenths: UInt32 = widthCount > 0
            ? UInt32(max(1, (widthSum * 10 + widthCount / 2) / widthCount))
            : UInt32(max(1, maxBounds.characterWidth)) * 10

        // FONTPROPS: integer-valued metrics plus the two atom-valued
        // charset props that Motif's XCreateFontSet REQUIRES — without
        // those, the FontSet builder can't match a per-charset variant
        // and falls through to "no usable fontset" (visible as the
        // "Cannot convert string ... to type FontSet" Xt warning). The
        // values are atom IDs interned from the charset registry/encoding
        // strings we got from the OpenFont XLFD's last two fields. Real
        // Sun returns ~21 FONTPROPS including FAMILY_NAME / FOUNDRY /
        // WEIGHT_NAME etc.; the four metric props + two charset props
        // here cover what dt-Motif / Athena widget layout actually reads.
        let props: [FontProp] = [
            FontProp(name: atoms.intern("FONT_ASCENT"),  value: UInt32(resolved.ascent)),
            FontProp(name: atoms.intern("FONT_DESCENT"), value: UInt32(resolved.descent)),
            FontProp(name: atoms.intern("DEFAULT_CHAR"), value: 32),
            FontProp(name: atoms.intern("AVERAGE_WIDTH"), value: avgWidthTenths),
            // Charset registry/encoding — atom IDs of the charset strings.
            // These are what Motif's per-charset FontSet probe reads.
            FontProp(name: atoms.intern("CHARSET_REGISTRY"),
                     value: atoms.intern(resolved.charsetRegistry.uppercased())),
            FontProp(name: atoms.intern("CHARSET_ENCODING"),
                     value: atoms.intern(resolved.charsetEncoding)),
        ]

        return QueryFontReply(
            sequenceNumber: sequence,
            minBounds: minBounds,
            maxBounds: maxBounds,
            minCharOrByte2: range.lowerBound, maxCharOrByte2: range.upperBound,
            defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0,
            allCharsExist: payload.allExist,
            fontAscent: Int16(resolved.ascent),
            fontDescent: Int16(resolved.descent),
            properties: props,
            charInfos: charInfos
        )
    }

    /// Resolve the GC by id and translate to a typed `GCState`.
    private func gcState(_ gcId: UInt32, byteOrder: ByteOrder) -> GCState {
        guard let entry = gcs.get(gcId) else { return GCState() }
        return GCState.materialise(from: entry, byteOrder: byteOrder)
    }

    /// Effective background color for a window. Reads the cached CWBackPixel
    /// (set at CreateWindow time, optionally overridden by
    /// ChangeWindowAttributes); falls back to white when no bg pixel was
    /// configured. Used by ClearArea and by the paint-on-map flow.
    private func windowBackground(_ windowId: UInt32, byteOrder: ByteOrder) -> RGB16 {
        guard let w = windows.get(windowId) else {
            return RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
        }
        if let pixel = w.backPixel {
            return resolveColor(pixel)
        }
        return RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
    }

    // MARK: - Drawing

    private func handlePolySegment(_ r: PolySegment, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolySegment.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolySegment.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        let translated = r.segments.map {
            LineSegment(
                x1: $0.x1 &+ dx, y1: $0.y1 &+ dy,
                x2: $0.x2 &+ dx, y2: $0.y2 &+ dy
            )
        }
        bridge.drawPolySegment(
            target: target,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            segments: translated,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    /// PolyPoint (op 64) — draws single-pixel dots at each point using the
    /// GC's foreground. Pre-2026-05-15 had no Framer decoder and fell
    /// through to BadRequest, breaking any plotting client (xmgrace,
    /// xfig point markers, scatter plots). Implemented here as a series
    /// of 1×1 PolyFillRectangle calls — Phase 1; the proper bridge
    /// method would use CGContext.fill(rect) with a 1×1 pixel directly
    /// without going through the rectangle dispatch. Same coordinate-
    /// mode handling as PolyLine.
    private func handlePolyPoint(_ r: PolyPoint, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyPoint.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyPoint.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        var rects: [Rectangle] = []
        rects.reserveCapacity(r.points.count)
        var lastX: Int16 = 0
        var lastY: Int16 = 0
        for (i, p) in r.points.enumerated() {
            let absX: Int16
            let absY: Int16
            if r.coordinateMode == .origin || i == 0 {
                absX = p.x; absY = p.y
            } else {
                absX = lastX &+ p.x; absY = lastY &+ p.y
            }
            lastX = absX; lastY = absY
            rects.append(Rectangle(x: absX &+ dx, y: absY &+ dy, width: 1, height: 1))
        }
        bridge.drawPolyFillRectangle(
            target: target,
            foreground: resolveColor(state.foreground),
            background: resolveColor(state.background),
            function: state.function,
            fillStyle: state.fillStyle,
            stipple: state.stipple, tile: state.tile,
            stippleOriginX: state.tileStippleXOrigin &+ Int16(truncatingIfNeeded: dx),
            stippleOriginY: state.tileStippleYOrigin &+ Int16(truncatingIfNeeded: dy),
            rectangles: rects,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyLine(_ r: PolyLine, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyLine.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyLine.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        // CoordinateMode.previous means each subsequent point is a delta from
        // the prior absolute position; we accumulate to get all-absolute.
        var points: [DrawPoint] = []
        points.reserveCapacity(r.points.count)
        var lastX: Int16 = 0
        var lastY: Int16 = 0
        for (i, p) in r.points.enumerated() {
            let absX: Int16
            let absY: Int16
            if r.coordinateMode == .origin || i == 0 {
                absX = p.x; absY = p.y
            } else {
                absX = lastX &+ p.x; absY = lastY &+ p.y
            }
            lastX = absX; lastY = absY
            points.append(DrawPoint(x: absX &+ dx, y: absY &+ dy))
        }
        bridge.drawPolyLine(
            target: target,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            points: points,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handleFillPoly(_ r: FillPoly, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: FillPoly.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: FillPoly.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        var points: [DrawPoint] = []
        points.reserveCapacity(r.points.count)
        var lastX: Int16 = 0
        var lastY: Int16 = 0
        for (i, p) in r.points.enumerated() {
            let absX: Int16
            let absY: Int16
            if r.coordinateMode == .origin || i == 0 {
                absX = p.x; absY = p.y
            } else {
                absX = lastX &+ p.x; absY = lastY &+ p.y
            }
            lastX = absX; lastY = absY
            points.append(DrawPoint(x: absX &+ dx, y: absY &+ dy))
        }
        // Per X11 spec: Convex/Nonconvex use the GC's fill-rule for shape; for
        // Complex it also uses fill-rule. We just pass the GC state's fill-rule.
        bridge.drawFillPoly(
            target: target,
            foreground: resolveColor(state.foreground),
            points: points,
            evenOdd: state.fillRuleEvenOdd,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyFillRectangle(_ r: PolyFillRectangle, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyFillRectangle.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyFillRectangle.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        let translated = r.rectangles.map {
            Rectangle(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height
            )
        }
        bridge.drawPolyFillRectangle(
            target: target,
            foreground: resolveColor(state.foreground),
            background: resolveColor(state.background),
            function: state.function,
            fillStyle: state.fillStyle,
            stipple: state.stipple, tile: state.tile,
            // Translate the stipple origin by the same window offset we
            // applied to the rectangle. Without this, the stipple grid
            // shifts relative to the fill rect by exactly the window's
            // offset within its top-level — and Motif's text caret
            // (origin set per-paint to the cursor's window-local top
            // left) decodes as a scrambled fragment instead of the
            // I-beam stipple pattern.
            stippleOriginX: state.tileStippleXOrigin &+ Int16(truncatingIfNeeded: dx),
            stippleOriginY: state.tileStippleYOrigin &+ Int16(truncatingIfNeeded: dy),
            rectangles: translated,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyRectangle(_ r: PolyRectangle, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyRectangle.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyRectangle.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        let translated = r.rectangles.map {
            Rectangle(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height
            )
        }
        bridge.drawPolyRectangle(
            target: target,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            rectangles: translated,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handlePolyArc(_ r: PolyArc, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyArc.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyArc.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        let translated = r.arcs.map {
            Arc(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height,
                angle1: $0.angle1, angle2: $0.angle2
            )
        }
        bridge.drawPolyArc(
            target: target,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            arcs: translated,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handlePolyFillArc(_ r: PolyFillArc, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyFillArc.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyFillArc.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        let translated = r.arcs.map {
            Arc(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height,
                angle1: $0.angle1, angle2: $0.angle2
            )
        }
        bridge.drawPolyFillArc(
            target: target,
            foreground: resolveColor(state.foreground),
            arcs: translated,
            clipRectangles: state.clipRectangles
        )
    }

    private func handleImageText8(_ r: ImageText8, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: ImageText8.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: ImageText8.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        // Pull the GC's font; fall back to "fixed" if no font set.
        let resolvedFont: ResolvedFont
        if let entry = fonts.get(state.font) {
            resolvedFont = entry.resolved
        } else {
            resolvedFont = FontResolver.resolve(name: "fixed")
        }
        bridge.drawImageText8(
            target: target,
            foreground: resolveColor(state.foreground),
            background: resolveColor(state.background),
            font: resolvedFont,
            x: r.x &+ dx, y: r.y &+ dy,
            string: r.string,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyText8(_ r: PolyText8, byteOrder: ByteOrder) {
        guard let target = validateDrawTarget(r.drawable, majorOpcode: PolyText8.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyText8.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let (dx, dy) = target.windowOffset
        let resolvedFont: ResolvedFont
        if let entry = fonts.get(state.font) {
            resolvedFont = entry.resolved
        } else {
            resolvedFont = FontResolver.resolve(name: "fixed")
        }
        bridge.drawPolyText8(
            target: target,
            foreground: resolveColor(state.foreground),
            font: resolvedFont,
            x: r.x &+ dx, y: r.y &+ dy,
            items: r.items,
            clipRectangles: state.clipRectangles
        )
    }

    private func handleCopyArea(_ r: CopyArea, byteOrder: ByteOrder) {
        // BadDrawable check runs up front for both src and dst so unknown
        // drawable IDs emit the spec-correct error regardless of any other
        // condition (and the error references the offending ID).
        // validateDrawTarget below resolves known drawables to a DrawTarget;
        // it returns nil for the root drawable (known but not renderable —
        // we don't keep a root pixel buffer), which CopyArea handles by
        // emitting BadImplementation (spec lets us, and we don't take
        // screenshots of root).
        if !isKnownDrawable(r.srcDrawable) {
            emitError(.drawable, majorOpcode: CopyArea.opcode, badResourceId: r.srcDrawable)
            return
        }
        if !isKnownDrawable(r.dstDrawable) {
            emitError(.drawable, majorOpcode: CopyArea.opcode, badResourceId: r.dstDrawable)
            return
        }
        guard validateGC(r.gc, majorOpcode: CopyArea.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        guard let srcTarget = validateDrawTarget(r.srcDrawable, majorOpcode: CopyArea.opcode) else {
            emitError(.implementation, majorOpcode: CopyArea.opcode)
            return
        }
        guard let dstTarget = validateDrawTarget(r.dstDrawable, majorOpcode: CopyArea.opcode) else {
            emitError(.implementation, majorOpcode: CopyArea.opcode)
            return
        }

        // Spec requires BadMatch on src.depth != dst.depth. Not enforced
        // here yet — window depth is often the CopyFromParent sentinel
        // (0) which would generate spurious mismatches against pixmaps
        // that carry an explicit depth. Motif and Athena always create
        // pixmaps at root-depth so depth mismatches don't actually
        // happen in practice for the clients we host. Tracked as a
        // follow-up: resolve sentinel depths before comparing.
        let (srcDX, srcDY) = srcTarget.windowOffset
        let (dstDX, dstDY) = dstTarget.windowOffset
        log?.log("  CopyArea src=\(srcTarget) dst=\(dstTarget) srcXY=(\(r.srcX),\(r.srcY)) dstXY=(\(r.dstX),\(r.dstY)) \(r.width)x\(r.height)")
        let state = gcState(r.gc, byteOrder: byteOrder)
        bridge.copyArea(
            src: srcTarget,
            dst: dstTarget,
            srcX: r.srcX &+ srcDX, srcY: r.srcY &+ srcDY,
            dstX: r.dstX &+ dstDX, dstY: r.dstY &+ dstDY,
            width: r.width, height: r.height,
            clipRectangles: state.clipRectangles
        )
        // X11 spec: when GC has graphics-exposures=True, CopyArea must be
        // followed by GraphicsExpose events (one per obscured source
        // region) OR a single NoExpose if the source had no obscured
        // pixels. When graphics-exposures=False, the server MUST emit
        // NEITHER. Pre-2026-05-15 we emitted NoExpose unconditionally,
        // queuing an event Xt-internal GCs (which set graphicsExposures
        // = False) explicitly said they didn't want — Athena ScrollBar's
        // GC is the classic case.
        //
        // xterm's CopyWait (util.c:709) BLOCKS in XWindowEvent waiting
        // for the GraphicsExpose/NoExpose pair when graphics-exposures
        // is True, so we still emit NoExpose for that case (every
        // same-window backing-store copy has no obscured source).
        if state.graphicsExposures {
            let noExpose = NoExposureEvent(
                sequenceNumber: sequenceNumber,
                drawable: r.dstDrawable,
                minorOpcode: 0,
                majorOpcode: 62  // X_CopyArea
            )
            outbound.append(noExpose.encode(byteOrder: byteOrder))
        }
    }

    private func handleClearArea(_ r: ClearArea, byteOrder: ByteOrder) {
        guard let entry = validateWindow(r.window, majorOpcode: ClearArea.opcode) else { return }
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.window) else { return }
        let bg = windowBackground(r.window, byteOrder: byteOrder)
        // X11 spec: if width is 0, fill to window's right edge; if height is 0,
        // fill to bottom.
        let fillW = r.width == 0 ? UInt16(max(0, Int(entry.width) - Int(r.x))) : r.width
        let fillH = r.height == 0 ? UInt16(max(0, Int(entry.height) - Int(r.y))) : r.height
        log?.log("  ClearArea window=0x\(String(r.window, radix: 16)) at (\(r.x),\(r.y)) \(fillW)x\(fillH) (req w=\(r.width) h=\(r.height) win=\(entry.width)x\(entry.height) exposures=\(r.exposures))")
        // X11 spec (mi/miwindow.c:miClearToBackground): the request rect is
        // built in screen coords (drawable.x + r.x ...), then intersected
        // with pWin->clipList. Only the surviving sub-rects are painted.
        // Without this, a ClearArea on a parent paints the parent's bg
        // pixel right through any descendant windows whose clipList ought
        // to mask them — the dthelpview 2026-05-19 "leftover blue button
        // rectangles inside the white DisplayArea on expand" bug.
        let reqBox = BoxRec(
            x1: Int32(r.x) + Int32(dx), y1: Int32(r.y) + Int32(dy),
            x2: Int32(r.x) + Int32(dx) + Int32(fillW),
            y2: Int32(r.y) + Int32(dy) + Int32(fillH)
        )
        let clippedRects: [Framer.Rectangle]
        if reqBox.isEmpty {
            clippedRects = []
        } else {
            let clipped = entry.clipList.intersected(with: Region(box: reqBox))
            clippedRects = clipped.rects.map { box in
                Framer.Rectangle(
                    x: Int16(clamping: box.x1),
                    y: Int16(clamping: box.y1),
                    width: UInt16(clamping: box.x2 - box.x1),
                    height: UInt16(clamping: box.y2 - box.y1)
                )
            }
        }
        bridge.clearArea(topLevel: top, rects: clippedRects, background: bg)
        // X11 spec: if `exposures` is True, the server sends an Expose event
        // for the cleared region (so the client can redraw on top). xcalc's
        // LCD update sequence is "ClearArea + wait for Expose + draw digits"
        // — without this we cleared the LCD but xcalc never redrew. The
        // Expose event reports the REQUESTED rect (in window-local coords),
        // not the clipped sub-rects — clients expect the rect they asked
        // for. The X server emits Expose for the visible-region intersection
        // (multiple Expose events for a multi-band region); we simplify by
        // emitting the bounding rect when the intersection is non-empty.
        if r.exposures, entry.eventMask & (1 << 15) != 0, !clippedRects.isEmpty {
            let expose = ExposeEvent(
                sequenceNumber: sequenceNumber, window: r.window,
                x: UInt16(bitPattern: r.x), y: UInt16(bitPattern: r.y),
                width: fillW, height: fillH, count: 0
            )
            outbound.append(expose.encode(byteOrder: byteOrder))
        }
    }

    public var byteOrder: ByteOrder? {
        if case .running(let bo) = phase { return bo }
        return nil
    }

    /// Emit an X11 protocol error to the client. Per the XError-honesty policy
    /// (CLAUDE.md Working conventions, DECISIONS.md 2026-05-14): when a request
    /// can't be served, emit the correct error on the wire rather than silently
    /// dropping or faking success. Logs prominently with `[XERROR]` so the
    /// condition is visible during debugging. No-op if the session isn't in
    /// the `.running` phase (pre-handshake errors travel through SetupRefused,
    /// not XError).
    func emitError(
        _ code: XErrorCode,
        majorOpcode: UInt8,
        badResourceId: UInt32 = 0,
        minorOpcode: UInt16 = 0
    ) {
        guard let order = byteOrder else { return }
        let bytes = XError.encode(
            code: code,
            sequenceNumber: sequenceNumber,
            badResourceId: badResourceId,
            minorOpcode: minorOpcode,
            majorOpcode: majorOpcode,
            byteOrder: order
        )
        outbound.append(bytes)
        errorsEmitted += 1
        let opName = opcodeName(majorOpcode) ?? "?"
        log?.log("[XERROR] \(code) on \(opName) (major=\(majorOpcode)) seq=\(sequenceNumber) badId=0x\(String(badResourceId, radix: 16))")
    }

    /// Tear down all of this client's resources on disconnect, per X11 spec
    /// close-down behavior (default mode = DestroyAll). The most visible
    /// effect: every top-level NSWindow the client mapped should close, so
    /// when xfontsel issues quit, its main window doesn't linger on screen.
    /// We don't explicitly handle SetCloseDownMode (RetainPermanent /
    /// RetainTemporary) — we always treat as DestroyAll. MUST be called on
    /// `protocolQueue` so the bridge's destroyTopLevel runs in the same
    /// thread context as session-state mutation.
    public func cleanupOnDisconnect() {
        // Revoke selection ownership held by ANY window this session created
        // (R6 dispatch.c:DeleteClientFromAnySelections). Without this,
        // GetSelectionOwner from another client would return a stale window
        // id, and ConvertSelection would forward a SelectionRequest into the
        // void. No SelectionClear emitted — the owner client is gone.
        let allIds = Set(windows.windows.keys)
        let revoked = coordinator.revokeSelections(ownedBy: allIds)
        if !revoked.isEmpty {
            log?.log("disconnect: revoked ownership of \(revoked.count) selection(s)")
        }
        // Pull this session's handlers off the bridge so dead-session
        // closures stop firing on every AppKit event. Safe even when
        // bridge is nil (test mode).
        bridge?.removeHandlers(token: bridgeHandlerToken)
        guard let bridge = bridge, let bo = byteOrder else { return }
        // Snapshot top-level ids first (mutating windows during walk would
        // be a bug). Top-levels = direct children of the root window.
        let topLevels = windows.windows
            .filter { $0.value.parent == config.rootWindowId }
            .map { $0.key }
        log?.log("disconnect: destroying \(topLevels.count) top-level window(s)")
        for id in topLevels {
            bridge.destroyTopLevel(
                id: id, byteOrder: bo,
                sequence: sequenceNumber, outbound: outbound
            )
            windows.remove(id)
        }
    }

    /// Drain any pending outbound bytes onto the wire via writeCallback.
    /// No-op in tests (writeCallback nil) — tests inspect bytes via
    /// `outbound.drain()` directly. MUST be called on `protocolQueue`.
    public func flushOutbound() {
        guard let callback = writeCallback else { return }
        let bytes = outbound.drain()
        if !bytes.isEmpty {
            callback(bytes)
        }
    }

    /// Decorate a raw WM_NAME-derived title with the wmInstance prefix when
    /// known. Result like "[xterm] $ ls" — prefix elided before WM_CLASS
    /// arrives so we don't end up with "[] foo".
    private func titleForDisplay(_ raw: String) -> String {
        guard let inst = wmInstance, !inst.isEmpty else { return raw }
        return "[\(inst)] \(raw)"
    }

    /// Parse a WM_CLASS property's bytes (two null-terminated strings:
    /// instance, class). Returns nil for the instance if the data is
    /// truncated or empty.
    private func parseWMClass(_ data: [UInt8]) -> (instance: String?, cls: String?) {
        var parts: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == 0 {
                parts.append(String(decoding: current, as: UTF8.self))
                current = []
                if parts.count == 2 { break }
            } else {
                current.append(byte)
            }
        }
        // If only one terminator was present, treat the trailing run as the
        // second field.
        if !current.isEmpty, parts.count < 2 {
            parts.append(String(decoding: current, as: UTF8.self))
        }
        let instance = parts.first?.isEmpty == false ? parts.first : nil
        let cls = parts.count >= 2 ? parts[1] : nil
        return (instance, cls)
    }

    /// Append client bytes; return any bytes the server should send back.
    /// May process multiple requests in one call if they all arrived in the
    /// same chunk. May process zero requests if the chunk is partial (e.g.
    /// half a request header) — those bytes stay buffered.
    ///
    /// Bytes are queued on `outbound` during dispatch (same place async events
    /// from other threads land). The return value is whatever was queued
    /// during this call plus anything else that happened to be sitting on the
    /// queue. Production callers should generally drain `outbound` directly
    /// rather than rely on this return value, but tests use it.
    public func feed(_ bytes: [UInt8]) -> [UInt8] {
        inbound.append(contentsOf: bytes)

        loop: while true {
            switch phase {
            case .awaitingSetup:
                guard let consumed = trySetup() else { break loop }
                inbound.removeFirst(consumed)
            case .running(let bo):
                guard let consumed = tryRequest(byteOrder: bo) else { break loop }
                inbound.removeFirst(consumed)
            }
        }
        return outbound.drain()
    }

    // MARK: - Setup

    private func trySetup() -> Int? {
        guard inbound.count >= 12 else { return nil }
        let order: ByteOrder
        switch inbound[0] {
        case 0x42: order = .msbFirst
        case 0x6C: order = .lsbFirst
        default:
            log?.log("setup: invalid byte-order marker 0x\(String(inbound[0], radix: 16))")
            // Can't proceed; close by signaling no progress and let the
            // transport decide. We keep the bytes around so the test can see
            // we made no output.
            return nil
        }

        let nameLen: Int
        let dataLen: Int
        switch order {
        case .lsbFirst:
            nameLen = Int(inbound[6]) | (Int(inbound[7]) << 8)
            dataLen = Int(inbound[8]) | (Int(inbound[9]) << 8)
        case .msbFirst:
            nameLen = (Int(inbound[6]) << 8) | Int(inbound[7])
            dataLen = (Int(inbound[8]) << 8) | Int(inbound[9])
        }
        let totalSize = 12 + nameLen + xPad(nameLen) + dataLen + xPad(dataLen)
        guard inbound.count >= totalSize else { return nil }

        do {
            _ = try SetupRequest.decode(from: Array(inbound[0..<totalSize]))
        } catch {
            log?.log("setup: decode failed: \(error)")
            return nil
        }

        let accepted = config.makeSetupAccepted()
        let bytes = SetupReply.accepted(accepted).encode(byteOrder: order)
        outbound.append(bytes)
        phase = .running(byteOrder: order)
        setupAcceptedSent = true
        log?.log("setup: accepted byteOrder=\(order)")
        return totalSize
    }

    // MARK: - Request loop

    private func tryRequest(byteOrder: ByteOrder) -> Int? {
        guard inbound.count >= 4 else { return nil }
        let lenIn4: UInt16
        switch byteOrder {
        case .lsbFirst: lenIn4 = UInt16(inbound[2]) | (UInt16(inbound[3]) << 8)
        case .msbFirst: lenIn4 = (UInt16(inbound[2]) << 8) | UInt16(inbound[3])
        }
        let totalSize = Int(lenIn4) * 4
        guard totalSize >= 4 else {
            // length=0 leaves us unable to advance the stream — we don't
            // know how many bytes to skip. Per spec we may emit BadLength
            // and close. Bump the sequence so the error carries a useful
            // value, emit, then ask the listener to tear us down via
            // shouldClose. Pre-2026-05-14 this just returned nil and
            // looped forever with the same wedge bytes at the front.
            sequenceNumber &+= 1
            log?.log("request: bogus length \(lenIn4) — emitting BadLength and closing")
            emitError(.length, majorOpcode: inbound[0])
            shouldClose = true
            return nil
        }
        guard inbound.count >= totalSize else { return nil }

        let bytes = Array(inbound[0..<totalSize])
        sequenceNumber &+= 1
        requestsProcessed += 1

        do {
            let request = try Request.decode(from: bytes, byteOrder: byteOrder)
            log?.log("req[\(sequenceNumber)] \(opcodeName(request))")
            dispatch(request, byteOrder: byteOrder)
        } catch {
            // Decode of a well-framed request failed — the length was sane,
            // the body wasn't. Per spec emit BadLength/BadValue and skip
            // the bad bytes; don't tear down the connection because the
            // stream is still synchronized after `totalSize`. The framer
            // throws on (a) truncated bodies (we already gated on
            // count >= totalSize), (b) invalid enum values inside known
            // request bodies — both map cleanest to BadValue, which is what
            // xorg's dispatch.c does in the equivalent path.
            log?.log("request: decode error opcode=\(bytes[0]) seq=\(sequenceNumber): \(error)")
            emitError(.value, majorOpcode: bytes[0])
        }
        return totalSize
    }

    // MARK: - Dispatch

    private func dispatch(_ request: Request, byteOrder: ByteOrder) {
        switch request {

        case .createWindow(let r):
            // BadWindow on bad parent. Root is a valid parent argument.
            guard validateWindowOrRoot(r.parent, majorOpcode: CreateWindow.opcode) else { break }
            // BadIDChoice on wid out of client range or already in use.
            if emitBadIDChoiceIfInvalid(r.wid, majorOpcode: CreateWindow.opcode) { break }
            // BadCursor on bad CWCursor value (sentinel 0 = None, OK).
            if let cursorVal = ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: CW.cursor, byteOrder: byteOrder),
               cursorVal != 0, cursors.glyph(cursorVal) == nil {
                emitError(.cursor, majorOpcode: CreateWindow.opcode, badResourceId: cursorVal)
                break
            }
            let mask = r.valueMask
            let read = { (bit: UInt32) -> UInt32? in
                ValueListReader.read(valueList: r.valueList, mask: mask, bit: bit, byteOrder: byteOrder)
            }
            let eventMask = read(CW.eventMask) ?? 0
            let backPixel = read(CW.backPixel)
            let borderPixel = read(CW.borderPixel)
            let cursor = read(CW.cursor)
            let overrideRedirect = (read(CW.overrideRedirect) ?? 0) != 0
            // All the other CW* fields (synthesis #6 "ChangeWindowAttributes
            // attribute drops"). Default values per X11 spec.
            let bitGravity = UInt8(truncatingIfNeeded: read(CW.bitGravity) ?? 0)        // Forget
            let winGravity = UInt8(truncatingIfNeeded: read(CW.winGravity) ?? 1)        // NorthWest
            let backingStore = UInt8(truncatingIfNeeded: read(CW.backingStore) ?? 0)    // NotUseful
            let backingPlanes = read(CW.backingPlanes) ?? ~UInt32(0)
            let backingPixel = read(CW.backingPixel) ?? 0
            let saveUnder = (read(CW.saveUnder) ?? 0) != 0
            let colormapRaw = read(CW.colormap)
            // CWColormap value 0 = CopyFromParent — store nil so the read
            // path can fall back to the inherited / default cmap.
            let colormap: UInt32? = (colormapRaw == 0) ? nil : colormapRaw
            let doNotPropagateMask = UInt16(truncatingIfNeeded: read(CW.dontPropagate) ?? 0)
            let entry = WindowEntry(
                id: r.wid, parent: r.parent, depth: r.depth,
                x: r.x, y: r.y, width: r.width, height: r.height,
                borderWidth: r.borderWidth, windowClass: r.windowClass, visual: r.visual,
                valueMask: mask, valueList: r.valueList,
                mapped: false, eventMask: eventMask,
                backPixel: backPixel,
                borderPixel: borderPixel,
                cursor: (cursor == 0) ? nil : cursor,
                overrideRedirect: overrideRedirect,
                bitGravity: bitGravity,
                winGravity: winGravity,
                backingStore: backingStore,
                backingPlanes: backingPlanes,
                backingPixel: backingPixel,
                saveUnder: saveUnder,
                colormap: colormap,
                doNotPropagateMask: doNotPropagateMask
            )
            windows.insert(entry)
            // Link into parent's sibling chain at the TOP — newly created
            // windows go above all existing siblings per X spec
            // ("MapWindow with no sibling specified, default Above"). No-op
            // for top-levels (root has no WindowEntry to anchor on);
            // AppKit handles inter-top-level stacking.
            SiblingChain.linkAtTop(r.wid, parent: r.parent, in: windows)
            let isTop = r.parent == config.rootWindowId
            log?.log("  CreateWindow wid=0x\(String(r.wid, radix: 16)) parent=0x\(String(r.parent, radix: 16)) \(r.width)x\(r.height) at (\(r.x),\(r.y)) bw=\(r.borderWidth) eventMask=0x\(String(eventMask, radix: 16)) topLevel=\(isTop) override=\(overrideRedirect)")
            // Register top-levels with the bridge. Both regular and
            // override-redirect get a slot — the override-redirect path
            // skips NSWindow chrome but the bridge still needs the slot
            // to (a) attach a backing context and view, (b) honor unmap
            // / orderOut later, (c) route drawing requests targeting the
            // popup's drawable id. Skipping registerTopLevel for
            // override-redirect previously meant slot(id) returned nil
            // and the popup never received drawings or its unmap.
            // Quickplot helper windows (1x1 / 5x5) are excluded by their
            // small size / non-mapping path; popups (real menus) come
            // up via MapWindow with override=true and DO need a slot.
            if isTop {
                bridge?.registerTopLevel(
                    id: r.wid,
                    geometry: TopLevelGeometry(
                        x: r.x, y: r.y, width: r.width, height: r.height,
                        borderWidth: r.borderWidth
                    ),
                    eventMask: eventMask
                )
            }
            // Per X11 spec section 10.5: CreateNotify is emitted to clients
            // with SubstructureNotifyMask on the parent. WMs use this to
            // notice new top-levels; deep-widget toolkits use it to track
            // children. Parent=root case is skipped because root isn't in
            // our windows table.
            let seq = sequenceNumber
            let parent = r.parent
            let wid = r.wid
            let cx = r.x, cy = r.y, cw = r.width, ch = r.height
            let cbw = r.borderWidth
            let cOR = overrideRedirect
            notifySubstructure(parent: parent) { eventTarget in
                CreateNotifyEvent(
                    sequenceNumber: seq, parent: eventTarget, window: wid,
                    x: cx, y: cy, width: cw, height: ch,
                    borderWidth: cbw, overrideRedirect: cOR
                ).encode(byteOrder: byteOrder)
            }

        case .changeWindowAttributes(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: ChangeWindowAttributes.opcode) else { break }
            if let newMask = ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: CW.eventMask, byteOrder: byteOrder) {
                if r.window == config.rootWindowId {
                    // Root has no WindowEntry; track its event mask
                    // separately so SubstructureNotify-on-root works.
                    rootEventMask = newMask
                } else {
                    windows.setEventMask(r.window, newMask)
                }
            }
            if let newBackPixel = ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: CW.backPixel, byteOrder: byteOrder) {
                windows.setBackPixel(r.window, newBackPixel)
                // If this is a top-level, push the new bg through to the
                // NSWindow.backgroundColor so live-resize stays in-color.
                if isTopLevel(r.window) {
                    bridge?.setTopLevelWindowBackground(
                        id: r.window, color: resolveColor(newBackPixel)
                    )
                }
            }
            if let newBorderPixel = ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: CW.borderPixel, byteOrder: byteOrder) {
                windows.setBorderPixel(r.window, newBorderPixel)
            }
            if let newCursor = ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: CW.cursor, byteOrder: byteOrder) {
                windows.setCursor(r.window, (newCursor == 0) ? nil : newCursor)
                // If the pointer is currently in a window whose effective
                // cursor just changed (this window or a descendant that
                // inherits from it), refresh the on-screen cursor without
                // waiting for the next pointer move. xterm flips its
                // top-level cursor mid-session via this path.
                refreshCursorIfPointerAffected(by: r.window)
            }
            // Mid-life CW* attribute writes (synthesis #6 "ChangeWindowAttributes
            // attribute drops" — shipped 2026-05-15). Each was previously
            // silently dropped on the write side AND returned as zero on the
            // read side. Now stored on the WindowEntry and echoed back by
            // GetWindowAttributes. None of these drive a rendering pipeline
            // change yet (backing-store, save-under, gravity, do-not-propagate
            // are accept-and-store stubs); colormap and override-redirect
            // mid-life flip are stored without invalidating dependent state.
            let cwRead = { (bit: UInt32) -> UInt32? in
                ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: bit, byteOrder: byteOrder)
            }
            if r.window != config.rootWindowId {
                if let v = cwRead(CW.overrideRedirect) {
                    windows.setOverrideRedirect(r.window, v != 0)
                }
                if let v = cwRead(CW.bitGravity) {
                    windows.setBitGravity(r.window, UInt8(truncatingIfNeeded: v))
                }
                if let v = cwRead(CW.winGravity) {
                    windows.setWinGravity(r.window, UInt8(truncatingIfNeeded: v))
                }
                if let v = cwRead(CW.backingStore) {
                    windows.setBackingStore(r.window, UInt8(truncatingIfNeeded: v))
                }
                if let v = cwRead(CW.backingPlanes) {
                    windows.setBackingPlanes(r.window, v)
                }
                if let v = cwRead(CW.backingPixel) {
                    windows.setBackingPixel(r.window, v)
                }
                if let v = cwRead(CW.saveUnder) {
                    windows.setSaveUnder(r.window, v != 0)
                }
                if let v = cwRead(CW.colormap) {
                    // 0 == CopyFromParent sentinel.
                    windows.setColormap(r.window, v == 0 ? nil : v)
                }
                if let v = cwRead(CW.dontPropagate) {
                    windows.setDoNotPropagateMask(r.window, UInt16(truncatingIfNeeded: v))
                }
            }
            // Per X11 spec: changing CWBackPixel / CWBorderPixel does NOT
            // trigger an automatic repaint. The new pixel takes effect on the
            // next ClearArea / Expose-driven repaint. An earlier version of
            // this handler repainted the whole window on every change; that
            // broke xterm's scroll pattern (xterm flips the bg pixel
            // temporarily around a 1-line ClearArea, and we'd repaint the
            // ENTIRE window each flip, wiping all scrolled content).

        case .destroyWindow(let r):
            guard let entry = validateWindow(r.window, majorOpcode: DestroyWindow.opcode) else { break }
            let wasTopLevel = isTopLevel(r.window)
            // Capture the containing top-level + parent BEFORE remove so we
            // can recompute clip regions and emit SubstructureNotify after.
            let preDestroyTopId = topLevelAndOffset(for: r.window)?.0
            let parentId = entry.parent

            // Per X11 spec, DestroyWindow recursively destroys all inferiors
            // in inferior-first (post-order) traversal and emits DestroyNotify
            // for each. Pre-2026-05-15 only the named window was destroyed,
            // leaving descendants orphaned in the table. Build the list now,
            // then sweep below before tearing down r.window itself.
            var doomedInferiors: [UInt32] = []
            func collectInferiors(of p: UInt32) {
                for (cid, w) in windows.windows where w.parent == p {
                    collectInferiors(of: cid)
                    doomedInferiors.append(cid)
                }
            }
            collectInferiors(of: r.window)

            let structureNotifyMask: UInt32 = 1 << 17
            let seq = sequenceNumber
            for id in doomedInferiors {
                guard let infEntry = windows.get(id) else { continue }
                coordinator.revokeSelections(ownedBy: [id])
                let infParent = infEntry.parent
                // Structure-variant DestroyNotify on the inferior itself
                // if it has StructureNotifyMask.
                if infEntry.eventMask & structureNotifyMask != 0 {
                    let ev = DestroyNotifyEvent(
                        sequenceNumber: seq, event: id, window: id
                    )
                    outbound.append(ev.encode(byteOrder: byteOrder))
                }
                // Substructure-variant DestroyNotify on the inferior's
                // parent. Skipped at the top of this loop when infParent
                // is r.window — but actually we still want it, since the
                // parent IS being destroyed but its SubstructureNotifyMask
                // may want to know its children died first. Spec says
                // emit; we'll do it. The parent's own destroy comes
                // after this loop, so events stay in inferior-first order.
                notifySubstructure(parent: infParent) { eventTarget in
                    DestroyNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: id
                    ).encode(byteOrder: byteOrder)
                }
                SiblingChain.unlink(id, in: windows)
                windows.remove(id)
                properties.deleteAll(window: id)
            }

            // Now r.window itself. (Bridge.destroyTopLevel emits the
            // structure-variant DestroyNotify for top-levels below; for
            // non-top-levels we don't currently emit a structure-variant
            // on the named window — only the substructure variant via
            // notifySubstructure. That's a pre-existing gap, not
            // introduced by inferior recursion. Leaving as-is.)
            coordinator.revokeSelections(ownedBy: [r.window])
            // Unlink from parent's sibling chain before removing the entry
            // itself. unlink() handles fixing both ends of every link
            // (firstChild/lastChild, prevSib/nextSib of neighbors).
            SiblingChain.unlink(r.window, in: windows)
            windows.remove(r.window)
            properties.deleteAll(window: r.window)
            if wasTopLevel {
                // destroyTopLevel emits DestroyNotify(event=window). The
                // root substructure variant fires too if a WM-style client
                // registered SubstructureNotifyMask on root via
                // ChangeWindowAttributes. We don't currently have any such
                // client but the path is spec-correct.
                bridge?.destroyTopLevel(
                    id: r.window, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
                let seq = sequenceNumber
                let dst = r.window
                notifySubstructure(parent: parentId) { eventTarget in
                    DestroyNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: dst
                    ).encode(byteOrder: byteOrder)
                }
            } else {
                if let topId = preDestroyTopId, topId != r.window {
                    ClipListEngine.recomputeClips(forTopLevel: topId, in: windows)
                    emitVisibilityChanges(forTopLevel: topId)
                }
                // Per X11 spec: parents with SubstructureNotifyMask receive
                // DestroyNotify with `event` = the parent. Without this,
                // toolkit code listening for child-destroyed events (e.g.,
                // Athena's destroy-callback chain) misses the destroy.
                let seq = sequenceNumber
                let dst = r.window
                notifySubstructure(parent: parentId) { eventTarget in
                    DestroyNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: dst
                    ).encode(byteOrder: byteOrder)
                }
            }

        case .mapWindow(let r):
            guard let preMapEntry = validateWindow(r.window, majorOpcode: MapWindow.opcode) else { break }
            // Per X11 spec section 10.5: "If the window is already mapped,
            // this request has no effect." Some Motif/Xt apps (quickplot
            // observed 2026-05-09) issue MapWindow twice during init; we
            // were creating a second NSWindow each time, hence the
            // duplicate-window-on-screen bug. Early-out if already mapped.
            if preMapEntry.mapped {
                break
            }
            windows.setMapped(r.window, true)
            // Recompute clipList BEFORE emitting events so the bridge can
            // pass per-window visible-rect lists into the Expose path.
            // Step E1 makes Expose enumerate clipList rects instead of
            // covering the full window — fully-covered descendants now
            // emit zero Expose events (the dt-Motif 248-Expose flood
            // collapses to per-leaf-widget counts).
            recomputeClipsForSubtreeContaining(r.window)
            let isTop = isTopLevel(r.window)
            let entry = windows.get(r.window)
            let isOverrideRedirect = entry?.overrideRedirect ?? false
            log?.log("  MapWindow window=0x\(String(r.window, radix: 16)) topLevel=\(isTop) override=\(isOverrideRedirect)")
            // override-redirect top-levels are popups (menus, tooltips,
            // drag indicators). They need a real NSWindow to be visible
            // and clickable — we just bring them up borderless +
            // non-activating + at popup-menu level so they float above
            // the main window without stealing focus and without WM
            // chrome. Skipping NSWindow creation entirely (the previous
            // behavior) made every Athena/Motif menu invisible: client
            // thinks it posted, server says yes, nothing on screen.
            if isTop {
                // WM emulation: pick a root position for this top-level on
                // first map, update WindowEntry, and tell the client via
                // ConfigureNotify before the bridge creates the NSWindow.
                // After this, the X-root coord we hand to the bridge for
                // NSWindow placement matches what the client now believes
                // its root position to be — so XTranslateCoordinates,
                // submenu placement math, button event root_x/root_y all
                // line up with what's actually on screen.
                placeTopLevelIfNeeded(id: r.window)
                let postPlaceEntry = windows.get(r.window)
                let descendants = mappedDescendantSnapshots(of: r.window)
                let topMask = postPlaceEntry?.eventMask ?? 0
                let topExposeRects = exposeRectsForWindow(r.window)
                let currentGeom = postPlaceEntry.map { TopLevelGeometry(
                    x: $0.x, y: $0.y,
                    width: $0.width, height: $0.height,
                    borderWidth: $0.borderWidth
                ) } ?? TopLevelGeometry(x: 0, y: 0, width: 1, height: 1, borderWidth: 0)
                bridge?.mapTopLevel(
                    id: r.window, geometry: currentGeom,
                    eventMask: topMask,
                    topLevelExposeRects: topExposeRects,
                    descendants: descendants,
                    overrideRedirect: isOverrideRedirect,
                    byteOrder: byteOrder, sequence: sequenceNumber,
                    outbound: outbound
                )
                // ICCCM 4.1.5: after MapNotify, the WM must send the client
                // a SYNTHETIC ConfigureNotify carrying the placed root
                // coordinates. Toolkits (Xt, Motif) cache widget root coords
                // at realization and only invalidate the cache on synthetic
                // events; without this, Motif's MenuBar hit-test computes
                // cascade-button rectangles in stale (pre-placement) root
                // coords, the cascade click falls "outside" every gadget,
                // and the popup never posts. Skip for override-redirect
                // popups (no WM intervenes in those).
                if !isOverrideRedirect, let placed = windows.get(r.window) {
                    let synth = ConfigureNotifyEvent(
                        sequenceNumber: sequenceNumber,
                        event: r.window, window: r.window, aboveSibling: 0,
                        x: placed.x, y: placed.y,
                        width: placed.width, height: placed.height,
                        borderWidth: placed.borderWidth,
                        overrideRedirect: false
                    )
                    outbound.append(synth.encode(byteOrder: byteOrder, synthetic: true))
                    log?.log("  → synthetic ConfigureNotify on 0x\(String(r.window, radix: 16)) at (\(placed.x),\(placed.y)) \(placed.width)x\(placed.height) (ICCCM 4.1.5)")
                }
                // Set the NSWindow.backgroundColor to match the X bg pixel
                // so live-resize doesn't flash a different color (white by
                // default) in the newly-exposed region before the next
                // draw cycle catches up.
                bridge?.setTopLevelWindowBackground(
                    id: r.window,
                    color: windowBackground(r.window, byteOrder: byteOrder)
                )
                // Paint top-level bg + every mapped descendant's bg. The
                // bridge dispatches paint to main async; mapTopLevel was
                // dispatched first so its view-creation block runs before
                // these paints, and the paints run before any client-driven
                // drawing (which arrives via the read thread → main FIFO).
                let paints = mappedBackgroundPaints(topLevelId: r.window, byteOrder: byteOrder)
                if !paints.isEmpty {
                    bridge?.paintWindowRects(topLevel: r.window, rects: paints)
                }
                // Root substructure notify for new top-level visibility
                // (fires only if a WM-style client registered
                // SubstructureNotifyMask on root).
                let seq = sequenceNumber
                let win = r.window
                let isOR = isOverrideRedirect
                notifySubstructure(parent: preMapEntry.parent) { eventTarget in
                    MapNotifyEvent(
                        sequenceNumber: seq, event: eventTarget,
                        window: win, overrideRedirect: isOR
                    ).encode(byteOrder: byteOrder)
                }
            } else {
                if let (top, dx, dy) = topLevelAndOffset(for: r.window),
                   let entry = windows.get(r.window) {
                    var rects = paintRectsForWindow(entry: entry, dx: dx, dy: dy, byteOrder: byteOrder)
                    // Cascade bg-paint to mapped descendants of r.window.
                    // When a non-top-level maps and its subtree was already
                    // mapped (the dthelpview pattern: children mapped before
                    // wrapper shell), the whole subtree transitions from
                    // "mapped but not viewable" to "viewable" simultaneously.
                    // Each newly-viewable descendant needs its bg painted —
                    // mirrors the 2026-05-19 Expose cascade. Without this,
                    // descendant areas show the fresh-bitmap default or
                    // whatever the bridge happened to paint previously,
                    // which only works by accident when the descendant's
                    // bg happens to match the default. The post-2026-05-20
                    // paintRectsForWindow already clips each window's bg
                    // to its clipList, so descendant paints land cleanly
                    // and never bleed into sub-descendants.
                    rects.append(contentsOf: descendantBgPaints(of: r.window, byteOrder: byteOrder))
                    if !rects.isEmpty {
                        bridge?.paintWindowRects(topLevel: top, rects: rects)
                    }
                }
                bridge?.mapDescendant(
                    id: r.window, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
                // Per X11 spec: parents with SubstructureNotifyMask receive
                // MapNotify(event=parent) when a child becomes viewable.
                // Toolkit code (Athena, Motif) uses this to redraw chrome
                // around newly-shown widgets. The bridge above emits the
                // event=window variant; emit the substructure variant here.
                let seq = sequenceNumber
                let win = r.window
                let isOR = isOverrideRedirect
                notifySubstructure(parent: preMapEntry.parent) { eventTarget in
                    MapNotifyEvent(
                        sequenceNumber: seq, event: eventTarget,
                        window: win, overrideRedirect: isOR
                    ).encode(byteOrder: byteOrder)
                }
                // Per X11 spec: a window that becomes viewable gets Expose
                // for its visible region if its event mask has
                // ExposureMask. Step E1: emit per-clipList-rect (in
                // window-local coords) instead of one full-rect event —
                // fully-covered descendants emit nothing.
                //
                // We also have to cascade Expose to the subtree under
                // r.window: when r.window becomes viewable, every
                // already-mapped descendant also transitions from
                // "mapped but not viewable" to "viewable" simultaneously
                // (viewability requires the WHOLE ancestor chain to be
                // mapped, per spec). Dthelpview hits this — it maps
                // children (DisplayArea, scrollbars) BEFORE mapping its
                // shell wrapper, so without the descendant cascade the
                // DisplayArea never gets the Expose it's waiting on and
                // the man-page content area renders blank.
                if let entry = windows.get(r.window),
                   entry.eventMask & (1 << 15) != 0 {
                    let rects = exposeRectsForWindow(r.window)
                    MockWindowBridge.emitExposesForRects(
                        window: r.window, rects: rects,
                        byteOrder: byteOrder, sequence: sequenceNumber,
                        outbound: outbound
                    )
                }
                for d in mappedDescendantSnapshots(of: r.window)
                where d.eventMask & MockWindowBridge.exposureMask != 0 {
                    MockWindowBridge.emitExposesForRects(
                        window: d.id, rects: d.exposeRects,
                        byteOrder: byteOrder, sequence: sequenceNumber,
                        outbound: outbound
                    )
                }
            }

        case .mapSubwindows(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: MapSubwindows.opcode) else { break }
            // Per X11 spec 10.5: "MapSubwindows performs a MapWindow request
            // on all unmapped children of the window, in top-to-bottom
            // stacking order." Two cases matter for paint-on-map:
            //
            // 1. Called BEFORE the top-level is mapped (xcalc's pattern):
            //    just mark + MapNotify. The bg paint + Expose land when the
            //    top-level itself maps and emitMapSequence walks descendants.
            //
            // 2. Called AFTER the top-level is mapped (dt-Motif's pattern —
            //    dtcalc / dtterm map their entire deep widget hierarchy this
            //    way via repeated MapSubwindows once the calculator panel is
            //    already on screen): we must do the bg paint + Expose right
            //    here, because there's no future top-level map to catch them.
            //    Without that, Motif PushButton/Gadget code never gets the
            //    Expose signal to draw shadow lines or button labels and
            //    every button stays invisible — verified 2026-05-10 against
            //    dtcalc rendering as a flat grey panel with only the LCD
            //    visible.
            let parentEntry = windows.get(r.window)
            let parentIsMapped = parentEntry?.mapped ?? false
            let topInfo = topLevelAndOffset(for: r.window)

            // Pass 1: mark each unmapped child mapped + emit MapNotify
            // (event=window) via the bridge, plus MapNotify(event=parent)
            // to r.window if it has SubstructureNotifyMask. The latter is
            // the chain Athena/Motif depend on to redraw container chrome
            // around newly-shown children.
            var newlyMapped: [UInt32] = []
            for (_, w) in windows.windows where w.parent == r.window && !w.mapped {
                windows.setMapped(w.id, true)
                bridge?.mapDescendant(
                    id: w.id, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
                let seq = sequenceNumber
                let childId = w.id
                let childOR = w.overrideRedirect
                notifySubstructure(parent: r.window) { eventTarget in
                    MapNotifyEvent(
                        sequenceNumber: seq, event: eventTarget,
                        window: childId, overrideRedirect: childOR
                    ).encode(byteOrder: byteOrder)
                }
                newlyMapped.append(w.id)
            }
            // Recompute clipList once for the whole batch — every
            // newly-mapped child now has its current visible region in
            // WindowEntry.clipList.
            recomputeClipsForSubtreeContaining(r.window)

            // Pass 2: paint bg + emit Expose for each newly-mapped child.
            // Step E1: Expose enumerates clipList rects in window-local
            // coords; fully-covered children emit zero Expose events.
            if parentIsMapped, let (top, _, _) = topInfo {
                for childId in newlyMapped {
                    guard let entry = windows.get(childId) else { continue }
                    let (_, dx, dy) = topLevelAndOffset(for: childId) ?? (top, 0, 0)
                    let rects = paintRectsForWindow(entry: entry, dx: dx, dy: dy, byteOrder: byteOrder)
                    if !rects.isEmpty {
                        bridge?.paintWindowRects(topLevel: top, rects: rects)
                    }
                    if entry.eventMask & (1 << 15) != 0 {
                        let exposeRects = exposeRectsForWindow(childId)
                        MockWindowBridge.emitExposesForRects(
                            window: childId, rects: exposeRects,
                            byteOrder: byteOrder, sequence: sequenceNumber,
                            outbound: outbound
                        )
                    }
                }
            }

        case .unmapWindow(let r):
            guard let entry = validateWindow(r.window, majorOpcode: UnmapWindow.opcode) else { break }
            let parentId = entry.parent
            // Capture the soon-to-be-unmapped child's borderClip. After
            // unmap + clip recompute that region becomes uncovered on the
            // parent and needs to be painted + Expose'd. Same shape as the
            // ConfigureWindow E1.5 path.
            let preUnmapBorderClip = entry.borderClip
            windows.setMapped(r.window, false)
            log?.log("  UnmapWindow window=0x\(String(r.window, radix: 16)) topLevel=\(isTopLevel(r.window))")
            if isTopLevel(r.window) {
                bridge?.unmapTopLevel(
                    id: r.window, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
                // Root substructure notify (only fires if a WM-style client
                // set SubstructureNotifyMask on root).
                let seq = sequenceNumber
                let dst = r.window
                notifySubstructure(parent: parentId) { eventTarget in
                    UnmapNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: dst,
                        fromConfigure: false
                    ).encode(byteOrder: byteOrder)
                }
            } else {
                // Descendant unmap: parents with SubstructureNotifyMask
                // receive UnmapNotify with event=parent. Real-WM toolkit
                // code uses this to redraw uncovered regions; without it,
                // the parent may render stale content under the (now hidden)
                // child.
                let seq = sequenceNumber
                let dst = r.window
                notifySubstructure(parent: parentId) { eventTarget in
                    UnmapNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: dst,
                        fromConfigure: false
                    ).encode(byteOrder: byteOrder)
                }
            }
            recomputeClipsForSubtreeContaining(r.window)
            // Repaint parent's bg over the area the child was occupying
            // (the captured borderClip — now uncovered) + emit Expose to
            // parent if it has ExposureMask. Mirrors the ConfigureWindow
            // E1.5 path. Skipped when the unmap was a top-level (parent
            // is root and not in the windows table) or borderClip was
            // already empty (window was unviewable).
            if !isTopLevel(r.window), !preUnmapBorderClip.isEmpty {
                repaintParentOverUncovered(
                    uncovered: preUnmapBorderClip,
                    parentId: parentId,
                    byteOrder: byteOrder
                )
            }

        case .configureWindow(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: ConfigureWindow.opcode) else { break }
            let mask = UInt32(r.valueMask)
            let x = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.x, byteOrder: byteOrder).map { Int16(truncatingIfNeeded: $0) }
            let y = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.y, byteOrder: byteOrder).map { Int16(truncatingIfNeeded: $0) }
            let w = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.width, byteOrder: byteOrder).map { UInt16(truncatingIfNeeded: $0) }
            let h = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.height, byteOrder: byteOrder).map { UInt16(truncatingIfNeeded: $0) }
            let stackModeRaw = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.stackMode, byteOrder: byteOrder).map { UInt8(truncatingIfNeeded: $0) }
            let siblingRaw = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.sibling, byteOrder: byteOrder)
            log?.log("  ConfigureWindow window=0x\(String(r.window, radix: 16)) mask=0x\(String(r.valueMask, radix: 16)) x=\(x.map(String.init) ?? "-") y=\(y.map(String.init) ?? "-") w=\(w.map(String.init) ?? "-") h=\(h.map(String.init) ?? "-") stackMode=\(stackModeRaw.map(String.init) ?? "-") sibling=\(siblingRaw.map { "0x" + String($0, radix: 16) } ?? "-")")

            // Apply stack-mode + sibling BEFORE geometry, mirroring R6's
            // dispatch.c order. Stack reordering is independent of move/
            // resize but affects what's visible after the configure, so
            // the subsequent clipList recompute sees the new chain order.
            // Skip for top-levels — root has no WindowEntry to anchor
            // firstChild/lastChild on; AppKit handles top-level stacking.
            var stackChanged = false
            if let mode = stackModeRaw,
               let entry = windows.get(r.window),
               windows.get(entry.parent) != nil {
                let priorPrev = entry.prevSib
                let priorNext = entry.nextSib
                if let sib = siblingRaw, sib != 0 {
                    // Spec BadMatch if sibling isn't actually a sibling
                    // (different parent) or doesn't exist.
                    guard let sibEntry = windows.get(sib),
                          sibEntry.parent == entry.parent else {
                        emitError(.match, majorOpcode: ConfigureWindow.opcode, badResourceId: sib)
                        break
                    }
                    SiblingChain.unlink(r.window, in: windows)
                    switch mode {
                    case 0:     // Above sibling → id goes directly above sibling
                        SiblingChain.linkAbove(r.window, sibling: sib, in: windows)
                    case 1:     // Below sibling → id goes directly below sibling
                        if let nextOfSib = sibEntry.nextSib {
                            SiblingChain.linkAbove(r.window, sibling: nextOfSib, in: windows)
                        } else {
                            SiblingChain.linkAtBottom(r.window, parent: entry.parent, in: windows)
                        }
                    case 2, 3, 4:
                        // TopIf / BottomIf / Opposite need rectangle-occlusion
                        // tests we don't yet implement. Approximation:
                        // Above-semantics, which preserves the "ensure
                        // visibility" intent for the common case. Logged
                        // for visibility; revisit when a client we host
                        // actually exercises these.
                        log?.log("  ConfigureWindow stackMode=\(mode) (TopIf/BottomIf/Opposite) approximated as Above")
                        SiblingChain.linkAbove(r.window, sibling: sib, in: windows)
                    default:
                        emitError(.value, majorOpcode: ConfigureWindow.opcode)
                        break
                    }
                } else {
                    SiblingChain.unlink(r.window, in: windows)
                    switch mode {
                    case 0:     // Above (no sibling) → top of stack
                        SiblingChain.linkAtTop(r.window, parent: entry.parent, in: windows)
                    case 1:     // Below (no sibling) → bottom of stack
                        SiblingChain.linkAtBottom(r.window, parent: entry.parent, in: windows)
                    case 2, 3, 4:
                        // Same approximation as above. TopIf without a
                        // sibling means "if any sibling occludes me, go
                        // top"; we just go to top.
                        log?.log("  ConfigureWindow stackMode=\(mode) (no sibling) approximated as Above")
                        SiblingChain.linkAtTop(r.window, parent: entry.parent, in: windows)
                    default:
                        emitError(.value, majorOpcode: ConfigureWindow.opcode)
                        break
                    }
                }
                let nowEntry = windows.get(r.window)
                stackChanged = (nowEntry?.prevSib != priorPrev) || (nowEntry?.nextSib != priorNext)
            } else if let sib = siblingRaw, sib != 0, stackModeRaw == nil {
                // Spec BadMatch: CWSibling without CWStackMode is invalid.
                emitError(.match, majorOpcode: ConfigureWindow.opcode, badResourceId: sib)
                break
            }

            // E1.5: capture pre-move state so we can compute the area of
            // parent newly uncovered by this window's move/resize.
            let preMoveBorderClip = windows.get(r.window)?.borderClip ?? .empty
            let preMoveParent = windows.get(r.window)?.parent
            let result = windows.resize(r.window, width: w, height: h, x: x, y: y)
            if let (old, new) = result, let entry = windows.get(r.window) {
                if entry.parent != config.rootWindowId {
                    bridge?.descendantResized(
                        id: r.window, parent: entry.parent,
                        geometry: TopLevelGeometry(
                            x: entry.x, y: entry.y,
                            width: entry.width, height: entry.height,
                            borderWidth: entry.borderWidth
                        )
                    )
                }
                let sizeChanged = old.width != new.width || old.height != new.height
                let posChanged = old.x != new.x || old.y != new.y
                // Per X11 spec: emit ConfigureNotify if the configuration
                // actually changed, on every window with StructureNotifyMask
                // set in its event mask. xterm's Xt geometry manager waits
                // for this synchronous confirmation before completing widget
                // realization — without it, Xt does a probing ping-pong
                // resize that wipes xterm's screen buffer.
                let structureNotifyMask: UInt32 = 1 << 17
                if sizeChanged || posChanged || stackChanged {
                    // aboveSibling per X spec: "the sibling immediately
                    // above this window, or None (0) if topmost". That's
                    // prevSib in our chain orientation. For top-levels
                    // (parent isn't in the table) it's 0.
                    let aboveSibling: UInt32 = windows.get(r.window)?.prevSib ?? 0
                    // StructureNotify variant on the window itself.
                    if entry.eventMask & structureNotifyMask != 0 {
                        log?.log("  → emit ConfigureNotify on 0x\(String(r.window, radix: 16)) \(new.width)x\(new.height) at (\(new.x),\(new.y)) above=0x\(String(aboveSibling, radix: 16))")
                        let cfgEv = ConfigureNotifyEvent(
                            sequenceNumber: sequenceNumber,
                            event: r.window, window: r.window, aboveSibling: aboveSibling,
                            x: new.x, y: new.y,
                            width: new.width, height: new.height,
                            borderWidth: new.borderWidth,
                            overrideRedirect: false
                        )
                        outbound.append(cfgEv.encode(byteOrder: byteOrder))
                    }
                    // SubstructureNotify variant on the parent. Athena/Motif
                    // geometry managers use this to know "my child changed
                    // size, time to re-layout siblings."
                    let seq = sequenceNumber
                    let win = r.window
                    let nx = new.x, ny = new.y, nw = new.width, nh = new.height
                    let nbw = new.borderWidth
                    notifySubstructure(parent: entry.parent) { eventTarget in
                        ConfigureNotifyEvent(
                            sequenceNumber: seq, event: eventTarget,
                            window: win, aboveSibling: aboveSibling,
                            x: nx, y: ny,
                            width: nw, height: nh,
                            borderWidth: nbw,
                            overrideRedirect: false
                        ).encode(byteOrder: byteOrder)
                    }
                }
                // Recompute clipList NOW so the new visible regions drive
                // both the E1.5 parent-repaint pass and the E2 size-grow
                // Expose emission below.
                recomputeClipsForSubtreeContaining(r.window)

                // E1.5: if a non-top-level window moved/resized, the
                // parent has newly-uncovered area where this window used
                // to be. Paint parent's bg over that delta and emit
                // Expose to parent. Retires the "Descendant geometry
                // change leaves stale pixels on parent" SHORTCUT.
                if (sizeChanged || posChanged),
                   let parentId = preMoveParent,
                   parentId != config.rootWindowId {
                    let postMoveBorderClip = windows.get(r.window)?.borderClip ?? .empty
                    let uncovered = preMoveBorderClip.subtracting(postMoveBorderClip)
                    if !uncovered.isEmpty {
                        repaintParentOverUncovered(
                            uncovered: uncovered, parentId: parentId,
                            byteOrder: byteOrder
                        )
                    }
                }

                // Per X11 server contract (mi/mfb): when a window grows or
                // moves, the server paints the window's bg-pixel into the
                // newly-claimed visible region BEFORE the client gets the
                // Expose. The client only paints content on top; the bg
                // is the server's responsibility on every visibility
                // transition. Without this, the newly-claimed pixels stay
                // as whatever the bitmap had — the dthelpview 2026-05-20
                // bug where the form's bg was blue but the L-shape of
                // grown pixels stayed fresh-bitmap-white because we never
                // painted them. Phase 1 paints the FULL new clipList
                // (matches bit-grav=Forget semantics); for bit-grav=
                // NorthWest windows with content this over-paints, but
                // the subsequent Expose triggers the client to redraw on
                // top. Step F (when it lands) will refine to paint only
                // the (new clipList - old clipList) delta.
                let sizeGrew = new.width > old.width || new.height > old.height
                if sizeGrew || posChanged {
                    if let (top, dx, dy) = topLevelAndOffset(for: r.window),
                       let postEntry = windows.get(r.window) {
                        let rects = paintRectsForWindow(entry: postEntry, dx: dx, dy: dy, byteOrder: byteOrder)
                        if !rects.isEmpty {
                            bridge?.paintWindowRects(topLevel: top, rects: rects)
                        }
                    }
                }
                // E2: emit Expose using clipList rects when the window's
                // size grew. clipList ∩ (new - old) would be exact; using
                // clipList alone is a defensible over-emit (already-
                // painted pixels get re-Exposed but clients redraw
                // idempotently). Step F refines this with proper region
                // delta math.
                if sizeGrew && (entry.eventMask & MockWindowBridge.exposureMask != 0) {
                    log?.log("  → emit Expose on 0x\(String(r.window, radix: 16)) \(new.width)x\(new.height)")
                    let rects = exposeRectsForWindow(r.window)
                    MockWindowBridge.emitExposesForRects(
                        window: r.window, rects: rects,
                        byteOrder: byteOrder, sequence: sequenceNumber,
                        outbound: outbound
                    )
                }
            } else if stackChanged, let entry = windows.get(r.window) {
                // Stack-only change (no geometry mutation). Still need to
                // emit ConfigureNotify per spec and recompute clips so
                // overlap-affected siblings get correct visibility.
                let structureNotifyMask: UInt32 = 1 << 17
                let aboveSibling: UInt32 = entry.prevSib ?? 0
                if entry.eventMask & structureNotifyMask != 0 {
                    log?.log("  → emit ConfigureNotify on 0x\(String(r.window, radix: 16)) stack-only above=0x\(String(aboveSibling, radix: 16))")
                    let cfgEv = ConfigureNotifyEvent(
                        sequenceNumber: sequenceNumber,
                        event: r.window, window: r.window,
                        aboveSibling: aboveSibling,
                        x: entry.x, y: entry.y,
                        width: entry.width, height: entry.height,
                        borderWidth: entry.borderWidth,
                        overrideRedirect: false
                    )
                    outbound.append(cfgEv.encode(byteOrder: byteOrder))
                }
                let seq = sequenceNumber
                let win = r.window
                let ex = entry.x, ey = entry.y, ew = entry.width, eh = entry.height, ebw = entry.borderWidth
                notifySubstructure(parent: entry.parent) { eventTarget in
                    ConfigureNotifyEvent(
                        sequenceNumber: seq, event: eventTarget,
                        window: win, aboveSibling: aboveSibling,
                        x: ex, y: ey, width: ew, height: eh,
                        borderWidth: ebw,
                        overrideRedirect: false
                    ).encode(byteOrder: byteOrder)
                }
                // Recompute clips: stack reorder changes who occludes whom.
                recomputeClipsForSubtreeContaining(r.window)
            }

        case .internAtom(let r):
            let name = String(decoding: r.name, as: UTF8.self)
            let atom = r.onlyIfExists ? atoms.lookupOrZero(name) : atoms.intern(name)
            let reply = InternAtomReply(sequenceNumber: sequenceNumber, atom: atom)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .changeProperty(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: ChangeProperty.opcode) else { break }
            // Property must be a valid atom (cannot be None=0). Type is a
            // type atom — spec doesn't allow None either, but we accept
            // type=0 as an effective no-op type tag since clients almost
            // never do that and the resulting property reads back with
            // type=0 (caller's choice).
            guard validateAtom(r.property, majorOpcode: ChangeProperty.opcode) else { break }
            if r.type != 0 {
                guard validateAtom(r.type, majorOpcode: ChangeProperty.opcode) else { break }
            }
            let changeResult = properties.change(
                window: r.window, property: r.property, type: r.type,
                format: r.format.rawValue, mode: r.mode.rawValue, value: r.data
            )
            if changeResult == .mismatch {
                // Spec 10.10: BadMatch on Prepend/Append when request's
                // type or format doesn't match the existing entry's. The
                // entry is left untouched; no PropertyNotify.
                emitError(.match, majorOpcode: ChangeProperty.opcode)
                break
            }
            // Per X11 spec section 10.10: ChangeProperty emits PropertyNotify
            // with state=NewValue to clients with PropertyChangeMask on the
            // window (atom 1<<22 in eventMask). Xt's PROPERTY_CHANGE_TIMESTAMP
            // mechanism listens for these to capture a fresh server timestamp.
            emitPropertyNotify(window: r.window, atom: r.property, state: .newValue, byteOrder: byteOrder)
            // WM_NAME or WM_ICON_NAME (39 / 37) → push to NSWindow title.
            // Strip trailing nulls — real Xlib clients sometimes include the
            // C string terminator in the property data, sometimes not.
            // When wmInstance is known, prefix it ([xterm], [xcalc], …) so
            // the user can tell at a glance which X client owns the window.
            if r.property == 39 || r.property == 37 {
                let trimmed = r.data.prefix(while: { $0 != 0 })
                let title = String(decoding: trimmed, as: UTF8.self)
                bridge?.setTopLevelTitle(id: r.window, title: titleForDisplay(title))
            }
            // WM_CLASS lands as two null-terminated strings: instance + class.
            // First sighting identifies the client — rename the per-session
            // log file (via onIdentified) and re-emit the window title with
            // the new prefix so a window mapped before WM_CLASS still gets
            // updated.
            if r.property == atoms.lookupOrZero("WM_CLASS"), wmInstance == nil {
                let parts = parseWMClass(r.data)
                if let inst = parts.instance {
                    wmInstance = inst
                    wmClass = parts.cls
                    log?.log("WM_CLASS: instance=\"\(inst)\" class=\"\(parts.cls ?? "")\"")
                    onIdentified?(inst, parts.cls ?? "")
                    // Re-emit the title for this window if it already has
                    // a WM_NAME stored — apply the new [instance] prefix.
                    if let nameEntry = properties.get(window: r.window, property: 39) {
                        let trimmed = nameEntry.value.prefix(while: { $0 != 0 })
                        let title = String(decoding: trimmed, as: UTF8.self)
                        bridge?.setTopLevelTitle(id: r.window, title: titleForDisplay(title))
                    }
                }
            }
            // Selection roundtrip arrival: the owner just ChangeProperty'd
            // the converted text into our sink window. Push to NSPasteboard
            // and clear the property so we don't trip on stale data on the
            // next copy. X STRING type is ISO-8859-1 (Latin-1).
            if r.window == selectionSinkWindow,
               r.property == atoms.lookupOrZero(selectionSinkPropertyName) {
                let text = String(bytes: r.data, encoding: .isoLatin1) ?? ""
                log?.log("  copy: received \(r.data.count) bytes from selection owner — writing NSPasteboard")
                bridge?.writeClipboard(text: text)
                properties.delete(window: r.window, property: r.property)
            }

        case .deleteProperty(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: DeleteProperty.opcode) else { break }
            guard validateAtom(r.property, majorOpcode: DeleteProperty.opcode) else { break }
            // Per spec: PropertyNotify with state=Deleted fires only if the
            // property actually existed before the delete.
            let existed = properties.get(window: r.window, property: r.property) != nil
            properties.delete(window: r.window, property: r.property)
            if existed {
                emitPropertyNotify(window: r.window, atom: r.property, state: .deleted, byteOrder: byteOrder)
            }

        case .getProperty(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: GetProperty.opcode) else { break }
            guard validateAtom(r.property, majorOpcode: GetProperty.opcode) else { break }
            // r.type = 0 means AnyPropertyType per spec — skip validation.
            if r.type != 0 {
                guard validateAtom(r.type, majorOpcode: GetProperty.opcode) else { break }
            }
            let reply: GetPropertyReply
            let existing = properties.get(window: r.window, property: r.property)
            log?.log("  GetProperty win=0x\(String(r.window, radix: 16)) prop=\(r.property) (\(atoms.name(for: r.property) ?? "?")) → \(existing.map { "\($0.value.count) bytes" } ?? "empty")")
            if let entry = existing {
                reply = GetPropertyReply(
                    sequenceNumber: sequenceNumber,
                    format: entry.format,
                    type: entry.type,
                    bytesAfter: 0,
                    value: entry.value
                )
            } else {
                reply = GetPropertyReply.empty(sequenceNumber: sequenceNumber)
            }
            outbound.append(reply.encode(byteOrder: byteOrder))
            // Per X11 spec: when delete=True and the property existed, the
            // property is removed after the reply and PropertyNotify(state=
            // Deleted) is emitted (only when the type matched or AnyType
            // was requested — our reply ignores the type filter today, so
            // the simpler rule "existed → delete + notify" is what we
            // implement).
            if r.delete, existing != nil {
                properties.delete(window: r.window, property: r.property)
                emitPropertyNotify(window: r.window, atom: r.property, state: .deleted, byteOrder: byteOrder)
            }

        case .openFont(let r):
            // BadIDChoice on fid out of client range or already in use.
            // We always resolve some font (FontResolver falls back to a
            // default), so BadName isn't a real outcome for us — even
            // unknown XLFD strings find a Mac substitute. Empty name
            // strings would be BadValue per spec; the resolver tolerates
            // them too. Leave that as a future tightening.
            if emitBadIDChoiceIfInvalid(r.fid, majorOpcode: OpenFont.opcode) { break }
            // Parse the font name (XLFD or alias), resolve to a Mac substitute
            // with cell-snapped metrics. Stored on the FontEntry so QueryFont
            // and any future text-rendering dispatch can answer without
            // re-parsing.
            let nameStr = String(decoding: r.name, as: UTF8.self)
            let resolved = FontResolver.resolve(name: nameStr)
            fonts.insert(FontEntry(id: r.fid, name: r.name, resolved: resolved))
            log?.log("  OpenFont fid=0x\(String(r.fid, radix: 16)) \"\(nameStr)\" → \(resolved.macFontName) pt=\(resolved.pointSize) cell=\(resolved.cellWidth)x\(resolved.cellHeight) asc=\(resolved.ascent) desc=\(resolved.descent) charset=\(resolved.charsetRegistry)-\(resolved.charsetEncoding)")

        case .closeFont(let r):
            guard fonts.get(r.font) != nil else {
                emitError(.font, majorOpcode: CloseFont.opcode, badResourceId: r.font)
                break
            }
            fonts.remove(r.font)

        case .queryFont(let r):
            // Look up the font and answer with cell-snapped metrics derived
            // from the resolved Mac substitute. Per
            // SERVER_RESOLUTION_SCALING_AND_FONTS.md "critical invariant":
            // the metrics we report must match what we actually render.
            // Unknown font → BadFont; previous fallback-to-"fixed" was a
            // lie that hid use-after-free / never-opened bugs.
            guard let entry = fonts.get(r.font) else {
                emitError(.font, majorOpcode: QueryFont.opcode, badResourceId: r.font)
                break
            }
            let reply = makeQueryFontReply(resolved: entry.resolved, sequence: sequenceNumber)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryTextExtents(let r):
            // Motif's CascadeButton uses this to measure menu-title labels
            // during XmRowColumn layout. Pre-2026-05-15 this fell through
            // to BadRequest and Motif fell back to a default-width estimate
            // that produced visibly-misaligned menu titles. Per spec,
            // unknown font → BadFont.
            guard let entry = fonts.get(r.fid) else {
                emitError(.font, majorOpcode: QueryTextExtents.opcode, badResourceId: r.fid)
                break
            }
            // CHAR2B chars are 2 bytes each, MSB first per X spec
            // (independent of the connection byte-order). Decode to
            // UniChar then ask Core Text for actual per-glyph advances —
            // critical for proportional fonts (Helvetica, Times) where
            // a per-char width is the wrong answer. Same code path
            // PolyText8 / ImageText8 use to actually draw, so the
            // reported width matches the rendered width.
            var characters: [UniChar] = []
            characters.reserveCapacity(r.stringBytes.count / 2)
            var i = 0
            while i + 1 < r.stringBytes.count {
                let hi = UInt16(r.stringBytes[i])
                let lo = UInt16(r.stringBytes[i + 1])
                characters.append((hi << 8) | lo)
                i += 2
            }
            let resolved = entry.resolved
            let overallWidth = FontResolver.measureTextWidth(resolved, characters: characters)
            let reply = QueryTextExtentsReply(
                sequenceNumber: sequenceNumber,
                drawDirection: 0,         // LeftToRight
                fontAscent: Int16(truncatingIfNeeded: resolved.ascent),
                fontDescent: Int16(truncatingIfNeeded: resolved.descent),
                overallAscent: Int16(truncatingIfNeeded: resolved.ascent),
                overallDescent: Int16(truncatingIfNeeded: resolved.descent),
                overallWidth: overallWidth,
                overallLeft: 0,
                overallRight: overallWidth
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .createPixmap(let r):
            // BadDrawable on bad drawable arg (per spec, drawable supplies
            // the pixmap's screen). Root is acceptable.
            if !isKnownDrawable(r.drawable) {
                emitError(.drawable, majorOpcode: CreatePixmap.opcode, badResourceId: r.drawable)
                break
            }
            // BadValue on depth=0 (per spec; zero is not a valid depth).
            if r.depth == 0 {
                emitError(.value, majorOpcode: CreatePixmap.opcode)
                break
            }
            // BadIDChoice on pid out of client range or already in use.
            if emitBadIDChoiceIfInvalid(r.pid, majorOpcode: CreatePixmap.opcode) { break }
            pixmaps.allocate(id: r.pid, drawable: r.drawable, depth: r.depth, width: r.width, height: r.height)

        case .freePixmap(let r):
            guard pixmaps.get(r.pixmap) != nil else {
                emitError(.pixmap, majorOpcode: FreePixmap.opcode, badResourceId: r.pixmap)
                break
            }
            pixmaps.remove(r.pixmap)

        case .createGC(let r):
            // BadDrawable on bad drawable arg (drawable supplies the GC's
            // screen + depth). BadIDChoice on cid out of range or in use.
            if !isKnownDrawable(r.drawable) {
                emitError(.drawable, majorOpcode: CreateGC.opcode, badResourceId: r.drawable)
                break
            }
            if emitBadIDChoiceIfInvalid(r.cid, majorOpcode: CreateGC.opcode) { break }
            gcs.insert(id: r.cid, drawable: r.drawable, valueMask: r.valueMask, valueList: r.valueList, byteOrder: byteOrder)

        case .changeGC(let r):
            guard validateGC(r.gc, majorOpcode: ChangeGC.opcode) != nil else { break }
            gcs.change(r.gc, valueMask: r.valueMask, valueList: r.valueList, byteOrder: byteOrder)

        case .freeGC(let r):
            guard validateGC(r.gc, majorOpcode: FreeGC.opcode) != nil else { break }
            gcs.remove(r.gc)

        // MARK: Colormap opcodes 78-90 (post-comparison-study sweep 2026-05-15)
        //
        // We only advertise the default colormap. PseudoColor → TrueColor
        // backing means no real palette: writable cells aren't supported,
        // colormap allocation isn't real. Emitting the spec-correct error
        // (BadAlloc for "we can't allocate", BadAccess for "writable but
        // not by you", BadColor for "no such colormap") lets Xt's color-
        // converter fallback paths degrade gracefully.

        case .createColormap(let r):
            // We don't allocate additional colormaps. BadAlloc says
            // "server out of resources" which is honest.
            log?.log("  CreateColormap mid=0x\(String(r.mid, radix: 16)) alloc=\(r.alloc) → BadAlloc")
            emitError(.alloc, majorOpcode: CreateColormap.opcode, badResourceId: r.mid)

        case .freeColormap(let r):
            if r.cmap == config.defaultColormapId {
                // Per spec, the root's default colormap cannot be freed.
                emitError(.access, majorOpcode: FreeColormap.opcode, badResourceId: r.cmap)
                break
            }
            emitError(.color, majorOpcode: FreeColormap.opcode, badResourceId: r.cmap)

        case .copyColormapAndFree(let r):
            if r.srcCmap != config.defaultColormapId {
                emitError(.color, majorOpcode: CopyColormapAndFree.opcode, badResourceId: r.srcCmap)
                break
            }
            // Source is valid but we can't allocate the destination.
            emitError(.alloc, majorOpcode: CopyColormapAndFree.opcode, badResourceId: r.mid)

        case .installColormap(let r):
            // No-op when cmap is the default (already "installed");
            // BadColor otherwise. Real impl would also emit
            // ColormapNotify(installed=true) when something actually
            // changes. Here nothing changes.
            if r.cmap != config.defaultColormapId {
                emitError(.color, majorOpcode: InstallColormap.opcode, badResourceId: r.cmap)
            }

        case .uninstallColormap(let r):
            if r.cmap != config.defaultColormapId {
                emitError(.color, majorOpcode: UninstallColormap.opcode, badResourceId: r.cmap)
            }
            // Uninstalling the default is a no-op in our model (it's
            // always effectively installed since we have only one).

        case .listInstalledColormaps(let r):
            // We always have exactly one colormap installed (the default).
            // Spec says reply lists colormaps currently mapped on the
            // screen's hardware lookup table; with a TrueColor backing
            // the concept doesn't really apply, but spec-correct reply
            // is required by clients that consult it.
            guard validateWindowOrRoot(r.window, majorOpcode: ListInstalledColormaps.opcode) else { break }
            let reply = ListInstalledColormapsReply(
                sequenceNumber: sequenceNumber,
                colormaps: [config.defaultColormapId]
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .allocColorPlanes(let r):
            // Same as AllocColorCells: no read-write planes on TrueColor.
            // BadAlloc is the right semantic for Xt fallback.
            log?.log("  AllocColorPlanes cmap=0x\(String(r.cmap, radix: 16)) colors=\(r.colors) rgb=\(r.red)/\(r.green)/\(r.blue) → BadAlloc")
            emitError(.alloc, majorOpcode: AllocColorPlanes.opcode, badResourceId: r.cmap)

        case .freeColors(let r):
            // FreeColors is the inverse of AllocColor — releases pixels.
            // We track pixel allocations with a monotonic counter, no
            // reference counting yet. Accepting silently on the default
            // cmap (the client's allocation will eventually be reused
            // because we don't recycle anyway). BadColor otherwise.
            if r.cmap != config.defaultColormapId {
                emitError(.color, majorOpcode: FreeColors.opcode, badResourceId: r.cmap)
            }

        case .storeColors(let r):
            // Spec: StoreColors writes RGB values into specific colormap
            // cells. Requires the cells to have been allocated read-write
            // via AllocColorCells/AllocColorPlanes — neither of which we
            // honor. Per spec, attempting to store into a cell the client
            // doesn't own r/w is BadAccess. (BadColor on bad cmap.)
            if r.cmap != config.defaultColormapId {
                emitError(.color, majorOpcode: StoreColors.opcode, badResourceId: r.cmap)
                break
            }
            emitError(.access, majorOpcode: StoreColors.opcode)

        case .storeNamedColor(let r):
            if r.cmap != config.defaultColormapId {
                emitError(.color, majorOpcode: StoreNamedColor.opcode, badResourceId: r.cmap)
                break
            }
            emitError(.access, majorOpcode: StoreNamedColor.opcode)

        case .allocColor(let r):
            // BadColor on cmap arg that isn't a known colormap. We only
            // advertise the default colormap; anything else is BadColor.
            if r.cmap != config.defaultColormapId {
                emitError(.color, majorOpcode: AllocColor.opcode, badResourceId: r.cmap)
                break
            }
            let allocated = colors.allocate(red: r.red, green: r.green, blue: r.blue)
            let reply = AllocColorReply(
                sequenceNumber: sequenceNumber,
                red: allocated.allocated.red,
                green: allocated.allocated.green,
                blue: allocated.allocated.blue,
                pixel: allocated.pixel
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .allocNamedColor(let r):
            // Resolve the X color name (or #hex spec) against the embedded
            // X11R6 rgb.txt database, allocate a pixel, and reply. Unknown
            // names fall back to black with a warning — we don't emit XErrors
            // yet (per SHORTCUTS), so this keeps clients moving rather than
            // hanging on a missing reply.
            let rgb: RGB16
            if let resolved = XColorDatabase.lookup(bytes: r.name) {
                rgb = resolved
            } else {
                let nameStr = String(bytes: r.name, encoding: .ascii) ?? "<binary>"
                log?.log("AllocNamedColor: unknown name \"\(nameStr)\", falling back to black")
                rgb = RGB16(red: 0, green: 0, blue: 0)
            }
            let allocated = colors.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
            let reply = AllocNamedColorReply(
                sequenceNumber: sequenceNumber,
                pixel: allocated.pixel,
                exactRed: rgb.red, exactGreen: rgb.green, exactBlue: rgb.blue,
                visualRed: rgb.red, visualGreen: rgb.green, visualBlue: rgb.blue
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .lookupColor(let r):
            // Same name resolution as AllocNamedColor but doesn't allocate a
            // pixel. xterm uses this for `-fg <name>` when it intends to do
            // its own AllocColor on the resolved RGB.
            let rgb: RGB16
            if let resolved = XColorDatabase.lookup(bytes: r.name) {
                rgb = resolved
            } else {
                let nameStr = String(bytes: r.name, encoding: .ascii) ?? "<binary>"
                log?.log("LookupColor: unknown name \"\(nameStr)\", falling back to black")
                rgb = RGB16(red: 0, green: 0, blue: 0)
            }
            let reply = LookupColorReply(
                sequenceNumber: sequenceNumber,
                exactRed: rgb.red, exactGreen: rgb.green, exactBlue: rgb.blue,
                visualRed: rgb.red, visualGreen: rgb.green, visualBlue: rgb.blue
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getInputFocus:
            // Default focus on a fresh X connection is PointerRoot (1), not
            // None (0). Returning None made Motif's translation engine treat
            // the client as un-focused and silently refuse to dispatch widget
            // callbacks (verified 2026-05-09 against quickplot from SS2 — the
            // app rendered, click events landed at the right widget, but no
            // callbacks fired and no follow-up X requests came back). If a
            // SetInputFocus has explicitly set a focus window, return that;
            // otherwise PointerRoot, with revert-to=Parent matching what real
            // Xsun returns by default.
            let focusValue: UInt32 = focusWindow ?? 1   // 1 == PointerRoot
            let reply = GetInputFocusReply(
                sequenceNumber: sequenceNumber,
                revertTo: .parent,
                focus: focusValue
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryExtension:
            let reply = QueryExtensionReply(
                sequenceNumber: sequenceNumber,
                present: false, majorOpcode: 0, firstEvent: 0, firstError: 0
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .polySegment(let r):
            handlePolySegment(r, byteOrder: byteOrder)

        case .polyLine(let r):
            handlePolyLine(r, byteOrder: byteOrder)

        case .polyPoint(let r):
            handlePolyPoint(r, byteOrder: byteOrder)

        case .fillPoly(let r):
            handleFillPoly(r, byteOrder: byteOrder)

        case .clearArea(let r):
            handleClearArea(r, byteOrder: byteOrder)

        case .polyFillRectangle(let r):
            handlePolyFillRectangle(r, byteOrder: byteOrder)

        case .polyRectangle(let r):
            handlePolyRectangle(r, byteOrder: byteOrder)

        case .imageText8(let r):
            handleImageText8(r, byteOrder: byteOrder)

        case .polyText8(let r):
            handlePolyText8(r, byteOrder: byteOrder)

        case .copyArea(let r):
            handleCopyArea(r, byteOrder: byteOrder)

        // Silent no-ops: requests xclock or other apps may issue that we
        // don't yet wire to rendering. Add real handlers as needed.
        case .createCursor(let r):
            // Pixmap-source cursor. Spec requires source (and mask if non-zero)
            // to be valid 1-bit-depth pixmaps; we validate existence but not
            // depth (we don't synthesize the actual cursor bitmap anyway —
            // NSCursor renders as the macOS arrow for pixmap cursors). Hotspot
            // and fg/bg colors are ignored. The cursor ID still has to live in
            // the table so subsequent CWCursor references and FreeCursor work.
            // Sentinel sourceGlyph=0xFFFF means "no X cursor-font glyph — fall
            // back to NSCursor.arrow at crossing time."
            guard pixmaps.get(r.source) != nil else {
                emitError(.pixmap, majorOpcode: CreateCursor.opcode, badResourceId: r.source)
                break
            }
            if r.mask != 0, pixmaps.get(r.mask) == nil {
                emitError(.pixmap, majorOpcode: CreateCursor.opcode, badResourceId: r.mask)
                break
            }
            cursors.insert(CursorEntry(id: r.cid, sourceGlyph: 0xFFFF))
            log?.log("  CreateCursor cid=0x\(String(r.cid, radix: 16)) source=0x\(String(r.source, radix: 16)) mask=0x\(String(r.mask, radix: 16)) hotspot=(\(r.x),\(r.y)) [NSCursor.arrow fallback]")

        case .createGlyphCursor(let r):
            // Source and mask fonts must be valid per spec. We don't actually
            // use them (NSCursor substitution by sourceChar), but a client
            // passing a bogus font ID should still hear BadFont. maskFont=0
            // is the spec "None" sentinel and skips validation.
            guard fonts.get(r.sourceFont) != nil else {
                emitError(.font, majorOpcode: CreateGlyphCursor.opcode, badResourceId: r.sourceFont)
                break
            }
            if r.maskFont != 0, fonts.get(r.maskFont) == nil {
                emitError(.font, majorOpcode: CreateGlyphCursor.opcode, badResourceId: r.maskFont)
                break
            }
            // Only the source-glyph index matters — we substitute NSCursor at
            // crossing time, ignoring the source/mask fonts and fg/bg colors.
            cursors.insert(CursorEntry(id: r.cid, sourceGlyph: r.sourceChar))
            log?.log("  CreateGlyphCursor cid=0x\(String(r.cid, radix: 16)) sourceChar=\(r.sourceChar)")

        case .freeCursor(let r):
            guard cursors.glyph(r.cursor) != nil else {
                emitError(.cursor, majorOpcode: FreeCursor.opcode, badResourceId: r.cursor)
                break
            }
            cursors.remove(r.cursor)

        case .setInputFocus(let r):
            // focus = 0 (None) or 1 (PointerRoot) are spec-legal sentinel
            // values — not real window IDs, don't validate them. Otherwise
            // the window must exist; root is also valid (per spec, focus
            // can be set to root with revert-to None).
            if r.focus != 0 && r.focus != 1 {
                guard validateWindowOrRoot(r.focus, majorOpcode: SetInputFocus.opcode) else { break }
            }
            // Track the requested focus window. KeyPress / KeyRelease will
            // route here on next event. We don't synthesize FocusIn /
            // FocusOut on the X-protocol-level focus chain — that's a
            // Phase-4 polish item — but routing keys to the focus window
            // is what Motif actually needs to make text input work.
            // r.focus = 0 (None) or 1 (PointerRoot) → fall back to
            // pointer-position routing.
            focusWindow = (r.focus == 0 || r.focus == 1) ? nil : r.focus
            log?.log("  SetInputFocus focus=0x\(String(r.focus, radix: 16))")

        case .grabPointer(let r):
            guard validateWindowOrRoot(r.grabWindow, majorOpcode: GrabPointer.opcode) else { break }
            // confineTo = 0 means None (no confinement) — sentinel, not a
            // window ID. Otherwise must be a real window.
            if r.confineTo != 0 {
                guard validateWindowOrRoot(r.confineTo, majorOpcode: GrabPointer.opcode) else { break }
            }
            handleGrabPointer(r, byteOrder: byteOrder)

        case .ungrabPointer:
            handleUngrabPointer()

        case .changeActivePointerGrab(let r):
            // Change cursor + event mask on the existing active pointer
            // grab without releasing it. Used by Xt's XtPopupSpringLoaded
            // (menu post path) to transfer the press-time grab from the
            // menu title widget to the menu window once the menu maps. If
            // we silent-drop this, the menu maps then immediately unmaps
            // because the active grab still targets the menu title and
            // the release is interpreted as "click-without-selection →
            // cancel." Verified 2026-05-10 against xfontsel font-menu
            // post; same path applies to Motif menu posting.
            if var grab = pointerGrab {
                grab = PointerGrab(
                    window: grab.window,
                    eventMask: r.eventMask,
                    ownerEvents: grab.ownerEvents,
                    cursor: r.cursor
                )
                pointerGrab = grab
                if r.cursor != 0, let topLevel = topLevelAncestor(of: grab.window) {
                    bridge?.setCursor(topLevel: topLevel, glyph: cursors.glyph(r.cursor))
                }
                log?.log("  ChangeActivePointerGrab: cursor=0x\(String(r.cursor, radix: 16)) eventMask=0x\(String(r.eventMask, radix: 16))")
            } else {
                log?.log("  ChangeActivePointerGrab: no active grab — ignoring")
            }

        case .grabKeyboard(let r):
            guard validateWindowOrRoot(r.grabWindow, majorOpcode: GrabKeyboard.opcode) else { break }
            handleGrabKeyboard(r, byteOrder: byteOrder)

        case .ungrabKeyboard:
            handleUngrabKeyboard()

        case .polyArc(let r):
            handlePolyArc(r, byteOrder: byteOrder)

        case .polyFillArc(let r):
            handlePolyFillArc(r, byteOrder: byteOrder)

        case .setClipRectangles(let r):
            guard validateGC(r.gc, majorOpcode: SetClipRectangles.opcode) != nil else { break }
            // Update the GC's clip rectangles + clip origin. The rendering
            // pipeline does NOT yet honor these (would require threading
            // clip through every draw bridge method); the data is tracked
            // on the GCEntry so a future targeted draw-method sweep can
            // pick it up without losing client-set clip state. See
            // OPCODE_STATUS for the limitation.
            gcs.setClip(
                r.gc, rectangles: r.rectangles,
                xOrigin: r.clipXOrigin, yOrigin: r.clipYOrigin
            )

        case .setDashes(let r):
            guard validateGC(r.gc, majorOpcode: SetDashes.opcode) != nil else { break }
            // Update the GC's dash pattern + offset. Same caveat as
            // SetClipRectangles: data is tracked on the GCEntry, but the
            // stroke methods don't yet apply dashes via CGContext.
            // setLineDash. Tracked separately so `solid` lines are still
            // correct for the common case (no SetDashes ever issued).
            gcs.setDashes(r.gc, dashes: r.dashes, offset: r.dashOffset)

        case .putImage(let r):
            // Argument validation per XError-honesty policy: unknown drawable
            // → BadDrawable, unknown GC → BadGC.
            if !isKnownDrawable(r.drawable) {
                emitError(.drawable, majorOpcode: PutImage.opcode, badResourceId: r.drawable)
                break
            }
            guard validateGC(r.gc, majorOpcode: PutImage.opcode) != nil else { break }

            // format=Bitmap (X depth-1, packed 1bpp) is the only path
            // implemented today. Quickplot's icon buttons go through this:
            // XCreatePixmapFromBitmapData → XCreatePixmap depth=N +
            // XPutImage format=Bitmap depth=1 into the depth-N pixmap, with
            // GC fg/bg replacing the 1/0 bits. Other formats (XYPixmap,
            // ZPixmap) stay silent-dropped — none of the clients we host
            // today exercise them. See SHORTCUTS.
            if r.format != .bitmap || r.depth != 1 {
                log?.log("  PutImage drawable=0x\(String(r.drawable, radix: 16)) format=\(r.format) depth=\(r.depth) \(r.width)x\(r.height) — silent-drop (non-bitmap path not implemented; see SHORTCUTS)")
                break
            }

            guard let target = validateDrawTarget(r.drawable, majorOpcode: PutImage.opcode) else {
                emitError(.implementation, majorOpcode: PutImage.opcode)
                break
            }
            let (dx, dy) = target.windowOffset
            let state = gcState(r.gc, byteOrder: byteOrder)
            let fg = resolveColor(state.foreground)
            let bg = resolveColor(state.background)
            log?.log("  PutImage drawable=0x\(String(r.drawable, radix: 16)) gc=0x\(String(r.gc, radix: 16)) bitmap \(r.width)x\(r.height) at (\(r.dstX),\(r.dstY)) leftPad=\(r.leftPad)")
            bridge?.drawPutImage(
                target: target,
                sourceData: r.data,
                sourceWidth: r.width, sourceHeight: r.height,
                dstX: r.dstX &+ dx, dstY: r.dstY &+ dy,
                leftPad: r.leftPad,
                foreground: fg, background: bg,
                clipRectangles: state.clipRectangles
            )

        case .circulateWindow(let r):
            // Per X11 spec section 10.6 / CirculateWindow:
            //   direction=0 RaiseLowest: if any sibling is occluded by
            //     another, raise the lowest occluded sibling to the top.
            //   direction=1 LowerHighest: if any sibling occludes another,
            //     lower the highest occluding sibling to the bottom.
            // No CirculateNotify if no rotation occurred.
            //
            // We don't yet have per-sibling occlusion tests, so we
            // approximate: if there are at least two children, always
            // rotate one position. RaiseLowest moves lastChild to top;
            // LowerHighest moves firstChild to bottom. Matches what R6
            // produces when siblings genuinely do overlap (the common
            // client expectation). Clients calling CirculateWindow as a
            // no-op-if-already-stacked check will see an unconditional
            // rotation; no hosted client today exercises that pattern.
            // Root is a valid arg per spec, but root has no WindowEntry —
            // top-level Z-order is owned by AppKit. No-op on root.
            if r.window == config.rootWindowId { break }
            guard let entry = validateWindow(r.window, majorOpcode: CirculateWindow.opcode) else { break }
            guard r.direction == 0 || r.direction == 1 else {
                emitError(.value, majorOpcode: CirculateWindow.opcode)
                break
            }
            guard let first = entry.firstChild, let last = entry.lastChild,
                  first != last else {
                // Zero or one child — nothing to rotate, no event.
                break
            }
            let moved: UInt32
            let place: UInt8
            if r.direction == 0 {
                // RaiseLowest: take lastChild, put it at the top.
                moved = last
                place = 0       // Top
                SiblingChain.unlink(last, in: windows)
                SiblingChain.linkAtTop(last, parent: r.window, in: windows)
            } else {
                // LowerHighest: take firstChild, put it at the bottom.
                moved = first
                place = 1       // Bottom
                SiblingChain.unlink(first, in: windows)
                SiblingChain.linkAtBottom(first, parent: r.window, in: windows)
            }
            let seq = sequenceNumber
            let structureNotifyMask: UInt32 = 1 << 17
            // CirculateNotify(event=window) — delivered to the moved
            // window if it has StructureNotifyMask.
            if let movedEntry = windows.get(moved),
               movedEntry.eventMask & structureNotifyMask != 0 {
                let ev = CirculateNotifyEvent(
                    sequenceNumber: seq, event: moved, window: moved, place: place
                )
                outbound.append(ev.encode(byteOrder: byteOrder))
            }
            // CirculateNotify(event=parent) — delivered to the parent via
            // notifySubstructure if it has SubstructureNotifyMask.
            notifySubstructure(parent: r.window) { eventTarget in
                CirculateNotifyEvent(
                    sequenceNumber: seq, event: eventTarget,
                    window: moved, place: place
                ).encode(byteOrder: byteOrder)
            }
            recomputeClipsForSubtreeContaining(r.window)

        case .reparentWindow(let r):
            // Update the window's parent + position. We don't move the
            // backing NSWindow (rootless: only top-levels have NSWindows
            // and reparenting a top-level is rare); only intra-NSWindow
            // descendant reparenting updates state. Per X spec the server
            // is supposed to emit ReparentNotify on the moved window if
            // its parent has SubstructureNotifyMask; we emit it
            // unconditionally on the moved window itself (matches what
            // most WMs expect to round-trip). Parent validation deferred
            // to the root-aware sweep (root is a valid parent argument).
            guard validateWindow(r.window, majorOpcode: ReparentWindow.opcode) != nil else { break }
            if var entry = windows.get(r.window) {
                let oldParent = entry.parent
                // Capture old containing top-level before mutating parent.
                let oldTopId = topLevelAndOffset(for: r.window)?.0
                // Unlink from OLD parent's sibling chain before mutating
                // parent. Per X spec, the reparented window goes on top of
                // the new parent's stack (equivalent of MapWindow's default
                // stack mode). linkAtTop after the parent change.
                SiblingChain.unlink(r.window, in: windows)
                entry.parent = r.parent
                entry.x = r.x
                entry.y = r.y
                windows.insert(entry)
                SiblingChain.linkAtTop(r.window, parent: r.parent, in: windows)
                let ev = ReparentNotifyEvent(
                    sequenceNumber: sequenceNumber,
                    event: r.window, window: r.window,
                    parent: r.parent, x: r.x, y: r.y,
                    overrideRedirect: false
                )
                outbound.append(ev.encode(byteOrder: byteOrder))
                // Per X spec: both the OLD and NEW parents receive
                // ReparentNotify with event=parent if they have
                // SubstructureNotifyMask. Without it, parent containers
                // don't redraw their child layouts to reflect the move.
                let seq = sequenceNumber
                let win = r.window
                let newParent = r.parent
                let rx = r.x, ry = r.y
                notifySubstructure(parent: oldParent) { eventTarget in
                    ReparentNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: win,
                        parent: newParent, x: rx, y: ry,
                        overrideRedirect: false
                    ).encode(byteOrder: byteOrder)
                }
                if newParent != oldParent {
                    notifySubstructure(parent: newParent) { eventTarget in
                        ReparentNotifyEvent(
                            sequenceNumber: seq, event: eventTarget, window: win,
                            parent: newParent, x: rx, y: ry,
                            overrideRedirect: false
                        ).encode(byteOrder: byteOrder)
                    }
                }
                log?.log("  ReparentWindow window=0x\(String(r.window, radix: 16)) old-parent=0x\(String(oldParent, radix: 16)) new-parent=0x\(String(r.parent, radix: 16)) at (\(r.x),\(r.y))")
                // Recompute both old and new top-level subtrees.
                if let oldTopId, oldTopId != r.window {
                    ClipListEngine.recomputeClips(forTopLevel: oldTopId, in: windows)
                    emitVisibilityChanges(forTopLevel: oldTopId)
                }
                recomputeClipsForSubtreeContaining(r.window)
            }

        case .destroySubwindows(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: DestroySubwindows.opcode) else { break }
            // Per spec, destroy each child of the requested window in
            // bottom-to-top order. We don't track stacking; iterate the
            // table. Recursive: each child's subwindows go too.
            // Capture child IDs BEFORE destroy so we can emit
            // DestroyNotify(event=parent) for each via notifySubstructure
            // after the table mutation.
            let doomedDirectChildren = windows.windows
                .filter { $0.value.parent == r.window }
                .map { $0.key }
            destroySubtree(parentOf: r.window, includeRoot: false)
            let seq = sequenceNumber
            for childId in doomedDirectChildren {
                notifySubstructure(parent: r.window) { eventTarget in
                    DestroyNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: childId
                    ).encode(byteOrder: byteOrder)
                }
            }
            recomputeClipsForSubtreeContaining(r.window)

        case .unmapSubwindows(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: UnmapSubwindows.opcode) else { break }
            // Set mapped=false on every direct child of the requested
            // window. Emit UnmapNotify(event=parent) for each via
            // notifySubstructure if the parent has SubstructureNotifyMask.
            // After the recompute, repaint parent's bg over each child's
            // previously-occupied borderClip + emit Expose if the parent
            // has ExposureMask. Same shape as the UnmapWindow descendant
            // path.
            var unmappedChildren: [(UInt32, Region)] = []  // (id, preUnmapBorderClip)
            for (id, w) in windows.windows where w.parent == r.window && w.mapped {
                if var e = windows.get(id) {
                    unmappedChildren.append((id, e.borderClip))
                    e.mapped = false
                    windows.insert(e)
                }
            }
            let seq = sequenceNumber
            for (childId, _) in unmappedChildren {
                notifySubstructure(parent: r.window) { eventTarget in
                    UnmapNotifyEvent(
                        sequenceNumber: seq, event: eventTarget, window: childId,
                        fromConfigure: false
                    ).encode(byteOrder: byteOrder)
                }
            }
            log?.log("  UnmapSubwindows parent=0x\(String(r.window, radix: 16))")
            recomputeClipsForSubtreeContaining(r.window)
            // After the recompute, repaint parent over each child's
            // previously-covered region. Root parent (windows.get returns
            // nil) is skipped — root isn't in our windows table.
            if windows.get(r.window) != nil {
                for (_, preUnmapClip) in unmappedChildren where !preUnmapClip.isEmpty {
                    repaintParentOverUncovered(
                        uncovered: preUnmapClip,
                        parentId: r.window,
                        byteOrder: byteOrder
                    )
                }
            }

        case .grabButton(let r):
            guard validateWindowOrRoot(r.grabWindow, majorOpcode: GrabButton.opcode) else { break }
            // Passive button grab: when the matching button-press happens
            // on the grab-window or any descendant, the server is supposed
            // to auto-install an active pointer grab on grab-window. We
            // record the entry but don't yet honor it in the ButtonPress
            // delivery path — Motif/Athena's primary click flow doesn't
            // need passive button grabs (they install via the "implicit
            // pointer grab" we already handle in handleMouseEvent). Some
            // menu-popup paths in Motif do use this. Tracked for a future
            // sweep; documented in OPCODE_STATUS.
            passiveButtonGrabs.append(PassiveButtonGrab(
                grabWindow: r.grabWindow,
                button: r.button,
                modifiers: r.modifiers,
                eventMask: r.eventMask,
                ownerEvents: r.ownerEvents
            ))
            log?.log("  GrabButton window=0x\(String(r.grabWindow, radix: 16)) button=\(r.button) mods=0x\(String(r.modifiers, radix: 16))")

        case .grabKey(let r):
            guard validateWindowOrRoot(r.grabWindow, majorOpcode: GrabKey.opcode) else { break }
            // Passive key grab. Same pattern as GrabButton: record the
            // entry, deliver via the natural KeyPress path until we wire
            // active-on-match here. Quickplot registers ~5 of these for
            // accelerator keys.
            passiveKeyGrabs.append(PassiveKeyGrab(
                grabWindow: r.grabWindow,
                key: r.key,
                modifiers: r.modifiers,
                ownerEvents: r.ownerEvents
            ))
            log?.log("  GrabKey window=0x\(String(r.grabWindow, radix: 16)) key=\(r.key) mods=0x\(String(r.modifiers, radix: 16))")

        case .allowEvents:
            // Releases events queued behind a frozen grab. We don't
            // implement frozen grabs (every grab we install is in
            // GrabModeAsync state), so there's nothing queued to release —
            // safe no-op.
            break

        case .warpPointer(let r):
            // Programmatic pointer move. In rootless mode warping the macOS
            // pointer feels jarring (the user's physical pointer would
            // jump). We update our last-known logical position so QueryPointer
            // returns the warped value, but do not call CGWarpMouseCursorPosition
            // — clients that depend on the visible cursor jumping will see
            // a discrepancy. Documented in OPCODE_STATUS as low-confidence.
            if let stl = topLevelAncestor(of: r.dstWindow) {
                let (dx, dy) = absoluteOrigin(of: r.dstWindow, topLevel: stl)
                lastPointerTopLevel = stl
                lastPointerXY = (dx &+ r.dstX, dy &+ r.dstY)
            }

        case .sendEvent(let r):
            // destination = 0 (PointerWindow) and 1 (InputFocus) are spec
            // sentinels meaning "the window currently under the pointer /
            // with input focus" — not real window IDs, don't validate.
            // Otherwise the destination must be a real window or root.
            if r.destination != 0 && r.destination != 1 {
                guard validateWindowOrRoot(r.destination, majorOpcode: SendEvent.opcode) else { break }
            }
            // Deliver the synthetic 32-byte event the client supplied to
            // the destination window. Per X11 spec the server rewrites
            // bytes 0 and 2..3:
            //   - byte 0: set high bit (0x80) to mark as synthetic
            //   - bytes 2..3: replace with the server's current sequence
            //     number (NOT whatever the client put there)
            // Skipping the seq rewrite means the event lands on the wire
            // with whatever bogus seq the client supplied (often 0). Xlib's
            // wrap-detection then treats the dip as a wrap, expands to
            // 65536+, and prints "sequence lost in reply type 0x..!" —
            // verified 2026-05-10 against quickplot SendEvent flow during
            // menu posting. Propagation up the ancestor chain (when
            // propagate=true) is NOT honored; predefined destinations
            // (PointerWindow=0, InputFocus=1) deliver to the supplied id.
            var bytes = r.event
            bytes[0] |= 0x80
            switch byteOrder {
            case .lsbFirst:
                bytes[2] = UInt8(truncatingIfNeeded: sequenceNumber)
                bytes[3] = UInt8(truncatingIfNeeded: sequenceNumber >> 8)
            case .msbFirst:
                bytes[2] = UInt8(truncatingIfNeeded: sequenceNumber >> 8)
                bytes[3] = UInt8(truncatingIfNeeded: sequenceNumber)
            }
            outbound.append(bytes)
            log?.log("  SendEvent dest=0x\(String(r.destination, radix: 16)) propagate=\(r.propagate) eventCode=\(bytes[0] & 0x7F)")

        case .grabServer, .ungrabServer:
            // Accepted as a no-op. We're multi-client today but don't yet
            // implement GrabServer's "block all other clients" semantic
            // (would require coordinator-mediated pause of other sessions'
            // request dispatch). Latent gap: a WM that depends on
            // GrabServer to make atomic multi-request changes won't get
            // atomicity. No client we host today exercises this.
            break

        case .noOperation:
            // Xt scatters XNoOp as wire flushes. Spec says always succeeds;
            // no reply. Pre-2026-05-14 this fell through to BadRequest,
            // hitting every Xt-based client multiple times per session.
            break

        case .setCloseDownMode(let r):
            // Client tells server what to do with its resources on
            // disconnect. We don't yet support RetainPermanent /
            // RetainTemporary close-down (Product 2 territory); spec lets
            // us implement only Destroy (the default). Accept silently
            // — clients expect no reply, and the next disconnect will
            // tear down all resources regardless of stored mode.
            log?.log("  SetCloseDownMode: mode=\(r.mode) (recorded, not honored)")

        case .killClient(let r):
            // Spec: kill the client owning the given resource (or all
            // RetainTemporary clients if resource == AllTemporary=0).
            // Single-real-client tier today; accept silently. Real impl
            // would look up resource → client → close client socket.
            log?.log("  KillClient: resource=0x\(String(r.resource, radix: 16)) (no-op, multi-client not yet)")

        case .ungrabButton(let r):
            // Remove matching passive button grabs. AnyButton=0 and
            // AnyModifier=0x8000 are wildcards per spec — they match
            // every previously-registered grab on the window.
            guard validateWindowOrRoot(r.grabWindow, majorOpcode: UngrabButton.opcode) else { break }
            passiveButtonGrabs.removeAll { g in
                g.grabWindow == r.grabWindow
                  && (r.button == 0 || g.button == r.button)
                  && (r.modifiers == 0x8000 || g.modifiers == r.modifiers)
            }

        case .ungrabKey(let r):
            guard validateWindowOrRoot(r.grabWindow, majorOpcode: UngrabKey.opcode) else { break }
            passiveKeyGrabs.removeAll { g in
                g.grabWindow == r.grabWindow
                  && (r.key == 0 || g.key == r.key)
                  && (r.modifiers == 0x8000 || g.modifiers == r.modifiers)
            }

        case .getMotionEvents(let r):
            // swift-x doesn't keep a motion-event ring (motion-buffer-size
            // is advertised as 0 in the connection-info reply). Spec-correct
            // answer is an empty event list.
            guard validateWindowOrRoot(r.window, majorOpcode: GetMotionEvents.opcode) else { break }
            let reply = GetMotionEventsReply(sequenceNumber: sequenceNumber)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .allocColorCells(let r):
            // Read-write colormap cells aren't supported: swift-x advertises
            // a single PseudoColor visual but renders on TrueColor (Mac
            // backing store has no real palette). Spec lets us emit
            // BadAlloc when the requested allocation can't succeed.
            // Important: must NOT be BadRequest (the pre-2026-05-14 default
            // for opcodes with no framer decoder). Xt's color converter
            // catches BadAlloc and falls back to read-only AllocColor;
            // BadRequest gets logged as "server is broken." Equivalent of
            // what XQuartz does at xpr/xprScreen.c — TrueColor framebuffer,
            // refuse writable cells.
            log?.log("  AllocColorCells: cmap=0x\(String(r.cmap, radix: 16)) colors=\(r.colors) planes=\(r.planes) → BadAlloc (no read-write cells on TrueColor backing)")
            emitError(.alloc, majorOpcode: AllocColorCells.opcode, badResourceId: r.cmap)

        case .recolorCursor(let r):
            // We substitute NSCursor glyphs and don't honor the X-protocol
            // fg/bg colors. Cosmetic no-op on the rendering side, but still
            // validate the cursor argument per spec — clients passing a bad
            // cursor ID should hear BadCursor.
            guard cursors.glyph(r.cursor) != nil else {
                emitError(.cursor, majorOpcode: RecolorCursor.opcode, badResourceId: r.cursor)
                break
            }
            break

        case .bell(let r):
            // Audible alert. Map to NSBeep — the X spec lets us scale by
            // the percent value (-100..100) but macOS NSBeep has no volume
            // control, so we just beep on any non-zero positive request
            // and stay silent on zero/negative (per spec the latter
            // requests a softer/silenced bell).
            if r.percent > 0 { bridge?.bell() }

        case .listFonts(let r):
            // Pattern-match against the synthesized Phase-1 font list.
            let pattern = String(decoding: r.pattern, as: UTF8.self)
            let names = SynthesizedFonts.match(pattern: pattern, max: Int(r.maxNames))
            let reply = ListFontsReply(sequenceNumber: sequenceNumber, names: names)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getKeyboardMapping(let r):
            let keysyms = DefaultKeyboardMap.keysyms(firstKeycode: r.firstKeycode, count: r.count)
            let reply = GetKeyboardMappingReply(
                sequenceNumber: sequenceNumber,
                keysymsPerKeycode: DefaultKeyboardMap.keysymsPerKeycode,
                keysyms: keysyms
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getModifierMapping:
            let reply = GetModifierMappingReply(
                sequenceNumber: sequenceNumber,
                keycodesPerModifier: DefaultModifierMap.keycodesPerModifier,
                keycodes: DefaultModifierMap.keycodes
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getPointerMapping:
            let reply = GetPointerMappingReply(
                sequenceNumber: sequenceNumber,
                map: DefaultPointerMap.map
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryColors(let r):
            // Look up each requested pixel in our ColorTable; unknown pixels
            // resolve to black (consistent with the dispatch-time fallback).
            let entries: [QueryColorsRGB] = r.pixels.map { pixel in
                let rgb = colors.rgb(for: pixel) ?? RGB16(red: 0, green: 0, blue: 0)
                return QueryColorsRGB(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
            let reply = QueryColorsReply(sequenceNumber: sequenceNumber, colors: entries)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getSelectionOwner(let r):
            let owner = coordinator.selectionOwner(r.selection)?.window ?? 0
            let reply = GetSelectionOwnerReply(sequenceNumber: sequenceNumber, owner: owner)
            outbound.append(reply.encode(byteOrder: byteOrder))

        // SetSelectionOwner has no reply per X11 spec. Track ownership so we
        // ConvertSelection: a client wants the contents of a selection
        // converted to a target type and stored on a property of its
        // requestor window. If we know the owner, forward as a
        // SelectionRequest event so the owner can fulfil. If no owner,
        // the spec says we MUST reply with SelectionNotify(property=None)
        // — otherwise the client hangs waiting for the conversion.
        // dtcalc tripped this during init, hanging at request 85 because
        // we silent-dropped opcode 24.
        case .convertSelection(let r):
            log?.log("  ConvertSelection requestor=0x\(String(r.requestor, radix: 16)) sel=\(r.selection) target=\(r.target) prop=\(r.property)")
            // CRITICAL: every SelectionNotify below must echo `r.time`
            // verbatim. Xt's HandleSelectionReplies in X11R6 Selection.c
            // uses MATCH_SELECT, which checks `event->time == info->time`
            // and silently drops the event if they differ. Do NOT
            // substitute serverTime for selection events (server-generated
            // events like ButtonPress are a different story).
            switch selectionMediator.convertSelection(r) {
            case .stubOwnerReplyEmpty:
                // Stub owner (e.g. CDE customization daemon at 0xFFFE_0003).
                // Write empty bytes to the requestor's property and emit
                // SelectionNotify(property=p) signalling success. dt apps
                // get empty bytes for whatever they're trying to convert,
                // fall back to compiled defaults, and proceed.
                properties.change(
                    window: r.requestor, property: r.property, type: r.target,
                    format: 8, mode: 0, value: []
                )
                let event = SelectionNotifyEvent(
                    sequenceNumber: sequenceNumber,
                    time: r.time,
                    requestor: r.requestor,
                    selection: r.selection,
                    target: r.target,
                    property: r.property
                )
                outbound.append(event.encode(byteOrder: byteOrder))
                log?.log("  → stub-daemon SelectionNotify(empty) for sel=\(r.selection) prop=\(r.property) time=\(r.time)")

            case .forwardToRealOwner(let ownerWindow):
                let event = SelectionRequestEvent(
                    sequenceNumber: sequenceNumber,
                    time: r.time,
                    owner: ownerWindow,
                    requestor: r.requestor,
                    selection: r.selection,
                    target: r.target,
                    property: r.property
                )
                outbound.append(event.encode(byteOrder: byteOrder))
                log?.log("  → forwarded SelectionRequest to owner=0x\(String(ownerWindow, radix: 16))")

            case .replyNoOwner:
                // No owner — reply directly to requestor with property=None
                // per spec.
                let event = SelectionNotifyEvent(
                    sequenceNumber: sequenceNumber,
                    time: r.time,
                    requestor: r.requestor,
                    selection: r.selection,
                    target: r.target,
                    property: 0
                )
                outbound.append(event.encode(byteOrder: byteOrder))
                log?.log("  → SelectionNotify property=None (no owner for sel=\(r.selection))")
            }

        // can run the copy roundtrip later (or right now, in xterm-style
        // mode). owner=0 clears the selection.
        case .setSelectionOwner(let r):
            if r.owner == 0 {
                // Clearing ownership. If we previously held this selection,
                // a SelectionClear isn't required by spec for the "owner ==
                // None" path — the owning client is the one driving the
                // clear and already knows it gave up the selection.
                coordinator.clearSelectionOwner(r.selection)
                log?.log("SetSelectionOwner: cleared selection atom=\(r.selection)")
            } else {
                // Atomic swap returns the prior owner. Spec 4.2.1: when a
                // new client takes ownership, the previous owner gets a
                // SelectionClear. We emit it only when the prior owner
                // window lives in our windows table (same-session case);
                // cross-session SelectionClear delivery would need a
                // coordinator-mediated routing path that doesn't exist
                // yet. The mediator's stub-owned-selection case (CDE
                // daemon impersonation) is also same-session and works
                // here because the stub window IS in our windows table.
                let prior = coordinator.swapSelectionOwner(r.selection, window: r.owner, time: r.time)
                log?.log("SetSelectionOwner: selection atom=\(r.selection) owner=0x\(String(r.owner, radix: 16)) time=\(r.time)")
                if let prior = prior,
                   prior.window != r.owner,
                   windows.get(prior.window) != nil {
                    let clear = SelectionClearEvent(
                        sequenceNumber: sequenceNumber,
                        time: r.time,
                        owner: prior.window,
                        selection: r.selection
                    )
                    outbound.append(clear.encode(byteOrder: byteOrder))
                    log?.log("  → SelectionClear to prior owner 0x\(String(prior.window, radix: 16))")
                }
                let prefs = clipboardPrefs.current
                if r.selection == 1, prefs.enabled, prefs.mode == .xtermStyle {
                    requestSelectionConversion(selectionAtom: 1)
                }
            }

        // Replies we don't yet implement — note them so the live test surfaces
        // what's missing without dropping the connection.
        case .getWindowAttributes(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: GetWindowAttributes.opcode) else { break }
            // Synthesise a reply from the WindowEntry. Pre-2026-05-15 most
            // fields returned zeros regardless of what was set — a lie on
            // the wire flagged by the comparison study. Now reads back
            // every CW* attribute the client wrote (synthesis #6).
            let entry = windows.get(r.window)
            let mapState: UInt8 = (entry?.mapped == true) ? 2 : 0   // Viewable / Unmapped
            let visualId = config.rootVisualId
            let cls: UInt16 = entry?.windowClass == .inputOnly ? 2 : 1
            // Colormap: per-window override if set, else CopyFromParent
            // (which collapses to the screen's default for our purposes —
            // we don't yet walk the parent chain because no client we host
            // sets per-window colormaps).
            let cmap = entry?.colormap ?? config.defaultColormapId
            let reply = GetWindowAttributesReply(
                sequenceNumber: sequenceNumber,
                backingStore: entry?.backingStore ?? 0,
                visualId: visualId,
                windowClass: cls,
                bitGravity: entry?.bitGravity ?? 0,
                winGravity: entry?.winGravity ?? 1,
                backingBitPlanes: entry?.backingPlanes ?? ~UInt32(0),
                backingPixel: entry?.backingPixel ?? 0,
                saveUnder: entry?.saveUnder ?? false,
                mapInstalled: true,
                mapState: mapState,
                overrideRedirect: entry?.overrideRedirect ?? false,
                colormap: cmap,
                allEventMasks: entry?.eventMask ?? 0,
                yourEventMask: entry?.eventMask ?? 0,
                doNotPropagateMask: entry?.doNotPropagateMask ?? 0
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getGeometry(let r):
            // Drawable can be a window (incl. root) or pixmap. Unknown
            // drawable → BadDrawable; silent-log was a wedging lie since the
            // client blocks in _XReply waiting for a response.
            if let w = windows.get(r.drawable) {
                let reply = GetGeometryReply(
                    sequenceNumber: sequenceNumber,
                    depth: w.depth == 0 ? 8 : w.depth,
                    root: config.rootWindowId,
                    x: w.x, y: w.y,
                    width: w.width, height: w.height,
                    borderWidth: w.borderWidth
                )
                outbound.append(reply.encode(byteOrder: byteOrder))
            } else if let p = pixmaps.get(r.drawable) {
                let reply = GetGeometryReply(
                    sequenceNumber: sequenceNumber,
                    depth: p.depth, root: config.rootWindowId,
                    x: 0, y: 0,
                    width: p.width, height: p.height, borderWidth: 0
                )
                outbound.append(reply.encode(byteOrder: byteOrder))
            } else if r.drawable == config.rootWindowId {
                // Root isn't in the windows table; synthesize from screen
                // config. Root depth is 8 per SetupAccepted.
                let reply = GetGeometryReply(
                    sequenceNumber: sequenceNumber,
                    depth: 8,
                    root: config.rootWindowId,
                    x: 0, y: 0,
                    width: config.widthInPixels,
                    height: config.heightInPixels,
                    borderWidth: 0
                )
                outbound.append(reply.encode(byteOrder: byteOrder))
            } else {
                emitError(.drawable, majorOpcode: GetGeometry.opcode, badResourceId: r.drawable)
            }

        case .queryBestSize(let r):
            // Spec takes a drawable to identify the screen/depth context.
            // We don't actually use it for sizing, but still validate per
            // XError-honesty policy — clients passing a bogus drawable
            // should learn about it.
            if !isKnownDrawable(r.drawable) {
                emitError(.drawable, majorOpcode: QueryBestSize.opcode, badResourceId: r.drawable)
                break
            }
            // Pragmatic reply. For Cursor class, return 16×16 — the canonical
            // X cursor size; doesn't matter much because we substitute NSCursor.
            // For Tile / Stipple, echo the requested dimensions back so the
            // client doesn't have to renegotiate sizes. (Real servers use this
            // to advertise hardware-optimal pixmap sizes; we have no such
            // optimization, so any sane number works.)
            let (w, h): (UInt16, UInt16)
            switch r.sizeClass {
            case .cursor: (w, h) = (16, 16)
            case .tile, .stipple: (w, h) = (r.width, r.height)
            }
            let reply = QueryBestSizeReply(sequenceNumber: sequenceNumber, width: w, height: h)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .translateCoordinates(let r):
            guard validateWindowOrRoot(r.srcWindow, majorOpcode: TranslateCoordinates.opcode) else { break }
            guard validateWindowOrRoot(r.dstWindow, majorOpcode: TranslateCoordinates.opcode) else { break }
            // Translate (srcX, srcY) from srcWindow's coordinate system to
            // dstWindow's. If both share a top-level, walk each window's
            // origin chain to top-level coords, do the subtraction, return
            // same-screen=true. If they're in different top-levels (rare;
            // we don't track inter-NSWindow root positions meaningfully)
            // we return same-screen=false and zero coords — clients that
            // need cross-screen translation are exotic and we'll cross
            // that bridge if it ever matters.
            //
            // Without this reply Motif blocks forever in `_XReply` waiting
            // on it. Quickplot from SS2 stopped dispatching widget callbacks
            // after issuing one TranslateCoordinates we silent-dropped
            // (verified 2026-05-09). The "Motif click dispatch dead-end" was
            // never about Motif refusing to dispatch — Xlib was just stuck
            // mid-reply, and clicks couldn't propagate through a blocked
            // socket reader. Implementing this reply unblocks the client.
            // Coordinate convention: a window's position-in-root is its
            // absolute origin within its top-level PLUS the top-level's
            // own root coords (the WM placement for regular windows; the
            // client-requested coords for override-redirect popups). Pre-
            // 2026-05-21 this code treated every top-level as sitting at
            // (0,0) — fine before we honored client placement, but wrong
            // now that we do. Visible as: Motif second-tier cascade menus
            // popping up at the wrong screen position. First-tier menus
            // are unaffected because Motif caches their cascade-button
            // root coords from the synthetic ConfigureNotify on the main
            // window; second-tier menus are children of a popup top-level
            // and Motif re-queries via XTranslateCoordinates, which routes
            // through this handler. All windows share the single X screen
            // → sameScreen=true.
            let srcTopLevel = topLevelAncestor(of: r.srcWindow)
            let dstTopLevel = topLevelAncestor(of: r.dstWindow)
            let isRoot: (UInt32) -> Bool = { $0 == self.config.rootWindowId }
            // Top-level's own root coords (entry.x, entry.y). Defaults to
            // (0, 0) for the root drawable or an unknown window.
            let topLevelRoot: (UInt32?) -> (Int16, Int16) = { tl in
                guard let id = tl, let e = self.windows.get(id) else { return (0, 0) }
                return (e.x, e.y)
            }
            let srcRoot: (Int16, Int16) = {
                if isRoot(r.srcWindow) { return (r.srcX, r.srcY) }
                guard let stl = srcTopLevel else { return (r.srcX, r.srcY) }
                let (sx, sy) = self.absoluteOrigin(of: r.srcWindow, topLevel: stl)
                let (tx, ty) = topLevelRoot(stl)
                return (tx &+ sx &+ r.srcX, ty &+ sy &+ r.srcY)
            }()
            let dstOriginInRoot: (Int16, Int16) = {
                if isRoot(r.dstWindow) { return (0, 0) }
                guard let dtl = dstTopLevel else { return (0, 0) }
                let (dx, dy) = self.absoluteOrigin(of: r.dstWindow, topLevel: dtl)
                let (tx, ty) = topLevelRoot(dtl)
                return (tx &+ dx, ty &+ dy)
            }()
            let outX: Int16 = srcRoot.0 &- dstOriginInRoot.0
            let outY: Int16 = srcRoot.1 &- dstOriginInRoot.1
            let reply = TranslateCoordinatesReply(
                sequenceNumber: sequenceNumber, sameScreen: true,
                child: 0, dstX: outX, dstY: outY
            )
            log?.log("  TranslateCoordinates src=0x\(String(r.srcWindow, radix: 16)) dst=0x\(String(r.dstWindow, radix: 16)) (\(r.srcX),\(r.srcY)) → (\(reply.dstX),\(reply.dstY)) sameScreen=\(reply.sameScreen)")
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryTree(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: QueryTree.opcode) else { break }
            // Per X11 spec the children list is in bottom-to-top stacking
            // order. For windows in our table we walk the sibling chain
            // (lastChild → prevSib → ...); for the root we fall back to
            // dict-sort-by-id since root has no WindowEntry and AppKit
            // owns top-level stacking.
            let children = SiblingChain.directChildrenBottomFirst(
                of: r.window, in: windows
            )
            let parent: UInt32 = r.window == config.rootWindowId
                ? 0
                : (windows.get(r.window)?.parent ?? 0)
            let reply = QueryTreeReply(
                sequenceNumber: sequenceNumber,
                root: config.rootWindowId,
                parent: parent,
                children: children
            )
            log?.log("  QueryTree window=0x\(String(r.window, radix: 16)) → parent=0x\(String(parent, radix: 16)) children=\(children.count)")
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getAtomName(let r):
            // Unknown atom (or atom=0 which is the spec sentinel None) →
            // BadAtom. Previously returned an empty name as a lie — the
            // spec is unambiguous here and Xlib clients DO handle BadAtom
            // (Xt's atom intern path uses it as a probe).
            guard r.atom != 0, let nameStr = atoms.name(for: r.atom) else {
                emitError(.atom, majorOpcode: GetAtomName.opcode, badResourceId: r.atom)
                break
            }
            let reply = GetAtomNameReply(
                sequenceNumber: sequenceNumber,
                name: Array(nameStr.utf8)
            )
            log?.log("  GetAtomName atom=\(r.atom) → \"\(nameStr)\"")
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryPointer(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: QueryPointer.opcode) else { break }
            // Best-effort answer: report the last known pointer position
            // in root coords, the deepest mapped descendant of the queried
            // window that contains the pointer (or None), and the current
            // mod+button mask. winX/winY are relative to the queried
            // window. Per X spec same-screen=true unless the pointer is
            // on a different screen — single-screen for us.
            //
            // lastPointerXY is stored top-level-local (NSWindow coords);
            // rootCoords adds the top-level's WM-emulation root offset so
            // the reply matches the convention every other root_x/root_y
            // field uses.
            let (px, py) = lastPointerXY ?? (0, 0)
            var winX: Int16 = px
            var winY: Int16 = py
            var child: UInt32 = 0
            var rxOut: Int16 = px
            var ryOut: Int16 = py
            if let topLevel = lastPointerTopLevel {
                let (rx, ry) = rootCoords(topLevel: topLevel, localX: px, localY: py)
                rxOut = rx
                ryOut = ry
                if let stl = topLevelAncestor(of: r.window), stl == topLevel {
                    let (qx, qy) = absoluteOrigin(of: r.window, topLevel: stl)
                    winX = px &- qx
                    winY = py &- qy
                }
                child = currentPointerWindow[topLevel] ?? 0
                if child == r.window { child = 0 }
            }
            var mask: UInt16 = currentModifierState
            for b in heldButtons where b >= 1 && b <= 5 {
                mask |= UInt16(1) << (7 + b)
            }
            let reply = QueryPointerReply(
                sequenceNumber: sequenceNumber,
                sameScreen: true,
                root: config.rootWindowId,
                child: child,
                rootX: rxOut, rootY: ryOut,
                winX: winX, winY: winY,
                mask: mask
            )
            log?.log("  QueryPointer window=0x\(String(r.window, radix: 16)) → child=0x\(String(child, radix: 16)) root=(\(rxOut),\(ryOut)) win=(\(winX),\(winY)) mask=0x\(String(mask, radix: 16))")
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .listExtensions:
            // Empty list — we don't implement any X extensions (no XKB,
            // no SHAPE, no MIT-SHM, etc.). Clients that ListExtensions get
            // back nothing and proceed without extension features.
            let reply = ListExtensionsReply(sequenceNumber: sequenceNumber, names: [])
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryKeymap:
            // We don't track held-key state across the connection (only
            // modifier state during translation). Returning all-zeros is a
            // defensible best-effort: it tells the client "no keys are
            // currently held," which is true for the common idle case.
            // Phase 4: track per-keycode press state on key events and
            // mirror it here. Updated to honest-low confidence in
            // OPCODE_STATUS until that lands.
            let reply = QueryKeymapReply(
                sequenceNumber: sequenceNumber,
                keys: [UInt8](repeating: 0, count: 32)
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .unknown(let op, _):
            unknownOpcodes.append(op)
            let n = opcodeName(op) ?? "unknown"
            log?.log("dispatch: unknown opcode \(op) (\(n))")
            // Per XError-honesty policy (CLAUDE.md), don't silently drop.
            // BadRequest is the spec-correct error for "the major or minor
            // opcode does not specify a valid request" — covers both true
            // unknowns (extension opcodes from extensions we don't install,
            // which is why our QueryExtension reports them not-present) and
            // core opcodes whose body decoder we haven't written.
            emitError(.request, majorOpcode: op)
        }
    }
}

// Pull the Request enum's opcode tag for logging. Cheap and exhaustive enough
// that the compiler tells us when we add a new case.
private func opcodeName(_ request: Request) -> String {
    switch request {
    case .createWindow: return "CreateWindow"
    case .changeWindowAttributes: return "ChangeWindowAttributes"
    case .getWindowAttributes: return "GetWindowAttributes"
    case .destroyWindow: return "DestroyWindow"
    case .destroySubwindows: return "DestroySubwindows"
    case .reparentWindow: return "ReparentWindow"
    case .mapWindow: return "MapWindow"
    case .mapSubwindows: return "MapSubwindows"
    case .unmapWindow: return "UnmapWindow"
    case .unmapSubwindows: return "UnmapSubwindows"
    case .configureWindow: return "ConfigureWindow"
    case .getGeometry: return "GetGeometry"
    case .queryTree: return "QueryTree"
    case .internAtom: return "InternAtom"
    case .getAtomName: return "GetAtomName"
    case .changeProperty: return "ChangeProperty"
    case .deleteProperty: return "DeleteProperty"
    case .getProperty: return "GetProperty"
    case .setSelectionOwner: return "SetSelectionOwner"
    case .getSelectionOwner: return "GetSelectionOwner"
    case .convertSelection: return "ConvertSelection"
    case .sendEvent: return "SendEvent"
    case .grabPointer: return "GrabPointer"
    case .ungrabPointer: return "UngrabPointer"
    case .grabButton: return "GrabButton"
    case .changeActivePointerGrab: return "ChangeActivePointerGrab"
    case .grabKeyboard: return "GrabKeyboard"
    case .ungrabKeyboard: return "UngrabKeyboard"
    case .grabKey: return "GrabKey"
    case .allowEvents: return "AllowEvents"
    case .grabServer: return "GrabServer"
    case .ungrabServer: return "UngrabServer"
    case .queryPointer: return "QueryPointer"
    case .translateCoordinates: return "TranslateCoordinates"
    case .warpPointer: return "WarpPointer"
    case .setInputFocus: return "SetInputFocus"
    case .getInputFocus: return "GetInputFocus"
    case .queryKeymap: return "QueryKeymap"
    case .openFont: return "OpenFont"
    case .closeFont: return "CloseFont"
    case .queryFont: return "QueryFont"
    case .listFonts: return "ListFonts"
    case .createPixmap: return "CreatePixmap"
    case .freePixmap: return "FreePixmap"
    case .createGC: return "CreateGC"
    case .freeGC: return "FreeGC"
    case .setDashes: return "SetDashes"
    case .setClipRectangles: return "SetClipRectangles"
    case .clearArea: return "ClearArea"
    case .copyArea: return "CopyArea"
    case .changeGC: return "ChangeGC"
    case .polyLine: return "PolyLine"
    case .polySegment: return "PolySegment"
    case .polyArc: return "PolyArc"
    case .fillPoly: return "FillPoly"
    case .polyRectangle: return "PolyRectangle"
    case .polyFillRectangle: return "PolyFillRectangle"
    case .polyFillArc: return "PolyFillArc"
    case .putImage: return "PutImage"
    case .polyText8: return "PolyText8"
    case .imageText8: return "ImageText8"
    case .allocColor: return "AllocColor"
    case .allocNamedColor: return "AllocNamedColor"
    case .queryColors: return "QueryColors"
    case .lookupColor: return "LookupColor"
    case .queryBestSize: return "QueryBestSize"
    case .queryExtension: return "QueryExtension"
    case .bell: return "Bell"
    case .createCursor: return "CreateCursor"
    case .createGlyphCursor: return "CreateGlyphCursor"
    case .freeCursor: return "FreeCursor"
    case .recolorCursor: return "RecolorCursor"
    case .listExtensions: return "ListExtensions"
    case .getKeyboardMapping: return "GetKeyboardMapping"
    case .getModifierMapping: return "GetModifierMapping"
    case .getPointerMapping: return "GetPointerMapping"
    case .ungrabButton: return "UngrabButton"
    case .ungrabKey: return "UngrabKey"
    case .getMotionEvents: return "GetMotionEvents"
    case .allocColorCells: return "AllocColorCells"
    case .setCloseDownMode: return "SetCloseDownMode"
    case .killClient: return "KillClient"
    case .noOperation: return "NoOperation"
    case .createColormap: return "CreateColormap"
    case .freeColormap: return "FreeColormap"
    case .copyColormapAndFree: return "CopyColormapAndFree"
    case .installColormap: return "InstallColormap"
    case .uninstallColormap: return "UninstallColormap"
    case .listInstalledColormaps: return "ListInstalledColormaps"
    case .allocColorPlanes: return "AllocColorPlanes"
    case .freeColors: return "FreeColors"
    case .storeColors: return "StoreColors"
    case .storeNamedColor: return "StoreNamedColor"
    case .circulateWindow: return "CirculateWindow"
    case .queryTextExtents: return "QueryTextExtents"
    case .polyPoint: return "PolyPoint"
    case .unknown(let op, _): return "unknown(\(op))"
    }
}
