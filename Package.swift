// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SpikDoum", platforms: [.macOS(.v26)], products: [.executable(name: "SpikDoum", targets: ["SpikDoum"])], targets: [.executableTarget(name: "SpikDoum"), .testTarget(name: "SpikDoumTests", dependencies: ["SpikDoum"])], swiftLanguageModes: [.v5])
