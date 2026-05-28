// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SadiKit",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "SadiKit", targets: ["SadiKit"]),
    ],
    targets: [
        .target(
            name: "SadiKit",
            path: "Sources/SadiKit"
        ),
        .testTarget(
            name: "SadiKitTests",
            dependencies: ["SadiKit"],
            path: "Tests/SadiKitTests"
        ),
    ]
)
