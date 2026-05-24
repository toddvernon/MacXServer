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
        .executable(name: "swiftx-capture", targets: ["SwiftXCapture"]),
        .executable(name: "swiftx-server", targets: ["SwiftXServer"]),
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
        .executableTarget(
            name: "SwiftXCapture",
            dependencies: ["SwiftXCaptureCore", "Framer"]
        ),
        .executableTarget(
            name: "SwiftXServer",
            dependencies: ["SwiftXServerCore", "Framer"]
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
