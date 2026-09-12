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
            name: "CArgon2",
            path: "Sources/CArgon2",
            exclude: ["VENDORING.md"],
            sources: [
                "argon2.c",
                "core.c",
                "encoding.c",
                "ref.c",
                "thread.c",
                "blake2/blake2b.c",
            ],
            publicHeadersPath: "include",
            // Renames blake2b's seven external symbols at compile time, so
            // they don't collide with libsodium's own `blake2b` (already a
            // dependency of this package, below) at final link time — see
            // this task's build-integration trap writeup above, and
            // `Sources/CArgon2/VENDORING.md`. Verified: without these seven
            // defines, linking any target/test that pulls in both CArgon2
            // and Sodium fails with six `duplicate symbol` errors.
            cSettings: [
                .define("blake2b", to: "mypass_argon2_blake2b"),
                .define("blake2b_init", to: "mypass_argon2_blake2b_init"),
                .define("blake2b_init_key", to: "mypass_argon2_blake2b_init_key"),
                .define("blake2b_init_param", to: "mypass_argon2_blake2b_init_param"),
                .define("blake2b_update", to: "mypass_argon2_blake2b_update"),
                .define("blake2b_final", to: "mypass_argon2_blake2b_final"),
                .define("blake2b_long", to: "mypass_argon2_blake2b_long"),
            ]
        ),
        .target(
            name: "MyPassKit",
            dependencies: [
                "CArgon2",
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            exclude: ["Resources/PASSWORD_RULES_PROVENANCE.md"],
            resources: [
                .copy("Resources/public_suffix_list.dat"),
                .copy("Resources/password-rules.json")
            ]
        ),
        .testTarget(
            name: "MyPassKitTests",
            dependencies: ["MyPassKit", "CArgon2", .product(name: "Sodium", package: "swift-sodium")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MyPassKitPublicAPITests",
            dependencies: ["MyPassKit"],
            path: "Tests/MyPassKitPublicAPITests"
        )
    ]
)
