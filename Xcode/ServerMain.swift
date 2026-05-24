import AppKit
import SwiftXServerCore

// @main entry for the MacXServer .app bundle target in
// MacXServer.xcodeproj. Calls into the shared ServerEntry.run()
// which sets up NSApplication, the listener, the AppDelegate, the
// status menu, and the AppKit runloop.
//
// The .app accepts the same CLI flags as the SPM executable
// (--host / --port / --capture / --no-capture) when launched
// from Terminal; the Finder-launched case just uses defaults.

@main
struct MacXServerMain {
    static func main() {
        ServerEntry.run()
    }
}
