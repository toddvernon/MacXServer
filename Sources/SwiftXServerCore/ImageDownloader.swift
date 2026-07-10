import Foundation
import CryptoKit

/// Progress phases for one image install, in pipeline order. The UI maps these
/// onto the machine row's thermometer (download fraction while downloading, a
/// barber pole for the fixed-cost phases).
public enum ImageDownloadPhase: Equatable, Sendable {
    /// Streaming the gz payload. `fraction` is 0...1 of `sizeGz`.
    case downloading(fraction: Double)
    /// SHA-256 of the downloaded gz.
    case verifyingDownload
    /// gunzip to the temp sibling.
    case decompressing
    /// SHA-256 of the decompressed image + guest-OS banner check.
    case verifyingImage
    /// Atomic move into place.
    case installing

    /// Short human label ("Downloading… 42%").
    public var label: String {
        switch self {
        case .downloading(let f):
            return "Downloading\u{2026} \(Int((f * 100).rounded()))%"
        case .verifyingDownload: return "Verifying download\u{2026}"
        case .decompressing:     return "Decompressing\u{2026}"
        case .verifyingImage:    return "Verifying image\u{2026}"
        case .installing:        return "Installing\u{2026}"
        }
    }
}

/// Everything that can go wrong installing an image, each with a user-facing
/// message. The pipeline never leaves partial files behind on failure.
public enum ImageDownloadError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case destinationExists(String)
    case checksumMismatch(what: String)
    case gunzipFailed(String)
    case wrongGuest(expected: MachineOS, detection: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The server answered with HTTP \(code)."
        case .insufficientDiskSpace(let needed, let available):
            let fmt = ByteCountFormatter()
            return "Not enough disk space: the download needs "
                + "\(fmt.string(fromByteCount: needed)) free, only "
                + "\(fmt.string(fromByteCount: available)) available."
        case .destinationExists(let path):
            return "A file already exists at \(path). Attach it with "
                + "Choose Image, or remove it and download again."
        case .checksumMismatch(let what):
            return "The \(what) failed its checksum \u{2014} the file is "
                + "corrupt. Nothing was installed; try the download again."
        case .gunzipFailed(let detail):
            return "Decompressing the image failed: \(detail)"
        case .wrongGuest(let expected, let detection):
            return "The downloaded image doesn't contain "
                + "\(expected.displayName) (\(detection)). Nothing was "
                + "installed \u{2014} this is a catalog problem, not yours."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

/// Downloads, verifies, and installs a curated disk image: stream the gz
/// payload with progress → SHA-256 the gz → gunzip to a temp sibling →
/// SHA-256 the image → guest-OS banner check → atomic move into place.
/// Three independent verifications (transport corruption, gunzip truncation,
/// wrong-payload-in-catalog) per IMAGE_DOWNLOAD_PLAN.md. All temp files live
/// next to the destination (same volume, so the final move is a rename) and
/// are removed on any failure. Cancellation rides Swift task cancellation;
/// a cancelled install cleans up and throws `.cancelled`.
public enum ImageDownloader {

    // MARK: - Destination naming (IMAGE_DOWNLOAD_PLAN.md "Where images land")

    /// The one global images directory. Not user-visible config yet (the
    /// default just works); created on first download.
    public static var defaultImagesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("macXserver/Images", isDirectory: true)
    }

    /// The canonical filename for a machine's downloaded image. Never
    /// user-chosen: a bundled fixture gets `<os>-boot.qcow2` (the name the
    /// whole tooling ecosystem knows); a user-created machine gets
    /// `<os>-<shortid>.qcow2` where shortid derives from the machine's
    /// *identity* (first 8 hex of its UUID), not its name — renaming the
    /// machine never orphans the file, and two same-OS machines can never
    /// fight over a filename.
    public static func imageFilename(os: MachineOS, machineID: UUID,
                                     bundled: Bool) -> String {
        if bundled { return "\(os.rawValue)-boot.qcow2" }
        let shortID = machineID.uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "").prefix(8)
        return "\(os.rawValue)-\(shortID).qcow2"
    }

    // MARK: - The pipeline

    /// Run the full install pipeline for `entry`, landing the image at
    /// `destination`. `expectedOS` is the target machine's OS — the third
    /// verification (`GuestOSDetector` banner) must agree with it. `onPhase`
    /// is delivered on the main queue, throttled to ~1% steps while
    /// downloading. Throws `ImageDownloadError`; on any throw the destination
    /// is untouched and temp files are gone.
    public static func install(entry: ImageCatalog.Entry,
                               destination: URL,
                               expectedOS: MachineOS,
                               onPhase: @escaping @Sendable (ImageDownloadPhase) -> Void)
        async throws
    {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Refuse to clobber: the qcow2 IS a user's disk state if one is
        // sitting there. (Re-download-over-existing is a deliberate non-goal
        // in v1; the plan's honest v0 is "delete it in Finder, download
        // again".)
        guard !fm.fileExists(atPath: destination.path) else {
            throw ImageDownloadError.destinationExists(destination.path)
        }

        // Disk preflight: the gz and the decompressed image coexist briefly.
        let needed = entry.sizeGz + entry.size + 100 * 1024 * 1024
        if let available = try? dir.resourceValues(
               forKeys: [.volumeAvailableCapacityForImportantUsageKey])
               .volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw ImageDownloadError.insufficientDiskSpace(
                needed: needed, available: available)
        }

        // Temp siblings in the destination directory (same volume → the final
        // move is an atomic rename). Distinctive suffixes so a crashed run's
        // leftovers are recognizable; stale ones are swept before we start.
        let tempGz = dir.appendingPathComponent(
            destination.lastPathComponent + ".download.gz")
        let tempImage = dir.appendingPathComponent(
            destination.lastPathComponent + ".download")
        try? fm.removeItem(at: tempGz)
        try? fm.removeItem(at: tempImage)
        // Whatever happens below, never leave partials behind.
        defer {
            try? fm.removeItem(at: tempGz)
            try? fm.removeItem(at: tempImage)
        }

        let report: @Sendable (ImageDownloadPhase) -> Void = { phase in
            DispatchQueue.main.async { onPhase(phase) }
        }

        // 1. Download the gz payload with progress.
        report(.downloading(fraction: 0))
        try await download(from: entry.url, to: tempGz,
                           expectedSize: entry.sizeGz) { fraction in
            report(.downloading(fraction: fraction))
        }
        try Task.checkCancellation()

        // 2. Verify the gz checksum (transport corruption).
        report(.verifyingDownload)
        guard try sha256Hex(of: tempGz) == entry.sha256Gz.lowercased() else {
            throw ImageDownloadError.checksumMismatch(what: "downloaded file")
        }
        try Task.checkCancellation()

        // 3. gunzip to the temp sibling. /usr/bin/gunzip over an in-process
        //    decoder on purpose: boring, always present, handles every gzip
        //    variant; its missing integrity story is covered by step 4.
        report(.decompressing)
        try gunzip(tempGz, to: tempImage)
        try Task.checkCancellation()

        // 4. Verify the image checksum (gunzip truncation — the NAS lesson:
        //    never trust size).
        report(.verifyingImage)
        guard try sha256Hex(of: tempImage) == entry.sha256.lowercased() else {
            throw ImageDownloadError.checksumMismatch(what: "decompressed image")
        }

        // 5. Guest-OS banner check (wrong-payload-in-catalog, human upload
        //    error). Essentially free after the hash read.
        let detection = GuestOSDetector.detect(imagePath: tempImage.path)
        guard detection.os == expectedOS else {
            throw ImageDownloadError.wrongGuest(expected: expectedOS,
                                                detection: detection.explanation)
        }
        try Task.checkCancellation()

        // 6. Atomic move into place.
        report(.installing)
        try fm.moveItem(at: tempImage, to: destination)
    }

    // MARK: - Download (URLSession download task + progress delegate)

    /// Stream `url` to `file` with progress callbacks (throttled to ~1%
    /// steps). A classic delegate-driven download task: the payload never
    /// passes through memory, and `file://` source URLs work so tests stay
    /// off the network.
    private static func download(from url: URL, to file: URL,
                                 expectedSize: Int64,
                                 onProgress: @escaping @Sendable (Double) -> Void)
        async throws
    {
        let delegate = DownloadDelegate(destination: file,
                                        expectedSize: expectedSize,
                                        onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral,
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, Error>) in
                delegate.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate,
                                          @unchecked Sendable {
        private let destination: URL
        private let expectedSize: Int64
        private let onProgress: @Sendable (Double) -> Void
        /// Guarded by the serial delegate queue URLSession creates for us.
        var continuation: CheckedContinuation<Void, Error>?
        private var lastReportedPercent = -1

        init(destination: URL, expectedSize: Int64,
             onProgress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.expectedSize = expectedSize
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite : expectedSize
            guard total > 0 else { return }
            let fraction = min(1, Double(totalBytesWritten) / Double(total))
            let percent = Int(fraction * 100)
            if percent != lastReportedPercent {   // throttle: ~100 callbacks total
                lastReportedPercent = percent
                onProgress(fraction)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // The URLSession temp file dies when this callback returns, so the
            // move happens here, synchronously. A move failure is reported via
            // didCompleteWithError? No — that fires with nil error after this;
            // stash the failure and resume exactly once there.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
            // Reject non-2xx up front (a 404 page is not an image).
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                moveError = ImageDownloadError.httpStatus(http.statusCode)
            }
        }
        private var moveError: Error?

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let cont = continuation else { return }
            continuation = nil
            if let error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    cont.resume(throwing: ImageDownloadError.cancelled)
                } else {
                    cont.resume(throwing: error)
                }
            } else if let moveError {
                cont.resume(throwing: moveError)
            } else {
                cont.resume()
            }
        }
    }

    // MARK: - Hashing + gunzip

    /// Streaming SHA-256 of a file (1 MB chunks — the images are GBs; never
    /// load them whole). Lowercase hex.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// gunzip `source` into `target` via /usr/bin/gunzip (stdout redirect).
    /// The exit status is the only integrity signal we take from it; real
    /// integrity is the caller's SHA-256 of the output.
    static func gunzip(_ source: URL, to target: URL) throws {
        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: target.path) else {
            throw ImageDownloadError.gunzipFailed("can't open \(target.path)")
        }
        defer { try? out.close() }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        proc.arguments = ["-c", source.path]
        proc.standardOutput = out
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw ImageDownloadError.gunzipFailed("\(error)")
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw ImageDownloadError.gunzipFailed(
                err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
