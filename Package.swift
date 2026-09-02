// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarfaSDK",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
        .watchOS(.v11),
        .tvOS(.v18),
    ],
    products: [
        .library(name: "MarfaSDK", targets: ["MarfaSDK"]),
        .library(name: "MarfaSDKTestSupport", targets: ["MarfaSDKTestSupport"]),
        .executable(name: "codegen-custom-types", targets: ["codegen-custom-types"]),
        .executable(name: "sync-custom-types", targets: ["sync-custom-types"]),
        .executable(name: "cloudkit-smoke", targets: ["cloudkit-smoke"]),
        .plugin(name: "GenerateMarfaCustomTypes", targets: ["GenerateMarfaCustomTypes"]),
    ],
    dependencies: [
        // No external dependencies — the SDK builds on Foundation,
        // Security, SwiftData, and `os`.
    ],
    targets: [
        .target(
            name: "MarfaSDK",
            // Developer documentation that lives beside the code it
            // describes. SwiftPM treats any undeclared file in a target
            // directory as an unhandled resource and warns — in every
            // consuming app's build, not just this package's.
            exclude: ["LocalStore/README.md"]
        ),
        .target(
            name: "MarfaSDKTestSupport",
            dependencies: ["MarfaSDK"]
        ),
        .testTarget(
            name: "MarfaSDKTests",
            dependencies: ["MarfaSDK", "MarfaSDKTestSupport"],
            resources: [.copy("Fixtures")]
        ),

        // MARK: - Codegen — wire types + core domain models (existing)

        .executableTarget(
            name: "codegen-wire",
            path: "scripts",
            exclude: [
                "wire-types.json", "openapi.json", "sync-openapi.sh",
                "sync-types.sh", "codegen-domain.swift",
                "MarfaCodegenCore", "codegen-custom-types", "sync-custom-types",
                "cloudkit-smoke", "PublicSurfaceCore", "public-surface",
                "public-surface.sh", "public-surface.txt",
                "consumer-pins.sh", "openapi-source.txt", "spec-drift.sh",
            ],
            sources: ["codegen-wire.swift"]
        ),
        .executableTarget(
            name: "codegen-domain",
            path: "scripts",
            exclude: [
                "wire-types.json", "openapi.json", "sync-openapi.sh",
                "sync-types.sh", "codegen-wire.swift",
                "MarfaCodegenCore", "codegen-custom-types", "sync-custom-types",
                "cloudkit-smoke", "PublicSurfaceCore", "public-surface",
                "public-surface.sh", "public-surface.txt",
                "consumer-pins.sh", "openapi-source.txt", "spec-drift.sh",
            ],
            sources: ["codegen-domain.swift"]
        ),

        // MARK: - Codegen — custom types (new)

        .target(
            name: "MarfaCodegenCore",
            path: "scripts/MarfaCodegenCore",
            resources: [.copy("core-types")]
        ),
        .executableTarget(
            name: "codegen-custom-types",
            dependencies: ["MarfaCodegenCore"],
            path: "scripts/codegen-custom-types"
        ),
        .executableTarget(
            name: "sync-custom-types",
            dependencies: ["MarfaCodegenCore"],
            path: "scripts/sync-custom-types"
        ),
        .plugin(
            name: "GenerateMarfaCustomTypes",
            capability: .command(
                intent: .custom(
                    verb: "generate-marfa-custom-types",
                    description: "Generate typed Swift wrappers for custom Marfa types."
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Write generated Swift files into the package's output directory."
                    ),
                    .allowNetworkConnections(
                        scope: .all(),
                        reason: "Fetch custom type schemas from a live Marfa instance (only when --sync is passed)."
                    ),
                ]
            ),
            dependencies: ["codegen-custom-types", "sync-custom-types"],
            path: "Plugins/GenerateMarfaCustomTypes"
        ),
        .testTarget(
            name: "CodegenCustomTypesTests",
            dependencies: ["MarfaCodegenCore", "MarfaSDK"],
            path: "Tests/CodegenCustomTypesTests",
            exclude: ["CompileCheck"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CodegenCompileCheckTests",
            dependencies: ["MarfaSDK"],
            path: "Tests/CodegenCustomTypesTests/CompileCheck"
        ),

        // MARK: - Public surface lock

        .target(
            name: "PublicSurfaceCore",
            path: "scripts/PublicSurfaceCore"
        ),
        .executableTarget(
            name: "public-surface",
            dependencies: ["PublicSurfaceCore"],
            path: "scripts/public-surface"
        ),
        .testTarget(
            name: "PublicSurfaceTests",
            dependencies: ["PublicSurfaceCore"],
            path: "Tests/PublicSurfaceTests"
        ),

        // MARK: - CloudKit readiness smoke (manual)

        .executableTarget(
            name: "cloudkit-smoke",
            dependencies: ["MarfaSDK"],
            path: "scripts/cloudkit-smoke"
        ),
    ],
    swiftLanguageModes: [.v6]
)

// `NonisolatedNonsendingByDefault` is the Swift 6.2 concurrency-
// ergonomics change — nonisolated async functions run on the caller's
// actor instead of hopping to the global executor — and it becomes the
// default in a future language mode. Tools-version 6.2 alone does not
// enable it; the flag has to be set per target. Applied to every
// non-plugin target (plugin targets accept no build settings).
for target in package.targets where target.type != .plugin {
    var settings = target.swiftSettings ?? []
    settings.append(.enableUpcomingFeature("NonisolatedNonsendingByDefault"))
    target.swiftSettings = settings
}
