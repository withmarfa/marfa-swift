// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MymeSDK",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
        .watchOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "MymeSDK", targets: ["MymeSDK"]),
        .library(name: "MymeSDKTestSupport", targets: ["MymeSDKTestSupport"]),
        .executable(name: "codegen-custom-types", targets: ["codegen-custom-types"]),
        .executable(name: "sync-custom-types", targets: ["sync-custom-types"]),
        .plugin(name: "GenerateMymeCustomTypes", targets: ["GenerateMymeCustomTypes"]),
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

        // MARK: - Codegen — wire types + core domain models (existing)

        .executableTarget(
            name: "codegen-wire",
            path: "scripts",
            exclude: [
                "wire-types.json", "openapi.json", "sync-openapi.sh",
                "sync-types.sh", "codegen-domain.swift",
                "MymeCodegenCore", "codegen-custom-types", "sync-custom-types",
            ],
            sources: ["codegen-wire.swift"]
        ),
        .executableTarget(
            name: "codegen-domain",
            path: "scripts",
            exclude: [
                "wire-types.json", "openapi.json", "sync-openapi.sh",
                "sync-types.sh", "codegen-wire.swift",
                "MymeCodegenCore", "codegen-custom-types", "sync-custom-types",
            ],
            sources: ["codegen-domain.swift"]
        ),

        // MARK: - Codegen — custom types (new)

        .target(
            name: "MymeCodegenCore",
            path: "scripts/MymeCodegenCore",
            resources: [.copy("core-types")]
        ),
        .executableTarget(
            name: "codegen-custom-types",
            dependencies: ["MymeCodegenCore"],
            path: "scripts/codegen-custom-types"
        ),
        .executableTarget(
            name: "sync-custom-types",
            dependencies: ["MymeCodegenCore"],
            path: "scripts/sync-custom-types"
        ),
        .plugin(
            name: "GenerateMymeCustomTypes",
            capability: .command(
                intent: .custom(
                    verb: "generate-myme-custom-types",
                    description: "Generate typed Swift wrappers for custom Myme types."
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Write generated Swift files into the package's output directory."
                    ),
                    .allowNetworkConnections(
                        scope: .all(),
                        reason: "Fetch custom type schemas from a live Myme instance (only when --sync is passed)."
                    ),
                ]
            ),
            dependencies: ["codegen-custom-types", "sync-custom-types"],
            path: "Plugins/GenerateMymeCustomTypes"
        ),
        .testTarget(
            name: "CodegenCustomTypesTests",
            dependencies: ["MymeCodegenCore", "MymeSDK"],
            path: "Tests/CodegenCustomTypesTests",
            exclude: ["CompileCheck"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CodegenCompileCheckTests",
            dependencies: ["MymeSDK"],
            path: "Tests/CodegenCustomTypesTests/CompileCheck"
        ),
    ],
    swiftLanguageModes: [.v6]
)
