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
    ],
    targets: [
        .target(name: "MymeSDK"),
        .target(
            name: "MymeSDKTestSupport",
            dependencies: ["MymeSDK"]
        ),
        .testTarget(
            name: "MymeSDKTests",
            dependencies: ["MymeSDK", "MymeSDKTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
