// swift-tools-version: 6.4
import PackageDescription

/// ModelRelay runs small chains of language-model steps (prompt, extract,
/// classify, branch, fan out) and lets each step pick its own model.
/// AnyLanguageModel provides the native inference and conversation runtime.
let package = Package(
    name: "ModelRelay",
    platforms: [.macOS(.v27), .iOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "ModelRelay", targets: ["ModelRelay"]),
        // Optional convenience catalog for native AnyLanguageModel MLX providers.
        .library(name: "ModelRelayMLX", targets: ["ModelRelayMLX"]),
        // Optional: sends request steps with URLSession.
        .library(name: "ModelRelayHTTP", targets: ["ModelRelayHTTP"]),
        // Optional: specialized decision models such as Jev.
        .library(name: "ModelRelayCloud", targets: ["ModelRelayCloud"]),
        // Optional: tool sets from MCP servers (Streamable HTTP), with OAuth
        // sign-in helpers.
        .library(name: "ModelRelayMCP", targets: ["ModelRelayMCP"]),
    ],
    // Local MLX inference is opt-in. Selecting the MLX product also requires
    // enabling this trait; core and network clients don't need its toolchain.
    // The trait enables AnyLanguageModel's native MLX backend; SwiftPM still
    // resolves its optional package graph.
    traits: [
        .trait(name: "MLX", description: "MLX models from Hugging Face (ModelRelayMLX)"),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/AnyLanguageModel", exact: "1.0.0", traits: [
            .trait(name: "MLX", condition: .when(traits: ["MLX"])),
        ]),
    ],
    targets: [
        .target(
            name: "ModelRelay",
            dependencies: [.product(name: "AnyLanguageModel", package: "AnyLanguageModel")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ModelRelayMLX",
            dependencies: [
                "ModelRelay",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        .target(
            name: "ModelRelayHTTP",
            dependencies: ["ModelRelay"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ModelRelayCloud",
            dependencies: ["ModelRelay"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ModelRelayMCP",
            dependencies: ["ModelRelay"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .executableTarget(name: "relay-bench", dependencies: ["ModelRelay", "ModelRelayMLX"]),
        // A local HTTP server that runs workflows from JSON files, so tools like
        // n8n can use Apple's models: `swift run relay-serve Examples/workflows`.
        .executableTarget(name: "relay-serve", dependencies: ["ModelRelay", "ModelRelayMLX"]),
        // A one-window Mac app to try workflows by hand: `swift run RelayPlayground`.
        .executableTarget(name: "RelayPlayground", dependencies: ["ModelRelay", "ModelRelayMLX"]),
        .testTarget(name: "ModelRelayTests", dependencies: ["ModelRelay", .product(name: "AnyLanguageModel", package: "AnyLanguageModel")]),
        .testTarget(name: "ModelRelayNetworkTests", dependencies: [.product(name: "AnyLanguageModel", package: "AnyLanguageModel"), "ModelRelay", "ModelRelayHTTP", "ModelRelayCloud", "ModelRelayMCP"]),
    ]
)
