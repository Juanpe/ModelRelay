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
            guard let reply = model.next() else { throw Failure() }
            if reply == "<hang>" { try await Task.sleep(for: .seconds(60)) }
            await channel.send(.response(action: .appendText(reply, tokenCount: 1)))
        }
    }

    let name: String
    private let replies: Mutex<[String?]>
    private let calls = Mutex(0)

    /// `nil` in `replies` makes that call fail.
    init(_ name: String, replies: [String?]) {
        self.name = name
        self.replies = Mutex(replies)
    }

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    var executorConfiguration: String { name }
    var callCount: Int { calls.withLock { $0 } }

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
