import SwiftUI
import AppKit
import SwiftXServerCore

// SwiftUI Preferences panel. Tabs: Cut/Paste (real), Capture (real),
// Display (placeholder), Network (placeholder). Hero-panel layout
// inside each tab — SF Symbol header + .title2 + caption — same
// vocabulary as the Resources editor so the two windows feel like
// they belong to the same app.

/// Identifies the Preferences tabs so callers (e.g. the SPARCstation menu's
/// Install action) can open the window to a specific tab.
enum PreferencesTab: Hashable {
    case cutPaste, capture, mouse, display, sparcStation, network
}

struct PreferencesPanelView: View {

    @ObservedObject var model: PreferencesPanelModel

    init(model: PreferencesPanelModel) {
        self.model = model
    }

    var body: some View {
        TabView(selection: $model.selectedTab) {
            CutPasteTab(model: model)
                .tabItem {
                    Label("Cut/Paste", systemImage: "doc.on.clipboard")
                }
                .tag(PreferencesTab.cutPaste)
            CaptureTab(model: model)
                .tabItem {
                    Label("Capture", systemImage: "recordingtape")
                }
                .tag(PreferencesTab.capture)
            MouseTab(model: model)
                .tabItem {
                    Label("Mouse", systemImage: "computermouse")
                }
                .tag(PreferencesTab.mouse)
            DisplayTab(model: model)
                .tabItem {
                    Label("Display", systemImage: "display")
                }
                .tag(PreferencesTab.display)
            SparcStationTab(model: model)
                .tabItem {
                    Label("SPARCstation", systemImage: "desktopcomputer")
                }
                .tag(PreferencesTab.sparcStation)
            PlaceholderTab(
                icon: "network",
                title: "Network",
                message: "Network settings coming soon."
            )
                .tabItem {
                    Label("Network", systemImage: "network")
                }
                .tag(PreferencesTab.network)
        }
        .frame(minWidth: 520, minHeight: 400)
        .padding(.top, 12)
    }
}

// MARK: - Cut/Paste tab

private struct CutPasteTab: View {
    @ObservedObject var model: PreferencesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "doc.on.clipboard",
                title: "Cut and Paste",
                caption: "Bridge X selection ownership to the Mac clipboard."
            )

            Toggle("Copy text from X windows to the Mac clipboard", isOn: $model.clipboardEnabled)
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text("When you drag-select text in an X window:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.copyMode) {
                    Text("Mac behavior — press \u{2318}C to copy what you've selected")
                        .tag(CopyMode.macStyle)
                    Text("Xterm behavior — copy automatically as soon as you select")
                        .tag(CopyMode.xtermStyle)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .padding(.leading, 4)
            }
            .disabled(!model.clipboardEnabled)

            Text("\u{2318}V (or Edit \u{203A} Paste) always pastes the Mac clipboard into the focused X window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Capture tab

private struct CaptureTab: View {
    @ObservedObject var model: PreferencesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "recordingtape",
                title: "Capture",
                caption: "Record every X client's wire traffic to a .xtap file."
            )

            Toggle("Capture every client to \(model.captureDirectory)", isOn: $model.captureSessions)
                .toggleStyle(.checkbox)

            Text("Each X client connection writes its own .xtap file you can " +
                 "send back with a bug report. /tmp is wiped at reboot, so " +
                 "captures don't accumulate.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Changes take effect for new client connections. Existing sessions keep their original capture setting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reveal Captures Folder in Finder") {
                    model.revealCapturesFolder()
                }
                Spacer()
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Mouse tab

/// The three "logical" X11 mouse buttons. Internal numbering matches
/// the X wire protocol (button 1 = primary, 2 = middle, 3 = secondary)
/// but the user never sees the numbers — the popups describe each role
/// by what it does in the **content area** of an X client (text widgets,
/// drawing areas, dialog buttons). Scrollbar-specific behavior is
/// handled by the dedicated toggle below the popups, so the popup labels
/// don't have to compete with scrollbar semantics.
private enum XButtonRole: UInt8, CaseIterable, Identifiable {
    case primary   = 1     // content: select / activate
    case middle    = 2     // content: paste in xterm, drag in Motif
    case secondary = 3     // content: extend selection in xterm, pop menu in Motif

    var id: UInt8 { rawValue }

    var menuLabel: String {
        switch self {
        case .primary:   return "Select text"
        case .middle:    return "Paste selection"
        case .secondary: return "Extend selection / open menu"
        }
    }
}

private struct MouseTab: View {
    @ObservedObject var model: PreferencesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "computermouse",
                title: "Mouse buttons",
                caption: "What each Mac mouse button does in X content areas."
            )

            Text("Pick what each Mac mouse button does in X content areas — text in xterm, the drawing area in quickplot, dialog buttons in dtcalc. Scrollbar behavior is handled by the override below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Left click:")
                    rolePicker(selection: Binding(
                        get: { XButtonRole(rawValue: model.pointerLeftClick) ?? .primary },
                        set: { model.pointerLeftClick = $0.rawValue }
                    ))
                }
                GridRow {
                    Text("Wheel click:")
                    rolePicker(selection: Binding(
                        get: { XButtonRole(rawValue: model.pointerWheelClick) ?? .middle },
                        set: { model.pointerWheelClick = $0.rawValue }
                    ))
                }
                GridRow {
                    Text("Right click:")
                    rolePicker(selection: Binding(
                        get: { XButtonRole(rawValue: model.pointerRightClick) ?? .secondary },
                        set: { model.pointerRightClick = $0.rawValue }
                    ))
                }
            }
            .padding(.leading, 4)

            Text("Scroll wheel rotation always emits scroll events. Modern xterm reads them natively; vintage xterm needs `<Btn4Down>: scroll-back(1,line)` / `<Btn5Down>: scroll-forw(1,line)` in `~/.Xdefaults`.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Scrollbar")
                    .font(.headline)
                Toggle("On an xterm scrollbar, any mouse button grabs the thumb",
                       isOn: $model.xtermScrollbarThumbOverride)
                    .toggleStyle(.checkbox)
                Text("macXserver detects when a click lands on an xterm scrollbar widget and substitutes \u{201C}grab thumb\u{201D} only there. Your content-area mapping above is untouched, and non-xterm clients are unaffected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rolePicker(selection: Binding<XButtonRole>) -> some View {
        Picker("", selection: selection) {
            ForEach(XButtonRole.allCases) { role in
                Text(role.menuLabel).tag(role)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Display tab

private struct DisplayTab: View {
    @ObservedObject var model: PreferencesPanelModel

    @State private var showingReseedConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "display",
                title: "Display",
                caption: "How X content is sized on screen and how windows are framed."
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Display size:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.displayScale) {
                    Text("Auto — picks best size for display")
                        .tag(DisplayScalePreference.auto)
                    Text("Comfortable — window size parity with Mac (3\u{00d7})")
                        .tag(DisplayScalePreference.comfortable)
                    Text("Compact — slightly smaller windows (2\u{00d7})")
                        .tag(DisplayScalePreference.compact)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .padding(.leading, 4)
            }

            Text("Takes effect on the next server launch. The macxserver --scale flag overrides this for one run.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Text("Window Frame")
                .font(.headline)

            Toggle("Use Motif window frame for new X windows", isOn: $model.motifFrameEnabled)
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title bar buttons:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.motifFrameButtonStyle) {
                    Text("Motif glyphs (raised menu dash, restore, maximize)")
                        .tag(MotifFrameButtonStyle.motif)
                    Text("Mac traffic lights (red close, yellow minimize, green zoom)")
                        .tag(MotifFrameButtonStyle.trafficLights)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .padding(.leading, 4)
            }
            .disabled(!model.motifFrameEnabled)

            Text("Toggling either setting only affects X windows mapped after the change. Existing windows keep whatever chrome they were created with.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            // Resources reseed — same backend as Edit Resources… > Revert,
            // surfaced here so the path from "I just changed something in
            // Preferences" to "I need to refresh my Motif resources" is one
            // click instead of three. Backup-first means user edits are
            // recoverable from <path>.bak if they regret the reseed.
            VStack(alignment: .leading, spacing: 8) {
                Text("Motif Resources")
                    .font(.headline)
                Text("Your X resources file at \(model.motifResourcesPath) overrides the bundled defaults. When the bundled defaults change (e.g. after a server update), reseed to pick them up. Your current file is backed up first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reseed Resources from Defaults\u{2026}") {
                        showingReseedConfirm = true
                    }
                    if let banner = model.reseedBanner {
                        Text(banner)
                            .font(.callout)
                            .foregroundStyle(model.reseedBannerIsError ? .red : .secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }

            Spacer(minLength: 16)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Reseed resources from defaults?", isPresented: $showingReseedConfirm) {
            Button("Reseed", role: .destructive) { model.reseedResources() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This replaces \(model.motifResourcesPath) with the bundled seed content. Your current file is saved to \(model.motifResourcesPath).bak first, so any edits you've made are recoverable from there.")
        }
    }
}

// MARK: - SPARCstation tab

private struct SparcStationTab: View {
    @ObservedObject var model: PreferencesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "desktopcomputer",
                title: "SPARCstation",
                caption: "The bundled SPARCstation 5 running Solaris 2.6."
            )

            Text("Disk image:")
                .foregroundStyle(.secondary)

            Text(model.sparcDiskImagePath.isEmpty
                 ? "No disk image selected" : model.sparcDiskImagePath)
                .font(.callout)
                .foregroundStyle(model.sparcDiskImagePath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Choose\u{2026}") { model.chooseSparcDiskImage() }
                if !model.sparcDiskImagePath.isEmpty {
                    Button("Reveal in Finder") { model.revealSparcDiskImage() }
                    Button("Clear") { model.sparcDiskImagePath = "" }
                }
                Spacer()
            }

            Text("Point this at a Solaris qcow2 disk image; the SPARCstation \u{203A} Run command boots it. Until the in-app downloader ships, this is how you select the image. Booting writes to the image (the VM persists its own state), so use a copy if you want to keep a pristine master.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Back up the disk image after each clean shutdown",
                   isOn: $model.sparcAutoBackupOnShutdown)

            Text("Keeps a dated \u{201C}last known good\u{201D} copy next to the image whenever the SPARCstation shuts down cleanly, so you can roll back if a later session corrupts it. Only the most recent few are kept. Turn this off to skip the automatic copies.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Placeholder tab

private struct PlaceholderTab: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared header

private struct PanelHeader: View {
    let icon: String
    let title: String
    let caption: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - View model

@MainActor
final class PreferencesPanelModel: ObservableObject {

    private let prefs: Preferences

    /// Which tab is showing. Driven by the tab bar, and set programmatically
    /// when a caller opens Preferences to a specific tab.
    @Published var selectedTab: PreferencesTab = .cutPaste

    @Published var clipboardEnabled: Bool {
        didSet {
            if clipboardEnabled != prefs.clipboardEnabled {
                prefs.clipboardEnabled = clipboardEnabled
            }
        }
    }

    @Published var copyMode: CopyMode {
        didSet {
            if copyMode != prefs.copyMode {
                prefs.copyMode = copyMode
            }
        }
    }

    @Published var captureSessions: Bool {
        didSet {
            if captureSessions != prefs.captureSessions {
                prefs.captureSessions = captureSessions
            }
        }
    }

    @Published var motifFrameEnabled: Bool {
        didSet {
            if motifFrameEnabled != prefs.motifFrameEnabled {
                prefs.motifFrameEnabled = motifFrameEnabled
            }
        }
    }

    @Published var motifFrameButtonStyle: MotifFrameButtonStyle {
        didSet {
            if motifFrameButtonStyle != prefs.motifFrameButtonStyle {
                prefs.motifFrameButtonStyle = motifFrameButtonStyle
            }
        }
    }

    @Published var displayScale: DisplayScalePreference {
        didSet {
            if displayScale != prefs.displayScale {
                prefs.displayScale = displayScale
            }
        }
    }

    @Published var pointerLeftClick: UInt8 {
        didSet {
            if pointerLeftClick != prefs.pointerLeftClick {
                prefs.pointerLeftClick = pointerLeftClick
            }
        }
    }

    @Published var pointerWheelClick: UInt8 {
        didSet {
            if pointerWheelClick != prefs.pointerWheelClick {
                prefs.pointerWheelClick = pointerWheelClick
            }
        }
    }

    @Published var pointerRightClick: UInt8 {
        didSet {
            if pointerRightClick != prefs.pointerRightClick {
                prefs.pointerRightClick = pointerRightClick
            }
        }
    }

    @Published var xtermScrollbarThumbOverride: Bool {
        didSet {
            if xtermScrollbarThumbOverride != prefs.xtermScrollbarThumbOverride {
                prefs.xtermScrollbarThumbOverride = xtermScrollbarThumbOverride
            }
        }
    }

    @Published var sparcDiskImagePath: String {
        didSet {
            if sparcDiskImagePath != prefs.sparcDiskImagePath {
                prefs.sparcDiskImagePath = sparcDiskImagePath
            }
        }
    }

    @Published var sparcAutoBackupOnShutdown: Bool {
        didSet {
            if sparcAutoBackupOnShutdown != prefs.sparcAutoBackupOnShutdown {
                prefs.sparcAutoBackupOnShutdown = sparcAutoBackupOnShutdown
            }
        }
    }

    var captureDirectory: String { prefs.captureDirectory }

    /// Path of the user-editable resources file. Same path the resources
    /// editor uses; surfaced here so the Display tab's reseed button can
    /// reference it in copy + the confirm dialog.
    var motifResourcesPath: String { ResourceFileLoader.defaultPath }

    @Published var reseedBanner: String? = nil
    @Published var reseedBannerIsError: Bool = false

    init(preferences: Preferences) {
        self.prefs = preferences
        self.clipboardEnabled = preferences.clipboardEnabled
        self.copyMode = preferences.copyMode
        self.captureSessions = preferences.captureSessions
        self.motifFrameEnabled = preferences.motifFrameEnabled
        self.motifFrameButtonStyle = preferences.motifFrameButtonStyle
        self.displayScale = preferences.displayScale
        self.pointerLeftClick = preferences.pointerLeftClick
        self.pointerWheelClick = preferences.pointerWheelClick
        self.pointerRightClick = preferences.pointerRightClick
        self.xtermScrollbarThumbOverride = preferences.xtermScrollbarThumbOverride
        self.sparcDiskImagePath = preferences.sparcDiskImagePath
        self.sparcAutoBackupOnShutdown = preferences.sparcAutoBackupOnShutdown
    }

    /// Pick a Solaris disk image with an open panel and store its path.
    func chooseSparcDiskImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Solaris Disk Image"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if !sparcDiskImagePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: sparcDiskImagePath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sparcDiskImagePath = url.path
    }

    /// Reveal the selected disk image in Finder.
    func revealSparcDiskImage() {
        guard !sparcDiskImagePath.isEmpty else { return }
        NSWorkspace.shared.selectFile(sparcDiskImagePath, inFileViewerRootedAtPath: "")
    }

    /// Reseed the user resources file from the bundled defaults. Same
    /// backend as the Resources editor's Revert button; surfaced here so
    /// Preferences users have a one-click path after a server update
    /// changes the compiled-in defaults. Backup-first so a previous
    /// customization is recoverable.
    func reseedResources() {
        do {
            let backupPath = try ResourceFileLoader.reseed(
                path: motifResourcesPath,
                seed: DefaultThemes.seedContent
            )
            reseedBannerIsError = false
            if let backupPath = backupPath {
                reseedBanner = "Reseeded. Previous file at \(backupPath). Restart Motif apps to see changes."
            } else {
                reseedBanner = "Reseeded. Restart Motif apps to see changes."
            }
        } catch {
            reseedBannerIsError = true
            reseedBanner = "Reseed failed: \(error.localizedDescription)"
        }
    }

    /// Open the captures folder in Finder. Creates the directory if it
    /// doesn't exist yet so the reveal always succeeds — same `mkdir
    /// -p` behavior `SessionCapture.init` does on the server side.
    func revealCapturesFolder() {
        let path = prefs.captureDirectory
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
