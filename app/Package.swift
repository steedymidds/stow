// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stow", path: "Sources/Stow")
    ],
    swiftLanguageVersions: [.v5]
)
