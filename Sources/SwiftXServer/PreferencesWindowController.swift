import AppKit

// Tabbed Preferences window. NSTabViewController in `.toolbar` mode gives us
// the System-Settings-style top toolbar with one toolbar item per tab.
//
// Tab 1 (Cut/Paste): the only tab with real settings today. Master enable
// checkbox plus a radio between "Mac behavior" (press Cmd-C to copy) and
// "Xterm behavior" (auto-copy on selection). Plain-English labels — no
// PRIMARY / CLIPBOARD / atom jargon.
//
// Tab 2 (Display) and Tab 3 (Network) are placeholders so the chrome is in
// place when we have something to put there. They each show a single
// "Coming soon" label.

final class PreferencesWindowController: NSWindowController {

    private let prefs: Preferences

    init(preferences: Preferences) {
        self.prefs = preferences

        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar

        let cutPaste = CutPasteViewController(preferences: preferences)
        cutPaste.title = "Cut/Paste"
        let cutPasteItem = NSTabViewItem(viewController: cutPaste)
        cutPasteItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        tabController.addTabViewItem(cutPasteItem)

        let display = PlaceholderViewController(message: "Display settings coming soon.")
        display.title = "Display"
        let displayItem = NSTabViewItem(viewController: display)
        displayItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        tabController.addTabViewItem(displayItem)

        let network = PlaceholderViewController(message: "Network settings coming soon.")
        network.title = "Network"
        let networkItem = NSTabViewItem(viewController: network)
        networkItem.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        tabController.addTabViewItem(networkItem)

        let window = NSWindow(contentViewController: tabController)
        window.title = "swiftx-server Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Cut/Paste tab

private final class CutPasteViewController: NSViewController {

    private let prefs: Preferences

    private let enableCheckbox = NSButton(checkboxWithTitle: "Copy text from X windows to the Mac clipboard",
                                          target: nil, action: nil)
    private let macRadio   = NSButton(radioButtonWithTitle: "Mac behavior — press \u{2318}C to copy what you've selected",
                                      target: nil, action: nil)
    private let xtermRadio = NSButton(radioButtonWithTitle: "Xterm behavior — copy automatically as soon as you select",
                                      target: nil, action: nil)
    private let modeLabel  = NSTextField(labelWithString: "When you drag-select text in an X window:")
    private let footnote   = NSTextField(labelWithString: "\u{2318}V (or Edit \u{203A} Paste) always pastes the Mac clipboard into the focused X window.")

    init(preferences: Preferences) {
        self.prefs = preferences
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        // Style the secondary text so it reads as a hint rather than a
        // headline. The mode label and footnote both sit below the active
        // controls, and the footnote in particular is meant to be reassurance
        // not configuration.
        modeLabel.textColor = .secondaryLabelColor
        footnote.textColor = .secondaryLabelColor
        footnote.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.maximumNumberOfLines = 0
        footnote.preferredMaxLayoutWidth = 380

        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableChanged(_:))
        macRadio.target = self
        macRadio.action = #selector(modeChanged(_:))
        xtermRadio.target = self
        xtermRadio.action = #selector(modeChanged(_:))

        // Group the two radios so AppKit handles the mutually-exclusive
        // selection. We could do it manually but binding via a shared
        // action + state read is simpler.
        let modeStack = NSStackView(views: [macRadio, xtermRadio])
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 4

        let modeBlock = NSStackView(views: [modeLabel, modeStack])
        modeBlock.orientation = .vertical
        modeBlock.alignment = .leading
        modeBlock.spacing = 6
        // Indent the radios slightly so they read as a sub-option of the
        // master enable checkbox.
        modeStack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)

        let outer = NSStackView(views: [enableCheckbox, modeBlock, footnote])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let root = NSView()
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])
        self.view = root

        syncFromModel()
    }

    private func syncFromModel() {
        enableCheckbox.state = prefs.clipboardEnabled ? .on : .off
        let mode = prefs.copyMode
        macRadio.state   = (mode == .macStyle)   ? .on : .off
        xtermRadio.state = (mode == .xtermStyle) ? .on : .off
        // Grey out the mode radios when copy is disabled — they'd have no
        // effect and the visual cue saves a support question later.
        let on = prefs.clipboardEnabled
        macRadio.isEnabled = on
        xtermRadio.isEnabled = on
        modeLabel.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func enableChanged(_ sender: NSButton) {
        prefs.clipboardEnabled = (sender.state == .on)
        syncFromModel()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        if sender === xtermRadio {
            prefs.copyMode = .xtermStyle
        } else {
            prefs.copyMode = .macStyle
        }
        syncFromModel()
    }
}

// MARK: - Placeholder tab

private final class PlaceholderViewController: NSViewController {
    private let message: String
    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let label = NSTextField(labelWithString: message)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let root = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        self.view = root
    }
}
