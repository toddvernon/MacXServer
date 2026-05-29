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
        .target(
            name: "SwiftXCaptureCore",
            dependencies: ["Framer"]
        ),
        .target(
            name: "SwiftXServerCore",
            dependencies: ["Framer", "SwiftXCaptureCore"]
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
