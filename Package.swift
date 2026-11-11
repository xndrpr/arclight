// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Arclight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "arclight", targets: ["Arclight"]),
        .library(name: "ArclightCore", targets: ["ArclightCore"]),
    ],
    targets: [
        .target(name: "ArclightCore"),
        .target(name: "ArclightMCP", dependencies: ["ArclightCore"]),
        .target(name: "ArclightEditor", dependencies: ["ArclightCore"]),
        .executableTarget(name: "Arclight", dependencies: ["ArclightCore", "ArclightMCP", "ArclightEditor"]),
        .testTarget(name: "ArclightCoreTests", dependencies: ["ArclightCore", "ArclightMCP", "ArclightEditor"]),
    ],
    swiftLanguageModes: [.v5]
)
