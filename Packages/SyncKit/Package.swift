// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SyncKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"])
    ],
    dependencies: [
        .package(path: "../MyPassKit")
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "MyPassKit", package: "MyPassKit")
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"]
        )
    ]
)
