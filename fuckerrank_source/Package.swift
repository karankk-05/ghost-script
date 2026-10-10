// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fuckerrank",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fuckerrank", targets: ["fuckerrank"]),
        .executable(name: "OwnerLicenseTool", targets: ["OwnerLicenseTool"]),
        .executable(name: "LicenseChecks", targets: ["LicenseChecks"]),
    ],
    targets: [
        .target(name: "LicenseCore"),
        .executableTarget(name: "OwnerLicenseTool", dependencies: ["LicenseCore"]),
        .executableTarget(
            name: "fuckerrank",
            dependencies: ["LicenseCore"],
            path: "Sources/fuckerrank",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "LicenseChecks", dependencies: ["LicenseCore"], path: "Tests/LicenseChecks"),
    ]
)
