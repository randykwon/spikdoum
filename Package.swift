// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpikDoum",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "SpikDoum", targets: ["SpikDoum"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.4", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "SpikDoum",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .testTarget(name: "SpikDoumTests", dependencies: ["SpikDoum"])
    ],
    swiftLanguageModes: [.v5]
)
