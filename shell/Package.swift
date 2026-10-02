// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceMac", path: "Sources/VoiceMac", linkerSettings: [.linkedFramework("Carbon")]),
    ]
)
