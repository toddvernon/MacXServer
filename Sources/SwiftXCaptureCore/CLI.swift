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
    swiftx-capture --listen <[host:]port> --forward <host:port> --output <path>
    swiftx-capture dump <path-to-xtap>

      --listen <[host:]port>    Address to listen for X clients on
      --forward <host:port>     Address of the upstream X server
      --output <path>           Path to write the .xtap capture file

      dump <path>               Chronological per-message dump
      summary <path>            Aggregate analysis of a recorded .xtap
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
