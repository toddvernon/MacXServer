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
        .executable(name: "swiftx-capture", targets: ["SwiftXCapture"]),
    ],
    targets: [
        .target(name: "Framer"),
        .target(
            name: "SwiftXCaptureCore",
            dependencies: ["Framer"]
        ),
        .executableTarget(
            name: "SwiftXCapture",
            dependencies: ["SwiftXCaptureCore", "Framer"]
        ),
        .testTarget(
            name: "FramerTests",
            dependencies: ["Framer"]
        ),
        .testTarget(
            name: "SwiftXCaptureCoreTests",
            dependencies: ["SwiftXCaptureCore"]
        ),
    ]
)
