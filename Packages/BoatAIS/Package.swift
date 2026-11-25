// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BoatAIS",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "BoatAIS", targets: ["BoatAIS"]),
    ],
    dependencies: [
        .package(path: "../BoatCore"),
    ],
    targets: [
        .target(name: "BoatAIS", dependencies: ["BoatCore"]),
        .testTarget(name: "BoatAISTests", dependencies: ["BoatAIS", "BoatCore"]),
    ],
    swiftLanguageModes: [.v6]
)
