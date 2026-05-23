import SwiftUI
import AppKit
import SwiftXServerCore

// SwiftUI Preferences panel. Three tabs: Cut/Paste (real settings),
// Display (placeholder), Network (placeholder). Hero-panel layout
// inside each tab — SF Symbol header + .title2 + caption — same
// vocabulary as the Resources editor so the two windows feel like
// they belong to the same app.

struct PreferencesPanelView: View {

    @StateObject private var model: PreferencesPanelModel

    init(preferences: Preferences) {
        _model = StateObject(wrappedValue: PreferencesPanelModel(preferences: preferences))
    }

    var body: some View {
        TabView {
            CutPasteTab(model: model)
                .tabItem {
                    Label("Cut/Paste", systemImage: "doc.on.clipboard")
                }
            PlaceholderTab(
                icon: "display",
                title: "Display",
                message: "Display settings coming soon."
            )
                .tabItem {
                    Label("Display", systemImage: "display")
                }
            PlaceholderTab(
                icon: "network",
                title: "Network",
                message: "Network settings coming soon."
            )
                .tabItem {
                    Label("Network", systemImage: "network")
                }
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

    init(preferences: Preferences) {
        self.prefs = preferences
        self.clipboardEnabled = preferences.clipboardEnabled
        self.copyMode = preferences.copyMode
    }
}
