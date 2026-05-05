public enum StartupHint {
    public static func displayHint(forListenPort port: UInt16, interfaces: [NetworkInterface]) -> String {
        guard port >= 6000 else {
            return "(non-standard X port; figure out a DISPLAY value yourself)"
        }
        let displayNumber = Int(port) - 6000
        let nonLoopback = interfaces.filter { !$0.isLoopback }
        if nonLoopback.isEmpty {
            return "(no non-loopback IPv4 interfaces found; check your network)"
        }

        var lines: [String] = []
        lines.append("On the Sun, set DISPLAY to one of:")
        let nameWidth = nonLoopback.map { $0.name.count }.max() ?? 0
        for iface in nonLoopback {
            let padded = iface.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            lines.append("  \(padded)  \(iface.address):\(displayNumber)")
        }
        return lines.joined(separator: "\n")
    }

    public static func displayNumber(forPort port: UInt16) -> Int? {
        guard port >= 6000 else { return nil }
        return Int(port) - 6000
    }
}
