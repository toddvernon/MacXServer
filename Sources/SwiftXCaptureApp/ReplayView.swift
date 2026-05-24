import SwiftUI

// Placeholder for the replay mode. Step 8 lands the real
// implementation: target field, pacing mode, hold-open toggle,
// progress bar; same semantics as the v1 CLI's `replay`
// subcommand but with the flags exposed as on-screen controls.

struct ReplayView: View {
    var body: some View {
        PlaceholderModeView(
            icon: "play.circle",
            title: "Replay",
            tagline: "Pipe a .xtap into a live X server. Smoke-test against your server or watch a recorded session render.",
            features: [
                "Pick a .xtap and a target server (host:port).",
                "Real-time pacing (timestamps from the capture) or fast pump for smoke tests.",
                "Hold-open after the last frame, so windows don't tear down before you can look.",
                "Progress bar with pause / stop / restart controls.",
            ],
            comingIn: "step 8"
        )
    }
}
