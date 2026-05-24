import SwiftUI

// Shared chrome for the three mode windows during step 5. Each
// mode declares its icon, title, tagline, and bullet list of what
// it WILL do once implemented. Reads as "this isn't ready yet, but
// here's the plan" — preferable to an apologetic "coming soon"
// page or, worse, an empty window.

struct PlaceholderModeView: View {

    let icon: String
    let title: String
    let tagline: String
    let features: [String]
    let comingIn: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle)
                    Text(tagline)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("What it'll do")
                    .font(.headline)

                ForEach(features, id: \.self) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 7)
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)

            Spacer()

            HStack {
                Image(systemName: "hammer")
                    .foregroundStyle(.secondary)
                Text("Implementation arrives in \(comingIn) of the capture v2 plan.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 560, height: 460)
    }
}
