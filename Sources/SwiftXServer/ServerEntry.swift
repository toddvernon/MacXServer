import Foundation
import AppKit
import Darwin
import SwiftXServerCore
import SwiftXCaptureCore

// Callable entry point for macxserver. The body that previously
// lived as top-level code in main.swift moved here so both the SPM
// `macxserver` executable target and an Xcode `.app` bundle's
// `@main` wrapper can call into the same setup. Behaviour is
// unchanged: parse CLI args, build the NSApplication + listener,
// run the AppKit runloop until quit.

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

enum ServerEntry {

    /// Drive the whole server. Never returns under normal operation
    /// (NSApplication.run() blocks); on exit codes it calls exit()
    /// directly the same way the top-level main.swift used to.
    ///
    /// `@MainActor` because the body touches AppKit (NSApplication,
    /// the AppDelegate, the bridge) which is main-actor-isolated.
    /// When this code lived as top-level in main.swift the actor
    /// isolation was implicit; promoting it to a function loses
    /// that, so we annotate explicitly.
    @MainActor
    static func run() {
        // Ignore SIGPIPE: a write to a socket whose peer already closed will
        // return EPIPE and the listener's read source picks up the EOF on the
        // next loop. Without this the kernel kills the process on the first
        // post-disconnect write, which manifests as "I quit my X client and
        // the server vanished." Safe to call here pre-thread-spawn — signal()
        // is per-process, not per-thread.
        signal(SIGPIPE, SIG_IGN)

        var host = "0.0.0.0"
        var port: UInt16 = 6000
        // nil = use the Preferences value at startup. `--capture` sets true,
        // `--no-capture` sets false. Resolved into a concrete bool below once
        // the AppDelegate is built and prefs are readable.
        var captureOverride: Bool? = nil

        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            // AppKit passes its own -NSFoo / -AppleBar key/value pairs
            // when an .app is launched from Xcode or Finder (e.g.
            // -NSDocumentRevisionsDebugMode YES). They're NSUserDefaults
            // pokes meant for the foundation layer, not our CLI. Skip
            // each arg AND its following value rather than blowing up.
            if args[i].hasPrefix("-NS") || args[i].hasPrefix("-Apple") {
                i += 2
                continue
            }
            switch args[i] {
            case "-h", "--help":
                print("""
                usage: macxserver [--host HOST] [--port PORT] [--capture | --no-capture]

                Listens for X client connections on HOST:PORT (default 0.0.0.0:6000
                which is X DISPLAY :0). Top-level X windows become real NSWindows on
                the Mac with native chrome.

                --capture / --no-capture override the Preferences toggle for this
                process. When capture is on, every accepted client writes its own
                .xtap to /tmp/swift-x-captures/ (configurable in Preferences).
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
            case "--capture":
                captureOverride = true
            case "--no-capture":
                captureOverride = false
            default:
                writeStderr("unknown arg: \(args[i])\n")
                exit(2)
            }
            i += 1
        }

        let log = StderrLogSink()
        WireTrace.installFromEnvironment()
        let listener = Listener(host: host, port: port, log: log)

        // Detect the connected display and pick a logical-root + integer-scale
        // combination per `SERVER_RESOLUTION_SCALING_AND_FONTS.md`.
        let displayConfig = DisplayConfig.forMainDisplay()
        let serverConfig = ServerConfig(displayConfig: displayConfig)
        let bridge = CocoaWindowBridge(scaleFactor: displayConfig.scale, log: log)

        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        // Wire the optional Motif-frame preference into the bridge now that
        // the AppDelegate (and its Preferences instance) exists. Bridge
        // snapshots `current` at mapTopLevel time, so the live values are
        // always honored for new windows.
        bridge.motifFramePrefs = appDelegate.preferences.motifFrameProvider
        appDelegate.listener = listener
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
            writeStderr("macxserver \(displayLabel)\n")
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

        // Resolve capture state: CLI override wins, else Preferences value. The
        // resolved bool is fixed for this process's lifetime — toggling the
        // Preferences checkbox at runtime only affects newly-accepted sessions
        // after a server restart (documented in the Capture tab UI).
        let captureEnabled = captureOverride ?? appDelegate.preferences.captureSessions
        let captureDirectory = appDelegate.preferences.captureDirectory
        appDelegate.captureActive = captureEnabled
        if captureEnabled {
            writeStderr("capture: every client session will be written to \(captureDirectory)\n")
        }
        let captureSinkFactory: ((Int) -> CaptureSink?)? = captureEnabled ? { clientNumber in
            do {
                return try SessionCapture(sessionId: clientNumber, directory: captureDirectory)
            } catch {
                writeStderr("capture: failed to start session \(clientNumber) capture: \(error)\n")
                return nil
            }
        } : nil

        // Font mappings: seed ~/.swiftx-fonts on first run and load into the
        // FontResolver cache. Subsequent runs read the user's file; the
        // embedded seed only re-seeds via Revert to Defaults in the editor.
        FontResolver.installMappings()

        // Coordinator is shared across every session this listener spins up — it
        // owns the global atom table and selection-owner state, and hands out
        // non-overlapping resource-id ranges per accepted client.
        let coordinator = ServerCoordinator()

        // Run the listener on a background thread so the main thread can drive AppKit.
        // runAccepting loops accepting connections; each accept spawns a dedicated
        // read+write thread pair. Quit via Cmd-Q (or `pkill macxserver`).
        DispatchQueue.global(qos: .userInitiated).async {
            listener.runAccepting(
                template: serverConfig,
                bridge: bridge,
                coordinator: coordinator,
                clipboardPrefs: prefsProvider,
                sessionLogFactory: { clientNumber in
                    // One file per connection in ~/Library/Logs/macxserver/.
                    // Renamed to <wmInstance>-<timestamp>.log when WM_CLASS arrives.
                    FileLogSink(sessionNumber: clientNumber)
                },
                captureSinkFactory: captureSinkFactory,
                sessionDidStart: { session, clientNumber, sessionLog, captureSink in
                    // When the client identifies itself via WM_CLASS, retitle
                    // both the log file (session-N-<ts>.log → <instance>-<ts>.log)
                    // and the capture file (.in-progress-N.xtap → <ts>-<instance>.xtap)
                    // so the disk artifacts say what app produced them.
                    session.onIdentified = { instance, _ in
                        if let fileSink = sessionLog as? FileLogSink {
                            fileSink.rename(toIdentified: instance)
                        }
                        if let sessionCapture = captureSink as? SessionCapture {
                            sessionCapture.rename(toClientName: instance)
                        }
                    }
                }
            )
            writeStderr("listener stopped.\n")
        }

        app.run()
    }
}
