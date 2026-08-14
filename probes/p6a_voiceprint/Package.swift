// swift-tools-version: 6.0
// P6a 探针专用临时包 —— 与主工程隔离,FluidAudio 依赖只进这里。
// 探针结论(能否单独加载 embedding 模型、中英区分度、阈值)写 probes/RESULTS.md。
import PackageDescription

let package = Package(
    name: "p6a-voiceprint",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "p6a",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources"
        )
    ]
)
