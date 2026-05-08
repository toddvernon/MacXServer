import Foundation
import Framer

// Lightweight resource tables for windows, GCs, pixmaps, fonts, and properties.
// M1 just records what the client created — nothing rendering-related.

public struct WindowEntry: Equatable, Sendable {
    public var id: UInt32
    public var parent: UInt32
    public var depth: UInt8
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public var windowClass: WindowClass
    public var visual: UInt32
    public var valueMask: UInt32
    public var valueList: [UInt8]
    public var mapped: Bool
    public var eventMask: UInt32
    /// Effective CWBackPixel for the window. nil = no explicit background
    /// (windowBackground() falls back to white). Seeded from CreateWindow's
    /// valueList; ChangeWindowAttributes updates it.
    public var backPixel: UInt32?
    /// Effective CWBorderPixel. nil = no explicit border color (default black
    /// on real X servers). Drives the 1px-or-N-px ring painted around the
    /// window's content area.
    public var borderPixel: UInt32?

    public init(
        id: UInt32, parent: UInt32, depth: UInt8,
        x: Int16, y: Int16, width: UInt16, height: UInt16,
        borderWidth: UInt16, windowClass: WindowClass, visual: UInt32,
        valueMask: UInt32, valueList: [UInt8],
        mapped: Bool = false, eventMask: UInt32 = 0,
        backPixel: UInt32? = nil,
        borderPixel: UInt32? = nil
    ) {
        self.id = id; self.parent = parent; self.depth = depth
        self.x = x; self.y = y; self.width = width; self.height = height
        self.borderWidth = borderWidth; self.windowClass = windowClass
        self.visual = visual; self.valueMask = valueMask; self.valueList = valueList
        self.mapped = mapped; self.eventMask = eventMask
        self.backPixel = backPixel
        self.borderPixel = borderPixel
    }
}

public final class WindowTable: @unchecked Sendable {
    // Thread-safety: read thread and the Cocoa main thread (resize handler)
    // both touch this table. NSLock keeps the underlying dictionary safe.
    private let lock = NSLock()
    private var _windows: [UInt32: WindowEntry] = [:]

    public init() {}

    public var windows: [UInt32: WindowEntry] {
        lock.lock(); defer { lock.unlock() }
        return _windows
    }
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _windows.count
    }

    public func insert(_ window: WindowEntry) {
        lock.lock(); _windows[window.id] = window; lock.unlock()
    }
    public func remove(_ id: UInt32) {
        lock.lock(); _windows.removeValue(forKey: id); lock.unlock()
    }
    public func get(_ id: UInt32) -> WindowEntry? {
        lock.lock(); defer { lock.unlock() }
        return _windows[id]
    }

    public func setMapped(_ id: UInt32, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.mapped = value
        _windows[id] = w
    }

    public func setEventMask(_ id: UInt32, _ mask: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.eventMask = mask
        _windows[id] = w
    }

    public func setBackPixel(_ id: UInt32, _ pixel: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.backPixel = pixel
        _windows[id] = w
    }

    public func setBorderPixel(_ id: UInt32, _ pixel: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.borderPixel = pixel
        _windows[id] = w
    }

    /// Returns `(oldEntry, newEntry)` so callers can decide whether the size
    /// actually changed (and thus whether to emit Expose / regrow backing).
    @discardableResult
    public func resize(_ id: UInt32, width: UInt16?, height: UInt16?, x: Int16?, y: Int16?) -> (WindowEntry, WindowEntry)? {
        lock.lock(); defer { lock.unlock() }
        guard let old = _windows[id] else { return nil }
        var w = old
        if let width = width   { w.width = width }
        if let height = height { w.height = height }
        if let x = x           { w.x = x }
        if let y = y           { w.y = y }
        _windows[id] = w
        return (old, w)
    }
}

public struct GCEntry: Equatable, Sendable {
    public var id: UInt32
    public var drawable: UInt32
    public var valueMask: UInt32
    public var valueList: [UInt8]

    public init(id: UInt32, drawable: UInt32, valueMask: UInt32, valueList: [UInt8]) {
        self.id = id; self.drawable = drawable
        self.valueMask = valueMask; self.valueList = valueList
    }
}

public final class GCTable {
    private(set) public var gcs: [UInt32: GCEntry] = [:]
    public init() {}

    public func insert(_ gc: GCEntry) { gcs[gc.id] = gc }
    public func remove(_ id: UInt32) { gcs.removeValue(forKey: id) }
    public func get(_ id: UInt32) -> GCEntry? { gcs[id] }

    public func change(_ id: UInt32, valueMask: UInt32, valueList: [UInt8]) {
        guard var entry = gcs[id] else { return }
        // Replace mask/values for the bits being changed. Per spec ChangeGC's
        // valueList carries only the bits set in valueMask, not a full snapshot.
        // For M1 we just append/overwrite a coarse record — finer state merging
        // arrives when we actually render.
        entry.valueMask |= valueMask
        entry.valueList.append(contentsOf: valueList)
        gcs[id] = entry
    }

    public var count: Int { gcs.count }
}

public struct PixmapEntry: Equatable, Sendable {
    public var id: UInt32
    public var drawable: UInt32
    public var depth: UInt8
    public var width: UInt16
    public var height: UInt16

    public init(id: UInt32, drawable: UInt32, depth: UInt8, width: UInt16, height: UInt16) {
        self.id = id; self.drawable = drawable; self.depth = depth
        self.width = width; self.height = height
    }
}

public final class PixmapTable {
    private(set) public var pixmaps: [UInt32: PixmapEntry] = [:]
    public init() {}

    public func insert(_ pixmap: PixmapEntry) { pixmaps[pixmap.id] = pixmap }
    public func remove(_ id: UInt32) { pixmaps.removeValue(forKey: id) }
    public func get(_ id: UInt32) -> PixmapEntry? { pixmaps[id] }

    public var count: Int { pixmaps.count }
}

public struct FontEntry: Equatable, Sendable {
    public var id: UInt32
    public var name: [UInt8]
    /// Resolved Mac font + cell metrics. Populated at OpenFont time so
    /// QueryFont can answer without re-parsing, and the bridge can
    /// instantiate the CTFont without round-tripping back to the session.
    public var resolved: ResolvedFont

    public init(id: UInt32, name: [UInt8], resolved: ResolvedFont) {
        self.id = id; self.name = name; self.resolved = resolved
    }
}

public final class FontTable {
    private(set) public var fonts: [UInt32: FontEntry] = [:]
    public init() {}

    public func insert(_ font: FontEntry) { fonts[font.id] = font }
    public func remove(_ id: UInt32) { fonts.removeValue(forKey: id) }
    public func get(_ id: UInt32) -> FontEntry? { fonts[id] }

    public var count: Int { fonts.count }
}

public struct PropertyEntry: Equatable, Sendable {
    public var window: UInt32
    public var property: UInt32     // ATOM
    public var type: UInt32         // ATOM
    public var format: UInt8        // 8/16/32
    public var value: [UInt8]

    public init(window: UInt32, property: UInt32, type: UInt32, format: UInt8, value: [UInt8]) {
        self.window = window; self.property = property
        self.type = type; self.format = format; self.value = value
    }
}

public final class PropertyTable {
    private(set) public var properties: [UInt32: [UInt32: PropertyEntry]] = [:]
    public init() {}

    public func change(window: UInt32, property: UInt32, type: UInt32, format: UInt8, mode: UInt8, value: [UInt8]) {
        var perWindow = properties[window] ?? [:]
        if mode == 0 || perWindow[property] == nil {
            perWindow[property] = PropertyEntry(window: window, property: property, type: type, format: format, value: value)
        } else if mode == 1 {                          // PropModePrepend
            var existing = perWindow[property]!
            existing.value = value + existing.value
            perWindow[property] = existing
        } else {                                       // PropModeAppend (mode == 2)
            var existing = perWindow[property]!
            existing.value.append(contentsOf: value)
            perWindow[property] = existing
        }
        properties[window] = perWindow
    }

    public func get(window: UInt32, property: UInt32) -> PropertyEntry? {
        properties[window]?[property]
    }

    public func delete(window: UInt32, property: UInt32) {
        properties[window]?.removeValue(forKey: property)
    }

    public func deleteAll(window: UInt32) {
        properties.removeValue(forKey: window)
    }

    public var totalCount: Int {
        properties.values.reduce(0) { $0 + $1.count }
    }
}
