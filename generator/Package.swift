// swift-tools-version: 6.0
// A package of its own, so Marfa depends only on the runtime the generated
// code needs.
import PackageDescription

let package = Package(
    name: "MarfaTypesGenerator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.13.1")
    ]
)
