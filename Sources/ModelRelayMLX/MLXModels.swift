#if MLX
import AnyLanguageModel
import ModelRelay

/// Optional catalog presets. Model loading, caching and inference belong to
/// AnyLanguageModel; ModelRelay does not wrap or translate its sessions.
public enum MLXModels {
    public static let qwen3_0_6B: ModelID = "mlx:qwen3-0.6b"
    public static let qwen3_1_7B: ModelID = "mlx:qwen3-1.7b"
    public static let qwen3_4B: ModelID = "mlx:qwen3-4b"
    public static let gemma3_1B: ModelID = "mlx:gemma3-1b"
    public static let llama3_2_3B: ModelID = "mlx:llama3.2-3b"

    static let configurations: [ModelID: String] = [
        qwen3_0_6B: "mlx-community/Qwen3-0.6B-4bit",
        qwen3_1_7B: "mlx-community/Qwen3-1.7B-4bit",
        qwen3_4B: "mlx-community/Qwen3-4B-4bit",
        gemma3_1B: "mlx-community/gemma-3-1b-it-qat-4bit",
        llama3_2_3B: "mlx-community/Llama-3.2-3B-Instruct-4bit",
    ]
    public static var ids: [ModelID] { Array(configurations.keys) }
}

extension ModelCatalog {
    /// Presets load lazily through AnyLanguageModel's shared model cache.
    public mutating func registerMLXModels() {
        for (id, modelID) in MLXModels.configurations {
            let model = MLXLanguageModel(modelId: modelID)
            register(id) { model }
        }
    }

    public func registeringMLXModels() -> ModelCatalog {
        var copy = self
        copy.registerMLXModels()
        return copy
    }
}
#endif
