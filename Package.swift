// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CD",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "CD", path: "Sources/CD",
                          linkerSettings: [.linkedFramework("MediaPlayer")])
    ],
    swiftLanguageModes: [.v5]
)
