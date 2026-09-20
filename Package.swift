// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchLauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchLauncher",
            path: "Sources/NotchLauncher"
        )
    ]
)
