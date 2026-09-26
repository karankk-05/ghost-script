// swift-tools-version: 6.0
// Throwaway Milestone-0 spikes — go/no-go validation of platform assumptions.
import PackageDescription

let package = Package(
    name: "Spikes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spike-capture-exclusion", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "spike-mirror-config", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "spike-pacing", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "spike-tcc-stub", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
