import Foundation

// Boot/shutdown progress milestones derived from REAL console transcripts of
// the three guest OSes, instead of a hand-tuned fraction table. Paste a fresh
// capture into the OS's transcript below to retune its bar; the parser turns
// each into an ordered set of landmark substrings spread evenly across the
// bar's range.
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
// Why per-OS (not a common table): the three guests share only the OpenBIOS
// prelude, which is over in the first seconds -- a common table would park the
// bar at ~20% for the whole kernel + userland bring-up. Per the guest-profile
// rule (GUEST_OS_PROFILE.md), the transcripts switch exhaustively on
// MachineOS, so a 4th OS won't compile until it brings its own capture.
//
// Curation rule for pastes: drop lines whose text varies run-to-run or
// machine-to-machine (dates, MAC addresses -- they derive from the machine id
// now -- memory sizes, hostids, syslog pids, login prompts). A variable line
// never matches, which is harmless, but it wastes a slot in the even spread.
// Leading `[   1.0000060]` NetBSD kernel timestamps are fine to leave in: the
// parser strips them (the value varies run-to-run; the remainder is the
// landmark, and runtime substring-matching ignores the live line's prefix).
//
// Noise handling: our own `[macXserver]` status lines (and the variable-count
// "waiting" chatter) are dropped, leading syslog timestamps are stripped so
// the stable remainder matches, and the garbled power-off tail is filtered.
//
// The authoritative end-pins live in QemuEngine, NOT here: boot reaches 1.0
// from the first `hello` (not the console), and shutdown bottoms out on
// pid-death. These tables only drive the smooth middle.

enum ProgressReference {

    /// Boot milestones for one guest OS, spread across [0.07, 0.95]; `hello`
    /// owns the final 1.0.
    static func boot(for os: MachineOS) -> [(String, Double)] {
        milestones(from: bootTranscript(for: os), from: 0.07, to: 0.95)
    }

    /// Shutdown milestones for one guest OS, spread across [0.92, 0.05],
    /// receding as the box comes down; pid-death drives the final 0.
    static func shutdown(for os: MachineOS) -> [(String, Double)] {
        milestones(from: shutdownTranscript(for: os), from: 0.92, to: 0.05)
    }

    // MARK: - Transcripts (one per guest OS, exhaustive)

    static func bootTranscript(for os: MachineOS) -> String {
        switch os {
        case .solaris26: return solaris26Boot
        case .sunos414:  return sunos414Boot
        case .netbsd:    return netbsdBoot
        }
    }

    static func shutdownTranscript(for os: MachineOS) -> String {
        switch os {
        case .solaris26: return solaris26Shutdown
        case .sunos414:  return sunos414Shutdown
        case .netbsd:    return netbsdShutdown
        }
    }

    // Captured 2026-06-23 from the bundled SS-5 / Solaris 2.6 image.
    private static let solaris26Boot = """
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

    private static let solaris26Shutdown = """
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

    // Captured 2026-07-07 from the bundled SS-5 / SunOS 4.1.4 image.
    private static let sunos414Boot = """
    Configuration device id QEMU version 1 machine id 32
    Probing SBus slot 0 offset 0
    Probing SBus slot 1 offset 0
    Probing SBus slot 2 offset 0
    Probing SBus slot 3 offset 0
    Probing SBus slot 4 offset 0
    Probing SBus slot 5 offset 0
    Invalid FCode start byte
    CPUs: 1 x FMI,MB86904
    Welcome to OpenBIOS v1.1 built on Sep 24 2024 19:56
    Loading a.out image...
    Loaded 7680 bytes
    bootpath: /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@3,0
    switching to new context:
    Boot: vmunix
    VAC ENABLED
    SunOS Release 4.1.4 (GENERIC) #2: Fri Oct 14 11:09:47 PDT 1994
    Copyright (c) 1983-1993, Sun Microsystems, Inc.
    cpu = SUNW,SPARCstation-5
    entering uniprocessor mode
    espdma0 at  SBus slot 5 0x8400000
    esp0 at  SBus slot 5 0x8800000 pri 4 (onboard)
    sd0 at esp0 target 3 lun 0
    ledma0 at  SBus slot 5 0x8400010
    le0 at  SBus slot 5 0x8c00000 pri 6 (onboard)
    tcx0: revision 0, screen 1024x768
    zs0 at  SBus slot 5 0x1100000 pri 12 (onboard)
    zs1 at  SBus slot 5 0x1000000 pri 12 (onboard)
    root on sd0a fstype 4.2
    swap on sd0b fstype spec size 262144K
    Setting netmask of le0 to 255.255.255.0
    le0: AUI Ethernet
    checking filesystems
    /dev/rsd0a: is stable.
    Automatic reboot in progress...
    checking quotas: done.
    starting rpc port mapper.
    starting RPC key server.
    Flushing routing tables:
    add net default: gateway 10.0.2.2
    network interface configuration:
    mount -vat nfs
    starting additional services: biod.
    starting system logger
    starting local daemons: auditd sendmail statd lockd
    link-editor directory cache
    Starting heliosAgent.
    heliosAgent started
    preserving editor files
    clearing /tmp
    standard daemons: update cron uucp.
    starting network daemons: inetd printer.
    """

    // NOTE: no bare "halted"/"Halted"-only landmark may appear in a shutdown
    // table if the OS's FIRST shutdown line already contains it as a substring
    // ("halt: halted by root") -- pickLowest would bottom the bar instantly.
    // SunOS's capital-H "Halted" is safe (the halt-by line is lowercase).
    private static let sunos414Shutdown = """
    halt: halted by
    syslogd: going down on signal 15
    syncing file systems... done
    Halted
    """

    // Captured 2026-07-07 from the bundled SS-5 / NetBSD 9.2 image. Kernel
    // `[   n.nnnnnnn]` timestamps are left as pasted; the parser strips them.
    private static let netbsdBoot = """
    Configuration device id QEMU version 1 machine id 32
    Probing SBus slot 0 offset 0
    Probing SBus slot 1 offset 0
    Probing SBus slot 2 offset 0
    Probing SBus slot 3 offset 0
    Probing SBus slot 4 offset 0
    Probing SBus slot 5 offset 0
    Invalid FCode start byte
    CPUs: 1 x FMI,MB86904
    Welcome to OpenBIOS v1.1 built on Sep 24 2024 19:56
    Not a bootable ELF image
    Loading a.out image...
    Loaded 65536 bytes
    bootpath: /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@0,0
    switching to new context:
    >> NetBSD/sparc Secondary Boot, Revision 1.15 (Wed May 12 13:15:55 UTC 2021)
    Booting netbsd
    [   1.0000000] NetBSD 9.2 (GENERIC) #0: Wed May 12 13:15:55 UTC 2021
    [   1.0000000] cpu0 at mainbus0: FMI,MB86904 @ 170 MHz, on-chip FPU
    [   1.0000000] obio0 at mainbus0
    [   1.0000000] clock0 at obio0 slot 0 offset 0x200000: mk48t08
    [   1.0000060] zs0 at obio0 slot 0 offset 0x100000 level 12 softpri 6
    [   1.0000060] zstty0 at zs0 channel 0 (console i/o)
    [   1.0000060] fdc0 at obio0 slot 0 offset 0x400000 level 11 softpri 4: chip 82077
    [   1.0000060] iommu0 at mainbus0 addr 0x10000000: version 0x5/0x0, page-size 4096, range 64MB
    [   1.0000060] sbus0 at iommu0: clock = 21.250 MHz
    [   1.0000060] esp0 at dma0 slot 5 offset 0x8800000 level 4: ESP200, 40MHz, SCSI ID 7
    [   1.0000060] scsibus0 at esp0: 8 targets, 8 luns per target
    [   1.0000060] le0: 8 receive buffers, 2 transmit buffers
    [   1.0000060] tcx0: SUNW,tcx, 1024 x 768
    [   1.0000060] audiocs0 at sbus0 slot 4 offset 0xc000000 level 5 (ipl 9): CS4231A
    [   1.0000060] scsibus0: waiting 2 seconds for devices to settle...
    [   3.0001280] sd0 at scsibus0 target 0 lun 0: <QEMU, QEMU HARDDISK, 2.5+> disk fixed
    [   4.0885080] root on sd0a dumps on sd0b
    [   4.0975230] root file system type: ffs
    Starting root file system check:
    /dev/rsd0a: file system is clean; not checking
    swapctl: setting dump device to /dev/sd0b
    Starting file system checks:
    Setting tty flags.
    Setting sysctl variables:
    Starting network.
    Hostname: netbsd.localdomain
    Configuring network interfaces: le0.
    add net default: gateway 10.0.2.2
    Waiting for DAD to complete for statically configured addresses...
    Building databases: dev, utmp, utmpx.
    Starting syslogd.
    Mounting all file systems...
    Clearing temporary files.
    Updating fontconfig cache: done.
    Checking quotas: done.
    Starting virecover.
    Checking for core dump...
    savecore: no core dump
    Starting local daemons:.
    Updating motd.
    Starting sshd.
    Starting postfix.
    Starting inetd.
    Starting heliosagent.
    Starting cron.
    """

    // "halted" is deliberately absent: the first shutdown line ("halt: halted
    // by <user>") contains it, and pickLowest would snap the bar to the bottom
    // on the first line. "unmounting done" is the deepest console landmark;
    // pid-death drives the final 0.
    // ("syslogd[157]:" carries a pid, so the landmark is the pid-free suffix.)
    private static let netbsdShutdown = """
    halt: halted by
    Exiting on signal 15
    [ 176.2483930] syncing disks... done
    [ 176.2483930] unmounting file systems...
    [ 176.4179230] unmounting done
    """

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
    /// fragments; strip leading syslog and NetBSD kernel timestamps so the
    /// stable remainder is what we match on.
    static func landmarks(from transcript: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let line = stripSyslogTimestamp(stripKernelTimestamp(trimmed))
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

    /// Strip a leading NetBSD kernel timestamp ("[   1.0000060] ") -- the value
    /// varies run to run, so the marker is the stable remainder. Runtime
    /// substring matching then ignores whatever timestamp the live line has.
    static func stripKernelTimestamp(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard Double(inner) != nil else { return line }
        return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
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
