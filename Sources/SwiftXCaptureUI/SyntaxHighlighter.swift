import AppKit

// Shared shape for the per-file syntax highlighters used by
// CodeEditorView. Each editor wraps an NSTextView whose textStorage's
// delegate is an instance of one of these — ResourceSyntaxHighlighter
// for `~/.swiftx-resources`, FontMappingSyntaxHighlighter for
// `~/.swiftx-fonts`. The protocol lets CodeEditorView remain agnostic.

public protocol SyntaxHighlighter: NSTextStorageDelegate {
    /// Re-apply highlighting to the entire storage. Called once after
    /// makeNSView sets initial text, and whenever updateNSView replaces
    /// the buffer (Reload from Disk / Revert).
    func applyAll(to storage: NSTextStorage)
}
