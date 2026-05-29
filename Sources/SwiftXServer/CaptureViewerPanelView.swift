import SwiftUI
import AppKit

// SwiftUI root for the capture viewer: a header plus the dark code editor
// (read-only) showing a decoded .xtap chrono dump — the same text the capture
// "decode to .txt" option writes, syntax-highlighted by CaptureSyntaxHighlighter.
// The text is decoded once by the caller (AppDelegate.openCapture) and handed
// in; this view never edits it.

struct CaptureViewerPanelView: View {

    let title: String     // capture filename
    let text: String      // decoded chrono dump

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            CodeEditorView(
                text: .constant(text),
                theme: .dark,
                makeHighlighter: { theme, font in
                    CaptureSyntaxHighlighter(theme: theme, baseFont: font)
                },
                isEditable: false,
                alwaysShowVerticalScroller: true
            )
            .frame(minHeight: 320)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2)
                Text("Decoded X11 wire log (read-only). The .xtap on disk stays the source of truth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
