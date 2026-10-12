import Foundation
import FoundationModels

/// A model behind an OpenAI-style `/chat/completions` endpoint: OpenAI itself,
/// or a local server such as Ollama (`http://localhost:11434/v1`) or LM Studio
/// (`http://localhost:1234/v1`). Guided generation uses a strict JSON schema.
public struct OpenAICompatibleModel: LanguageModel, Hashable {
    public var baseURL: URL
    public var model: String
    /// Sent as a bearer token. Local servers usually need none. Pass it from
    /// the Keychain; ModelRelay never stores it.
    public var apiKey: String?

    public init(baseURL: URL = URL(string: "https://api.openai.com/v1")!, model: String, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    public var executorConfiguration: OpenAICompatibleModel { self }

    public struct Executor: LanguageModelExecutor {
        public init(configuration: OpenAICompatibleModel) throws {}

        nonisolated(nonsending) public func respond(to request: LanguageModelExecutorGenerationRequest,
                                                    model: OpenAICompatibleModel,
                                                    streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let chat = ChatTurns(request.transcript)
            var messages: [[String: Any]] = []
            if !chat.system.isEmpty { messages.append(["role": "system", "content": chat.system]) }
            messages += chat.turns.map { ["role": $0.role, "content": $0.text] }

            var body: [String: Any] = ["model": model.model, "messages": messages]
            if let temperature = request.generationOptions.temperature { body["temperature"] = temperature }
            if let limit = request.generationOptions.maximumResponseTokens { body["max_tokens"] = limit }
            let schema = try request.schema.map(CloudSchema.init)
            if let schema {
                body["response_format"] = ["type": "json_schema",
                                           "json_schema": ["name": schema.name, "schema": schema.json, "strict": true]]
            }

            var headers: [String: String] = [:]
            if let key = model.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            let reply = try await CloudHTTP.postJSON(model.baseURL.appending(path: "chat/completions"),
                                                    headers: headers, body: body)
            let message = ((reply["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            guard let text = message?["content"] as? String else {
                throw CloudModelError(status: 200, message: "The reply had no text")
            }
            var output = text
            if let schema {
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
                    throw CloudModelError(status: 200, message: "The reply wasn't JSON")
                }
                output = try schema.content(from: object)
            }
            await channel.send(.response(action: .appendText(output, tokenCount: 1)))
        }
    }
}

extension OpenAICompatibleModel: CustomStringConvertible {
    /// Hides the key, so logging a model never prints it.
    public var description: String { "\(model) at \(baseURL.host() ?? baseURL.absoluteString)" }
}
