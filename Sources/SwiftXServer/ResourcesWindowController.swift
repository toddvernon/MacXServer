import AppKit
import SwiftXServerCore

// Standalone editor window for `~/.swiftx-resources`. See THEMES.md
// for the format and overall design.
//
// Layout (top to bottom): standard Mac.
//   Active theme: [▼ quickplot]
//   ╭─────────────────────────────────────────────╮
//   │  NSTextView in NSScrollView, monospaced,    │
//   │  plain text, find-bar enabled, horizontal   │
//   │  scroll for long lines.                     │
//   │  ...                                        │
//   ╰─────────────────────────────────────────────╯
//   [Revert to Defaults]              [Reload] [Save]
//   Saved. Restart Motif apps to see changes.
//
// Action area follows Mac dialog convention: default (Save, bound to
// Return) on the far right, other positive action (Reload) next to it,
// destructive (Revert) on the far left. Status text under the action
// row as a secondary label.
//
// Dirty tracking: NSTextViewDelegate.textDidChange sets a flag, Save
// becomes enabled. Save writes the buffer verbatim to disk (no
// re-serialize → user's formatting/comments/blank-line layout
// preserved exactly). Reload re-reads the file from disk (useful if
// you edited externally in vim). Revert overwrites the file with the
// bundled seed content after a confirmation dialog.
//
// What Save does NOT do:
//   - Push to running sessions. Resources are read per-session at
//     connect time; existing windows don't re-query. Next-launched
//     Motif app picks up the changes automatically because its
//     ServerSession init re-reads the file. Banner makes this clear.

final class ResourcesWindowController: NSWindowController {

    private let viewController: ResourcesViewController

    init(path: String = ResourceFileLoader.defaultPath) {
        self.viewController = ResourcesViewController(path: path)

        let window = NSWindow(contentViewController: viewController)
        window.title = "swiftx-server Resources"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 520, height: 360)
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

// MARK: - View controller

private final class ResourcesViewController: NSViewController, NSTextViewDelegate {

    private let path: String

    // State
    private var dirty: Bool = false {
        didSet {
            saveButton.isEnabled = dirty
        }
    }

    // UI
    private let themeLabel = NSTextField(labelWithString: "Active theme:")
    private let themePopUp = NSPopUpButton()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload from Disk", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert to Defaults", target: nil, action: nil)
    private let bannerLabel = NSTextField(labelWithString: "")

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        configureTextView()
        configureButtons()
        configureBanner()
        configureThemePopUp()
        self.view = buildLayout()
        loadFromDisk()
    }

    // MARK: - UI construction

    private func configureTextView() {
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
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.delegate = self

        // Horizontal scrolling for long resource lines (XLFDs go ~80 chars,
        // and per-app overrides like `*XmDialogShell*XmPushButtonGadget...`
        // run wider).
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
    }

    private func configureButtons() {
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        // Return key activates Save when the editor doesn't have focus —
        // makes Save the default action per Mac dialog convention. AppKit
        // gives default buttons the blue tint automatically.
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false   // disabled until dirty

        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)
        reloadButton.bezelStyle = .rounded

        revertButton.target = self
        revertButton.action = #selector(revertClicked)
        revertButton.bezelStyle = .rounded
    }

    private func configureBanner() {
        bannerLabel.textColor = .secondaryLabelColor
        bannerLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.maximumNumberOfLines = 2
    }

    private func configureThemePopUp() {
        themePopUp.target = self
        themePopUp.action = #selector(themeSelected)
    }

    private func buildLayout() -> NSView {
        // Top row: "Active theme:" label + popup, left-aligned with
        // natural intrinsic widths.
        let themeRow = NSStackView(views: [themeLabel, themePopUp])
        themeRow.orientation = .horizontal
        themeRow.alignment = .firstBaseline
        themeRow.spacing = 8
        themeRow.translatesAutoresizingMaskIntoConstraints = false
        themePopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Action row: destructive on the far left, positive group on
        // the far right with a flex spacer between. Standard Mac dialog
        // convention (System Settings, NSAlert, etc.). Save is the
        // rightmost / default button.
        let leadingGroup = NSStackView(views: [revertButton])
        leadingGroup.orientation = .horizontal
        leadingGroup.spacing = 8

        let trailingGroup = NSStackView(views: [reloadButton, saveButton])
        trailingGroup.orientation = .horizontal
        trailingGroup.spacing = 8

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionRow = NSStackView(views: [leadingGroup, spacer, trailingGroup])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        // Outer vertical stack: theme row, editor (takes slack),
        // action row, status banner.
        let outer = NSStackView(views: [themeRow, scrollView, actionRow, bannerLabel])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.distribution = .fill
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        // Scroll view absorbs vertical slack; everything else hugs its
        // intrinsic height.
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        themeRow.setContentHuggingPriority(.required, for: .vertical)
        actionRow.setContentHuggingPriority(.required, for: .vertical)
        bannerLabel.setContentHuggingPriority(.required, for: .vertical)

        let root = NSView()
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Each major row spans the full inner width.
            themeRow.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            themeRow.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            actionRow.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            bannerLabel.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            bannerLabel.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            // Editor minimum height so the window opens looking like an
            // editor, not a thin strip.
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        return root
    }

    // MARK: - File I/O

    private func loadFromDisk() {
        let content: String
        if FileManager.default.fileExists(atPath: path) {
            do {
                content = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                showBanner("Could not read \(path): \(error.localizedDescription)")
                return
            }
        } else {
            // First open before the server has run — show the seed so
            // the user has something to look at. Save will write it.
            content = DefaultThemes.seedContent
            dirty = true
        }
        textView.string = content
        if FileManager.default.fileExists(atPath: path) { dirty = false }
        rebuildThemePopUp()
        showBanner("")
    }

    private func saveToDisk() {
        let content = textView.string
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            dirty = false
            rebuildThemePopUp()
            showBanner("Saved. Restart Motif apps to see changes — toolkits cache resources at connect time.")
        } catch {
            showBanner("Save failed: \(error.localizedDescription)")
        }
    }

    private func revertToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Revert to bundled defaults?"
        alert.informativeText = """
        This replaces the contents of \(path) with the bundled seed content. \
        Any edits you've made are lost.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try DefaultThemes.seedContent.write(toFile: path, atomically: true, encoding: .utf8)
            loadFromDisk()
            showBanner("Reverted to bundled defaults.")
        } catch {
            showBanner("Revert failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Theme dropdown

    private func rebuildThemePopUp() {
        let file = ResourceFile.parse(textView.string)
        themePopUp.removeAllItems()
        let names = file.themeNames
        if names.isEmpty {
            themePopUp.addItem(withTitle: "(no themes defined)")
            themePopUp.isEnabled = false
        } else {
            themePopUp.addItems(withTitles: names)
            themePopUp.isEnabled = true
            if names.contains(file.activeTheme) {
                themePopUp.selectItem(withTitle: file.activeTheme)
            } else {
                // Active theme name doesn't match any [theme:X] block —
                // user picked a name that doesn't exist. Select nothing
                // and surface the situation in the banner.
                themePopUp.select(nil)
                showBanner("Active theme '\(file.activeTheme)' is not defined in the file.")
            }
        }
    }

    @objc private func themeSelected() {
        guard let title = themePopUp.titleOfSelectedItem else { return }
        let newText = replaceThemeLine(in: textView.string, with: title)
        if newText != textView.string {
            textView.string = newText
            dirty = true
            showBanner("")
        }
    }

    /// Find the `theme:` key inside `[swiftx-config]` and replace its value.
    /// Preserves everything else in the file byte-identical: other sections,
    /// other config keys, comments, blank lines, leading whitespace on the
    /// theme line itself. If no `theme:` line exists we append one inside
    /// the config section; if no config section exists we prepend one at
    /// the top of the file.
    private func replaceThemeLine(in text: String, with newTheme: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inConfigSection = false
        var sawConfigSection = false
        var configSectionLastLine = -1
        var changed = false

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inConfigSection = (trimmed == "[swiftx-config]")
                if inConfigSection { sawConfigSection = true }
                continue
            }
            if inConfigSection {
                configSectionLastLine = i
                if !changed, let colon = trimmed.firstIndex(of: ":") {
                    let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                    if key == "theme" {
                        // Preserve leading whitespace and the original key spelling.
                        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
                        lines[i] = "\(leading)theme: \(newTheme)"
                        changed = true
                    }
                }
            }
        }
        if changed { return lines.joined(separator: "\n") }

        // No `theme:` line existed. If the config section is present,
        // insert the line right after the last config-content line.
        if sawConfigSection, configSectionLastLine >= 0 {
            lines.insert("theme: \(newTheme)", at: configSectionLastLine + 1)
            return lines.joined(separator: "\n")
        }

        // No config section at all. Prepend a fresh one at the top.
        let prefix = ["[swiftx-config]", "theme: \(newTheme)", ""]
        return (prefix + lines).joined(separator: "\n")
    }

    // MARK: - Banner

    private func showBanner(_ message: String) {
        bannerLabel.stringValue = message
    }

    // MARK: - Actions

    @objc private func saveClicked() { saveToDisk() }
    @objc private func reloadClicked() { loadFromDisk() }
    @objc private func revertClicked() { revertToDefaults() }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        dirty = true
        // The user just typed; if they typed into the [swiftx-config]
        // section's `theme:` line, the popup might be stale. Re-parse
        // and re-select to keep them in sync — cheap on a 500-line file.
        rebuildThemePopUp()
        showBanner("")
    }
}
