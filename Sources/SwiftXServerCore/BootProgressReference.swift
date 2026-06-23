import Foundation

// Boot/shutdown progress milestones derived from REAL console transcripts of
// the bundled SPARCstation, instead of a hand-tuned fraction table. Paste a
// fresh capture into `bootTranscript` / `shutdownTranscript` to retune the
// bars; the parser turns each into an ordered set of landmark substrings
// spread evenly across the bar's range.
//
// Why position-based + transcript-driven:
//   - Loss-tolerant. The bar only has to recognize SOME lines. Each recognized
//     line snaps progress to that line's spot in the sequence, so if a user
//     edits which services start/stop, the bar just gets driven by different
//     lines -- it never stalls waiting for a line that no longer prints.
//   - Self-pacing on "chunky" boots. The bar dwells on a slow step for free:
//     it sits at the last-seen line's fraction until the next line prints, so
//     a long gap between lines = a natural pause. No timing data needed.
//   - Self-documenting. The reference IS the real log; refreshing it is a
//     paste, not a code change.
//
// Noise handling: our own `[macXserver]` status lines (and the variable-count
// "waiting" chatter) are dropped, leading syslog timestamps are stripped so
// the stable remainder matches, and the garbled power-off tail is filtered.
//
// The authoritative end-pins live in QemuEngine, NOT here: boot reaches 1.0
// from the first `hello` (not the console), and shutdown bottoms out on
// pid-death. These tables only drive the smooth middle.

enum ProgressReference {

    // Captured 2026-06-23 from the bundled SS-5 / Solaris 2.6 image.
    static let bootTranscript = """
    Configuration device id QEMU version 1 machine id 32
    Probing SBus slot 0 offset 0
    Probing SBus slot 1 offset 0
    Probing SBus slot 2 offset 0
    Probing SBus slot 3 offset 0
    Invalid FCode start byte
    Probing SBus slot 4 offset 0
    Probing SBus slot 5 offset 0
    CPUs: 1 x FMI,MB86904
    Welcome to OpenBIOS v1.1 built on Sep 24 2024 19:56
    Trying disk:a...
    Loading a.out image...
    Loaded 7680 bytes
    bootpath: /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@0,0:a
    switching to new context:
    SunOS Release 5.6 Version Generic_105181-05 [UNIX(R) System V Release 4.0]
    Copyright (c) 1983-1997, Sun Microsystems, Inc.
    configuring network interfaces: le0.
    Hostname: SPARCplug
    The system is coming up.  Please wait.
    checking ufs filesystems
    /dev/rdsk/c0t0d0s7: is clean.
    add net default: gateway 10.0.2.2
    starting rpc services: rpcbind keyserv done.
    Setting netmask of le0 to 255.255.255.0
    Setting default interface for multicast: add net 224.0.0.0: gateway SPARCplug
    syslog service starting.
    Print services started.
    volume management starting.
    Starting heliosAgent.
    heliosAgent started
    prngd started
    sshd started
    The system is ready.
    SPARCplug console login:
    """

    static let shutdownTranscript = """
    INIT: New run level: 5
    The system is coming down.  Please wait.
    System services are now being stopped.
    Print services stopped.
    Stopping the syslog service.
    syslogd: going down on signal 15
    snmpdx: received signal 15
    The system is down.
    syncing file systems
    """

    /// Boot milestones spread across [0.07, 0.95]; `hello` owns the final 1.0.
    static let boot: [(String, Double)] = milestones(from: bootTranscript, from: 0.07, to: 0.95)

    /// Shutdown milestones spread across [0.92, 0.05], receding as the box
    /// comes down; pid-death drives the final 0.
    static let shutdown: [(String, Double)] = milestones(from: shutdownTranscript, from: 0.92, to: 0.05)

    // MARK: - Parsing

    /// Turn a transcript into landmark→fraction pairs, evenly spaced across
    /// [from, to] in transcript order. `from`/`to` may be descending (shutdown).
    static func milestones(from transcript: String, from lo: Double, to hi: Double) -> [(String, Double)] {
        let marks = landmarks(from: transcript)
        guard marks.count > 1 else { return marks.map { ($0, lo) } }
        let last = Double(marks.count - 1)
        return marks.enumerated().map { i, mark in
            (mark, lo + (hi - lo) * (Double(i) / last))
        }
    }

    /// Ordered, de-duplicated stable landmark substrings: drop blank lines, our
    /// own `[macXserver]` status, the garbled power-off tail, and too-short
    /// fragments; strip leading syslog timestamps so the stable remainder is
    /// what we match on.
    static func landmarks(from transcript: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripSyslogTimestamp(raw.trimmingCharacters(in: .whitespaces))
            guard isStableLandmark(line), !seen.contains(line) else { continue }
            seen.insert(line)
            result.append(line)
        }
        return result
    }

    private static func isStableLandmark(_ line: String) -> Bool {
        if line.count < 6 { return false }                 // too short → matches too eagerly
        if line.contains("[macXserver]") { return false }  // our injected status, not guest console
        if line.contains("halt, power off") { return false } // garbled console as the CPU halts
        return true
    }

    /// Strip a leading SysV/syslog timestamp ("Jun 23 13:48:14 ") so the marker
    /// is the stable remainder ("snmpdx: received signal 15"). Substring
    /// matching at runtime then ignores whatever timestamp the live line has.
    private static func stripSyslogTimestamp(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        if parts.count == 4,
           months.contains(String(parts[0])),
           Int(parts[1]) != nil,
           isClock(String(parts[2])) {
            return String(parts[3])
        }
        return line
    }

    private static let months: Set<String> =
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func isClock(_ s: String) -> Bool {
        let c = s.split(separator: ":")
        return c.count == 3 && c.allSatisfy { Int($0) != nil }
    }
}
