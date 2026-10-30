// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Marfa",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "Marfa", targets: ["Marfa"]),
        .library(name: "MarfaTypes", targets: ["MarfaTypes"]),
        .library(name: "MarfaAPI", targets: ["MarfaAPI"]),
        .library(name: "MarfaTesting", targets: ["MarfaTesting"]),
        .library(name: "MarfaIcons", targets: ["MarfaIcons"]),
        .library(name: "MarfaBrandIcons", targets: ["MarfaBrandIcons"]),
        .library(name: "MarfaTelemetry", targets: ["MarfaTelemetry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.2"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    ],
    targets: [
        .binaryTarget(name: "MarfaCoreFFI", path: "Frameworks/MarfaCoreFFI.xcframework"),
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
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaTesting",
            dependencies: ["Marfa", "MarfaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaIcons",
            dependencies: ["Marfa"],
            resources: [.process("Lucide.xcassets")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaBrandIcons",
            dependencies: ["MarfaIcons"],
            resources: [.process("SimpleIcons.xcassets")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaTelemetry",
            dependencies: ["Marfa"],
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaTypes",
            dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaAPI",
            dependencies: [
                "Marfa",
                "MarfaTypes",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaTests",
            dependencies: ["Marfa", "MarfaAPI", "MarfaCore", "MarfaTypes"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaBehaviorTests",
            dependencies: ["Marfa", "MarfaTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaIconTests",
            dependencies: ["Marfa", "MarfaIcons"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaBrandIconTests",
            dependencies: ["Marfa", "MarfaIcons", "MarfaBrandIcons"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaTelemetryTests",
            dependencies: ["Marfa", "MarfaTelemetry"],
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
