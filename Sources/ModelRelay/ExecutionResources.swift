import AnyLanguageModel
import Foundation
import Synchronization

/// Mutable tool definitions for a reused NATIVE session, not another runtime.
/// Resolving the next request always uses the current step's tool wrappers,
/// write policy, call budget and value snapshot, never the previous step's.
final class StepTools: Sendable {
    private let value = Mutex<[any Tool]>([])
    var tools: [any Tool] {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

private struct CurrentStepInstructions: DynamicInstructions, Sendable {
    let state: StepTools
    var body: some DynamicInstructions { state.tools }
}

struct NativeConversation: Sendable {
    let session: LanguageModelSession
    let tools: StepTools
}

/// One run owns its model factories and native conversations. Never global,
/// never retained on WorkflowExecutor, and never shared between separate runs.
actor ExecutionResources {
    struct Key: Hashable, Sendable { let name: String; let model: ModelID }
    private var models: [ModelID: SharedResource<any LanguageModel>] = [:]
    private var decisions: [ModelID: SharedResource<(any DecisionModel)?>] = [:]
    private var conversations: [Key: NativeConversation] = [:]
    private var privacy: [Key: WorkflowExecutionPolicy.DataAccess] = [:]
    private var busy: Set<Key> = []
    private var restored: [Key: CheckpointConversation] = [:]

    init(conversations: [CheckpointConversation] = []) {
        for item in conversations {
            let key = Key(name: item.name, model: item.model)
            restored[key] = item
            privacy[key] = item.data
        }
    }

    /// Called only between top-level steps, after all native responses finish.
    func snapshot() -> [CheckpointConversation] {
        var saved = restored
        for (key, conversation) in conversations {
            saved[key] = CheckpointConversation(name: key.name, model: key.model,
                transcript: conversation.session.transcript, data: privacy[key] ?? .unrestricted)
        }
        return saved.values.sorted {
            $0.name == $1.name ? $0.model.rawValue < $1.model.rawValue : $0.name < $1.name
        }
    }

    func model(_ id: ModelID, catalog: ModelCatalog) async throws -> any LanguageModel {
        let resource = models[id] ?? SharedResource<any LanguageModel>()
        models[id] = resource
        return try await resource.get { try await catalog.model(id) }
    }

    func decisionModel(_ id: ModelID, catalog: ModelCatalog) async throws -> (any DecisionModel)? {
        let resource = decisions[id] ?? SharedResource<(any DecisionModel)?>()
        decisions[id] = resource
        return try await resource.get { try await catalog.decisionModel(id) }
    }

    func historyPolicy(_ context: StepContext?, models: [ModelID]) -> WorkflowExecutionPolicy.DataAccess {
        guard case .conversation(let name) = context else { return .unrestricted }
        return models.reduce(.unrestricted) { $0.combined(with: privacy[Key(name: name, model: $1)] ?? .unrestricted) }
    }

    func acquire(_ context: StepContext?, model id: ModelID, backend: any LanguageModel,
                 tools: [any Tool], data: WorkflowExecutionPolicy.DataAccess, step: String) throws -> NativeConversation {
        let key: Key?
        if case .conversation(let name) = context { key = Key(name: name, model: id) } else { key = nil }
        if let key, busy.contains(key) {
            throw RelayError.invalidContext(step: step, reason: "a conversation cannot run concurrently")
        }
        let conversation: NativeConversation
        if let key, let existing = conversations[key] { conversation = existing }
        else {
            let state = StepTools()
            let history = key.flatMap { restored[$0]?.transcript } ?? Transcript()
            let session = LanguageModelSession(model: backend, dynamicInstructions: CurrentStepInstructions(state: state), history: history)
            session.transcriptErrorHandlingPolicy = .revertTranscript
            conversation = NativeConversation(session: session, tools: state)
            if let key { conversations[key] = conversation; restored.removeValue(forKey: key) }
        }
        conversation.tools.tools = tools
        if let key {
            busy.insert(key)
            // Restrict even on failure: a provider/session may have seen data.
            privacy[key] = (privacy[key] ?? .unrestricted).combined(with: data)
        }
        return conversation
    }

    func release(_ context: StepContext?, model: ModelID, conversation: NativeConversation) {
        conversation.tools.tools = []
        if case .conversation(let name) = context { busy.remove(Key(name: name, model: model)) }
    }

    func finish() async {
        for resource in models.values { await resource.finish() }
        for resource in decisions.values { await resource.finish() }
        for conversation in conversations.values { conversation.tools.tools = [] }
        models.removeAll(); decisions.removeAll(); conversations.removeAll(); privacy.removeAll(); busy.removeAll(); restored.removeAll()
    }
}
