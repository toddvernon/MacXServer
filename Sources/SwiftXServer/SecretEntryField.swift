import AppKit

/// A secret-entry accessory view for NSAlert: a text field plus a "Show what I'm
/// typing" checkbox that swaps between a secure (dots) and a plain field, so the
/// user can verify what they entered. Reads `value` for the current text.
final class SecretEntryField: NSView {
    private let secure = NSSecureTextField()
    private let plain = NSTextField()
    private let toggle = NSButton(checkboxWithTitle: "Show what I\u{2019}m typing",
                                  target: nil, action: nil)
    private var revealed = false

    /// The current text, from whichever field is visible.
    var value: String {
        get { (revealed ? plain : secure).stringValue }
        set { secure.stringValue = newValue; plain.stringValue = newValue }
    }

    /// The field an NSAlert should make first responder (the visible one).
    var activeField: NSTextField { revealed ? plain : secure }

    init(width: CGFloat = 320) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        let fieldFrame = NSRect(x: 0, y: 26, width: width, height: 24)
        secure.frame = fieldFrame
        plain.frame = fieldFrame
        plain.isHidden = true
        toggle.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        toggle.target = self
        toggle.action = #selector(toggleReveal)
        addSubview(secure)
        addSubview(plain)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func toggleReveal() {
        revealed = (toggle.state == .on)
        // Carry the current text over to the field we're about to show.
        if revealed { plain.stringValue = secure.stringValue }
        else { secure.stringValue = plain.stringValue }
        plain.isHidden = !revealed
        secure.isHidden = revealed
        window?.makeFirstResponder(activeField)
    }
}
