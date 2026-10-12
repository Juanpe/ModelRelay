import Foundation
import FoundationModels

/// A Claude model through Anthropic's Messages API. Guided generation asks
/// Claude to call a single `respond` tool whose input is the schema, which
/// returns exactly the requested fields.
public struct ClaudeModel: LanguageModel, Hashable {
    public var model: String
    /// Pass it from the Keychain; ModelRelay never stores it.
    public var apiKey: String
    public var baseURL: URL
    public var maxTokens: Int

    public init(model: String, apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
                maxTokens: Int = 1024) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxTokens = maxTokens
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    public var executorConfiguration: ClaudeModel { self }

    public struct Executor: LanguageModelExecutor {
        public init(configuration: ClaudeModel) throws {}

        nonisolated(nonsending) public func respond(to request: LanguageModelExecutorGenerationRequest,
                                                    model: ClaudeModel,
                                                    streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let chat = ChatTurns(request.transcript)
            var body: [String: Any] = [
                "model": model.model,
                "max_tokens": request.generationOptions.maximumResponseTokens ?? model.maxTokens,
                "messages": chat.turns.map { ["role": $0.role, "content": $0.text] },
            ]
            if !chat.system.isEmpty { body["system"] = chat.system }
            if let temperature = request.generationOptions.temperature { body["temperature"] = temperature }
            let schema = try request.schema.map(CloudSchema.init)
            if let schema {
                body["tools"] = [["name": "respond", "description": "Give the answer in this exact shape.",
                                  "input_schema": schema.json]]
                body["tool_choice"] = ["type": "tool", "name": "respond"]
            }

            let reply = try await CloudHTTP.postJSON(model.baseURL.appending(path: "messages"),
                                                    headers: ["x-api-key": model.apiKey, "anthropic-version": "2023-06-01"],
                                                    body: body)
            let blocks = reply["content"] as? [[String: Any]] ?? []
            let output: String
            if let schema {
                guard let input = blocks.first(where: { $0["type"] as? String == "tool_use" })?["input"] else {
                    throw CloudModelError(status: 200, message: "Claude didn't return the requested fields")
                }
                output = try schema.content(from: input)
            } else {
                output = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            }
            await channel.send(.response(action: .appendText(output, tokenCount: 1)))
        }
    }
}

extension ClaudeModel: CustomStringConvertible {
    /// Hides the key, so logging a model never prints it.
    public var description: String { "Claude \(model)" }
}
