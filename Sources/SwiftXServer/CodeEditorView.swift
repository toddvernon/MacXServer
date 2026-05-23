import SwiftUI
import AppKit

// SwiftUI wrapper around NSScrollView + NSTextView +
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
// Line-number gutter is intentionally absent — see SHORTCUTS.md
// "Line-number gutter deferred."

struct CodeEditorView: NSViewRepresentable {

    @Binding var text: String
    let theme: EditorTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
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
        textView.allowsUndo = true
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
        let highlighter = ResourceSyntaxHighlighter(theme: theme, baseFont: font)
        if let storage = textView.textStorage {
            storage.delegate = highlighter
            highlighter.applyAll(to: storage)
        }
        context.coordinator.highlighter = highlighter

        // Scroll view. Overlay scrollers (the modern default in user prefs
        // but worth pinning explicitly) avoid the legacy-scroller corner
        // blob that paints a white square where the horizontal and vertical
        // bars would meet.
        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only push the binding back into the text view when it really
        // changed externally (Reload, Revert). If we wrote unconditionally
        // we'd clobber the user's cursor on every keystroke.
        if textView.string != text {
            textView.string = text
            if let storage = textView.textStorage {
                context.coordinator.highlighter?.applyAll(to: storage)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var highlighter: ResourceSyntaxHighlighter?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Push edits back into the SwiftUI binding. The highlighter
            // already ran via its NSTextStorageDelegate hook by the time
            // this fires.
            parent.text = textView.string
        }
    }
}


