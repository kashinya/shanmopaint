// swift-tools-version:5.9
import PackageDescription

// PaintCore はプラットフォーム非依存（Linux でもテスト可能）。
// Paint98（AppKit アプリ本体）は macOS でだけビルドする。
var targets: [Target] = [
    .target(name: "PaintCore"),
    .testTarget(name: "PaintCoreTests", dependencies: ["PaintCore"]),
]
var products: [Product] = [
    .library(name: "PaintCore", targets: ["PaintCore"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "Paint98", dependencies: ["PaintCore"]))
products.append(.executable(name: "Paint98", targets: ["Paint98"]))
#endif

let package = Package(
    name: "Paint98",
    platforms: [.macOS(.v12)],
    products: products,
    targets: targets
)
