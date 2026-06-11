// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Forge", targets: ["ForgeApp"]),
        .library(name: "ForgeCore", targets: ["ForgeCore"]),
    ],
    targets: [
        .target(name: "ForgeCore"),
        .executableTarget(name: "ForgeApp", dependencies: ["ForgeCore"]),
        .testTarget(name: "ForgeCoreTests", dependencies: ["ForgeCore"]),
    ]
)
