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

    public let config: ServerConfig

    /// Cross-session shared state (atoms, selection ownership, ID ranges).
    /// In single-client mode this is a freshly-constructed coordinator the
    /// session owns alone; in multi-client mode the listener hands the same
    /// coordinator to every session so they share atoms + selections.
    public let coordinator: ServerCoordinator

    /// Atoms — delegated to coordinator so atom IDs stay consistent across
    /// sessions. Kept as a property so call sites read `self.atoms.intern(…)`
    /// the same way they always did.
    public var atoms: AtomTable { coordinator.atoms }

    public let colors = ColorTable()
    public let windows = WindowTable()
    public let gcs = GCTable()
    public let pixmaps = PixmapTable()
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
        // All AppKit-side callbacks hop onto protocolQueue, run the handler,
        // and flush any bytes the handler appended to outbound. Since
        // protocolQueue is the only writer, no lock is needed at the socket.
        let queue = self.protocolQueue
        bridge?.setOnTopLevelResize { [weak self] id, width, height in
            queue.async {
                self?.handleTopLevelResize(id: id, width: width, height: height)
                self?.flushOutbound()
            }
        }
        bridge?.setOnKey { [weak self] topLevel, macKeyCode, modifierFlags, isDown in
            queue.async {
                self?.handleKeyEvent(
                    topLevel: topLevel, macKeyCode: macKeyCode,
                    modifierFlags: modifierFlags, isDown: isDown
                )
                self?.flushOutbound()
            }
        }
        bridge?.setOnFocus { [weak self] topLevel, gained in
            queue.async {
                self?.handleFocusChange(topLevel: topLevel, gained: gained)
                self?.flushOutbound()
            }
        }
        bridge?.setOnMouse { [weak self] topLevel, x, y, button, isDown in
            queue.async {
                self?.handleMouseEvent(
                    topLevel: topLevel, x: x, y: y, button: button, isDown: isDown
                )
                self?.flushOutbound()
            }
        }
        bridge?.setOnMouseDragged { [weak self] topLevel, x, y, button in
            queue.async {
                self?.handleMouseDragged(topLevel: topLevel, x: x, y: y, button: button)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPointerMoved { [weak self] topLevel, x, y in
            queue.async {
                self?.handlePointerMoved(topLevel: topLevel, x: x, y: y)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPointerEnteredView { [weak self] topLevel, x, y in
            queue.async {
                self?.handlePointerEnteredView(topLevel: topLevel, x: x, y: y)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPointerExitedView { [weak self] topLevel in
            queue.async {
                self?.handlePointerExitedView(topLevel: topLevel)
                self?.flushOutbound()
            }
        }
        bridge?.setOnPaste { [weak self] topLevel, text in
            queue.async {
                self?.handlePaste(topLevel: topLevel, text: text)
                self?.flushOutbound()
            }
        }
        bridge?.setOnCopy { [weak self] topLevel in
            queue.async {
                self?.handleCopy(topLevel: topLevel)
                self?.flushOutbound()
            }
        }
        bridge?.setOnCloseRequest { [weak self] topLevel in
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

        // Minimal RESOURCE_MANAGER on root. In a real CDE session, xrdb
        // merges user + system Xresources here, and Xt-based apps consult it
        // before falling back to app-defaults. We have nothing real to put
        // here, but a CDE-aware *customization: -color line tells Xt to look
        // for the -color flavored app-defaults files (e.g. Dtterm-color),
        // which is what dt apps expect under a colour CDE session. Empty
        // RESOURCE_MANAGER means apps load the plain-monochrome variants.
        let resourceManagerAtom: UInt32 = 23   // predefined RESOURCE_MANAGER
        let stringAtom: UInt32 = 31            // predefined STRING
        let resourceManagerText = "*customization:\t-color\n"
        properties.change(
            window: config.rootWindowId,
            property: resourceManagerAtom,
            type: stringAtom,
            format: 8,
            mode: 0,
            value: Array(resourceManagerText.utf8)
        )

        // CDE customization daemon impersonation. See SelectionMediator
        // for the rationale + the captured-from-u5 SDT Pixel Set bytes.
        selectionMediator.installCDECustomizationDaemonImpersonation()
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
        let pointerWindow = deepestMappedWindow(topLevel: topLevel, x: x, y: y)
        let from = currentPointerWindow[topLevel]
        if from != pointerWindow {
            currentPointerWindow[topLevel] = pointerWindow
            emitCrossings(topLevel: topLevel, from: from, to: pointerWindow, rootX: x, rootY: y)
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
            rootX: x, rootY: y,
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
            // Grab active with ownerEvents=true. Deliver to natural target
            // since we're single-client (the client owns every window in
            // this session); ownerEvents=true means "no redirect."
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
                rootX: x, rootY: y, mode: .grab
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
            rootX: x, rootY: y,
            eventX: x &- tx, eventY: y &- ty,
            state: state,
            sameScreen: true
        )
        log?.log("  → \(isDown ? "ButtonPress" : "ButtonRelease") button=\(button) target=0x\(String(target, radix: 16)) at top=(\(x),\(y)) local=(\(x &- tx),\(y &- ty)) state=0x\(String(state, radix: 16))")
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
                rootX: x, rootY: y, mode: .grab
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
                    rootX: x, rootY: y, mode: .ungrab
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
        let target = deepestMappedWindow(topLevel: topLevel, x: x, y: y)
        let from = currentPointerWindow[topLevel]
        if from != target {
            currentPointerWindow[topLevel] = target
            emitCrossings(topLevel: topLevel, from: from, to: target, rootX: x, rootY: y)
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
            rootX: x, rootY: y,
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
        let target = deepestMappedWindow(topLevel: topLevel, x: x, y: y)
        currentPointerWindow[topLevel] = target
        emitCrossings(topLevel: topLevel, from: nil, to: target, rootX: x, rootY: y)
        refreshCursor(topLevel: topLevel)
    }

    /// Pointer left the NSView's content area. Emit LeaveNotify chain for
    /// whichever X window the pointer was last in, then clear the tracker.
    public func handlePointerExitedView(topLevel: UInt32) {
        guard byteOrder != nil else { return }
        guard let from = currentPointerWindow[topLevel] else { return }
        currentPointerWindow[topLevel] = nil
        emitCrossings(topLevel: topLevel, from: from, to: nil, rootX: 0, rootY: 0)
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
                eventX: rootX &- tlX, eventY: rootY &- tlY,
                state: 0, mode: mode,
                sameScreen: true, focus: false
            )
            log?.log("  → LeaveNotify target=0x\(String(window, radix: 16)) detail=\(detail) at top=(\(rootX),\(rootY))")
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
                eventX: rootX &- tlX, eventY: rootY &- tlY,
                state: 0, mode: mode,
                sameScreen: true, focus: false
            )
            log?.log("  → EnterNotify target=0x\(String(window, radix: 16)) detail=\(detail) at top=(\(rootX),\(rootY))")
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
        for id in toRemove { windows.remove(id) }
        if includeRoot { windows.remove(parent) }
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

    // MARK: - Grabs

    private func handleGrabPointer(_ r: GrabPointer, byteOrder: ByteOrder) {
        // We always succeed. Real X servers can return AlreadyGrabbed when
        // a different client holds the pointer grab, but our session is
        // single-client per definition (one X connection = one session
        // = one client view of the pointer). NotViewable / Frozen aren't
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
            emitCrossings(
                topLevel: topLevel,
                from: currentPointerWindow[topLevel],
                to: r.grabWindow,
                rootX: px, rootY: py, mode: .grab
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
            emitCrossings(
                topLevel: topLevel,
                from: grab.window,
                to: currentPointerWindow[topLevel],
                rootX: px, rootY: py, mode: .ungrab
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

        // Top-level dimensions changed — refresh clip regions for the
        // whole subtree BEFORE emitting descendant Exposes so the new
        // clipList drives the rect-list each Expose carries.
        ClipListEngine.recomputeClips(forTopLevel: id, in: windows)
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
    /// target. Returns (topLevel, dx, dy) when the drawable is a renderable
    /// window subtree; nil otherwise. For unknown drawable IDs, emits
    /// BadDrawable referencing the bad ID. For valid-but-unrendererable
    /// drawables (pixmaps and the root), silently drops with a log line — see
    /// the "draws to pixmaps and root silently drop" entry in SHORTCUTS for
    /// why this is a documented lie rather than BadImplementation today
    /// (dt-apps draw into pixmaps as backing buffers, and emitting an error
    /// would break a working flow we haven't gotten to rendering yet).
    func validateDrawTarget(_ drawable: UInt32, majorOpcode: UInt8) -> (UInt32, Int16, Int16)? {
        if !isKnownDrawable(drawable) {
            emitError(.drawable, majorOpcode: majorOpcode, badResourceId: drawable)
            return nil
        }
        if let target = topLevelAndOffset(for: drawable) {
            return target
        }
        log?.log("validateDrawTarget: drawable 0x\(String(drawable, radix: 16)) is known (pixmap or root) but not renderable; dropping op opcode=\(majorOpcode)")
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
    /// current visibility state from clipList, and emit VisibilityNotify
    /// when the state transitioned (and the window has VisibilityChangeMask
    /// in its event mask). Update the stored `lastVisibilityState` either
    /// way so future calls see correct prior state.
    ///
    /// State derivation:
    ///   - !mapped → nil (window not viewable; X11 spec doesn't emit
    ///     VisibilityNotify for transitions involving unmapped state)
    ///   - mapped + area(clipList) == 0 → 2 (FullyObscured)
    ///   - mapped + area(clipList) == width*height → 0 (Unobscured)
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
                let area = regionArea(entry.clipList)
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
    /// in borderPixel, then an INNER rect (the content area) in backPixel.
    /// The inner-on-top-of-outer ordering leaves only the ring visible. With
    /// borderWidth == 0, emits the single bg rect.
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
            out.append(WindowBackgroundRect(
                x: dx, y: dy, width: entry.width, height: entry.height,
                color: windowBackground(entry.id, byteOrder: byteOrder)
            ))
        }
        return out
    }

    /// Build a QueryFontReply that reports the resolved font's cell-snapped
    /// metrics. Monospace path: min/max CharInfo bounds equal, charInfos
    /// empty (means "every char in range has metrics equal to minBounds"
    /// per X11 spec). Range covers printable ASCII 32..126 — Phase 4 polish
    /// extends to full Latin-1 / iso10646 BMP.
    private func makeQueryFontReply(resolved: ResolvedFont, sequence: UInt16) -> QueryFontReply {
        let bounds = CharInfo(
            leftSideBearing: 0,
            rightSideBearing: Int16(resolved.cellWidth),
            characterWidth: Int16(resolved.cellWidth),
            ascent: Int16(resolved.ascent),
            descent: Int16(resolved.descent),
            attributes: 0
        )
        return QueryFontReply(
            sequenceNumber: sequence,
            minBounds: bounds,
            maxBounds: bounds,
            minCharOrByte2: 32, maxCharOrByte2: 126,
            defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0,
            allCharsExist: true,
            fontAscent: Int16(resolved.ascent),
            fontDescent: Int16(resolved.descent),
            properties: [],
            charInfos: []
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
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolySegment.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolySegment.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.segments.map {
            LineSegment(
                x1: $0.x1 &+ dx, y1: $0.y1 &+ dy,
                x2: $0.x2 &+ dx, y2: $0.y2 &+ dy
            )
        }
        bridge.drawPolySegment(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            segments: translated,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handlePolyLine(_ r: PolyLine, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolyLine.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyLine.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
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
            topLevel: top,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            points: points,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handleFillPoly(_ r: FillPoly, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: FillPoly.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: FillPoly.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
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
            topLevel: top,
            foreground: resolveColor(state.foreground),
            points: points,
            evenOdd: state.fillRuleEvenOdd,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyFillRectangle(_ r: PolyFillRectangle, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolyFillRectangle.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyFillRectangle.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.rectangles.map {
            Rectangle(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height
            )
        }
        bridge.drawPolyFillRectangle(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            function: state.function,
            rectangles: translated,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyRectangle(_ r: PolyRectangle, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolyRectangle.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyRectangle.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.rectangles.map {
            Rectangle(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height
            )
        }
        bridge.drawPolyRectangle(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            rectangles: translated,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handlePolyArc(_ r: PolyArc, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolyArc.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyArc.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.arcs.map {
            Arc(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height,
                angle1: $0.angle1, angle2: $0.angle2
            )
        }
        bridge.drawPolyArc(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            arcs: translated,
            clipRectangles: state.clipRectangles,
            dashes: state.dashes,
            dashOffset: state.dashOffset
        )
    }

    private func handlePolyFillArc(_ r: PolyFillArc, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolyFillArc.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyFillArc.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.arcs.map {
            Arc(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height,
                angle1: $0.angle1, angle2: $0.angle2
            )
        }
        bridge.drawPolyFillArc(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            arcs: translated,
            clipRectangles: state.clipRectangles
        )
    }

    private func handleImageText8(_ r: ImageText8, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: ImageText8.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: ImageText8.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        // Pull the GC's font; fall back to "fixed" if no font set.
        let resolvedFont: ResolvedFont
        if let entry = fonts.get(state.font) {
            resolvedFont = entry.resolved
        } else {
            resolvedFont = FontResolver.resolve(name: "fixed")
        }
        bridge.drawImageText8(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            background: resolveColor(state.background),
            font: resolvedFont,
            x: r.x &+ dx, y: r.y &+ dy,
            string: r.string,
            clipRectangles: state.clipRectangles
        )
    }

    private func handlePolyText8(_ r: PolyText8, byteOrder: ByteOrder) {
        guard let (top, dx, dy) = validateDrawTarget(r.drawable, majorOpcode: PolyText8.opcode) else { return }
        guard validateGC(r.gc, majorOpcode: PolyText8.opcode) != nil else { return }
        guard let bridge = bridge else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let resolvedFont: ResolvedFont
        if let entry = fonts.get(state.font) {
            resolvedFont = entry.resolved
        } else {
            resolvedFont = FontResolver.resolve(name: "fixed")
        }
        bridge.drawPolyText8(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            font: resolvedFont,
            x: r.x &+ dx, y: r.y &+ dy,
            items: r.items,
            clipRectangles: state.clipRectangles
        )
    }

    private func handleCopyArea(_ r: CopyArea, byteOrder: ByteOrder) {
        // Per XError-honesty policy: distinguish unknown drawables (BadDrawable
        // referencing the offending ID) from valid-but-unimplemented cases
        // (cross-window copies and pixmap source/dest are spec-legal, we just
        // don't implement them yet — BadImplementation). Validation runs
        // before the bridge guard so error semantics don't depend on whether
        // we have a rendering target.
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
        // Phase 1: same-window copies only (xterm's scrolling case).
        guard let (srcTop, srcDX, srcDY) = topLevelAndOffset(for: r.srcDrawable),
              let (dstTop, dstDX, dstDY) = topLevelAndOffset(for: r.dstDrawable),
              srcTop == dstTop else {
            log?.log("  CopyArea: cross-window or pixmap not supported yet (src=0x\(String(r.srcDrawable, radix: 16)) dst=0x\(String(r.dstDrawable, radix: 16)))")
            emitError(.implementation, majorOpcode: CopyArea.opcode)
            return
        }
        log?.log("  CopyArea top=0x\(String(srcTop, radix: 16)) src=(\(r.srcX),\(r.srcY)) dst=(\(r.dstX),\(r.dstY)) \(r.width)x\(r.height)")
        let state = gcState(r.gc, byteOrder: byteOrder)
        bridge.copyArea(
            topLevel: srcTop,
            srcX: r.srcX &+ srcDX, srcY: r.srcY &+ srcDY,
            dstX: r.dstX &+ dstDX, dstY: r.dstY &+ dstDY,
            width: r.width, height: r.height,
            clipRectangles: state.clipRectangles
        )
        // X11 spec: every CopyArea on a GC with graphics-exposures=True must
        // be followed by GraphicsExpose events (one per obscured source
        // region) OR a single NoExpose if the source had no obscured
        // pixels. graphics-exposures defaults to True; xterm's CopyWait
        // (util.c:709) BLOCKS in XWindowEvent waiting for one of these.
        // Without it, the first scroll works but every subsequent scroll
        // hangs xterm. Our same-window backing-store copies never have
        // obscured source regions, so we always emit NoExpose.
        let noExpose = NoExposureEvent(
            sequenceNumber: sequenceNumber,
            drawable: r.dstDrawable,
            minorOpcode: 0,
            majorOpcode: 62  // X_CopyArea
        )
        outbound.append(noExpose.encode(byteOrder: byteOrder))
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
        bridge.clearArea(
            topLevel: top,
            x: r.x &+ dx, y: r.y &+ dy,
            width: fillW, height: fillH,
            background: bg
        )
        // X11 spec: if `exposures` is True, the server sends an Expose event
        // for the cleared region (so the client can redraw on top). xcalc's
        // LCD update sequence is "ClearArea + wait for Expose + draw digits"
        // — without this we cleared the LCD but xcalc never redrew.
        if r.exposures, entry.eventMask & (1 << 15) != 0 {
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
            log?.log("request: bogus length \(lenIn4) — closing")
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
            log?.log("request: decode error opcode=\(bytes[0]) seq=\(sequenceNumber): \(error)")
            // M1: don't synthesize XError for decode failures yet — for our
            // capture corpus, decode is trusted. If a real client sends bytes
            // we can't decode, that's a framer bug, not a protocol error.
        }
        return totalSize
    }

    // MARK: - Dispatch

    private func dispatch(_ request: Request, byteOrder: ByteOrder) {
        switch request {

        case .createWindow(let r):
            let mask = r.valueMask
            let eventMask = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CW.eventMask, byteOrder: byteOrder) ?? 0
            let backPixel = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CW.backPixel, byteOrder: byteOrder)
            let borderPixel = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CW.borderPixel, byteOrder: byteOrder)
            let cursor = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CW.cursor, byteOrder: byteOrder)
            let overrideRedirect =
                (ValueListReader.read(valueList: r.valueList, mask: mask, bit: CW.overrideRedirect, byteOrder: byteOrder) ?? 0) != 0
            let entry = WindowEntry(
                id: r.wid, parent: r.parent, depth: r.depth,
                x: r.x, y: r.y, width: r.width, height: r.height,
                borderWidth: r.borderWidth, windowClass: r.windowClass, visual: r.visual,
                valueMask: mask, valueList: r.valueList,
                mapped: false, eventMask: eventMask,
                backPixel: backPixel,
                borderPixel: borderPixel,
                cursor: (cursor == 0) ? nil : cursor,
                overrideRedirect: overrideRedirect
            )
            windows.insert(entry)
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
                let descendants = mappedDescendantSnapshots(of: r.window)
                let topMask = entry?.eventMask ?? 0
                let topExposeRects = exposeRectsForWindow(r.window)
                let currentGeom = entry.map { TopLevelGeometry(
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
                    let rects = paintRectsForWindow(entry: entry, dx: dx, dy: dy, byteOrder: byteOrder)
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
                if let entry = windows.get(r.window),
                   entry.eventMask & (1 << 15) != 0 {
                    let rects = exposeRectsForWindow(r.window)
                    MockWindowBridge.emitExposesForRects(
                        window: r.window, rects: rects,
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
            log?.log("  ConfigureWindow window=0x\(String(r.window, radix: 16)) mask=0x\(String(r.valueMask, radix: 16)) x=\(x.map(String.init) ?? "-") y=\(y.map(String.init) ?? "-") w=\(w.map(String.init) ?? "-") h=\(h.map(String.init) ?? "-")")
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
                if sizeChanged || posChanged {
                    // StructureNotify variant on the window itself.
                    if entry.eventMask & structureNotifyMask != 0 {
                        log?.log("  → emit ConfigureNotify on 0x\(String(r.window, radix: 16)) \(new.width)x\(new.height) at (\(new.x),\(new.y))")
                        let cfgEv = ConfigureNotifyEvent(
                            sequenceNumber: sequenceNumber,
                            event: r.window, window: r.window, aboveSibling: 0,
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
                            window: win, aboveSibling: 0,
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

                // E2: emit Expose using clipList rects when the window's
                // size grew. clipList ∩ (new - old) would be exact; using
                // clipList alone is a defensible over-emit (already-
                // painted pixels get re-Exposed but clients redraw
                // idempotently). Step F refines this with proper region
                // delta math.
                let sizeGrew = new.width > old.width || new.height > old.height
                if sizeGrew && (entry.eventMask & MockWindowBridge.exposureMask != 0) {
                    log?.log("  → emit Expose on 0x\(String(r.window, radix: 16)) \(new.width)x\(new.height)")
                    let rects = exposeRectsForWindow(r.window)
                    MockWindowBridge.emitExposesForRects(
                        window: r.window, rects: rects,
                        byteOrder: byteOrder, sequence: sequenceNumber,
                        outbound: outbound
                    )
                }
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
            properties.change(
                window: r.window, property: r.property, type: r.type,
                format: r.format.rawValue, mode: r.mode.rawValue, value: r.data
            )
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
            // Parse the font name (XLFD or alias), resolve to a Mac substitute
            // with cell-snapped metrics. Stored on the FontEntry so QueryFont
            // and any future text-rendering dispatch can answer without
            // re-parsing.
            let nameStr = String(decoding: r.name, as: UTF8.self)
            let resolved = FontResolver.resolve(name: nameStr)
            fonts.insert(FontEntry(id: r.fid, name: r.name, resolved: resolved))

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

        case .createPixmap(let r):
            pixmaps.insert(PixmapEntry(id: r.pid, drawable: r.drawable, depth: r.depth, width: r.width, height: r.height))

        case .freePixmap(let r):
            guard pixmaps.get(r.pixmap) != nil else {
                emitError(.pixmap, majorOpcode: FreePixmap.opcode, badResourceId: r.pixmap)
                break
            }
            pixmaps.remove(r.pixmap)

        case .createGC(let r):
            gcs.insert(id: r.cid, drawable: r.drawable, valueMask: r.valueMask, valueList: r.valueList, byteOrder: byteOrder)

        case .changeGC(let r):
            guard validateGC(r.gc, majorOpcode: ChangeGC.opcode) != nil else { break }
            gcs.change(r.gc, valueMask: r.valueMask, valueList: r.valueList, byteOrder: byteOrder)

        case .freeGC(let r):
            guard validateGC(r.gc, majorOpcode: FreeGC.opcode) != nil else { break }
            gcs.remove(r.gc)

        case .allocColor(let r):
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
            // PutImage needs depth/format-aware decoding (Bitmap / XYPixmap
            // / ZPixmap) and a pixel-storage model on PixmapEntry that we
            // don't have yet — pixmaps are tracked id/depth/dims-only.
            // For now this is a documented no-op (logged in OPCODE_STATUS /
            // SHORTCUTS). We still validate drawable + GC arguments at
            // entry per XError-honesty policy: unknown drawable → BadDrawable,
            // unknown GC → BadGC. The silent-drop is preserved for the
            // valid-drawable case (load-bearing for dt-apps' button chrome
            // pattern — same as the "draws to pixmaps silently drop" entry).
            if !isKnownDrawable(r.drawable) {
                emitError(.drawable, majorOpcode: PutImage.opcode, badResourceId: r.drawable)
                break
            }
            guard validateGC(r.gc, majorOpcode: PutImage.opcode) != nil else { break }
            log?.log("  PutImage drawable=0x\(String(r.drawable, radix: 16)) gc=0x\(String(r.gc, radix: 16)) format=\(r.format) depth=\(r.depth) \(r.width)x\(r.height) at (\(r.dstX),\(r.dstY)) — silent-drop, see SHORTCUTS")

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
                entry.parent = r.parent
                entry.x = r.x
                entry.y = r.y
                windows.insert(entry)
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
            // Single-client server: GrabServer's "block all other clients"
            // semantic has no effect. We accept the request to keep the
            // wire conversation flowing; client expects no reply.
            break

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
                coordinator.clearSelectionOwner(r.selection)
                log?.log("SetSelectionOwner: cleared selection atom=\(r.selection)")
            } else {
                coordinator.setSelectionOwner(r.selection, window: r.owner, time: r.time)
                log?.log("SetSelectionOwner: selection atom=\(r.selection) owner=0x\(String(r.owner, radix: 16)) time=\(r.time)")
                let prefs = clipboardPrefs.current
                if r.selection == 1, prefs.enabled, prefs.mode == .xtermStyle {
                    requestSelectionConversion(selectionAtom: 1)
                }
            }

        // Replies we don't yet implement — note them so the live test surfaces
        // what's missing without dropping the connection.
        case .getWindowAttributes(let r):
            guard validateWindowOrRoot(r.window, majorOpcode: GetWindowAttributes.opcode) else { break }
            // Synthesise a reply from the WindowEntry. Most fields are
            // sensible defaults; the live ones xterm cares about are class,
            // mapState, your-event-mask, and colormap.
            let entry = windows.get(r.window)
            let mapState: UInt8 = (entry?.mapped == true) ? 2 : 0   // Viewable / Unmapped
            let visualId = config.rootVisualId
            let cls: UInt16 = entry?.windowClass == .inputOnly ? 2 : 1
            let reply = GetWindowAttributesReply(
                sequenceNumber: sequenceNumber,
                visualId: visualId,
                windowClass: cls,
                mapState: mapState,
                colormap: config.defaultColormapId,
                allEventMasks: entry?.eventMask ?? 0,
                yourEventMask: entry?.eventMask ?? 0
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
            // Coordinate convention: each top-level X window is treated as
            // sitting at (0,0) in root coordinates. That matches how we
            // already stamp `rootX`/`rootY` on input events (using top-level
            // local coords). So translating between any two windows in the
            // same top-level subtree is straight subtraction; translating
            // between a top-level descendant and the root window is the
            // descendant's absolute origin within its top-level (since the
            // top-level itself is at (0,0) in root). All windows share the
            // single X screen → sameScreen=true.
            let srcTopLevel = topLevelAncestor(of: r.srcWindow)
            let dstTopLevel = topLevelAncestor(of: r.dstWindow)
            let isRoot: (UInt32) -> Bool = { $0 == self.config.rootWindowId }
            let srcRoot: (Int16, Int16) = {
                if isRoot(r.srcWindow) { return (r.srcX, r.srcY) }
                guard let stl = srcTopLevel else { return (r.srcX, r.srcY) }
                let (sx, sy) = self.absoluteOrigin(of: r.srcWindow, topLevel: stl)
                return (sx &+ r.srcX, sy &+ r.srcY)
            }()
            let dstOriginInRoot: (Int16, Int16) = {
                if isRoot(r.dstWindow) { return (0, 0) }
                guard let dtl = dstTopLevel else { return (0, 0) }
                return self.absoluteOrigin(of: r.dstWindow, topLevel: dtl)
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
            // Walk our window table for direct children of the requested
            // window. Per X11 spec the children list is in bottom-to-top
            // stacking order; we don't actually track stacking, so we
            // return them in our table-iteration order — works fine for
            // every Xt/Motif use we've seen, which only consumes the LIST
            // (e.g. to enumerate children for property propagation), not
            // its order. Parent is None (0) for the root window.
            let children = windows.windows.compactMap { (id, w) in
                w.parent == r.window ? id : nil
            }
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
            // in root coords (top-level local under our (0,0)-per-top-level
            // convention), the deepest mapped descendant of the queried
            // window that contains the pointer (or None), and the current
            // mod+button mask. winX/winY are relative to the queried
            // window. Per X spec same-screen=true unless the pointer is
            // on a different screen — single-screen for us.
            let (px, py) = lastPointerXY ?? (0, 0)
            var winX: Int16 = px
            var winY: Int16 = py
            var child: UInt32 = 0
            if let topLevel = lastPointerTopLevel {
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
                rootX: px, rootY: py,
                winX: winX, winY: winY,
                mask: mask
            )
            log?.log("  QueryPointer window=0x\(String(r.window, radix: 16)) → child=0x\(String(child, radix: 16)) root=(\(px),\(py)) win=(\(winX),\(winY)) mask=0x\(String(mask, radix: 16))")
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
    case .createGlyphCursor: return "CreateGlyphCursor"
    case .freeCursor: return "FreeCursor"
    case .recolorCursor: return "RecolorCursor"
    case .listExtensions: return "ListExtensions"
    case .getKeyboardMapping: return "GetKeyboardMapping"
    case .getModifierMapping: return "GetModifierMapping"
    case .getPointerMapping: return "GetPointerMapping"
    case .unknown(let op, _): return "unknown(\(op))"
    }
}
