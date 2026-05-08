import Foundation
import AppKit
import Darwin
import SwiftXServerCore

// CLI for the M2/M3 server. Listens on :6000, accepts one client connection,
// pops up real NSWindows for top-level X windows, and drives an AppKit
// runloop on the main thread so the windows actually appear.

func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

/// Walk the macOS interface list and return the IPv4 address of the primary
/// LAN interface (en0 preferred — Wi-Fi or built-in Ethernet on most Macs;
/// otherwise the first up, non-loopback `en*` interface). Used for the
/// menu-bar status string so the user can read off a real `xterm -display`
/// target instead of the literal bind-any address `0.0.0.0`.
func primaryLocalIPv4() -> String? {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let head = ifaddrPtr else { return nil }
    defer { freeifaddrs(head) }

    var fallback: String?
    var ptr: UnsafeMutablePointer<ifaddrs>? = head
    while let cur = ptr {
        defer { ptr = cur.pointee.ifa_next }
        let flags = Int32(cur.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let addr = cur.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET) else { continue }

        let name = String(cString: cur.pointee.ifa_name)
        // en* only — skip awdl/llw/utun/bridge/anpi/ap1 noise.
        guard name.hasPrefix("en") else { continue }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                             &host, socklen_t(NI_MAXHOST),
                             nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { continue }
        let ip = String(cString: host)
        if name == "en0" { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
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

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// `.regular`: standard Mac app. `.accessory` would hide the Dock icon but
// per Apple's docs also hides the menu bar entirely, which is wrong here —
// users need the App menu (Preferences, Quit) and Edit menu (Copy, Paste)
// at the top of the screen. Status-bar item still installs alongside.
app.setActivationPolicy(.regular)

do {
    let actual = try listener.bind()
    let display = port == 6000 ? "0" : String(Int(port) - 6000)
    // Resolve the bind address to something the user can actually paste into
    // `xterm -display`. If the caller passed an explicit --host that isn't
    // any/local/wildcard, respect it; otherwise deduce the primary LAN IP.
    let isWildcard = (host == "0.0.0.0" || host == "::" || host.isEmpty)
    let advertisedHost = isWildcard ? (primaryLocalIPv4() ?? host) : host
    let displayLabel = "Listening on \(advertisedHost):\(actual) — X display :\(display)"
    appDelegate.listenerStatus = displayLabel
    writeStderr("swiftx-server \(displayLabel)\n")
    writeStderr("display: native \(displayConfig.nativePixelWidth)×\(displayConfig.nativePixelHeight)px → ")
    writeStderr("X-logical \(displayConfig.logicalWidth)×\(displayConfig.logicalHeight) at \(displayConfig.scale)x ")
    writeStderr("(\(displayConfig.deviceWidth)×\(displayConfig.deviceHeight) device px), ~90 DPI\n")
    writeStderr("waiting for one client...\n\n")
} catch {
    writeStderr("error: \(error)\n")
    exit(1)
}

// Capture the prefs reference via a nonisolated accessor on AppDelegate so
// the listener thread can pass it to runAccepting. The provider type is Sendable.
let prefsProvider: ClipboardPreferencesProvider = appDelegate.sharedPreferences

// Coordinator is shared across every session this listener spins up — it
// owns the global atom table and selection-owner state, and hands out
// non-overlapping resource-id ranges per accepted client.
let coordinator = ServerCoordinator()

// Run the listener on a background thread so the main thread can drive AppKit.
// runAccepting loops accepting connections; each accept spawns a dedicated
// read+write thread pair. Quit via Cmd-Q (or `pkill swiftx-server`).
DispatchQueue.global(qos: .userInitiated).async {
    listener.runAccepting(
        template: serverConfig,
        bridge: bridge,
        coordinator: coordinator,
        clipboardPrefs: prefsProvider,
        sessionLogFactory: { clientNumber in
            // One file per connection in ~/Library/Logs/swiftx-server/.
            // Renamed to <wmInstance>-<timestamp>.log when WM_CLASS arrives.
            FileLogSink(sessionNumber: clientNumber)
        },
        sessionDidStart: { session, clientNumber, sessionLog in
            // When the client identifies itself via WM_CLASS, retitle the
            // log file from session-N-<ts>.log to <instance>-<ts>.log so
            // we can tell at a glance which app produced which trace.
            session.onIdentified = { instance, _ in
                if let fileSink = sessionLog as? FileLogSink {
                    fileSink.rename(toIdentified: instance)
                }
            }
        }
    )
    writeStderr("listener stopped.\n")
}

app.run()
