public struct DiffArgs: Equatable, Sendable {
    public var pathA: String
    public var pathB: String
    public var onlyDifferent: Bool

    public init(pathA: String, pathB: String, onlyDifferent: Bool) {
        self.pathA = pathA
        self.pathB = pathB
        self.onlyDifferent = onlyDifferent
    }
}

public struct CaptureArgs: Equatable, Sendable {
    public var listenHost: String
    public var listenPort: UInt16
    public var forwardHost: String
    public var forwardPort: UInt16
    public var outputPath: String

    public init(listenHost: String, listenPort: UInt16, forwardHost: String, forwardPort: UInt16, outputPath: String) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.forwardHost = forwardHost
        self.forwardPort = forwardPort
        self.outputPath = outputPath
    }
}

public enum CLIError: Error, Equatable, Sendable {
    case missingValue(flag: String)
    case unknownFlag(String)
    case missingFlag(String)
    case invalidHostPort(String)
}

public enum CLI {
    public static let usage = """
    macxcapture --listen <[host:]port> --forward <host:port> --output <path>
    macxcapture dump <path-to-xtap>
    macxcapture diff <a.xtap> <b.xtap> [--only-different]
    macxcapture replay <path-to-xtap> [--target <host:port>]

      --listen <[host:]port>    Address to listen for X clients on
      --forward <host:port>     Address of the upstream X server
      --output <path>           Path to write the .xtap capture file

      dump <path>               Chronological per-message dump
      summary <path>            Aggregate analysis of a recorded .xtap
      diff <a> <b>              Markdown diff of two captures, aligned per-direction
        --only-different        Suppress matching rows; show only diff/onlyA/onlyB
      replay <path>             Send a recorded session's C2S bytes to a target X server
        --target <host:port>    Defaults to 127.0.0.1:6000
        --realtime              Pace C2S frames using their original .xtap timestamps
                                (slow but lets the WM reparent and expose between frames,
                                so drawing actually appears on screen)
        --hold                  After sending, keep the connection open until Ctrl-C
                                (so windows stay mapped long enough to actually appear)
    """

    public static func parseCapture(_ args: [String]) throws -> CaptureArgs {
        var listen: String?
        var forward: String?
        var output: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--listen":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(flag: "--listen") }
                listen = args[i]
            case "--forward":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(flag: "--forward") }
                forward = args[i]
            case "--output":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(flag: "--output") }
                output = args[i]
            default:
                throw CLIError.unknownFlag(arg)
            }
            i += 1
        }

        guard let listen = listen else { throw CLIError.missingFlag("--listen") }
        guard let forward = forward else { throw CLIError.missingFlag("--forward") }
        guard let output = output else { throw CLIError.missingFlag("--output") }

        let listenHP = try parseHostPort(listen, defaultHost: "0.0.0.0")
        let forwardHP = try parseHostPort(forward, defaultHost: nil)

        return CaptureArgs(
            listenHost: listenHP.host,
            listenPort: listenHP.port,
            forwardHost: forwardHP.host,
            forwardPort: forwardHP.port,
            outputPath: output
        )
    }

    public static func parseReplay(_ args: [String]) throws -> ReplayArgs {
        var path: String?
        var target: String?
        var hold = false
        var realtime = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--target":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(flag: "--target") }
                target = args[i]
            case "--hold":
                hold = true
            case "--realtime":
                realtime = true
            default:
                if arg.hasPrefix("--") { throw CLIError.unknownFlag(arg) }
                guard path == nil else { throw CLIError.unknownFlag(arg) }
                path = arg
            }
            i += 1
        }

        guard let path = path else { throw CLIError.missingFlag("<path>") }
        let targetHP = try parseHostPort(target ?? "127.0.0.1:6000", defaultHost: nil)
        return ReplayArgs(inputPath: path, targetHost: targetHP.host, targetPort: targetHP.port, hold: hold, realtime: realtime)
    }

    public static func parseDiff(_ args: [String]) throws -> DiffArgs {
        var pathA: String?
        var pathB: String?
        var onlyDifferent = false

        for arg in args {
            switch arg {
            case "--only-different":
                onlyDifferent = true
            default:
                if arg.hasPrefix("--") { throw CLIError.unknownFlag(arg) }
                if pathA == nil { pathA = arg }
                else if pathB == nil { pathB = arg }
                else { throw CLIError.unknownFlag(arg) }
            }
        }

        guard let pathA = pathA else { throw CLIError.missingFlag("<a.xtap>") }
        guard let pathB = pathB else { throw CLIError.missingFlag("<b.xtap>") }
        return DiffArgs(pathA: pathA, pathB: pathB, onlyDifferent: onlyDifferent)
    }

    public static func parseHostPort(_ s: String, defaultHost: String?) throws -> (host: String, port: UInt16) {
        if s.hasPrefix(":") {
            let portString = String(s.dropFirst())
            guard let port = UInt16(portString) else { throw CLIError.invalidHostPort(s) }
            guard let host = defaultHost else { throw CLIError.invalidHostPort(s) }
            return (host, port)
        }
        guard let colonIdx = s.lastIndex(of: ":") else { throw CLIError.invalidHostPort(s) }
        let host = String(s[..<colonIdx])
        let portString = String(s[s.index(after: colonIdx)...])
        guard !host.isEmpty, let port = UInt16(portString) else {
            throw CLIError.invalidHostPort(s)
        }
        return (host, port)
    }
}
