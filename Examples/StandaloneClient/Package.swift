// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "StandaloneClient",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Use the sibling SDK checkout. No MLX trait or optional products.
        .package(path: "../..", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "StandaloneClient",
            dependencies: [.product(name: "ModelRelay", package: "ModelRelay")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ]
)
