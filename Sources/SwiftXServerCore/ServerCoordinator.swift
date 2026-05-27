import Foundation
import Framer

// Cross-session shared state for a multi-client server.
//
// In X11 some resources are per-server (atoms; selection ownership) and some
// are per-client (windows, GCs, properties on those windows, fonts). This
// class owns the per-server stuff so multiple ServerSessions can see a
// consistent view, and hands out non-overlapping resource-id ranges per
// connection so client-allocated IDs don't collide across sessions.
//
// Single-client servers can just construct a default coordinator and keep
// using it. Tests do this implicitly via ServerSession's default arg.

public final class ServerCoordinator: @unchecked Sendable {

    /// Shared atom table. X11 atoms are global per server (xterm interns
    /// "WM_CLASS" and gets atom 69; xcalc later interning "WM_CLASS" must
    /// get the same 69). Lives here, not on the session.
    public let atoms = AtomTable()

    /// Shared default colormap. X11 colormaps are server resources; every
    /// client on the same screen sees the same default. If xterm allocates
    /// pixel 17 = green, xcalc reading pixel 17 must also see green. Lives
    /// on the coordinator for the same reason atoms do.
    public let colors = ColorTable()

    /// Per-selection (owner window, time). Reads/writes are guarded by
    /// `lock`. PRIMARY (atom 1) is the only selection that matters in the
    /// xterm-on-u5 era; all selections are tracked anyway.
    public struct SelectionState: Equatable, Sendable {
        public var window: UInt32
        public var time: UInt32
    }

    private let lock = NSLock()
    private var selectionOwners: [UInt32: SelectionState] = [:]
    private var nextClientNumber: UInt32 = 0

    /// Resource-id ranges follow X11 convention: each client gets an
    /// `idBase | (idMask & N)` slice. `templateBase` is the value the
    /// first client receives; clients 2..N get `templateBase + N * (idMask + 1)`.
    /// We use the ServerConfig.default values as the template (base
    /// 0x04400000, mask 0x001FFFFF — 21 bits per client, 2M IDs each).
    public init() {}

    // MARK: - Per-client allocation

    /// Hand out a resource-id-base for a fresh accept. Each call returns a
    /// distinct, non-overlapping value derived from the supplied template
    /// base/mask. Thread-safe.
    public func allocateClientResourceIdBase(template: ServerConfig) -> (base: UInt32, mask: UInt32, clientNumber: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        nextClientNumber += 1
        // Stride = mask + 1. Client n's base = templateBase + (n-1) * stride.
        // mask stays the same — every client gets the same slice size.
        let stride = template.resourceIdMask &+ 1
        let base = template.resourceIdBase &+ (nextClientNumber &- 1) &* stride
        return (base: base, mask: template.resourceIdMask, clientNumber: nextClientNumber)
    }

    // MARK: - Selection state

    public func selectionOwner(_ atom: UInt32) -> SelectionState? {
        lock.lock(); defer { lock.unlock() }
        return selectionOwners[atom]
    }

    public func setSelectionOwner(_ atom: UInt32, window: UInt32, time: UInt32) {
        lock.lock()
        selectionOwners[atom] = SelectionState(window: window, time: time)
        lock.unlock()
    }

    /// Atomically replace the owner of `atom` and return what was there
    /// before. Returns nil if the selection was previously unowned. The
    /// caller is responsible for emitting SelectionClear to the prior
    /// owner per X11 spec section 4.2.1.
    public func swapSelectionOwner(_ atom: UInt32, window: UInt32, time: UInt32) -> SelectionState? {
        lock.lock(); defer { lock.unlock() }
        let prior = selectionOwners[atom]
        selectionOwners[atom] = SelectionState(window: window, time: time)
        return prior
    }

    public func clearSelectionOwner(_ atom: UInt32) {
        lock.lock()
        selectionOwners.removeValue(forKey: atom)
        lock.unlock()
    }

    /// Revoke ownership of every selection currently held by any window in
    /// `windowIds`. Returns the atoms that were cleared so the caller can
    /// log / verify. Used by destroyWindow and session cleanup per spec
    /// (R6 dispatch.c:DeleteWindowFromAnySelections /
    /// DeleteClientFromAnySelections). Spec doesn't require SelectionClear
    /// emission for the destroy/disconnect path (the window or client is
    /// gone, no one to deliver to).
    @discardableResult
    public func revokeSelections(ownedBy windowIds: Set<UInt32>) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        let stale = selectionOwners.filter { windowIds.contains($0.value.window) }.map { $0.key }
        for atom in stale { selectionOwners.removeValue(forKey: atom) }
        return stale
    }

    /// All atoms currently owned by `window`. Read-only view; coordinator
    /// holds the lock for the duration.
    public func selectionsOwned(by window: UInt32) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return selectionOwners.compactMap { $0.value.window == window ? $0.key : nil }
    }

    // MARK: - Root-window properties (server-global)

    private let rootProperties = PropertyTable()
    private var rootObservers: [UInt64: WeakObserver] = [:]

    private struct WeakObserver {
        weak var value: RootPropertyObserver?
    }

    @discardableResult
    public func changeRootProperty(window: UInt32, property: UInt32, type: UInt32, format: UInt8, mode: UInt8, value: [UInt8]) -> PropertyTable.ChangeResult {
        lock.lock(); defer { lock.unlock() }
        return rootProperties.change(window: window, property: property, type: type, format: format, mode: mode, value: value)
    }

    public func getRootProperty(window: UInt32, property: UInt32) -> PropertyEntry? {
        lock.lock(); defer { lock.unlock() }
        return rootProperties.get(window: window, property: property)
    }

    public func deleteRootProperty(window: UInt32, property: UInt32) {
        lock.lock(); defer { lock.unlock() }
        rootProperties.delete(window: window, property: property)
    }

    public func rootPropertyExists(window: UInt32, property: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rootProperties.get(window: window, property: property) != nil
    }

    public func registerRootPropertyObserver(token: UInt64, observer: RootPropertyObserver) {
        lock.lock(); defer { lock.unlock() }
        rootObservers[token] = WeakObserver(value: observer)
    }

    public func unregisterRootPropertyObserver(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        rootObservers.removeValue(forKey: token)
    }

    public func fanOutRootPropertyNotify(atom: UInt32, state: PropertyState, excludeToken: UInt64) {
        lock.lock()
        let live = rootObservers.compactMap { (tok, w) -> (UInt64, RootPropertyObserver)? in
            guard let obs = w.value else { return nil }
            return (tok, obs)
        }
        rootObservers = rootObservers.filter { $0.value.value != nil }
        lock.unlock()
        for (tok, obs) in live {
            if tok == excludeToken { continue }
            if obs.hasPropertyChangeMaskOnRoot {
                obs.deliverRootPropertyNotify(atom: atom, state: state)
            }
        }
    }
}

public protocol RootPropertyObserver: AnyObject {
    var hasPropertyChangeMaskOnRoot: Bool { get }
    func deliverRootPropertyNotify(atom: UInt32, state: PropertyState)
}
