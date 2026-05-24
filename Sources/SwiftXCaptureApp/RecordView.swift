import SwiftUI

// Placeholder for the proxy-record mode. Step 6 lands the real
// implementation: listen/forward fields, live byte counters, the
// scrolling decoded-request feed, Stop button that finalises the
// .xtap and offers to open it in a new Examine window.

struct RecordView: View {
    var body: some View {
        PlaceholderModeView(
            icon: "recordingtape",
            title: "Record",
            tagline: "Proxy capture between an X client and a real X server.",
            features: [
                "Listen on a TCP port; forward to a target X server.",
                "Stream the wire bytes to disk while the session is live.",
                "Show byte counters and the last few decoded requests in real time.",
                "Stop button finalises the .xtap and offers to open it for inspection.",
            ],
            comingIn: "step 6"
        )
    }
}
