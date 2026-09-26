// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhostScreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GhostScreen",
            path: "Sources/GhostScreen",
            resources: [.copy("Resources/Web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
