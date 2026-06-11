// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Forge", targets: ["ForgeApp"]),
        .library(name: "ForgeCore", targets: ["ForgeCore"]),
        .library(name: "ForgeMCP", targets: ["ForgeMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // Pinned below 2.87: later releases gate Span/lifetime code on
        // compiler(>=6.2), which this Xcode 26.0 beta snapshot can't parse.
        .package(url: "https://github.com/apple/swift-nio.git", "2.65.0"..<"2.87.0"),
        // Pinned below 1.13: newer swift-log manifests add unsafeFlags, which
        // SPM rejects in versioned (transitive) dependencies.
        .package(url: "https://github.com/apple/swift-log.git", "1.5.0"..<"1.7.0"),
        // Pinned to 1.1.x: newer releases use Span/lifetime syntax that this
        // Xcode 26.0 beta's Swift 6.2 snapshot cannot parse yet.
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.2.0"),
    ],
    targets: [
        .target(name: "ForgeCore"),
        .target(
            name: "ForgeMCP",
            dependencies: [
                "ForgeCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                // Not imported directly; declared so the version pin above
                // applies without an unused-dependency warning.
                .product(name: "DequeModule", package: "swift-collections"),
            ]
        ),
        .target(name: "ForgeTestSupport", dependencies: ["ForgeCore"]),
        .executableTarget(name: "ForgeApp", dependencies: ["ForgeCore", "ForgeMCP"]),
        .testTarget(name: "ForgeCoreTests", dependencies: ["ForgeCore", "ForgeTestSupport"]),
        .testTarget(name: "ForgeMCPTests", dependencies: ["ForgeMCP", "ForgeTestSupport"]),
    ]
)
