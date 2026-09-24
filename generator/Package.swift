// swift-tools-version: 6.0
// The generator of the wire types, pinned, as a package of its own so the
// package itself depends only on the runtime the generated code needs.
import PackageDescription

let package = Package(
    name: "MarfaTypesGenerator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.13.1")
    ]
)
