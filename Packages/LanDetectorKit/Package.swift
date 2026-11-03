// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanDetectorKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LanDetectorKit", targets: ["LanDetectorKit"]),
        .executable(name: "landetector-cli", targets: ["landetector-cli"]),
    ],
    targets: [
        .target(
            name: "LanDetectorKit",
            resources: [.copy("Resources"), .process("Localizable.xcstrings")]
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
