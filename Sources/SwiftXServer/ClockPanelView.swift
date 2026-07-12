import SwiftUI
import AppKit
import SwiftXServerCore

// Clock admin panel (Overview → Helios Admin Agents → Clock): show how far
// the machine's clock sits from this Mac's (NTP-true) clock and set it over
// the Helios agent as root. The interesting case is SunOS 4.1.4 with a wrong
// YEAR: the stock 4.1.4 date corrupts the clock hardware when handed a year
// (see ClockAdmin.swift for the whole story), so when the year must change
// the panel first asks the box's own date command whether it's Y2K-patched.
// Patched → the normal Set Clock. Not provable → the button becomes Force
// Set behind an explicit warning, so the human owns the gamble (Todd's call,
// 2026-07-12).

struct ClockPanelView: View {

    @StateObject private var model: ClockPanelModel
    private let machineName: String
    /// Explicit Dismiss button (Todd doesn't rely on the window-manager close
    /// button for dialogs).
    private let onDismiss: (() -> Void)?

    init(machineName: String,
         osProvider: @escaping () -> MachineOS?,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16,
         onDismiss: (() -> Void)? = nil) {
        self.machineName = machineName
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: ClockPanelModel(
            machineName: machineName,
            osProvider: osProvider, secretProvider: secretProvider,
            hostProvider: hostProvider, portProvider: portProvider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            readingBox
            if model.needsForce { forceWarning }
            actionRow
            bannerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 460)
        .onAppear { model.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clock")
                    .font(.title2)
                Text("Set \(machineName)'s clock from this Mac's clock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Reading

    private var readingBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = model.reading {
                LabeledContent("This Mac") {
                    Text(Self.timeString(r.checkedAt))
                }
                LabeledContent(machineName) {
                    Text(Self.timeString(r.guestDate))
                }
                Text(model.skewSentence)
                    .font(.callout)
                    .foregroundStyle(abs(r.skew) < 5 ? .secondary : .primary)
                    .padding(.top, 2)
            } else {
                Text(model.busy ? "Checking the machine's clock\u{2026}"
                                : "The machine's clock hasn't been read yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// The Force Set warning: shown only when the year must change on a
    /// SunOS 4.1.4 box whose date command couldn't prove itself Y2K-patched.
    private var forceWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Setting the year on this machine could make it unbootable.")
                    .font(.callout).bold()
                Text("The machine's year is wrong, and its date command failed "
                     + "the Year-2000 check (it answers like the stock SunOS 4.1.4 "
                     + "date, which writes a corrupt year to the clock chip). If "
                     + "that happens the machine won't boot, and recovery means "
                     + "booting install media just to re-enter the time. The safe "
                     + "fix is installing Sun patch 105143-03 first. Force Set "
                     + "runs the year change anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.yellow.opacity(0.12)))
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Dismiss") { onDismiss?() }
                .keyboardShortcut(.cancelAction)
            Button("Refresh") { model.load() }
                .disabled(model.busy)
            if model.needsForce {
                Button(role: .destructive) {
                    model.set(force: true)
                } label: {
                    Text("Force Set")
                }
                .disabled(model.busy)
            } else {
                Button("Set Clock") { model.set(force: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.reading == nil)
            }
        }
    }

    private var bannerRow: some View {
        Text(model.banner.isEmpty ? " " : model.banner)
            .font(.caption)
            .foregroundStyle(model.bannerIsError ? .red : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func timeString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - View model

@MainActor
final class ClockPanelModel: ObservableObject {

    struct Reading: Equatable {
        let guestDate: Date
        let checkedAt: Date
        /// Guest minus Mac, seconds, at check time.
        var skew: TimeInterval { guestDate.timeIntervalSince(checkedAt) }
        let yearDiffers: Bool
        /// Only run when the year differs on a 4.1.4 box; nil otherwise.
        let probe: ClockAdmin.Y2KProbe?
    }

    @Published var reading: Reading?
    @Published var busy = false
    @Published var banner = ""
    @Published var bannerIsError = false

    private let machineName: String
    private let osProvider: () -> MachineOS?
    private let secretProvider: () -> String?
    private let hostProvider: () -> String
    private let portProvider: () -> UInt16

    init(machineName: String,
         osProvider: @escaping () -> MachineOS?,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16) {
        self.machineName = machineName
        self.osProvider = osProvider
        self.secretProvider = secretProvider
        self.hostProvider = hostProvider
        self.portProvider = portProvider
    }

    /// The Force Set posture: the year must change, the box is 4.1.4, and the
    /// probe couldn't prove a patched date. (ClockAdmin.syncClock enforces
    /// the same rule server-side of this UI; the panel just decides which
    /// button to draw.)
    var needsForce: Bool {
        guard let r = reading, osProvider() == .sunos414, r.yearDiffers else { return false }
        return !(r.probe?.isPatched ?? false)
    }

    var skewSentence: String {
        guard let r = reading else { return "" }
        var sentence = Self.describeSkew(r.skew)
        if r.yearDiffers { sentence += " The year itself is wrong." }
        return sentence
    }

    // MARK: Helios I/O
    //
    // Same shape as DnsAdminPanelModel: HeliosClient is blocking and
    // one-request-in-flight, so each op runs on a global queue with its own
    // short-lived client and hops back to the main actor. `busy` serializes
    // at the UI level.

    func load() {
        guard !busy else { return }
        guard let os = osProvider() else {
            setBanner("The machine's OS isn't known yet.", error: true)
            return
        }
        busy = true
        setBanner("Reading the machine's clock\u{2026}", error: false)
        let secret = secretProvider()
        let host = hostProvider()
        let port = portProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Reading, Error>
            let client = HeliosClient(host: host, port: port, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                let sys = try client.sysinfo()
                let checkedAt = Date()
                let guestDate = Date(timeIntervalSince1970: sys.time)
                let yearDiffers = ClockAdmin.yearChanges(guest: guestDate, mac: checkedAt)
                var probe: ClockAdmin.Y2KProbe?
                if yearDiffers && os == .sunos414 {
                    probe = try ClockAdmin.probeY2KDate(transport: client)
                }
                outcome = .success(Reading(guestDate: guestDate, checkedAt: checkedAt,
                                           yearDiffers: yearDiffers, probe: probe))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let r):
                    self.reading = r
                    self.setBanner("", error: false)
                case .failure(let error):
                    self.setBanner("Couldn't read the clock: \(Self.describe(error))",
                                   error: true)
                }
            }
        }
    }

    func set(force: Bool) {
        guard !busy else { return }
        guard let os = osProvider() else {
            setBanner("The machine's OS isn't known yet.", error: true)
            return
        }
        busy = true
        setBanner(force ? "Force-setting the clock (year change)\u{2026}"
                        : "Setting the clock\u{2026}", error: false)
        let secret = secretProvider()
        let host = hostProvider()
        let port = portProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<(TimeInterval, Reading), Error>
            let client = HeliosClient(host: host, port: port, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                // Fresh guest time for the year decision -- never a stale one.
                let sys = try client.sysinfo()
                let guestDate = Date(timeIntervalSince1970: sys.time)
                let skew = try ClockAdmin.syncClock(os: os, transport: client,
                                                    guest: guestDate, force: force)
                // Re-read so the panel shows the post-set truth.
                let after = try client.sysinfo()
                let checkedAt = Date()
                let afterDate = Date(timeIntervalSince1970: after.time)
                let r = Reading(guestDate: afterDate, checkedAt: checkedAt,
                                yearDiffers: ClockAdmin.yearChanges(guest: afterDate,
                                                                    mac: checkedAt),
                                probe: nil)
                outcome = .success((skew, r))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let (skew, r)):
                    self.reading = r
                    self.setBanner(String(format: "Clock set -- the machine now reads "
                                          + "within %.0f second(s) of this Mac.",
                                          abs(skew).rounded(.up)), error: false)
                case .failure(let error):
                    self.setBanner("Couldn't set the clock: \(Self.describe(error))",
                                   error: true)
                }
            }
        }
    }

    private func setBanner(_ message: String, error: Bool) {
        banner = message
        bannerIsError = error
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? ClockAdminError { return e.errorDescription ?? "\(e)" }
        return (error as? HeliosClient.HeliosError)?.errorDescription
            ?? error.localizedDescription
    }

    /// Plain-English skew ("47 minutes behind this Mac"), no protocol jargon.
    static func describeSkew(_ skew: TimeInterval) -> String {
        let s = abs(skew)
        if s < 5 { return "The machine's clock matches this Mac." }
        let direction = skew < 0 ? "behind" : "ahead of"
        let amount: String
        switch s {
        case ..<120:            amount = "\(Int(s.rounded())) seconds"
        case ..<(2 * 3600):     amount = "\(Int((s / 60).rounded())) minutes"
        case ..<(2 * 86_400):   amount = "\(Int((s / 3600).rounded())) hours"
        default:                amount = "\(Int((s / 86_400).rounded())) days"
        }
        return "The machine's clock is \(amount) \(direction) this Mac."
    }
}
