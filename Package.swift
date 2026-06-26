// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-x",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Framer", targets: ["Framer"]),
        .library(name: "SwiftXCaptureCore", targets: ["SwiftXCaptureCore"]),
        .library(name: "SwiftXServerCore", targets: ["SwiftXServerCore"]),
        .library(name: "SwiftXCaptureUI", targets: ["SwiftXCaptureUI"]),
        .executable(name: "macxcapture", targets: ["SwiftXCapture"]),
        .executable(name: "macxserver", targets: ["SwiftXServer"]),
    ],
    targets: [
        .target(name: "Framer"),
        // Vendored libvterm (terminal-emulator state machine, MIT).
        // Built from source; see Sources/CVTerm/VENDOR.md.
        .target(
            name: "CVTerm",
            cSettings: [
                // The .c sources sit in the target root next to the private
                // headers (vterm_internal.h, utf8.h, rect.h) and the .inc
                // tables; make the root searchable for their quoted includes.
                .headerSearchPath("."),
                // libvterm gates its noisy DEBUG_LOG (Unhandled CSI / Unknown
                // DEC mode) on DEBUG; undefine it so the lib stays quiet even
                // in a debug build of the package.
                .unsafeFlags(["-UDEBUG"])
            ]
        ),
        .target(
            name: "SwiftXCaptureCore",
            dependencies: ["Framer"]
        ),
        .target(
            name: "SwiftXServerCore",
            dependencies: ["Framer", "SwiftXCaptureCore", "CVTerm"]
        ),
        // Shared AppKit/SwiftUI editor + capture viewer (dark code editor,
        // syntax highlighting, Save As / Export as Text). Used by both apps.
        .target(
            name: "SwiftXCaptureUI",
            dependencies: ["SwiftXCaptureCore", "Framer"]
        ),
        .executableTarget(
            name: "SwiftXCapture",
            dependencies: ["SwiftXCaptureCore", "SwiftXCaptureUI", "Framer"]
        ),
        .executableTarget(
            name: "SwiftXServer",
            dependencies: ["SwiftXServerCore", "SwiftXCaptureCore", "SwiftXCaptureUI", "Framer"]
        ),
        .testTarget(
            name: "FramerTests",
            dependencies: ["Framer"]
        ),
        .testTarget(
            name: "SwiftXCaptureCoreTests",
            dependencies: ["SwiftXCaptureCore"]
        ),
        .testTarget(
            name: "SwiftXServerCoreTests",
            dependencies: ["SwiftXServerCore", "Framer", "SwiftXCaptureCore"]
        ),
    ]
)
