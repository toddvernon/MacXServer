import Foundation
import AppKit
import SwiftXServerCore

// CLI for the M2/M3 server. Listens on :6000, accepts one client connection,
// pops up real NSWindows for top-level X windows, and drives an AppKit
// runloop on the main thread so the windows actually appear.

func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

var host = "0.0.0.0"
var port: UInt16 = 6000

let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "-h", "--help":
        print("""
        usage: swiftx-server [--host HOST] [--port PORT]

        Listens for one X client connection on HOST:PORT (default 0.0.0.0:6000
        which is X DISPLAY :0). Top-level X windows become real NSWindows on
        the Mac with native chrome.
        """)
        exit(0)
    case "--host":
        i += 1
        guard i < args.count else { writeStderr("--host needs a value\n"); exit(2) }
        host = args[i]
    case "--port":
        i += 1
        guard i < args.count, let p = UInt16(args[i]) else {
            writeStderr("--port needs a uint16\n"); exit(2)
        }
        port = p
    default:
        writeStderr("unknown arg: \(args[i])\n")
        exit(2)
    }
    i += 1
}

let log = StderrLogSink()
let listener = Listener(host: host, port: port, log: log)

// Detect the connected display and pick a logical-root + integer-scale
// combination per `SERVER_RESOLUTION_SCALING_AND_FONTS.md`.
let displayConfig = DisplayConfig.forMainDisplay()
let serverConfig = ServerConfig(displayConfig: displayConfig)
let bridge = CocoaWindowBridge(scaleFactor: displayConfig.scale, log: log)

do {
    let actual = try listener.bind()
    let display = port == 6000 ? "0" : String(Int(port) - 6000)
    writeStderr("swiftx-server listening on \(host):\(actual) (X display :\(display))\n")
    writeStderr("display: native \(displayConfig.nativePixelWidth)×\(displayConfig.nativePixelHeight)px → ")
    writeStderr("X-logical \(displayConfig.logicalWidth)×\(displayConfig.logicalHeight) at \(displayConfig.scale)x ")
    writeStderr("(\(displayConfig.deviceWidth)×\(displayConfig.deviceHeight) device px), ~90 DPI\n")
    writeStderr("waiting for one client...\n\n")
} catch {
    writeStderr("error: \(error)\n")
    exit(1)
}

// Run the listener on a background thread so the main thread can drive AppKit.
// We deliberately DO NOT terminate NSApp on disconnect — this keeps any
// windows the client created visible after it exits, so we can inspect what
// rendered. Quit via Cmd-Q (or `pkill swiftx-server`).
DispatchQueue.global(qos: .userInitiated).async {
    do {
        try listener.runOne(config: serverConfig, bridge: bridge)
    } catch {
        writeStderr("listener error: \(error)\n")
    }
    writeStderr("client gone; windows retained for inspection (Cmd-Q to quit).\n")
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.run()
