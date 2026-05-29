import SwiftUI
import AppKit
import Foundation

// SwiftUI wrapper around an EditorContainer (NSView holding a line-
// number gutter + NSScrollView+NSTextView side by side) +
// ResourceSyntaxHighlighter. SwiftUI's TextEditor is weak for code
// editing (no find-bar, no horizontal scroll, no monospace handling at
// the level we want), so we go straight to NSTextView and keep the
// AppKit knobs we already had on the old controller.
//
// Two-way binding with the surrounding SwiftUI state: changes from the
// text view update `text` via the coordinator's NSTextViewDelegate;
// external updates to `text` (e.g. Reload from Disk) replace the buffer
// contents and rerun the highlighter.
//
// Gutter implementation note: this was first attempted with an
// NSRulerView attached to the scroll view (see SHORTCUTS history) — that
// fought SwiftUI's NSScrollView hosting hard enough to scramble the
// whole layout. Going through a plain NSView placed beside the scroll
// view sidesteps the problem: the scroll view's own layout is left
// untouched, and the gutter just observes the clip view's bounds.

public struct CodeEditorView: NSViewRepresentable {

    @Binding var text: String
    let theme: EditorTheme
    /// Closure that builds the per-file syntax highlighter. Different
    /// editor instances (resources, font mappings) pass different
    /// highlighters, but every other piece — scroll view, gutter,
    /// theme application — is shared.
    let makeHighlighter: (EditorTheme, NSFont) -> SyntaxHighlighter
    /// Read-only mode (still selectable + copyable, no editing or undo).
    /// Used by the capture viewer, which shows decoded `.xtap` output.
    var isEditable: Bool = true
    /// Force a always-visible (legacy) vertical scroller instead of the
    /// fading overlay one — useful for long files where the thumb position
    /// tells you where you are. The capture viewer turns this on.
    var alwaysShowVerticalScroller: Bool = false

    public init(text: Binding<String>,
                theme: EditorTheme,
                makeHighlighter: @escaping (EditorTheme, NSFont) -> SyntaxHighlighter,
                isEditable: Bool = true,
                alwaysShowVerticalScroller: Bool = false) {
        self._text = text
        self.theme = theme
        self.makeHighlighter = makeHighlighter
        self.isEditable = isEditable
        self.alwaysShowVerticalScroller = alwaysShowVerticalScroller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> EditorContainer {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Text view sized large enough to support unbounded horizontal
        // scrolling — XLFDs and per-app override resource lines run wide.
        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFindBar = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = isEditable
        textView.font = font
        textView.backgroundColor = theme.background
        textView.textColor = theme.defaultText
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selection,
            .foregroundColor: theme.defaultText,
        ]
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // Horizontal scroll for long lines: detach text-container width
        // from text-view width and give the container effectively
        // unbounded width.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        textView.delegate = context.coordinator

        // Initial buffer + highlight.
        textView.string = text
        let highlighter = makeHighlighter(theme, font)
        if let storage = textView.textStorage {
            storage.delegate = highlighter
            highlighter.applyAll(to: storage)
        }
        context.coordinator.highlighter = highlighter

        // Scroll view (overlay scrollers — legacy style would paint a
        // white corner blob where the bars meet).
        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        if alwaysShowVerticalScroller {
            // Legacy scrollers stay put (and reserve a gutter) so the thumb
            // is always a position indicator, not a fading overlay. Force the
            // dark appearance so the scroller draws a light thumb that's
            // actually visible on the near-black editor background (the default
            // dark-on-dark scroller is invisible).
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.appearance = NSAppearance(named: .darkAqua)
        } else {
            scrollView.scrollerStyle = .overlay
        }
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background

        // Gutter + container.
        let gutter = LineNumberGutter(theme: theme, font: font)
        gutter.textView = textView
        let container = EditorContainer(gutter: gutter, scrollView: scrollView)
        container.startObserving()

        return container
    }

    public func updateNSView(_ container: EditorContainer, context: Context) {
        guard let textView = container.scrollView.documentView as? NSTextView else { return }
        // Only push the binding back into the text view when it really
        // changed externally (Reload, Revert). If we wrote unconditionally
        // we'd clobber the user's cursor on every keystroke.
        if textView.string != text {
            textView.string = text
            if let storage = textView.textStorage {
                context.coordinator.highlighter?.applyAll(to: storage)
            }
            container.refreshGutter()
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorContainer, context: Context) -> CGSize? {
        // Tell SwiftUI to use whatever frame the parent VStack proposes,
        // not the container's fittingSize. Without this the editor can
        // still over-claim height in some layout passes.
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var highlighter: (any SyntaxHighlighter)?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Push edits back into the SwiftUI binding. The highlighter
            // already ran via its NSTextStorageDelegate hook by the time
            // this fires.
            parent.text = textView.string
        }
    }
}

// MARK: - EditorContainer

/// Plain NSView that lays out a LineNumberGutter on the left and an
/// NSScrollView on the right, and keeps them in sync. Sitting between
/// SwiftUI and the editor lets us hand SwiftUI a non-NSScrollView root
/// (whose fittingSize doesn't bubble the document height up the way
/// NSScrollView's does), and gives the gutter a stable place to live
/// without entangling with the scroll view's internal layout.
public final class EditorContainer: NSView {

    let gutter: LineNumberGutter
    let scrollView: NSScrollView

    init(gutter: LineNumberGutter, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        // Clip subviews to our bounds so neither the gutter nor the
        // scroll view can paint outside the slot SwiftUI gave us.
        layer?.masksToBounds = true
        addSubview(gutter)
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = []   // we manage frames in layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // The bare-NSScrollView version of this editor worked because
    // NSScrollView's own fittingSize reported small. Once we wrap it in
    // a container, SwiftUI inspects the container's fittingSize and
    // (without these overrides) computes a value that lets the editor
    // claim the entire VStack vertical space — pushing the surrounding
    // header off-screen. Forcing both to "I have no preferred size" is
    // what makes SwiftUI give us only the proposed frame.
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    public override var fittingSize: NSSize { .zero }

    public override func layout() {
        super.layout()
        let gw = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: gw, height: bounds.height)
        scrollView.frame = NSRect(x: gw, y: 0,
                                  width: max(0, bounds.width - gw),
                                  height: bounds.height)
        // Trigger a gutter redraw — visible glyph range likely changed.
        gutter.needsDisplay = true
    }

    /// Hook up the observers that keep the gutter in sync with scroll
    /// position, text edits, and (indirectly) text changes that grow the
    /// gutter's width.
    func startObserving() {
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: clipView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textChanged(_:)),
            name: NSText.didChangeNotification,
            object: scrollView.documentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipViewChanged(_ note: Notification) {
        gutter.scrollOffset = scrollView.contentView.bounds.origin.y
        gutter.needsDisplay = true
    }

    @objc private func textChanged(_ note: Notification) {
        refreshGutter()
    }

    /// Recompute gutter width (line count may have changed digit count)
    /// and redraw. Called from updateNSView too, when SwiftUI hands us
    /// new text.
    func refreshGutter() {
        // Width change → re-layout. needsLayout triggers layout() which
        // sets needsDisplay on the gutter.
        needsLayout = true
    }
}
