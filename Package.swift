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
    targets: [
        .target(name: "MymeSDK"),
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
            exclude: ["wire-types.json", "openapi.json", "sync-openapi.sh"],
            sources: ["codegen-wire.swift"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
