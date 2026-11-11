// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ISOForge",
    defaultLocalization: "uk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ISOForge", targets: ["ISOForge"]),
        .executable(name: "ForgeWriter", targets: ["ForgeWriter"])
    ],
    targets: [
        .target(name: "ForgeCore"),
        .executableTarget(name: "ISOForge", dependencies: ["ForgeCore"], resources: [.process("Resources")]),
        .executableTarget(name: "ForgeWriter", dependencies: ["ForgeCore"]),
        .testTarget(name: "ForgeCoreTests", dependencies: ["ForgeCore"])
    ]
)
