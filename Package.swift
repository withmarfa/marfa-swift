// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MymeSDK",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "MymeSDK", targets: ["MymeSDK"]),
        .library(name: "MymeSDKTestSupport", targets: ["MymeSDKTestSupport"]),
    ],
    dependencies: [
        // GRDB — SQLite wrapper for the local mirror store.
        // Swift 6 strict concurrency support requires GRDB 7+.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MymeSDK",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "MymeSDKTestSupport",
            dependencies: ["MymeSDK"]
        ),
        .testTarget(
            name: "MymeSDKTests",
            dependencies: ["MymeSDK", "MymeSDKTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "codegen-wire",
            path: "scripts",
            exclude: [
                "wire-types.json", "openapi.json", "sync-openapi.sh",
                "core-types", "sync-types.sh", "codegen-domain.swift",
            ],
            sources: ["codegen-wire.swift"]
        ),
        .executableTarget(
            name: "codegen-domain",
            path: "scripts",
            exclude: [
                "wire-types.json", "openapi.json", "sync-openapi.sh",
                "core-types", "sync-types.sh", "codegen-wire.swift",
            ],
            sources: ["codegen-domain.swift"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
