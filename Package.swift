// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Marfa",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "Marfa", targets: ["Marfa"]),
        .library(name: "MarfaTypes", targets: ["MarfaTypes"]),
        .library(name: "MarfaTesting", targets: ["MarfaTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.11.0")
    ],
    targets: [
        .binaryTarget(name: "MarfaCoreFFI", url: "https://github.com/withmarfa/marfa-swift/releases/download/v0.0.24/MarfaCoreFFI.xcframework.zip", checksum: "d85c2aef6705651da11870cdf6de9fcb103d8f791c134264fd43eedcc056f0ec"),
        // Swift 5, because the generated glue is not Swift 6 clean.
        .target(
            name: "MarfaCore",
            dependencies: ["MarfaCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The core reads a folder's package flag through it; a static library
            // carries no link directive of its own into the xcframework.
            linkerSettings: [.linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS]))]
        ),
        .target(
            name: "Marfa",
            dependencies: ["MarfaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaTesting",
            dependencies: ["Marfa", "MarfaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaTypes",
            dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaTests",
            dependencies: ["Marfa", "MarfaCore", "MarfaTypes"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaBehaviorTests",
            dependencies: ["Marfa", "MarfaTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaImportTests",
            dependencies: ["Marfa"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("MemberImportVisibility")]
        ),
        .testTarget(
            name: "MarfaTypesTests",
            dependencies: ["MarfaTypes"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
