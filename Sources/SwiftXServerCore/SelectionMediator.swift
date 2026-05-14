import Framer

// Owns the selection-conversion policy for a ServerSession. Two paths:
//
//   1. Real client owns the selection (window id < 0xFFFE_0000):
//      forward a SelectionRequest event to the owner. The owner replies
//      via ChangeProperty + SetSelectionOwner-style protocol per ICCCM,
//      and we route the resulting bytes back to the requestor.
//
//   2. Server-internal stub owns the selection (window id ≥ 0xFFFE_0000):
//      the stub has no client behind it, so the standard SelectionRequest
//      forwarding wedges. We short-circuit: write empty bytes to the
//      requestor's property and emit SelectionNotify(property=r.property)
//      signalling "successfully converted to empty data." The dt-apps
//      pattern uses this — they read the actual payload (e.g. SDT Pixel
//      Set) via a direct GetProperty on the stub BEFORE the
//      ConvertSelection, so the ConvertSelection itself is a formality.
//
// The mediator owns the CDE customization daemon impersonation setup —
// previously a wall of inline init code in ServerSession.init. Future
// stub mediations (drag-drop, additional selections) plug in here.

/// What ConvertSelection resolved to. Caller (ServerSession) executes
/// the action, encoding bytes with its byteOrder + sequence number.
public enum SelectionConvertResult {
    /// No owner registered for this selection. Emit SelectionNotify
    /// with property=None (0) per X11 spec section 10.4.
    case replyNoOwner

    /// Real client owns the selection. Forward a SelectionRequest event
    /// to the owner; they reply via the ICCCM protocol.
    case forwardToRealOwner(ownerWindow: UInt32)

    /// Server-internal stub owns the selection. Write empty bytes to
    /// the requestor's property and emit SelectionNotify(property=
    /// r.property) signalling success.
    case stubOwnerReplyEmpty(stubWindow: UInt32)
}

/// Selection-conversion policy for a single ServerSession. Holds refs
/// to the resource tables it needs to consult. Not Sendable — owned by
/// the session and accessed from the protocol queue only.
public final class SelectionMediator {

    private let atoms: AtomTable
    private let coordinator: ServerCoordinator
    private let properties: PropertyTable
    private let windows: WindowTable
    private let config: ServerConfig

    /// Lowest window id reserved for server-internal stub windows. Any
    /// window id at or above this is a stub (CDE customization daemon
    /// at 0xFFFE_0003 today; future stubs may take other ids in this
    /// range). Real-client-allocated ids never reach this range because
    /// the resourceIdBase is 0x4400000 with mask 0x3FFFFF.
    public static let stubWindowFloor: UInt32 = 0xFFFE_0000

    public init(
        atoms: AtomTable,
        coordinator: ServerCoordinator,
        properties: PropertyTable,
        windows: WindowTable,
        config: ServerConfig
    ) {
        self.atoms = atoms
        self.coordinator = coordinator
        self.properties = properties
        self.windows = windows
        self.config = config
    }

    /// True iff `window` is in the server-internal stub range.
    public func isStubWindow(_ window: UInt32) -> Bool {
        return window >= Self.stubWindowFloor
    }

    /// Resolve a ConvertSelection request to the action the session
    /// should take. Pure decision — caller does the actual emission +
    /// property writes.
    public func convertSelection(_ r: ConvertSelection) -> SelectionConvertResult {
        guard let ownerState = coordinator.selectionOwner(r.selection) else {
            return .replyNoOwner
        }
        if isStubWindow(ownerState.window) {
            return .stubOwnerReplyEmpty(stubWindow: ownerState.window)
        }
        return .forwardToRealOwner(ownerWindow: ownerState.window)
    }

    // MARK: - Stub-daemon setup

    /// Impersonate the CDE customization daemon for the "Customize
    /// Data:N" selection.
    ///
    /// Background. dtcalc / dtterm / probably all dt-apps probe this
    /// selection at init: gold shows GetSelectionOwner returning a daemon
    /// window, then a direct GetProperty(SDT Pixel Set) on that window.
    /// When the selection has no owner (our prior behaviour), dt apps
    /// fall back to a formal ConvertSelection that we answered with
    /// property=None per spec — Xt then wedges indefinitely (verified by
    /// capture+wait 2 minutes 2026-05-10). The "no daemon" fallback in
    /// Solaris Xt is apparently untested in real installs (dtsession is
    /// always running under CDE), so its timeout-or-fall-through path
    /// doesn't actually fire.
    ///
    /// Fix: pretend a daemon is here. Register a stub window as owner of
    /// Customize Data:0. The ConvertSelection short-circuit (above)
    /// answers stub-owned conversions with empty bytes + a successful
    /// SelectionNotify, and dt-apps proceed.
    ///
    /// The "SDT Pixel Set" property is also pre-published on the stub
    /// window because dt-apps read it via direct GetProperty BEFORE the
    /// formal ConvertSelection. Bytes captured 2026-05-10 from u5's
    /// real CDE customization daemon via dtcalc-sun.xtap seq=29
    /// GetProperty reply.
    public func installCDECustomizationDaemonImpersonation() {
        let cdeDaemonWindow: UInt32 = 0xFFFE_0003
        windows.insert(WindowEntry(
            id: cdeDaemonWindow,
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
        let customizeAtom = atoms.intern("Customize Data:0")
        coordinator.setSelectionOwner(customizeAtom, window: cdeDaemonWindow, time: 0)

        let sdtPixelSetAtom = atoms.intern("SDT Pixel Set")
        let stringAtom: UInt32 = 31  // X11 predefined STRING atom
        let sdtPixelSetBytes = Array(
            "2_4_8_6_7_5_9_d_b_c_a_e_12_10_11_f_13_17_15_16_14_9_d_b_c_a_9_d_b_c_a_e_12_10_11_f_9_d_b_c_a_1".utf8
        )
        properties.change(
            window: cdeDaemonWindow,
            property: sdtPixelSetAtom,
            type: stringAtom,
            format: 8,
            mode: 0,
            value: sdtPixelSetBytes
        )
    }
}
