// swift-tools-version: 6.4
import PackageDescription

/// ModelRelay runs small chains of language-model steps (prompt, extract,
/// classify, branch, fan out) and lets each step pick its own model. Models are
/// FoundationModels `LanguageModel`s: Apple's on-device and Private Cloud
/// Compute models, MLX models through `MLXFoundationModels`, or your own.
let package = Package(
    name: "ModelRelay",
    platforms: [.macOS(.v27), .iOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "ModelRelay", targets: ["ModelRelay"]),
    ],
    targets: [
        .target(
            name: "ModelRelay",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .executableTarget(name: "relay-bench", dependencies: ["ModelRelay"]),
        .testTarget(name: "ModelRelayTests", dependencies: ["ModelRelay"]),
    ]
)
