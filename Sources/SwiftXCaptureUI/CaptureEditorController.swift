import AppKit
import Foundation

// Controller object held by CaptureViewerPanelView that lets the SwiftUI
// surface drive scroll + selection on the underlying NSTextView. We need
// this because SwiftUI's value-binding model doesn't fit imperative
// "jump to line N" actions cleanly — passing a controller through is the
// pragmatic shape.
//
// CodeEditorView's makeNSView calls `attach(_:)` with the live NSTextView
// reference. The parent view holds the controller via @StateObject so it
// survives view rebuilds, and uses it to implement Cmd-] / Cmd-[ and the
// landmark outline sidebar.

@MainActor
public final class CaptureEditorController: ObservableObject {

    private weak var textView: NSTextView?

    /// 1-based line currently in view (best effort: the first visible
    /// line, recomputed each time a navigation method runs). Published
    /// so the outline sidebar can highlight the closest landmark.
    @Published public var currentLine: Int = 1

    public init() {}

    /// Called by CodeEditorView during makeNSView to bind the text view.
    public func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    /// Move the selection + scroll to the 1-based line. Idempotent and
    /// no-op if the controller isn't bound to a text view yet.
    public func jump(toLine line: Int) {
        guard let tv = textView else { return }
        guard let range = rangeOfLine(line, in: tv.string) else { return }
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        currentLine = line
    }

    /// Best-effort first-visible line from the text view's scroll
    /// position. Used to decide what counts as "next" / "previous"
    /// landmark relative to the user's current view.
    public func firstVisibleLine() -> Int {
        guard let tv = textView,
              let scrollView = tv.enclosingScrollView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else { return 1 }
        let visibleY = scrollView.contentView.bounds.origin.y
        let charIndex = lm.characterIndex(
            for: NSPoint(x: 0, y: visibleY + 2),
            in: tc,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return lineNumber(at: charIndex, in: tv.string)
    }

    // MARK: - Helpers

    /// 1-based line range for `line` in `s`. nil if `line` is out of bounds.
    /// Walks line by line counting lengths; cheap for typical capture
    /// sizes (a few thousand lines).
    private func rangeOfLine(_ line: Int, in s: String) -> NSRange? {
        guard line >= 1 else { return nil }
        var current = 1
        var offset = 0
        let ns = s as NSString
        let total = ns.length
        while offset <= total {
            var lineEnd = 0
            var nextLineStart = 0
            ns.getLineStart(nil, end: &nextLineStart, contentsEnd: &lineEnd,
                            for: NSRange(location: offset, length: 0))
            if current == line {
                return NSRange(location: offset, length: lineEnd - offset)
            }
            current += 1
            if nextLineStart == offset { break }  // no progress = EOF
            offset = nextLineStart
        }
        return nil
    }

    private func lineNumber(at charIndex: Int, in s: String) -> Int {
        let ns = s as NSString
        guard charIndex >= 0 else { return 1 }
        let total = ns.length
        var line = 1
        var offset = 0
        while offset < charIndex && offset < total {
            var nextLineStart = 0
            ns.getLineStart(nil, end: &nextLineStart, contentsEnd: nil,
                            for: NSRange(location: offset, length: 0))
            if nextLineStart == offset { break }
            if nextLineStart > charIndex { break }
            offset = nextLineStart
            line += 1
        }
        return line
    }
}
