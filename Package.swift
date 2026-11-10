// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuCraft",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MenuCraft",
            path: "Sources/MenuCraft"
        )
    ],
    swiftLanguageModes: [.v5]
)
