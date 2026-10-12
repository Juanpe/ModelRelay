// swift-tools-version: 6.4
import PackageDescription

/// ModelRelay runs small chains of language-model steps (prompt, extract,
/// classify, branch, fan out) and lets each step pick its own model. Models are
/// FoundationModels `LanguageModel`s: Apple's on-device and Private Cloud
/// Compute models, MLX models (ModelRelayMLX), or your own.
let package = Package(
    name: "ModelRelay",
    platforms: [.macOS(.v27), .iOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "ModelRelay", targets: ["ModelRelay"]),
        // Optional: MLX models from Hugging Face. Separate so the core stays
        // dependency-free.
        .library(name: "ModelRelayMLX", targets: ["ModelRelayMLX"]),
        // Optional: sends request steps with URLSession.
        .library(name: "ModelRelayHTTP", targets: ["ModelRelayHTTP"]),
        // Optional: Claude and OpenAI-compatible servers (OpenAI, Ollama, LM
        // Studio) as FoundationModels `LanguageModel`s.
        .library(name: "ModelRelayCloud", targets: ["ModelRelayCloud"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .target(
            name: "ModelRelay",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ModelRelayMLX",
            dependencies: [
                "ModelRelay",
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
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
        .executableTarget(name: "relay-bench", dependencies: ["ModelRelay", "ModelRelayMLX"]),
        // A local HTTP server that runs workflows from JSON files, so tools like
        // n8n can use Apple's models: `swift run relay-serve Examples/workflows`.
        .executableTarget(name: "relay-serve", dependencies: ["ModelRelay", "ModelRelayMLX"]),
        // A one-window Mac app to try workflows by hand: `swift run RelayPlayground`.
        .executableTarget(name: "RelayPlayground", dependencies: ["ModelRelay", "ModelRelayMLX"]),
        .testTarget(name: "ModelRelayTests", dependencies: ["ModelRelay"]),
        .testTarget(name: "ModelRelayNetworkTests", dependencies: ["ModelRelay", "ModelRelayHTTP", "ModelRelayCloud"]),
    ]
)
