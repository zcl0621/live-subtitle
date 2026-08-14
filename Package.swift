// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSubtitle",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "LiveSubtitle",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/LiveSubtitle"),
        .testTarget(name: "LiveSubtitleTests", dependencies: ["LiveSubtitle"], path: "Tests/LiveSubtitleTests"),
    ]
)
