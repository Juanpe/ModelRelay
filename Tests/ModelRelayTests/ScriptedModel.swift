import FoundationModels
import Synchronization
@testable import ModelRelay

/// A FoundationModels `LanguageModel` that answers from a script, so the
/// runner is tested through the real `LanguageModelSession` path.
final class ScriptedModel: LanguageModel {
    struct Failure: Error {}

    struct Executor: LanguageModelExecutor {
        typealias Model = ScriptedModel
        init(configuration: String) throws {}

        nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
                                             streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            model.record(request.transcript)
            guard let reply = model.next() else { throw Failure() }
            if reply == "<hang>" { try await Task.sleep(for: .seconds(60)) }
            await channel.send(.response(action: .appendText(reply, tokenCount: 1)))
        }
    }

    let name: String
    private let replies: Mutex<[String?]>
    private let calls = Mutex(0)
    private let seen = Mutex<[String]>([])

    /// `nil` in `replies` makes that call fail.
    init(_ name: String, replies: [String?]) {
        self.name = name
        self.replies = Mutex(replies)
    }

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    var executorConfiguration: String { name }
    var callCount: Int { calls.withLock { $0 } }
    /// The prompt text of every call, to check what a model was shown.
    var prompts: [String] { seen.withLock { $0 } }

    func record(_ transcript: Transcript) {
        let text = transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment in
                if case .text(let text) = segment { text.content } else { nil }
            }.joined()
        }.joined(separator: "\n")
        seen.withLock { $0.append(text) }
    }

    func next() -> String? {
        calls.withLock { $0 += 1 }
        return replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

extension ModelCatalog {
    static func scripted(_ models: [ModelID: ScriptedModel]) -> ModelCatalog {
        var catalog = ModelCatalog()
        for (id, model) in models { catalog.register(id) { model } }
        return catalog
    }
}
