// swift-tools-version: 6.0
import PackageDescription

// 文山输入法的规则层。macOS 26 起，iOS 保持 17。
// 这里只有纯逻辑：词表、组句、纠错、词频和输入规则，不依赖 AppKit。
let package = Package(
    name: "WenshanCore",
    platforms: [.macOS("26.0"), .iOS("17.0")],
    products: [
        .library(name: "WenshanCore", targets: ["WenshanCore"]),
    ],
    targets: [
        .target(name: "WenshanCore"),
        .testTarget(name: "WenshanCoreTests", dependencies: ["WenshanCore"]),
    ]
)
