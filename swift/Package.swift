// swift-tools-version: 6.0
import PackageDescription

// 文山输入法的规则层和 macOS 壳。macOS 26 起，iOS 保持 17。
// WenshanCore 是纯逻辑，WenshanSwift 是 IMK 输入法进程。
let package = Package(
    name: "WenshanCore",
    platforms: [.macOS("26.0"), .iOS("17.0")],
    products: [
        .library(name: "WenshanCore", targets: ["WenshanCore"]),
        .executable(name: "WenshanSwift", targets: ["WenshanSwift"]),
    ],
    targets: [
        .target(name: "WenshanCore"),
        .executableTarget(
            name: "WenshanSwift",
            dependencies: ["WenshanCore"],
            path: "Sources/WenshanSwift"
        ),
        .testTarget(name: "WenshanCoreTests", dependencies: ["WenshanCore"]),
    ]
)
