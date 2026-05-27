import AppKit

// NSWindow subclass that hosts a MotifFrameView as its content view, with
// the X client view installed as a subview of the frame at the frame's
// clientRect. The styleMask deliberately omits .titled — .titled forces
// rounded corners at the window-server level (no API to disable). Without
// .titled but with the action bits, we get square corners AND working
// performClose / miniaturize / zoom hooks driven from MotifFrameView's
// button hit tests.

public final class MotifWindow: NSWindow {

    public let frameView: MotifFrameView

    public var buttonStyle: MotifFrameButtonStyle {
        get { frameView.buttonStyle }
        set { frameView.buttonStyle = newValue }
    }

    public var windowTitle: String {
        get { frameView.windowTitle }
        set { frameView.windowTitle = newValue }
    }

    /// Initialize with the NSWindow content rect (already grown to include
    /// frame insets per MotifTheme.current.horizontalPadding / verticalPadding) and
    /// the X client view that will live at the frame's clientRect.
    public init(contentRect: NSRect, clientView: NSView) {
        let frameView = MotifFrameView(
            frame: NSRect(origin: .zero, size: contentRect.size),
            clientView: clientView
        )
        self.frameView = frameView
        super.init(
            contentRect: contentRect,
            styleMask: [.closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        frameView.autoresizingMask = [.width, .height]
        self.contentView = frameView
        self.isMovableByWindowBackground = false
        self.hasShadow = true
        self.backgroundColor = .clear
    }

    public override var canBecomeKey: Bool  { true }
    public override var canBecomeMain: Bool { true }
}
