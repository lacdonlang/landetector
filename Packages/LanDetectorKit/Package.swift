// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanDetectorKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LanDetectorKit", targets: ["LanDetectorKit"]),
        .executable(name: "landetector-cli", targets: ["landetector-cli"]),
    ],
    targets: [
        .target(
            name: "LanDetectorKit",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "landetector-cli",
            dependencies: ["LanDetectorKit"]
        ),
        .testTarget(
            name: "LanDetectorKitTests",
            dependencies: ["LanDetectorKit"]
        ),
    ]
)
