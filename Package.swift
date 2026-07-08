// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSubtitle",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "LiveSubtitle", path: "Sources/LiveSubtitle"),
        .testTarget(name: "LiveSubtitleTests", dependencies: ["LiveSubtitle"], path: "Tests/LiveSubtitleTests"),
    ]
)
