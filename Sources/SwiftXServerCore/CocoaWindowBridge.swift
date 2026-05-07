import Foundation
import AppKit
import Framer

// Cocoa-side WindowBridge. Owns an NSWindow per top-level X window. AppKit
// calls always dispatch to the main thread; protocol events queue back to
// the OutboundQueue from the same main-thread block once the NSWindow is on
// screen.
//
// Per DECISIONS.md 2026-05-05 and RENDERING_DESIGN.md: rootless mode is
// primary — each top-level X window becomes a real NSWindow with native
// macOS chrome. The X subtree below the top-level is internal; drawing
// targets the single FlippedXView per top-level.

public final class CocoaWindowBridge: WindowBridge, @unchecked Sendable {

    private struct Slot: @unchecked Sendable {
        var geometry: TopLevelGeometry
        var eventMask: UInt32
        var pendingTitle: String?
        var window: NSWindow?
        var view: FlippedXView?
        var delegate: ResizeWindowDelegate?
    }

    private var slots: [UInt32: Slot] = [:]
    private let lock = NSLock()
    private var resizeHandler: (@Sendable (UInt32, UInt16, UInt16) -> Void)?
    private weak var log: ServerLogSink?

    public init(log: ServerLogSink? = nil) {
        self.log = log
    }

    public func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {
        resizeHandler = handler
    }

    // MARK: - WindowBridge

    public func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {
        lock.lock()
        slots[id] = Slot(geometry: geometry, eventMask: eventMask, pendingTitle: nil, window: nil, view: nil)
        lock.unlock()
    }

    public func mapTopLevel(
        id: UInt32,
        eventMask: UInt32,
        descendants: [DescendantSnapshot],
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    ) {
        lock.lock()
        guard let slot = slots[id] else { lock.unlock(); return }
        let geometry = slot.geometry
        let pendingTitle = slot.pendingTitle ?? "swift-x"
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let view = FlippedXView(frame: NSRect(x: 0, y: 0, width: Int(geometry.width), height: Int(geometry.height)))
            view.resizeBacking(width: Int(geometry.width), height: Int(geometry.height))
            view.autoresizingMask = [.width, .height]

            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let contentRect = NSRect(x: 100, y: 100,
                                     width: CGFloat(geometry.width),
                                     height: CGFloat(geometry.height))
            let win = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
            win.contentView = view
            win.title = pendingTitle
            win.isReleasedWhenClosed = false

            let delegate = ResizeWindowDelegate(windowId: id, bridge: self)
            win.delegate = delegate

            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.lock.lock()
            self.slots[id]?.window = win
            self.slots[id]?.view = view
            self.slots[id]?.delegate = delegate
            self.lock.unlock()

            MockWindowBridge.emitMapSequence(
                window: id, geometry: geometry,
                topLevelEventMask: eventMask,
                descendants: descendants,
                byteOrder: byteOrder, sequence: sequence,
                outbound: outbound
            )
        }
    }

    public func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let event = MapNotifyEvent(
            sequenceNumber: sequence, event: id, window: id,
            overrideRedirect: false
        )
        outbound.append(event.encode(byteOrder: byteOrder))
    }

    public func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let win = slot(id)?.window
        DispatchQueue.main.async {
            win?.orderOut(nil)
            let event = UnmapNotifyEvent(
                sequenceNumber: sequence, event: id, window: id, fromConfigure: false
            )
            outbound.append(event.encode(byteOrder: byteOrder))
        }
    }

    public func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let win = slot(id)?.window
        lock.lock()
        slots.removeValue(forKey: id)
        lock.unlock()
        DispatchQueue.main.async {
            win?.close()
            let event = DestroyNotifyEvent(
                sequenceNumber: sequence, event: id, window: id
            )
            outbound.append(event.encode(byteOrder: byteOrder))
        }
    }

    public func setTopLevelTitle(id: UInt32, title: String) {
        lock.lock()
        let win = slots[id]?.window
        if win == nil {
            slots[id]?.pendingTitle = title
        }
        lock.unlock()
        if let win = win {
            DispatchQueue.main.async { win.title = title }
        }
    }

    public func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {
        // M3 hook — mark the NSView's region for that descendant as needing
        // redraw. M2 doesn't do anything visible.
    }

    public func drawingTarget(for drawable: UInt32) -> Any? {
        slot(drawable)?.view
    }

    // MARK: - Drawing

    public func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            ctx.setLineWidth(CGFloat(max(lineWidth, 1)))
            for s in segments {
                ctx.move(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                ctx.addLine(to: CGPoint(x: CGFloat(s.x2), y: CGFloat(s.y2)))
            }
            ctx.strokePath()
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing,
                  !points.isEmpty else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            ctx.setLineWidth(CGFloat(max(lineWidth, 1)))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.strokePath()
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing,
                  !points.isEmpty else { return }
            ctx.saveGState()
            applyFill(ctx, foreground)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.closePath()
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyFill(ctx, background)
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    // MARK: - Helpers

    private func slot(_ id: UInt32) -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        return slots[id]
    }

    /// Called from the NSWindowDelegate after a user-driven resize. Resizes
    /// the FlippedXView's backing CGBitmapContext to match the new view size,
    /// then calls back into the session via `resizeHandler` so it can update
    /// WindowTable + emit ConfigureNotify.
    @MainActor
    fileprivate func handleNSWindowResize(id: UInt32) {
        let view = slot(id)?.view
        guard let view = view else { return }
        let bounds = view.bounds
        let newWidth = Int(bounds.width)
        let newHeight = Int(bounds.height)
        guard newWidth > 0, newHeight > 0 else { return }
        if newWidth != view.backingWidth || newHeight != view.backingHeight {
            view.resizeBacking(width: newWidth, height: newHeight)
            view.setNeedsDisplay(view.bounds)
        }
        resizeHandler?(id, UInt16(min(newWidth, 65535)), UInt16(min(newHeight, 65535)))
    }
}

/// NSWindowDelegate that catches user-driven resizes and forwards them to
/// the bridge. Stays @MainActor since NSWindowDelegate is.
@MainActor
private final class ResizeWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UInt32
    weak var bridge: CocoaWindowBridge?

    init(windowId: UInt32, bridge: CocoaWindowBridge) {
        self.windowId = windowId
        self.bridge = bridge
    }

    func windowDidResize(_ notification: Notification) {
        bridge?.handleNSWindowResize(id: windowId)
    }
}

private func applyForeground(_ ctx: CGContext, _ rgb: RGB16) {
    let r = CGFloat(rgb.red) / 65535.0
    let g = CGFloat(rgb.green) / 65535.0
    let b = CGFloat(rgb.blue) / 65535.0
    ctx.setStrokeColor(red: r, green: g, blue: b, alpha: 1)
}

private func applyFill(_ ctx: CGContext, _ rgb: RGB16) {
    let r = CGFloat(rgb.red) / 65535.0
    let g = CGFloat(rgb.green) / 65535.0
    let b = CGFloat(rgb.blue) / 65535.0
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
}
