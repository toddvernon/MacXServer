import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Advisory lock recording which machine + process is using a SPARCstation
/// disk image, so a second launch doesn't open the same qcow2 twice (which
/// corrupts it). The image lives in Dropbox and syncs across Todd's two
/// Macs, so the lock sits next to the image and is *host-aware*: a lock this
/// Mac reads might have been written by the other Mac, where the recorded
/// pid is meaningless. Plain-text and human-readable so it can be inspected
/// or deleted by hand.
///
/// Caveats this design accepts on purpose:
///   - Dropbox sync isn't instant, so cross-machine detection is best-effort.
///   - qemu's own qcow2 fcntl lock guards same-machine double-open hard, but
///     does NOT cross Dropbox (locks aren't synced, only bytes). This
///     advisory lock is the only cross-machine signal.
public struct ImageLock: Equatable, Sendable {
    /// Hostname (or IP if the hostname was unavailable) of the machine that
    /// holds the image. The cross-vs-same-machine decision keys off this.
    public let host: String
    /// The qemu process holding the image (NOT macXserver's pid — qemu is the
    /// process with the qcow2 open, and the one we'd reclaim). Only meaningful
    /// when `host` matches this machine.
    public let pid: Int32
    public let imagePath: String
    /// ISO-8601, for the "in use since …" message.
    public let startedAt: String
    public let appVersion: String
    /// The per-boot Helios secret the qemu holding this image was launched
    /// with. Persisted so a LATER macXserver process -- this Mac after a crash,
    /// or the other Mac via the Dropbox-synced lock -- can authenticate to that
    /// orphan's daemon and shut it down via Helios (the daemon requires this
    /// secret; without it the orphan-shutdown call fails auth). It's a
    /// loopback-only hostfwd token, regenerated every boot and useless once that
    /// qemu exits, so persisting it next to the image is low-risk. nil for locks
    /// written before this field existed (or by an unauthed launch).
    public let secret: String?
    /// The captive qemu's QMP control-socket path (VM_CONTROL.md Stage 3,
    /// "lock-as-VM-handle"). Lets a LATER process on THIS Mac clean-stop an
    /// orphan via a qcow2-clean QMP `quit` instead of SIGKILL -- no guest
    /// cooperation, no network auth. Local-filesystem path, so it's only
    /// meaningful when `host` matches this machine (same caveat as `pid`). nil
    /// for older locks or a launch without a QMP socket.
    public let qmpSocketPath: String?
    /// The captive qemu's serial-console socket path (VM_CONTROL.md Stage 3).
    /// Lets a later process re-attach the console *view* to a live orphan.
    /// Local-only, same host caveat as `qmpSocketPath`. nil for older locks.
    public let consoleSocketPath: String?
    /// The Mac-side hostfwd port of this guest's Helios daemon. With `secret`,
    /// makes the lock a complete handle for reaching a running guest's daemon --
    /// the orphan-recovery paths use it (they can't ask a registry which machine
    /// this was), and it's the interim channel for Claude Code to drive a guest
    /// (the MCP bridge supersedes it). nil for older locks.
    public let heliosPort: UInt16?

    public init(host: String, pid: Int32, imagePath: String,
                startedAt: String, appVersion: String, secret: String? = nil,
                qmpSocketPath: String? = nil, consoleSocketPath: String? = nil,
                heliosPort: UInt16? = nil) {
        self.host = host
        self.pid = pid
        self.imagePath = imagePath
        self.startedAt = startedAt
        self.appVersion = appVersion
        self.secret = secret
        self.qmpSocketPath = qmpSocketPath
        self.consoleSocketPath = consoleSocketPath
        self.heliosPort = heliosPort
    }

    /// Simple `key: value` lines, stable order, so a human can read it. The
    /// secret line is only emitted when present, so unauthed launches and the
    /// older format stay clean.
    public func serialized() -> String {
        var lines = [
            "host: \(host)",
            "pid: \(pid)",
            "image: \(imagePath)",
            "started: \(startedAt)",
            "appVersion: \(appVersion)",
        ]
        if let secret, !secret.isEmpty { lines.append("secret: \(secret)") }
        if let qmpSocketPath, !qmpSocketPath.isEmpty { lines.append("qmp: \(qmpSocketPath)") }
        if let consoleSocketPath, !consoleSocketPath.isEmpty { lines.append("console: \(consoleSocketPath)") }
        if let heliosPort { lines.append("heliosPort: \(heliosPort)") }
        return lines.joined(separator: "\n")
    }

    /// Parse the `key: value` format. Tolerant of unknown/missing optional
    /// keys; requires at least host + pid to be a usable lock.
    public static func parse(_ text: String) -> ImageLock? {
        var fields: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let host = fields["host"], !host.isEmpty,
              let pidStr = fields["pid"], let pid = Int32(pidStr) else { return nil }
        return ImageLock(
            host: host,
            pid: pid,
            imagePath: fields["image"] ?? "",
            startedAt: fields["started"] ?? "",
            appVersion: fields["appVersion"] ?? "",
            secret: fields["secret"].flatMap { $0.isEmpty ? nil : $0 },
            qmpSocketPath: fields["qmp"].flatMap { $0.isEmpty ? nil : $0 },
            consoleSocketPath: fields["console"].flatMap { $0.isEmpty ? nil : $0 },
            heliosPort: fields["heliosPort"].flatMap { UInt16($0) })
    }
}

/// The situation found when about to launch against an image.
public enum ImageLockStatus: Equatable, Sendable {
    /// No lock — safe to start.
    case free
    /// Lock from this host but the pid is gone (a hard crash left it behind).
    /// Safe to delete and start.
    case staleSameHost(ImageLock)
    /// Lock from this host, pid alive and actually our qemu — a real orphan
    /// (the Xcode-stop / crash footgun). Offer to shut it down / force quit.
    case localOrphan(ImageLock)
    /// Lock from a *different* host. We can't verify a remote pid, so this is
    /// a hard stop: the user deletes the lock if they know that Mac is idle.
    case remoteLocked(ImageLock)
}

public enum ImageLockManager {

    /// Sidecar path next to the image, e.g. `SUN40G.qcow2.macxserver-lock`.
    /// Next to the image (not Application Support) so both Macs sharing the
    /// Dropbox image see the same lock.
    public static func lockURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("macxserver-lock")
    }

    /// This machine's identity: hostname, or a primary IPv4 if the hostname
    /// is unavailable. Trailing `.local` is stripped so it reads cleanly.
    public static func currentHost() -> String {
        let name = ProcessInfo.processInfo.hostName
        if !name.isEmpty, name.lowercased() != "localhost" {
            return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        }
        return primaryIPv4() ?? "unknown-host"
    }

    /// Decide what to do about any existing lock. The `isAlive` / `isOurQemu`
    /// hooks are injectable so the decision logic is unit-testable without a
    /// real process.
    public static func evaluate(
        imageURL: URL,
        host: String = currentHost(),
        isAlive: (Int32) -> Bool = isProcessAlive,
        isOurQemu: (Int32) -> Bool = processIsOurQemu
    ) -> ImageLockStatus {
        let url = lockURL(for: imageURL)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let lock = ImageLock.parse(text) else { return .free }
        if lock.host != host { return .remoteLocked(lock) }
        if isAlive(lock.pid) && isOurQemu(lock.pid) { return .localOrphan(lock) }
        return .staleSameHost(lock)
    }

    /// Write our lock next to the image. `pid` is the qemu pid.
    @discardableResult
    public static func acquire(
        imageURL: URL, pid: Int32, appVersion: String, secret: String? = nil,
        qmpSocketPath: String? = nil, consoleSocketPath: String? = nil,
        heliosPort: UInt16? = nil,
        host: String = currentHost(), now: Date = Date()
    ) -> ImageLock {
        let stamp = ISO8601DateFormatter().string(from: now)
        let lock = ImageLock(host: host, pid: pid, imagePath: imageURL.path,
                             startedAt: stamp, appVersion: appVersion, secret: secret,
                             qmpSocketPath: qmpSocketPath, consoleSocketPath: consoleSocketPath,
                             heliosPort: heliosPort)
        try? lock.serialized().write(to: lockURL(for: imageURL),
                                     atomically: true, encoding: .utf8)
        return lock
    }

    /// Remove the lock only if it belongs to this host (don't clobber the
    /// other Mac's lock). Safe no-op if absent.
    public static func release(imageURL: URL, host: String = currentHost()) {
        let url = lockURL(for: imageURL)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let lock = ImageLock.parse(text) else { return }
        if lock.host == host {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Force-remove the lock regardless of owner. For the explicit
    /// "I deleted/killed it, proceed" paths in the UI.
    public static func forceRemove(imageURL: URL) {
        try? FileManager.default.removeItem(at: lockURL(for: imageURL))
    }

    // MARK: - Process probes (Darwin)

    /// Is `pid` a live process? `kill(pid, 0)` returns 0 if it exists and we
    /// can signal it; EPERM means it exists but is owned by someone else.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return false
        #endif
    }

    /// Is `pid` actually our bundled qemu (not an unrelated process that
    /// recycled the pid)? Guards Force Quit from killing the wrong thing.
    public static func processIsOurQemu(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return false }
        let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return path.hasSuffix("qemu-system-sparc")
        #else
        return false
        #endif
    }

    // MARK: - IP fallback

    private static func primaryIPv4() -> String? {
        #if canImport(Darwin)
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var best: String?
        var ptr = ifaddrPtr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuf,
                              socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = hostBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let ifname = String(cString: p.pointee.ifa_name)
            if ifname == "en0" { return ip }   // prefer the primary interface
            if best == nil { best = ip }
        }
        return best
        #else
        return nil
        #endif
    }
}
