// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MyPassKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MyPassKit", targets: ["MyPassKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1")
    ],
    targets: [
        .target(
            name: "MyPassKit",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium")
            ]
        ),
        .testTarget(
            name: "MyPassKitTests",
            dependencies: ["MyPassKit", .product(name: "Sodium", package: "swift-sodium")],
            resources: [.copy("Fixtures")]
        )
    ]
)
