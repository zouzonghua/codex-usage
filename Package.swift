// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .executable(name: "codex-usage", targets: ["CodexUsageCLI"]),
]
var targets: [Target] = [
    .target(name: "CodexUsageCore"),
    .executableTarget(name: "CodexUsageCLI", dependencies: ["CodexUsageCore"]),
    .testTarget(name: "CodexUsageTests", dependencies: ["CodexUsageCore"]),
]

#if os(macOS)
products.append(.executable(name: "CodexUsage", targets: ["CodexUsage"]))
targets.append(.executableTarget(name: "CodexUsage", dependencies: ["CodexUsageCore"]))
#endif

let package = Package(
    name: "CodexUsage",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets)
