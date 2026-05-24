import Foundation
import SwiftXCaptureCore

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print(CLI.usage)
    exit(args.isEmpty ? 1 : 0)
}

func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

if args.first == "dump" {
    let rest = Array(args.dropFirst())
    guard rest.count == 1 else {
        writeStderr("usage: swiftx-capture dump <path-to-xtap>\n")
        exit(2)
    }
    do {
        let chrono = try ChronoDumper.dump(path: rest[0])
        print(chrono)
    } catch {
        writeStderr("dump error: \(error)\n")
        exit(1)
    }
    exit(0)
}

if args.first == "summary" {
    let rest = Array(args.dropFirst())
    guard rest.count == 1 else {
        writeStderr("usage: swiftx-capture summary <path-to-xtap>\n")
        exit(2)
    }
    do {
        let summary = try Dumper.summarize(path: rest[0])
        print(summary)
    } catch {
        writeStderr("summary error: \(error)\n")
        exit(1)
    }
    exit(0)
}

if args.first == "diff" {
    let rest = Array(args.dropFirst())
    do {
        let parsed = try CLI.parseDiff(rest)
        let report = try CaptureDiff.compare(pathA: parsed.pathA, pathB: parsed.pathB)
        let rendered = CaptureDiff.render(report, options: DiffRenderOptions(onlyDifferent: parsed.onlyDifferent))
        print(rendered)
    } catch let error as CLIError {
        writeStderr("\(error)\n\n\(CLI.usage)\n")
        exit(2)
    } catch {
        writeStderr("diff error: \(error)\n")
        exit(1)
    }
    exit(0)
}

if args.first == "replay" {
    let rest = Array(args.dropFirst())
    do {
        let parsed = try CLI.parseReplay(rest)
        writeStderr("replaying \(parsed.inputPath) → \(parsed.targetHost):\(parsed.targetPort)\n")
        let result = try Replay.run(args: parsed)
        writeStderr("sent \(result.c2sFramesSent) frames, \(result.c2sBytesSent) bytes; received \(result.s2cBytesReceived) bytes from target\n")
    } catch let error as CLIError {
        writeStderr("\(error)\n\n\(CLI.usage)\n")
        exit(2)
    } catch {
        writeStderr("replay error: \(error)\n")
        exit(1)
    }
    exit(0)
}

do {
    let parsed = try CLI.parseCapture(args)
    let listenDescription = "\(parsed.listenHost):\(parsed.listenPort)"
    let forwardDescription = "\(parsed.forwardHost):\(parsed.forwardPort)"

    // /dev/null = pure proxy mode, no recording. Lets us test whether the
    // recorder's synchronous file-I/O-under-lock is impacting the wire path.
    let recorder: Recorder? = (parsed.outputPath == "/dev/null") ? nil : try Recorder(
        outputPath: parsed.outputPath,
        listen: listenDescription,
        forward: forwardDescription
    )

    let proxy = Proxy(
        listenHost: parsed.listenHost,
        listenPort: parsed.listenPort,
        forwardHost: parsed.forwardHost,
        forwardPort: parsed.forwardPort,
        sink: recorder
    )

    let actualPort = try proxy.start()

    let allInterfaces = enumerateIPv4Interfaces()
    let bindsToAll = parsed.listenHost == "0.0.0.0" || parsed.listenHost.isEmpty
    let displayedHost: String
    let hintInterfaces: [NetworkInterface]
    if bindsToAll {
        let nonLoopback = allInterfaces.filter { !$0.isLoopback }
        displayedHost = nonLoopback.first?.address ?? "0.0.0.0"
        hintInterfaces = allInterfaces
    } else {
        displayedHost = parsed.listenHost
        hintInterfaces = allInterfaces.filter { $0.address == parsed.listenHost }
    }

    var listenLine = "listening on \(displayedHost):\(actualPort)"
    if let displayNumber = StartupHint.displayNumber(forPort: actualPort) {
        listenLine += " (X display \(displayNumber))"
    }
    writeStderr(listenLine + "\n")
    writeStderr("forwarding to \(forwardDescription)\n")
    writeStderr("recording to \(parsed.outputPath)\n\n")

    writeStderr(StartupHint.displayHint(forListenPort: actualPort, interfaces: hintInterfaces) + "\n\n")

    try proxy.run()
    try recorder?.finalize()
    writeStderr("capture complete\n")
} catch let error as CLIError {
    writeStderr("\(error)\n\n\(CLI.usage)\n")
    exit(2)
} catch {
    writeStderr("error: \(error)\n")
    exit(1)
}
