import SwiftUI

// Placeholder for the examine mode. Step 7 lands the real
// implementation: file picker, request tree on the left, decoded
// detail pane on the right, timeline scrubber across the bottom.

struct OpenView: View {
    var body: some View {
        PlaceholderModeView(
            icon: "doc.text.magnifyingglass",
            title: "Open",
            tagline: "Browse a recorded .xtap. Make sense of what an X client did on the wire.",
            features: [
                "Open any .xtap from the server's /tmp/swift-x-captures/ folder or elsewhere.",
                "Tree view groups requests by phase (setup, window creation, drawing, events).",
                "Detail pane decodes the selected packet with structured, annotated, and raw-hex tabs.",
                "Timeline scrubber jumps by time, by request count, or filters by opcode.",
            ],
            comingIn: "step 7"
        )
    }
}
