// swift-tools-version: 6.0
import PackageDescription

// 文山输入法的规则层、macOS 壳和构建工具。macOS 26 起，iOS 保持 17。
// WenshanCore 是纯逻辑，WenshanSwift 是 IMK 输入法进程；
// dictgen 把 Rime 词库编译成 dict.bin，icon 画 App 和输入源图标，只在构建时运行。
let package = Package(
    name: "WenshanCore",
    platforms: [.macOS("26.0"), .iOS("17.0")],
    products: [
        .library(name: "WenshanCore", targets: ["WenshanCore"]),
        .executable(name: "WenshanSwift", targets: ["WenshanSwift"]),
        .executable(name: "dictgen", targets: ["dictgen"]),
        .executable(name: "icon", targets: ["icon"]),
    ],
    targets: [
        .target(name: "WenshanCore"),
        .executableTarget(
            name: "WenshanSwift",
            dependencies: ["WenshanCore"],
            path: "Sources/WenshanSwift"
        ),
        .executableTarget(name: "dictgen", dependencies: ["WenshanCore"]),
        .executableTarget(name: "icon"),
        .testTarget(name: "WenshanCoreTests", dependencies: ["WenshanCore"]),
        .testTarget(name: "DictgenTests", dependencies: ["dictgen", "WenshanCore"]),
    ]
)
