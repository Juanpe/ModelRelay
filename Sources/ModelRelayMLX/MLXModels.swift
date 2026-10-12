import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import ModelRelay
import Tokenizers

/// Small MLX models that suit ModelRelay's steps, by `mlx:` id. Weights come
/// from Hugging Face on first use and stay in its cache; apps that need to ask
/// before a download should check `isDownloaded` first.
public enum MLXModels {
    public static let qwen3_0_6B: ModelID = "mlx:qwen3-0.6b"
    public static let qwen3_1_7B: ModelID = "mlx:qwen3-1.7b"
    public static let qwen3_4B: ModelID = "mlx:qwen3-4b"
    public static let gemma3_1B: ModelID = "mlx:gemma3-1b"
    public static let llama3_2_3B: ModelID = "mlx:llama3.2-3b"

    static let configurations: [ModelID: ModelConfiguration] = [
        qwen3_0_6B: LLMRegistry.qwen3_0_6b_4bit,
        qwen3_1_7B: LLMRegistry.qwen3_1_7b_4bit,
        qwen3_4B: LLMRegistry.qwen3_4b_4bit,
        gemma3_1B: LLMRegistry.gemma3_1B_qat_4bit,
        llama3_2_3B: LLMRegistry.llama3_2_3B_4bit,
    ]

    public static var ids: [ModelID] { Array(configurations.keys) }
}

extension ModelCatalog {
    /// Registers the small MLX models. Each loads lazily, on first use, and is
    /// declared for guided generation (grammar-constrained output).
    public mutating func registerMLXModels() {
        for (id, configuration) in MLXModels.configurations {
            register(id) {
                #huggingFaceLanguageModel(configuration: configuration, capabilities: [.guidedGeneration])
            }
        }
    }

    public func registeringMLXModels() -> ModelCatalog {
        var copy = self
        copy.registerMLXModels()
        return copy
    }
}
