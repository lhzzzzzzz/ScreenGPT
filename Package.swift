// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenGPT",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenGPT", targets: ["ScreenGPT"])],
    targets: [
        .target(name: "ScreenGPTCore"),
        .executableTarget(name: "ScreenGPT", dependencies: ["ScreenGPTCore"]),
        .testTarget(name: "ScreenGPTCoreTests", dependencies: ["ScreenGPTCore"])
    ]
)
