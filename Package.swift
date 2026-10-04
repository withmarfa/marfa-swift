// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Marfa",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "Marfa", targets: ["Marfa"]),
        .library(name: "MarfaTypes", targets: ["MarfaTypes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.11.0")
    ],
    targets: [
        .binaryTarget(name: "MarfaCoreFFI", path: "Frameworks/MarfaCoreFFI.xcframework"),
        // Swift 5, because the generated glue is not Swift 6 clean.
        .target(
            name: "MarfaCore",
            dependencies: ["MarfaCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Marfa",
            dependencies: ["MarfaCore"],
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
            name: "MarfaTypesTests",
            dependencies: ["MarfaTypes"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
