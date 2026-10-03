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
        .binaryTarget(name: "MarfaCoreFFI", url: "https://github.com/withmarfa/marfa-swift/releases/download/v0.0.2/MarfaCoreFFI.xcframework.zip", checksum: "32a5175979d5d30ca0119a7321ee08254121fb3d426f51c875af40dd10f49456"),
        // Swift 5, because the generated glue is not Swift 6 clean.
        .target(
            name: "MarfaCore",
            dependencies: ["MarfaCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MarfaCoreNames",
            dependencies: ["MarfaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Marfa",
            dependencies: ["MarfaCore", "MarfaCoreNames"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarfaTypes",
            dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaTests",
            dependencies: ["Marfa", "MarfaCore", "MarfaCoreNames", "MarfaTypes"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarfaTypesTests",
            dependencies: ["MarfaTypes"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
