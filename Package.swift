// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TheeJ",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TheeJ"),
        .testTarget(name: "TheeJTests", dependencies: ["TheeJ"]),
    ],
    swiftLanguageModes: [.v5]
)
