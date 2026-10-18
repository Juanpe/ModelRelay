import AnyLanguageModel
import Foundation

/// Runs native model requests using resources owned by one workflow execution.
struct WorkflowModelRuntime: Sendable {
    let catalog: ModelCatalog
    let stepTimeout: Duration

    static func prompt(for kind: Step.Kind, source: Value, resolve: (String) -> Value?) -> String {
        let instruction: String = switch kind {
        case let .prompt(instruction), let .extract(instruction, _), let .classify(instruction, _),
             let .agent(instruction, _, _): instruction
        default: ""
        }
        let rendered = Template.render(instruction, resolve, text: \.modelText)

        // The source is data, clearly separated from the instruction. Lists
        // and fields reach the model as JSON.
        return instruction.contains("{{") ? rendered : "\(rendered)\n\nInput:\n\(source.modelText)"
    }

    func decide(
        _ questions: [Question],
        about text: String,
        model id: ModelID,
        step: Step,
        scope: WorkflowExecutionScope
    ) async throws -> Value {
        try catalog.check(id, policy: scope.policy, step: step.name)

        if catalog.isDecision(id) {
            if case .conversation = step.context {
                throw RelayError.invalidContext(step: step.name, reason: "decision-only models have no conversation; use handoff")
            }

            let resources = scope.resources
            try scope.control.beginModel(id, step: step.name)

            do {
                let result = try await withTimeout(stepTimeout) {
                    guard let decisions = try await resources.decisionModel(id, catalog: catalog) else { throw RelayError.unknownModel(id) }
                    try Task.checkCancellation()
                    return Answer.value(try await decisions.decide(questions, about: text))
                }
                scope.control.emit(.modelCompleted, step: step.name, model: id)
                return result
            } catch {
                scope.control.emit(.modelFailed, step: step.name, model: id, category: failureCategory(error))
                throw error
            }
        }

        return try await withSession(model: id, tools: [], step: step, scope: scope) { session in
            Answer.value(try await DecisionByLanguageModel.decide(questions, about: text, session: session))
        }
    }

    /// Shows the image and the instruction to a model that can see images.
    func read(
        _ image: ImageValue,
        instruction: String,
        model id: ModelID,
        step: Step,
        scope: WorkflowExecutionScope
    ) async throws -> Value {
        try catalog.check(id, policy: scope.policy, step: step.name)
        if catalog.isDecision(id) { throw InvalidOutput(reason: "\(id) answers questions; it can't read images") }
        guard catalog.supportsImages(id) else {
            throw InvalidOutput(reason: "\(id) can't read images. Choose a model that can see them")
        }

        return try await withSession(model: id, tools: [], step: step, scope: scope) { session in
            guard let picture = ImageCoding.picture(from: image.data) else { throw InvalidOutput(reason: "The image couldn't be opened") }
            return .text(try await session.respond { instruction; Attachment(picture) }.content)
        }
    }

    func generate(
        _ kind: Step.Kind,
        prompt: String,
        model id: ModelID,
        tools: [any Tool] = [],
        step: Step,
        scope: WorkflowExecutionScope
    ) async throws -> Value {
        try catalog.check(id, policy: scope.policy, step: step.name)
        if catalog.isDecision(id) {
            guard case let .classify(instruction, labels) = kind else {
                throw InvalidOutput(reason: "\(id) answers questions; it can't write text. Use it in Decide or Classify")
            }
            let question = Question(
                "label",
                instruction.isEmpty ? "Which label fits?" : instruction,
                .choice(labels.map { Question.Option($0) })
            )
            let input = prompt.components(separatedBy: "\n\nInput:\n").last ?? prompt
            let value = try await decide([question], about: input, model: id, step: step, scope: scope)
            guard let label = value["label"]?.textValue, labels.contains(label) else { throw InvalidOutput(reason: "Expected one of \(labels)") }
            return .text(label)
        }
        return try await withSession(model: id, tools: tools, step: step, scope: scope) { session in
            try await Self.respond(kind, prompt: prompt, session: session, hasTools: !tools.isEmpty)
        }
    }

    private func withSession(
        model id: ModelID,
        tools: [any Tool],
        step: Step,
        scope: WorkflowExecutionScope,
        operation: @escaping @Sendable (LanguageModelSession) async throws -> Value
    ) async throws -> Value {
        let resources = scope.resources
        let catalog = self.catalog
        try scope.control.beginModel(id, step: step.name)

        let work: @Sendable () async throws -> Value = {
            try Task.checkCancellation()
            let backend = try await resources.model(id, catalog: catalog)
            try Task.checkCancellation()
            let conversation = try await resources.acquire(
                step.context,
                model: id,
                backend: backend,
                tools: tools,
                data: scope.policy.data,
                step: step.name
            )

            do {
                try Task.checkCancellation()
                let value = try await operation(conversation.session)
                await conversation.session.waitForResponseCompletion()
                try Task.checkCancellation()
                await resources.release(step.context, model: id, conversation: conversation)
                return value
            } catch {
                await conversation.session.waitForResponseCompletion()
                await resources.release(step.context, model: id, conversation: conversation)
                throw error
            }
        }
        // OCR's first preparation can be long; preserve its existing behavior.
        do {
            let value = id == .appleTextRecognition ? try await work() : try await withTimeout(stepTimeout, work)
            scope.control.emit(.modelCompleted, step: step.name, model: id)
            return value
        } catch {
            scope.control.emit(.modelFailed, step: step.name, model: id, category: failureCategory(error))
            throw error
        }
    }

    private static func respond(_ kind: Step.Kind, prompt: String, session: LanguageModelSession, hasTools: Bool) async throws -> Value {
        switch kind {
        case let .extract(_, fields):
            let schema = try SchemaBuilder.object(named: "Result", fields: fields)
            return Value(try await session.respond(to: prompt, schema: schema).content)
        case let .classify(_, labels):
            let schema = try SchemaBuilder.label(from: labels)
            let raw = Value(try await session.respond(to: prompt, schema: schema).content).textValue
            // Models may quote or pad the label; anything outside the list is
            // invalid output (and goes to the fallback model, if any).
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard let label = labels.first(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else {
                throw InvalidOutput(reason: "Expected one of \(labels), got \(raw)")
            }
            return .text(label)
        default:
            if hasTools {
                // Native streaming providers own the complete tool loop.
                // In particular Anthropic's non-streaming API is one round.
                var text: String?
                for try await snapshot in session.streamResponse(to: prompt) {
                    text = snapshot.content
                }
                try Task.checkCancellation()
                guard let text else { throw InvalidOutput(reason: "The model returned no answer") }
                return .text(text)
            }
            return .text(try await session.respond(to: prompt).content)
        }
    }
}
