// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SyncKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"])
    ],
    dependencies: [
        .package(path: "../MyPassKit"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "MyPassKit", package: "MyPassKit"),
                .product(name: "Citadel", package: "Citadel")
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: [
                "SyncKit",
                .product(name: "Citadel", package: "Citadel")
            ]
        )
    ]
)
