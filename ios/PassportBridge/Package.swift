// swift-tools-version: 6.2
import PackageDescription

// The bridge core: no Bluetooth, no UI, no third-party dependencies, so it
// builds and tests on a Mac without a simulator.
let package = Package(
    name: "PassportBridge",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "PassportBridge", targets: ["PassportBridge"])],
    targets: [
        .target(name: "PassportBridge"),
        .testTarget(name: "PassportBridgeTests", dependencies: ["PassportBridge"],
                    resources: [.copy("Fixtures")]),
    ]
)
