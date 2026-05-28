// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pipetest",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "pipetest", targets: ["pipetest"]),
    ],
    dependencies: [
        .package(path: "../../SadiKit"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.7"),
    ],
    targets: [
        .executableTarget(
            name: "pipetest",
            dependencies: [
                .product(name: "SadiKit", package: "SadiKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/pipetest"
        ),
    ]
)
