import Foundation
import Framer

// Walks two .xtap captures and diffs them per direction, message by message.
// C2S and S2C are aligned independently by longest-common-subsequence on the
// formatted-line representation from ChronoDumper (so "same" means same
// opcode/kind plus same significant fields with atoms resolved by name).
// LCS makes the diff tolerant of stream skew: a divergence in the middle no
// longer poisons every downstream row. Unmatched runs are paired up entry-
// by-entry as `different` rows; excess on either side becomes onlyA / onlyB.
//
// Client-allocated resource IDs are not normalized: for the gold-vs-swiftx
// use case our resourceIdBase matches Sun's, so they align naturally.
//
// Server-allocated identifiers DO differ across servers and get scrubbed by
// `applyToleranceRules` before LCS keying: InternAtom atom IDs (the name in
// parens carries the canonical identity), QueryExtension's major-opcode and
// event/error bases, and AllocColor / AllocNamedColor pixel values. The
// displayed line keeps the original values so the user can read the actuals.

public enum DiffStatus: String, Equatable, Sendable {
    case same
    case different
    case onlyA
    case onlyB
}

public struct DiffRow: Equatable, Sendable {
    public var direction: Direction
    public var ordinal: Int
    public var aLine: String?
    public var bLine: String?
    public var status: DiffStatus

    public init(direction: Direction, ordinal: Int, aLine: String?, bLine: String?, status: DiffStatus) {
        self.direction = direction
        self.ordinal = ordinal
        self.aLine = aLine
        self.bLine = bLine
        self.status = status
    }
}

public struct DiffCounts: Equatable, Sendable {
    public var total: Int
    public var same: Int
    public var different: Int
    public var onlyA: Int
    public var onlyB: Int

    public init(total: Int = 0, same: Int = 0, different: Int = 0, onlyA: Int = 0, onlyB: Int = 0) {
        self.total = total
        self.same = same
        self.different = different
        self.onlyA = onlyA
        self.onlyB = onlyB
    }
}

public struct DiffReport: Equatable, Sendable {
    public var pathA: String
    public var pathB: String
    public var c2sRows: [DiffRow]
    public var s2cRows: [DiffRow]
    public var c2sCounts: DiffCounts
    public var s2cCounts: DiffCounts

    public init(pathA: String, pathB: String, c2sRows: [DiffRow], s2cRows: [DiffRow]) {
        self.pathA = pathA
        self.pathB = pathB
        self.c2sRows = c2sRows
        self.s2cRows = s2cRows
        self.c2sCounts = countRows(c2sRows)
        self.s2cCounts = countRows(s2cRows)
    }
}

public struct DiffRenderOptions: Sendable {
    public var onlyDifferent: Bool

    public init(onlyDifferent: Bool = false) {
        self.onlyDifferent = onlyDifferent
    }
}

public enum CaptureDiff {
    public static func compare(pathA: String, pathB: String) throws -> DiffReport {
        let (a, metaA) = try walkMessages(path: pathA)
        let (b, metaB) = try walkMessages(path: pathB)
        return diff(pathA: pathA, pathB: pathB, a: a, b: b, metaA: metaA, metaB: metaB)
    }

    static func diff(pathA: String, pathB: String,
                     a: [MessageEntry], b: [MessageEntry],
                     metaA: StreamMetadata = .empty, metaB: StreamMetadata = .empty) -> DiffReport {
        let aC2S = a.filter { $0.direction == .clientToServer }
        let bC2S = b.filter { $0.direction == .clientToServer }
        let aS2C = a.filter { $0.direction == .serverToClient }
        let bS2C = b.filter { $0.direction == .serverToClient }
        let c2sRows = alignAndCompare(direction: .clientToServer, a: aC2S, b: bC2S, metaA: metaA, metaB: metaB)
        let s2cRows = alignAndCompare(direction: .serverToClient, a: aS2C, b: bS2C, metaA: metaA, metaB: metaB)
        return DiffReport(pathA: pathA, pathB: pathB, c2sRows: c2sRows, s2cRows: s2cRows)
    }

    public static func render(_ report: DiffReport, options: DiffRenderOptions = DiffRenderOptions()) -> String {
        var out = ""
        out += "# capture diff\n\n"
        out += "- A: `\(report.pathA)`\n"
        out += "- B: `\(report.pathB)`\n\n"

        out += "## Summary\n\n"
        out += "| direction | total | same | different | only A | only B |\n"
        out += "| --- | ---: | ---: | ---: | ---: | ---: |\n"
        out += summaryRow(name: "C2S", c: report.c2sCounts)
        out += summaryRow(name: "S2C", c: report.s2cCounts)
        out += "\n"

        out += "## C2S (client → server)\n\n"
        out += renderTable(report.c2sRows, onlyDifferent: options.onlyDifferent)
        out += "\n"
        out += "## S2C (server → client)\n\n"
        out += renderTable(report.s2cRows, onlyDifferent: options.onlyDifferent)
        return out
    }
}

// MARK: - Internals

struct MessageEntry: Equatable, Sendable {
    var direction: Direction
    var timestamp: UInt64
    var line: String
}

// Per-stream state from the connection-setup phase that downstream
// normalization needs. Two captures of the same client against different
// servers will get different resource-id bases and different
// server-allocated root/colormap/visual IDs; subtracting them out lets
// the LCS treat semantically equal lines as equal.
struct StreamMetadata: Equatable, Sendable {
    var resourceIdBase: UInt32
    var resourceIdMask: UInt32
    var rootWindowIds: Set<UInt32>
    var rootVisualIds: Set<UInt32>
    var defaultColormapIds: Set<UInt32>

    static let empty = StreamMetadata(
        resourceIdBase: 0, resourceIdMask: 0,
        rootWindowIds: [], rootVisualIds: [], defaultColormapIds: []
    )
}

func walkMessages(path: String) throws -> (entries: [MessageEntry], metadata: StreamMetadata) {
    let frames = try CaptureReader.read(from: path)

    var byteOrder: ByteOrder = .lsbFirst
    for f in frames where f.direction == .clientToServer && !f.bytes.isEmpty {
        byteOrder = (f.bytes[0] == 0x42) ? .msbFirst : .lsbFirst
        break
    }

    var c2s = StreamWalker()
    var s2c = StreamWalker()
    var ctx = ChronoContext()
    var entries: [MessageEntry] = []
    var metadata: StreamMetadata = .empty

    for frame in frames {
        switch frame.direction {
        case .clientToServer:
            c2s.append(frame.bytes, timestamp: frame.timestamp)
            while let (ts, raw) = try c2s.extractC2S(byteOrder: byteOrder, setupSeen: ctx.c2sSetupSeen) {
                if !ctx.c2sSetupSeen {
                    ctx.c2sSetupSeen = true
                    if case .setupRequest(let r) = raw {
                        entries.append(MessageEntry(direction: .clientToServer, timestamp: ts, line: formatSetupRequest(r)))
                    }
                } else if case .request(let req) = raw {
                    let seq = ctx.nextSeq
                    ctx.nextSeq &+= 1
                    ctx.seqToOpcode[seq] = opcodeOf(req)
                    if case .internAtom(let ia) = req {
                        ctx.seqToInternAtomName[seq] = String(decoding: ia.name, as: UTF8.self)
                    }
                    if case .queryExtension(let qe) = req {
                        ctx.seqToQueryExtensionName[seq] = String(decoding: qe.name, as: UTF8.self)
                    }
                    entries.append(MessageEntry(direction: .clientToServer, timestamp: ts, line: formatRequest(req, seq: seq, ctx: ctx)))
                }
            }
        case .serverToClient:
            s2c.append(frame.bytes, timestamp: frame.timestamp)
            while let (ts, raw) = try s2c.extractS2C(byteOrder: byteOrder, setupSeen: ctx.s2cSetupSeen) {
                if !ctx.s2cSetupSeen {
                    ctx.s2cSetupSeen = true
                    if case .setupReply(let r) = raw {
                        if case .accepted(let acc) = r {
                            metadata.resourceIdBase = acc.resourceIdBase
                            metadata.resourceIdMask = acc.resourceIdMask
                            metadata.rootWindowIds = Set(acc.screens.map(\.root))
                            metadata.rootVisualIds = Set(acc.screens.map(\.rootVisual))
                            metadata.defaultColormapIds = Set(acc.screens.map(\.defaultColormap))
                        }
                        entries.append(MessageEntry(direction: .serverToClient, timestamp: ts, line: formatSetupReply(r)))
                    }
                } else if case .serverMessage(let m) = raw {
                    entries.append(MessageEntry(direction: .serverToClient, timestamp: ts, line: formatServerMessage(m, byteOrder: byteOrder, ctx: &ctx)))
                }
            }
        }
    }

    return (entries, metadata)
}

private func alignAndCompare(direction: Direction,
                              a: [MessageEntry], b: [MessageEntry],
                              metaA: StreamMetadata, metaB: StreamMetadata) -> [DiffRow] {
    // LCS matches on a normalized key: leading "[seq=N]" stripped (sequence
    // numbers are stream-local — once gold and swiftx diverge in request
    // count, every downstream message has a different seq even when the
    // semantic content is identical), plus tolerance rules that scrub the
    // known server-allocated identifiers and substitute per-stream
    // canonical forms for resource IDs that legitimately differ. Display
    // still shows the original line so the user can read the actuals.
    let aKeys = a.map { applyToleranceRules(normalizeIdentifiers(stripSeqPrefix($0.line), metadata: metaA)) }
    let bKeys = b.map { applyToleranceRules(normalizeIdentifiers(stripSeqPrefix($0.line), metadata: metaB)) }
    let alignment = longestCommonSubsequence(a: aKeys, b: bKeys)
    return emitRows(direction: direction, a: a, b: b, alignment: alignment)
}

// Rewrite every "0xNNNN" in `line` to a per-stream canonical form so the
// same semantic identifier from two different servers compares equal:
//
//   - root window id  -> "0xROOT"
//   - root visual id  -> "0xVISUAL"
//   - default cmap id -> "0xCMAP"
//   - client-allocated (id high bits match resourceIdBase) -> "0xC<offset>"
//   - anything else   -> left alone (still a server-allocated atom or the
//                        like; the tolerance rules above handle the
//                        named cases)
//
// The client allocates resource IDs as `base | <small monotonically-
// increasing offset>` so the offset-only form is stable across captures
// from the same client against different servers.
func normalizeIdentifiers(_ line: String, metadata: StreamMetadata) -> String {
    if metadata.resourceIdMask == 0
        && metadata.rootWindowIds.isEmpty
        && metadata.rootVisualIds.isEmpty
        && metadata.defaultColormapIds.isEmpty {
        return line
    }
    return line.replacing(/0x[0-9A-Fa-f]+/) { match in
        let s = String(match.0)
        guard let id = UInt32(s.dropFirst(2), radix: 16) else { return s }
        if metadata.rootWindowIds.contains(id) { return "0xROOT" }
        if metadata.rootVisualIds.contains(id) { return "0xVISUAL" }
        if metadata.defaultColormapIds.contains(id) { return "0xCMAP" }
        if metadata.resourceIdMask != 0 {
            let baseBits = id & ~metadata.resourceIdMask
            if baseBits == metadata.resourceIdBase {
                let offset = id & metadata.resourceIdMask
                return "0xC" + String(offset, radix: 16, uppercase: true)
            }
        }
        return s
    }
}

func stripSeqPrefix(_ line: String) -> String {
    guard line.hasPrefix("[seq=") else { return line }
    guard let close = line.firstIndex(of: "]") else { return line }
    let after = line.index(after: close)
    if after < line.endIndex, line[after] == " " {
        return String(line[line.index(after: after)...])
    }
    return String(line[after...])
}

// Scrub fields that legitimately differ between two servers serving the
// same client. Each rule replaces the value with `*` so the canonical
// identity (atom name, extension name, RGB) carries the equality. Lines
// without these substrings pass through untouched.
//
// Patterns are anchored on the field-name prefix that ChronoDumper emits,
// so an unrelated substring like "major=5" appearing inside a property
// data dump won't get touched: only the literal " major=N" inside a
// QueryExtension reply gets matched.
//
// Patterns are re-compiled each call. Cheap (three short patterns) and
// keeps us out of Swift 6's non-Sendable global-let trap without having
// to launder `Regex<AnyRegexOutput>` through `nonisolated(unsafe)`.
func applyToleranceRules(_ line: String) -> String {
    var s = line
    // InternAtom reply: atom value differs across servers; the name in parens
    // carries the canonical identity. Match both hex and "None".
    s = s.replacing(
        try! Regex(#"Reply \(InternAtom\)\s+atom=(?:0x[0-9A-Fa-f]+|None)"#),
        with: "Reply (InternAtom)      atom=*"
    )
    // QueryExtension reply: name= and present= are canonical; the
    // major-opcode and first-event / first-error bases are server-private.
    s = s.replacing(
        try! Regex(#"major=\d+ firstEvent=\d+ firstError=\d+"#),
        with: "major=* firstEvent=* firstError=*"
    )
    // AllocColor / AllocNamedColor: server-allocated pixel value differs;
    // the RGB triple carries the request identity.
    s = s.replacing(try! Regex(#"pixel=0x[0-9A-Fa-f]+"#), with: "pixel=*")
    return s
}

// A single position in the aligned output. Either matched (both indices
// non-nil) or unmatched (exactly one index non-nil).
struct AlignmentPair: Equatable {
    var aIdx: Int?
    var bIdx: Int?
}

// Classic O(n*m) LCS on formatted lines. Captures of a few thousand messages
// fit comfortably; if we ever need to diff 50K-message sessions we'd switch
// to Hirschberg's for linear-space LCS or Myers for faster near-identical
// streams. Not worth the complexity now.
func longestCommonSubsequence(a: [String], b: [String]) -> [AlignmentPair] {
    let n = a.count, m = b.count
    if n == 0 { return (0..<m).map { AlignmentPair(aIdx: nil, bIdx: $0) } }
    if m == 0 { return (0..<n).map { AlignmentPair(aIdx: $0, bIdx: nil) } }

    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 1...n {
        for j in 1...m {
            if a[i-1] == b[j-1] {
                dp[i][j] = dp[i-1][j-1] + 1
            } else {
                dp[i][j] = max(dp[i-1][j], dp[i][j-1])
            }
        }
    }

    var pairs: [AlignmentPair] = []
    var i = n, j = m
    while i > 0 || j > 0 {
        if i > 0, j > 0, a[i-1] == b[j-1] {
            pairs.append(AlignmentPair(aIdx: i-1, bIdx: j-1))
            i -= 1
            j -= 1
        } else if j > 0, (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
            pairs.append(AlignmentPair(aIdx: nil, bIdx: j-1))
            j -= 1
        } else {
            pairs.append(AlignmentPair(aIdx: i-1, bIdx: nil))
            i -= 1
        }
    }
    return pairs.reversed()
}

// Walks the alignment and produces DiffRows. Matched pairs become `same`.
// Each contiguous unmatched run gets its A- and B-only entries paired up
// pairwise as `different` rows; whichever side has more entries spills the
// excess as onlyA or onlyB after the paired rows.
private func emitRows(direction: Direction, a: [MessageEntry], b: [MessageEntry], alignment: [AlignmentPair]) -> [DiffRow] {
    var rows: [DiffRow] = []
    var ordinal = 0
    var i = 0
    while i < alignment.count {
        let p = alignment[i]
        if let aIdx = p.aIdx, let bIdx = p.bIdx {
            rows.append(DiffRow(
                direction: direction, ordinal: ordinal,
                aLine: a[aIdx].line, bLine: b[bIdx].line, status: .same
            ))
            ordinal += 1
            i += 1
            continue
        }

        var aRun: [Int] = []
        var bRun: [Int] = []
        while i < alignment.count {
            let q = alignment[i]
            if q.aIdx != nil, q.bIdx != nil { break }
            if let aIdx = q.aIdx { aRun.append(aIdx) }
            if let bIdx = q.bIdx { bRun.append(bIdx) }
            i += 1
        }

        let pairs = min(aRun.count, bRun.count)
        for k in 0..<pairs {
            rows.append(DiffRow(
                direction: direction, ordinal: ordinal,
                aLine: a[aRun[k]].line, bLine: b[bRun[k]].line, status: .different
            ))
            ordinal += 1
        }
        for k in pairs..<aRun.count {
            rows.append(DiffRow(
                direction: direction, ordinal: ordinal,
                aLine: a[aRun[k]].line, bLine: nil, status: .onlyA
            ))
            ordinal += 1
        }
        for k in pairs..<bRun.count {
            rows.append(DiffRow(
                direction: direction, ordinal: ordinal,
                aLine: nil, bLine: b[bRun[k]].line, status: .onlyB
            ))
            ordinal += 1
        }
    }
    return rows
}

func countRows(_ rows: [DiffRow]) -> DiffCounts {
    var c = DiffCounts(total: rows.count)
    for r in rows {
        switch r.status {
        case .same: c.same += 1
        case .different: c.different += 1
        case .onlyA: c.onlyA += 1
        case .onlyB: c.onlyB += 1
        }
    }
    return c
}

private func summaryRow(name: String, c: DiffCounts) -> String {
    "| \(name) | \(c.total) | \(c.same) | \(c.different) | \(c.onlyA) | \(c.onlyB) |\n"
}

private func renderTable(_ rows: [DiffRow], onlyDifferent: Bool) -> String {
    var out = "| # | status | A | B |\n"
    out += "| ---: | --- | --- | --- |\n"
    var emitted = 0
    for r in rows {
        if onlyDifferent && r.status == .same { continue }
        let aCell = mdEscape(r.aLine ?? "")
        let bCell: String
        switch r.status {
        case .same: bCell = "="
        case .different: bCell = mdEscape(r.bLine ?? "")
        case .onlyA: bCell = "_(missing)_"
        case .onlyB: bCell = mdEscape(r.bLine ?? "")
        }
        let aDisplay: String
        if r.status == .onlyB { aDisplay = "_(missing)_" } else { aDisplay = aCell }
        out += "| \(r.ordinal) | \(r.status.rawValue) | \(aDisplay) | \(bCell) |\n"
        emitted += 1
    }
    if emitted == 0 {
        out += "| | | _(no rows)_ | |\n"
    }
    return out
}

private func mdEscape(_ s: String) -> String {
    // Pipes break markdown tables; backslash-escape them. Newlines shouldn't
    // appear in formatted lines, but collapse them defensively.
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "|": out += "\\|"
        case "\n": out += " "
        default: out.append(ch)
        }
    }
    return out
}
