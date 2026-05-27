import Foundation

public enum LauncherTokenKind: Equatable, Sendable {
    case comment, sectionHeader, key, separator, value, unknown
}

public struct LauncherTokenSpan: Equatable, Sendable {
    public let kind: LauncherTokenKind
    public let range: NSRange
}

public enum LauncherTokenizer {
    public static func tokenize(_ text: String) -> [LauncherTokenSpan] {
        var spans: [LauncherTokenSpan] = []
        let ns = text as NSString
        var pos = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let utf16 = NSRange(lineRange, in: text)
            let line = ns.substring(with: utf16)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                pos = utf16.location + utf16.length
                return
            }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("!") {
                spans.append(LauncherTokenSpan(kind: .comment, range: utf16))
            } else if trimmed.hasPrefix("[") && trimmed.contains("]") {
                spans.append(LauncherTokenSpan(kind: .sectionHeader, range: utf16))
            } else if let eqIdx = line.firstIndex(of: "=") {
                let eqUtf16 = line.distance(from: line.startIndex, to: eqIdx)
                let keyRange = NSRange(location: utf16.location, length: eqUtf16)
                let sepRange = NSRange(location: utf16.location + eqUtf16, length: 1)
                let valStart = utf16.location + eqUtf16 + 1
                let valLen = utf16.length - eqUtf16 - 1
                if keyRange.length > 0 { spans.append(LauncherTokenSpan(kind: .key, range: keyRange)) }
                spans.append(LauncherTokenSpan(kind: .separator, range: sepRange))
                if valLen > 0 { spans.append(LauncherTokenSpan(kind: .value, range: NSRange(location: valStart, length: valLen))) }
            } else {
                spans.append(LauncherTokenSpan(kind: .unknown, range: utf16))
            }
            pos = utf16.location + utf16.length
        }
        return spans
    }
}
