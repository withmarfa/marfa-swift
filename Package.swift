// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MymeSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MymeSDK", targets: ["MymeSDK"]),
    ],
    targets: [
        .target(name: "MymeSDK"),
        .testTarget(
            name: "MymeSDKTests",
            dependencies: ["MymeSDK"]
        ),
    ]
)
