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
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0")
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "MyPassKit", package: "MyPassKit"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: [
                "SyncKit",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        )
    ]
)
