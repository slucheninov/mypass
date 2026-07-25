// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ExtensionBridgeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExtensionBridgeKit", targets: ["ExtensionBridgeKit"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ExtensionBridgeKit", dependencies: []),
        .testTarget(name: "ExtensionBridgeKitTests", dependencies: ["ExtensionBridgeKit"])
    ]
)
