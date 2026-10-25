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
        // This is a fork, not Apple's swift-nio-ssh. Citadel 0.12.1 (needed for
        // SFTP sync) declares exactly this URL and range, so SyncKit must name the
        // same one for SwiftPM to resolve a single swift-nio-ssh. The fork describes
        // itself as "A fork of Apple's NIOSSH, to be archived once Apple reviews and
        // merges 2 year old PRs"; it forks Joannis/swift-nio-ssh (branch citadel2).
        // Swapping it out is a separate change that has to move Citadel too.
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
