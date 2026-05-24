import SwiftUI

// The launch window. Three big button-cards, one per mode.
// Inspired by Xcode's "Choose a template" screen — clear visual
// hierarchy, large hit targets, descriptions that say what each
// mode is for.
//
// Clicking a card opens the corresponding mode window and closes
// the chooser. Re-opening the chooser means relaunching for now;
// proper File-menu wiring lands in a later step.

struct ModeChooserView: View {

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            VStack(alignment: .leading, spacing: 4) {
                Text("MacXCapture")
                    .font(.largeTitle)
                Text("Choose what you want to do.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            VStack(spacing: 12) {
                ModeCard(
                    icon: "recordingtape",
                    title: "Record",
                    subtitle: "Sit between an X client and an X server. Save the wire traffic to a .xtap file."
                ) {
                    openWindow(id: WindowID.record.rawValue)
                    dismissWindow(id: WindowID.modeChooser.rawValue)
                }

                ModeCard(
                    icon: "doc.text.magnifyingglass",
                    title: "Open",
                    subtitle: "Browse an existing .xtap. Inspect requests, replies, events; jump by time or by opcode."
                ) {
                    openWindow(id: WindowID.open.rawValue)
                    dismissWindow(id: WindowID.modeChooser.rawValue)
                }

                ModeCard(
                    icon: "play.circle",
                    title: "Replay",
                    subtitle: "Send a captured .xtap into a live X server. Real-time pacing or fast pump."
                ) {
                    openWindow(id: WindowID.replay.rawValue)
                    dismissWindow(id: WindowID.modeChooser.rawValue)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 560)
    }
}

/// A single mode-chooser row. Button styled to look like a card so
/// each mode is a clear, large target.
private struct ModeCard: View {

    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3).fontWeight(.semibold)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
