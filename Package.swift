// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexUsage", targets: ["CodexUsage"]),
    ],
    targets: [
        .target(
            name: "CodexUsageCore",
            path: "Sources/CodexUsageCore"),
        .executableTarget(
            name: "CodexUsage",
            dependencies: ["CodexUsageCore"],
            path: "Sources/CodexUsage",
            resources: [.process("Resources")]),
        .testTarget(
            name: "CodexUsageTests",
            dependencies: ["CodexUsageCore"],
            path: "Tests/CodexUsageTests"),
    ])
