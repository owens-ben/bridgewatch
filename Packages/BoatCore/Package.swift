// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BoatCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "BoatCore", targets: ["BoatCore"]),
    ],
    targets: [
        .target(name: "BoatCore"),
        .testTarget(
            name: "BoatCoreTests",
            dependencies: ["BoatCore"],
            // Relay-generated fixtures (relay/PROTOCOL.md); regenerate with `npm run fixtures` in relay/.
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
