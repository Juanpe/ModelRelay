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

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration, .toolCalling]) }
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
                "messages": ClaudeModel.messages(chat.turns),
            ]
            if !chat.system.isEmpty { body["system"] = chat.system }
            if let temperature = request.generationOptions.temperature { body["temperature"] = temperature }
            let schema = try request.schema.map(CloudSchema.init)
            if let schema {
                body["tools"] = [["name": "respond", "description": "Give the answer in this exact shape.",
                                  "input_schema": schema.json]]
                body["tool_choice"] = ["type": "tool", "name": "respond"]
            } else if !request.enabledToolDefinitions.isEmpty {
                body["tools"] = request.enabledToolDefinitions.map { tool in
                    ["name": tool.name, "description": tool.description, "input_schema": ChatTurns.parameters(tool)]
                }
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
                // Claude wants tools: hand the calls to the session, which runs
                // them and asks again with their results.
                let uses = blocks.filter { $0["type"] as? String == "tool_use" }
                if !uses.isEmpty {
                    for use in uses {
                        await channel.send(.toolCalls(action: .toolCall(
                            id: use["id"] as? String ?? UUID().uuidString, name: use["name"] as? String ?? "",
                            action: .appendArguments(ChatTurns.jsonString(ChatTurns.object(use["input"])), tokenCount: 1))))
                    }
                    return
                }
                output = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            }
            await channel.send(.response(action: .appendText(output, tokenCount: 1)))
        }
    }
}

extension ClaudeModel {
    /// Messages API turns: tool calls are `tool_use` blocks from the assistant,
    /// their results `tool_result` blocks from the user, grouped per turn.
    static func messages(_ turns: [ChatTurns.Turn]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        func append(_ role: String, _ blocks: [[String: Any]]) {
            if var last = messages.last, last["role"] as? String == role, var content = last["content"] as? [[String: Any]] {
                content += blocks
                last["content"] = content
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }
        for turn in turns {
            switch turn {
            case .user(let text): append("user", [["type": "text", "text": text]])
            case .assistant(let text): append("assistant", [["type": "text", "text": text]])
            case .toolCalls(let calls):
                append("assistant", calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": ChatTurns.object($0.arguments)] })
            case .toolResult(let id, _, let text):
                append("user", [["type": "tool_result", "tool_use_id": id, "content": text]])
            }
        }
        return messages
    }
}

extension ClaudeModel: CustomStringConvertible {
    /// Hides the key, so logging a model never prints it.
    public var description: String { "Claude \(model)" }
}
