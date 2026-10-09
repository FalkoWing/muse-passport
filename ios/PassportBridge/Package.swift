// swift-tools-version: 6.2
import PackageDescription

// The bridge core and portable Opus codec build and test without a simulator.
let package = Package(
    name: "PassportBridge",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "PassportBridge", targets: ["PassportBridge"])],
    dependencies: [.package(path: "../../shared/opus")],
    targets: [
        .target(name: "PassportBridge", dependencies: [.product(name: "PassportOpus", package: "opus")]),
        .testTarget(name: "PassportBridgeTests", dependencies: ["PassportBridge"],
                    resources: [.copy("Fixtures")]),
    ]
)
