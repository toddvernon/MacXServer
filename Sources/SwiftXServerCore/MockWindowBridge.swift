import Framer

// Test bridge that records every call so M2 unit tests can assert the session
// triggers the right window lifecycle hooks. Also synthesizes the "post-map"
// event sequence inline (synchronously) so the tests don't need a real Cocoa
// runloop.

public final class MockWindowBridge: WindowBridge, @unchecked Sendable {

    public struct Registered: Equatable, Sendable {
        public var id: UInt32
        public var geometry: TopLevelGeometry
        public var eventMask: UInt32
    }

    public private(set) var registered: [Registered] = []
    public private(set) var mapped: [UInt32] = []
    public private(set) var unmapped: [UInt32] = []
    public private(set) var destroyed: [UInt32] = []
    public private(set) var titles: [UInt32: String] = [:]
    public private(set) var descendantsMapped: [UInt32] = []

    /// Magic synthetic parent ID that ReparentNotify reports. Real Cocoa bridge
    /// uses a similar fabricated ID — there's no actual X window for the
    /// macOS frame.
    public static let syntheticParentId: UInt32 = 0xC0FFEE00

    public init() {}

    private var resizeHandler: (@Sendable (UInt32, UInt16, UInt16) -> Void)?

    public func setOnTopLevelResize(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {
        resizeHandler = handler
    }

    /// Test helper: pretend the user resized the NSWindow for `id`.
    public func simulateResize(id: UInt32, width: UInt16, height: UInt16) {
        resizeHandler?(id, width, height)
    }

    public func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {
        registered.append(Registered(id: id, geometry: geometry, eventMask: eventMask))
    }

    public func mapTopLevel(
        id: UInt32,
        geometry: TopLevelGeometry,
        eventMask: UInt32,
        topLevelExposeRects: [BoxRec],
        descendants: [DescendantSnapshot],
        overrideRedirect: Bool = false,
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    ) {
        mapped.append(id)
        Self.emitMapSequence(
            window: id, geometry: geometry,
            topLevelEventMask: eventMask,
            topLevelExposeRects: topLevelExposeRects,
            descendants: descendants,
            overrideRedirect: overrideRedirect,
            byteOrder: byteOrder, sequence: sequence,
            outbound: outbound
        )
    }

    public func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        descendantsMapped.append(id)
    }

    public func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        unmapped.append(id)
        let event = UnmapNotifyEvent(sequenceNumber: sequence, event: id, window: id, fromConfigure: false)
        outbound.append(event.encode(byteOrder: byteOrder))
    }

    public func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        destroyed.append(id)
        let event = DestroyNotifyEvent(sequenceNumber: sequence, event: id, window: id)
        outbound.append(event.encode(byteOrder: byteOrder))
    }

    public func setTopLevelTitle(id: UInt32, title: String) {
        titles[id] = title
    }

    /// X11 ExposureMask bit per xproto X.h.
    public static let exposureMask: UInt32 = 1 << 15

    /// Emit ReparentNotify + ConfigureNotify + MapNotify on the top-level,
    /// then Expose on the top-level and any descendant whose event mask
    /// includes ExposureMask. Used by both Mock and Cocoa bridges so the
    /// emission order stays in one place. Per Step E1, Expose emission
    /// enumerates each window's clipList rect-list (in window-local
    /// coords) — a fully-covered window emits no Expose; a partially-
    /// obscured window emits one Expose per visible rect with the count
    /// field tracking how many siblings follow.
    public static func emitMapSequence(
        window: UInt32,
        geometry: TopLevelGeometry,
        topLevelEventMask: UInt32,
        topLevelExposeRects: [BoxRec],
        descendants: [DescendantSnapshot],
        overrideRedirect: Bool = false,
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue,
        syntheticParent: UInt32 = MockWindowBridge.syntheticParentId
    ) {
        // Override-redirect popups bypass the WM by spec — the WM doesn't
        // reparent them and shouldn't claim it did. Emitting a synthetic
        // ReparentNotify here used to confuse Motif's submenu state
        // machine (popup looked "stolen by the WM" → submenu dismissed
        // as soon as the user moused into it). Sun's X server emits
        // MapNotify + ConfigureNotify but no ReparentNotify for these,
        // verified against the quickplot-on-ss2 capture.
        if !overrideRedirect {
            let reparent = ReparentNotifyEvent(
                sequenceNumber: sequence,
                event: window, window: window, parent: syntheticParent,
                x: geometry.x, y: geometry.y,
                overrideRedirect: false
            )
            outbound.append(reparent.encode(byteOrder: byteOrder))
        }
        let configure = ConfigureNotifyEvent(
            sequenceNumber: sequence,
            event: window, window: window, aboveSibling: 0,
            x: geometry.x, y: geometry.y,
            width: geometry.width, height: geometry.height,
            borderWidth: geometry.borderWidth,
            overrideRedirect: overrideRedirect
        )
        let mappedEv = MapNotifyEvent(
            sequenceNumber: sequence,
            event: window, window: window,
            overrideRedirect: overrideRedirect
        )
        outbound.append(configure.encode(byteOrder: byteOrder))
        outbound.append(mappedEv.encode(byteOrder: byteOrder))

        if topLevelEventMask & exposureMask != 0 {
            emitExposesForRects(
                window: window, rects: topLevelExposeRects,
                byteOrder: byteOrder, sequence: sequence, outbound: outbound
            )
        }
        for d in descendants where d.eventMask & exposureMask != 0 {
            emitExposesForRects(
                window: d.id, rects: d.exposeRects,
                byteOrder: byteOrder, sequence: sequence, outbound: outbound
            )
        }
    }

    /// Emit one Expose per visible rect (window-local coords) with the
    /// `count` field set to the number of siblings remaining in the
    /// batch. Per spec a `count > 0` tells the client more Expose events
    /// for the same window are about to follow; some toolkits use this
    /// to coalesce redraws. Empty rect list emits nothing.
    public static func emitExposesForRects(
        window: UInt32,
        rects: [BoxRec],
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    ) {
        let n = rects.count
        for (i, r) in rects.enumerated() {
            // Expose's x/y are UInt16 (per protocol; window-local coords
            // that should be non-negative for a visible rect). Clamp at 0
            // defensively — a negative top-left here would indicate a
            // bug in clipList computation or window-local translation.
            let x = r.x1 < 0 ? 0 : UInt16(clamping: r.x1)
            let y = r.y1 < 0 ? 0 : UInt16(clamping: r.y1)
            let expose = ExposeEvent(
                sequenceNumber: sequence, window: window,
                x: x, y: y,
                width: UInt16(clamping: r.x2 - r.x1),
                height: UInt16(clamping: r.y2 - r.y1),
                count: UInt16(clamping: n - 1 - i)
            )
            outbound.append(expose.encode(byteOrder: byteOrder))
        }
    }
}
