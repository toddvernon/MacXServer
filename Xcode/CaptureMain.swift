import SwiftUI

// @main entry for the MacXCapture .app bundle target in
// MacXServer.xcodeproj. Mirrors what main.swift does for the SPM
// executable when no args are given: hand the runloop to
// SwiftXCaptureApp.
//
// This file is ONLY in the Xcode .app target's compile sources.
// The SPM executable target excludes it and uses main.swift
// instead, which can ALSO route to the CLI when subcommands are
// passed. The .app is GUI-only by design — anyone launching it
// from Finder gets the chooser window.

@main
struct CaptureAppMain {
    static func main() {
        SwiftXCaptureApp.main()
    }
}
