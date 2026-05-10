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

    public func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {
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
            descendants: descendants,
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
    /// emission order stays in one place.
    public static func emitMapSequence(
        window: UInt32,
        geometry: TopLevelGeometry,
        topLevelEventMask: UInt32,
        descendants: [DescendantSnapshot],
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue,
        syntheticParent: UInt32 = MockWindowBridge.syntheticParentId
    ) {
        let reparent = ReparentNotifyEvent(
            sequenceNumber: sequence,
            event: window, window: window, parent: syntheticParent,
            x: geometry.x, y: geometry.y,
            overrideRedirect: false
        )
        let configure = ConfigureNotifyEvent(
            sequenceNumber: sequence,
            event: window, window: window, aboveSibling: 0,
            x: geometry.x, y: geometry.y,
            width: geometry.width, height: geometry.height,
            borderWidth: geometry.borderWidth,
            overrideRedirect: false
        )
        let mappedEv = MapNotifyEvent(
            sequenceNumber: sequence,
            event: window, window: window,
            overrideRedirect: false
        )
        outbound.append(reparent.encode(byteOrder: byteOrder))
        outbound.append(configure.encode(byteOrder: byteOrder))
        outbound.append(mappedEv.encode(byteOrder: byteOrder))

        if topLevelEventMask & exposureMask != 0 {
            let expose = ExposeEvent(
                sequenceNumber: sequence, window: window,
                x: 0, y: 0, width: geometry.width, height: geometry.height, count: 0
            )
            outbound.append(expose.encode(byteOrder: byteOrder))
        }
        for d in descendants where d.eventMask & exposureMask != 0 {
            let expose = ExposeEvent(
                sequenceNumber: sequence, window: d.id,
                x: 0, y: 0, width: d.width, height: d.height, count: 0
            )
            outbound.append(expose.encode(byteOrder: byteOrder))
        }
    }
}
