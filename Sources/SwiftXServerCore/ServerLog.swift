import Foundation

// Tiny logger so the session can emit a trace without depending on os.Logger
// or a real logging framework. Tests can install a sink that captures lines.

public protocol ServerLogSink: AnyObject {
    func log(_ line: String)
}

public final class StderrLogSink: ServerLogSink {
    public init() {}
    public func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

public final class CapturingLogSink: ServerLogSink {
    public private(set) var lines: [String] = []
    public init() {}
    public func log(_ line: String) { lines.append(line) }
}

public enum ServerLogLevel: Int, Comparable {
    case trace = 0, info = 1, warn = 2, error = 3
    public static func < (lhs: ServerLogLevel, rhs: ServerLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
