import Foundation
import Synchronization
import AnyLanguageModel

struct InvalidOutput: Error, CustomStringConvertible {
    var reason: String
    var description: String { reason }
}

public enum RelayError: Error, Equatable, Sendable {
    case unknownModel(ModelID)
    case missingModel(step: String)
    case unknownReference(String, step: String)
    case stepFailed(step: String, reason: String)
    /// A request step ran but the runner has no `RequestPerformer`.
    case requestsUnavailable(step: String)
    /// A request step needs `{{secret.NAME}}` and no secret has that name.
    case missingSecret(String, step: String)
    /// A request that changes something was not allowed by the `WritePolicy`.
    case writeNotAllowed(step: String)
}

/// What one step did: its result, which model produced it and how long it took.
public struct StepRecord: Sendable, Hashable {
    public var step: String
    public var value: Value
    public var model: ModelID?
    public var usedFallback: Bool
    public var duration: Duration
    public var skipped: Bool
    /// Tools an agent step called, in order (empty for other steps).
    public var toolCalls: [String] = []
    /// What the step read: the prompt a model was given, the text a decision
    /// was about, or the request it sent with secrets hidden. Nil for steps
    /// that read nothing of their own.
    public var input: String? = nil
    /// Why the step failed. Only on the record of the step a run stopped at,
    /// which the observer receives before the run throws.
    public var failure: String? = nil
}

public struct RunReport: Sendable {
    public var output: Value
    public var records: [StepRecord]
    public var duration: Duration
}

/// Runs workflows. Each `run` is independent; cancelling the calling task
/// cancels the run. Model output is only ever data: it can fill a value, never
/// choose what the runner does next except through an explicit `ifEquals`.
public actor WorkflowRunner {
    private let catalog: ModelCatalog
    private let stepTimeout: Duration
    private let context: RequestContext
    private let toolKits: [String: ToolKit]
    private let toolServers: (any ToolServerConnector)?
    private let clock = ContinuousClock()

    /// `stepTimeout` bounds one model call or request. Small models occasionally
    /// run away; a call that takes longer counts as a failure (and tries the
    /// fallback model, if any). Request steps need `requests`; those that change
    /// something also need a `writePolicy` that allows them. Custom bodies
    /// use the same cooperative timeout and run once, without fallback.
    /// Tool sets with a server need `toolServers`.
    public init(catalog: ModelCatalog = ModelCatalog(), stepTimeout: Duration = .seconds(30),
                requests: (any RequestPerformer)? = nil, secrets: (any SecretProvider)? = nil,
                writePolicy: WritePolicy = .deny, toolKits: [ToolKit] = [],
                toolServers: (any ToolServerConnector)? = nil) {
        self.catalog = catalog
        self.stepTimeout = stepTimeout
        self.toolServers = toolServers
        self.toolKits = Dictionary(toolKits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.context = RequestContext(requests: requests, secrets: secrets, writePolicy: writePolicy, timeout: stepTimeout)
    }

    /// `onStep` is called as each step finishes, is skipped or fails (the step
    /// a run stops at gets a record with `failure` before the run throws), so a
    /// caller keeps what ran, shows progress live, and can say why it stopped.
    public func run(_ workflow: Workflow, input: Value,
                    onStep: (@Sendable (StepRecord) -> Void)? = nil) async throws -> RunReport {
        let start = clock.now
        var scope = Scope(input: input, observer: onStep)
        let last = try await runSteps(workflow.steps, scope: &scope)
        let output = workflow.output.flatMap { scope.results[$0] } ?? last
        return RunReport(output: output, records: scope.records, duration: clock.now - start)
    }

    // MARK: - Steps

    private struct Scope: Sendable {
        var input: Value
        var results: [String: Value] = [:]
        var records: [StepRecord] = []
        var previous: Value
        let observer: (@Sendable (StepRecord) -> Void)?

        init(input: Value, observer: (@Sendable (StepRecord) -> Void)? = nil) {
            self.input = input
            self.previous = input
            self.observer = observer
        }

        mutating func record(_ record: StepRecord) {
            records.append(record)
            observer?(record)
        }

        /// `input`, `step` or `step.field`.
        func resolve(_ reference: String) -> Value? {
            let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
            let base = parts[0] == "input" ? input : results[parts[0]]
            guard let base else { return nil }
            return parts.count == 2 ? base[parts[1]] : base
        }
    }

    private func runSteps(_ steps: [Step], scope: inout Scope) async throws -> Value {
        for step in steps {
            try Task.checkCancellation()
            let value = try await runRecordingFailure(step, scope: &scope)
            scope.results[step.name] = value
            scope.previous = value
        }
        return scope.previous
    }

    /// Runs a step; if a step that does work itself (not a block) fails, it
    /// gets a record saying why and with what input, then the error goes on.
    private func runRecordingFailure(_ step: Step, scope: inout Scope) async throws -> Value {
        let start = clock.now
        let trace = StepTrace()
        do {
            return try await runStep(step, scope: &scope, trace: trace)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !Self.isBlock(step) {
                scope.record(StepRecord(step: step.name, value: .null, model: step.model, usedFallback: false,
                                        duration: clock.now - start, skipped: false, input: trace.input,
                                        failure: failureReason(error)))
            }
            throw error
        }
    }

    private static func isBlock(_ step: Step) -> Bool {
        switch step.kind {
        case .ifEquals, .switchOn, .parallel: true
        default: false
        }
    }

    private func runStep(_ step: Step, scope: inout Scope, trace: StepTrace) async throws -> Value {
        let start = clock.now
        let source: Value
        if let reference = step.input {
            guard let value = scope.resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
            source = value
        } else {
            source = scope.previous
        }

        switch step.kind {
        case .template(let template):
            let value = Value.text(Template.render(template, scope.resolve))
            scope.record(StepRecord(step: step.name, value: value, model: nil, usedFallback: false,
                                            duration: clock.now - start, skipped: false))
            return value

        case .custom(let body):
            trace.input = source.textValue
            let values = CustomStepContext(input: source, workflowInput: scope.input, results: scope.results)
            let value: Value
            do {
                value = try await withTimeout(stepTimeout, message: "it ran longer than \(stepTimeout)") {
                    try Task.checkCancellation()
                    return try await body.call(values)
                }
            } catch {
                try Self.rethrowCancellation(error)
                throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
            }
            scope.record(StepRecord(step: step.name, value: value, model: nil, usedFallback: false,
                                    duration: clock.now - start, skipped: false, input: trace.input))
            return value

        case .useTool(let kitID, let toolName, let arguments):
            guard let kit = toolKits[kitID] else {
                throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(kitID)” isn't available")
            }
            let rendered = arguments.mapValues { Template.render($0, scope.resolve) }
            let value: Value
            if kit.server != nil {
                let connection = try await connect(kit, step: step.name)
                guard let tool = try await serverTools(kit, connection, step: step.name).first(where: { $0.name == toolName }) else {
                    throw RelayError.stepFailed(step: step.name, reason: "\(kit.name) has no tool “\(toolName)”")
                }
                let typed = ServerArguments.typed(rendered, for: tool)
                let call = ServerCallDescription.prepared(kit: kit, tool: tool.name, arguments: typed)
                trace.input = call.description
                if tool.changesSomething { try await context.authorize(call, step: step.name) }
                do {
                    // One attempt only, like a request: the call may have happened.
                    value = try await withTimeout(stepTimeout) { try await connection.call(tool.name, arguments: typed) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RelayError.stepFailed(step: step.name, reason: "\(kit.name): \(failureReason(error))")
                }
            } else {
                guard let spec = kit.tools.first(where: { $0.name == toolName }) else {
                    throw RelayError.stepFailed(step: step.name, reason: "\(kit.name) has no tool “\(toolName)”")
                }
                value = try await context.perform(spec.request, step: step.name, trace: trace) { reference in
                    if reference.hasPrefix("args.") { return rendered[String(reference.dropFirst("args.".count))].map(Value.text) }
                    return scope.resolve(reference)
                }
            }
            scope.record(StepRecord(step: step.name, value: value, model: nil, usedFallback: false,
                                    duration: clock.now - start, skipped: false, input: trace.input))
            return value

        case .request(let request):
            let value = try await context.perform(request, step: step.name, trace: trace, resolve: scope.resolve)
            scope.record(StepRecord(step: step.name, value: value, model: nil, usedFallback: false,
                                    duration: clock.now - start, skipped: false, input: trace.input))
            return value

        case .ifEquals(let reference, let expected, let then, let otherwise):
            guard let value = scope.resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
            let branch = value.textValue == expected ? then : otherwise
            let skipped = value.textValue == expected ? otherwise : then
            for step in skipped.flatMap(Self.flatten) {
                scope.record(StepRecord(step: step.name, value: .null, model: nil, usedFallback: false,
                                                duration: .zero, skipped: true))
            }
            return try await runSteps(branch, scope: &scope)

        case .switchOn(let reference, let cases, let otherwise):
            guard let value = scope.resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
            let key = value.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = cases.firstIndex { $0.value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame }
            let branch = chosen.map { cases[$0].steps } ?? otherwise
            var skipped = otherwise
            for (index, item) in cases.enumerated() where index != chosen { skipped += item.steps }
            if chosen == nil { skipped = cases.flatMap(\.steps) }
            for step in skipped.flatMap(Self.flatten) {
                scope.record(StepRecord(step: step.name, value: .null, model: nil, usedFallback: false,
                                                duration: .zero, skipped: true))
            }
            return try await runSteps(branch, scope: &scope)

        case .parallel(let steps):
            let snapshot = scope
            let results = try await withThrowingTaskGroup(of: (Int, Value, [StepRecord]).self) { group in
                for (index, child) in steps.enumerated() {
                    group.addTask {
                        var local = snapshot
                        local.records = []
                        let value = try await self.runRecordingFailure(child, scope: &local)
                        return (index, value, local.records)
                    }
                }
                var collected: [(Int, Value, [StepRecord])] = []
                for try await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }
            }
            var merged: [String: Value] = [:]
            for (index, value, records) in results {
                merged[steps[index].name] = value
                scope.results[steps[index].name] = value
                scope.records += records
            }
            return .dictionary(merged)

        case .agent(_, let ownTools, let kitIDs):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            var specs = ownTools
            var servers: [(ToolKit, any ToolServerConnection, [ServerTool])] = []
            for id in kitIDs ?? [] {
                guard let kit = toolKits[id] else {
                    throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(id)” isn't available")
                }
                if kit.server != nil {
                    let connection = try await connect(kit, step: step.name)
                    servers.append((kit, connection, try await serverTools(kit, connection, step: step.name)))
                } else {
                    specs += kit.tools
                }
            }
            let prompt = Self.prompt(for: step.kind, source: source, resolve: scope.resolve)
            trace.input = prompt
            let snapshot = scope
            let log = ToolCallLog(limit: AgentTool.maxCallsPerStep)
            var tools: [any Tool] = specs.map {
                RequestTool(spec: $0, step: step.name, context: context, log: log, resolve: { snapshot.resolve($0) })
            }
            for (kit, connection, list) in servers {
                tools += list.map { ServerToolCall(tool: $0, kit: kit, connection: connection, step: step.name,
                                                   context: context, log: log) }
            }
            var model = primary
            var usedFallback = false
            let value: Value
            do {
                value = try await generate(.prompt(instruction: ""), prompt: prompt, model: primary, tools: tools)
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                // A tool may already have changed something: only retry on the
                // fallback model when no tool was called.
                guard let fallback = step.fallback, log.calls.isEmpty else {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
                do {
                    value = try await generate(.prompt(instruction: ""), prompt: prompt, model: fallback, tools: tools)
                    model = fallback
                    usedFallback = true
                } catch {
                    try Self.rethrowCancellation(error)
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }
            scope.record(StepRecord(step: step.name, value: value, model: model, usedFallback: usedFallback,
                                    duration: clock.now - start, skipped: false, toolCalls: log.calls, input: prompt))
            return value

        case .decide(let questions):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            if let problem = Question.problem(in: questions) {
                throw RelayError.stepFailed(step: step.name, reason: problem)
            }
            let text = source.modelText
            trace.input = text
            do {
                let value = try await decide(questions, about: text, model: primary)
                scope.record(StepRecord(step: step.name, value: value, model: primary, usedFallback: false,
                                        duration: clock.now - start, skipped: false, input: text))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                guard let fallback = step.fallback else {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
                do {
                    let value = try await decide(questions, about: text, model: fallback)
                    scope.record(StepRecord(step: step.name, value: value, model: fallback, usedFallback: true,
                                            duration: clock.now - start, skipped: false, input: text))
                    return value
                } catch {
                    try Self.rethrowCancellation(error)
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }

        case .readImage(let instruction):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            guard case .image(let image) = source else {
                throw RelayError.stepFailed(step: step.name, reason: "it needs an image, and got \(source.kindName)")
            }
            let text = Template.render(instruction.isEmpty ? ImageReading.defaultInstruction : instruction, scope.resolve,
                                       text: \.modelText)
            // The picture itself is never kept: the trace says what it was.
            let input = "\(text)\n\n[\(ImageReading.describe(image))]"
            trace.input = input
            do {
                let value = try await read(image, instruction: text, model: primary)
                scope.record(StepRecord(step: step.name, value: value, model: primary, usedFallback: false,
                                        duration: clock.now - start, skipped: false, input: input))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                guard let fallback = step.fallback else {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
                do {
                    let value = try await read(image, instruction: text, model: fallback)
                    scope.record(StepRecord(step: step.name, value: value, model: fallback, usedFallback: true,
                                            duration: clock.now - start, skipped: false, input: input))
                    return value
                } catch {
                    try Self.rethrowCancellation(error)
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }

        case .prompt, .extract, .classify:
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            let prompt = Self.prompt(for: step.kind, source: source, resolve: scope.resolve)
            trace.input = prompt
            do {
                let value = try await generate(step.kind, prompt: prompt, model: primary)
                scope.record(StepRecord(step: step.name, value: value, model: primary, usedFallback: false,
                                        duration: clock.now - start, skipped: false, input: prompt))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                guard let fallback = step.fallback else {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
                // One retry on the fallback model; never more (no retry loops).
                do {
                    let value = try await generate(step.kind, prompt: prompt, model: fallback)
                    scope.record(StepRecord(step: step.name, value: value, model: fallback, usedFallback: true,
                                            duration: clock.now - start, skipped: false, input: prompt))
                    return value
                } catch {
                    try Self.rethrowCancellation(error)
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }
        }
    }

    /// Cancellation is control flow, never a model failure to retry. Some
    /// providers wrap it, so also check the calling task's cancellation state.
    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
    }

    private static func flatten(_ step: Step) -> [Step] {
        switch step.kind {
        case .ifEquals(_, _, let then, let otherwise): [step] + (then + otherwise).flatMap(flatten)
        case .switchOn(_, let cases, let otherwise): [step] + (cases.flatMap(\.steps) + otherwise).flatMap(flatten)
        case .parallel(let steps): [step] + steps.flatMap(flatten)
        default: [step]
        }
    }

    private static func prompt(for kind: Step.Kind, source: Value, resolve: (String) -> Value?) -> String {
        let instruction: String = switch kind {
        case .prompt(let instruction), .extract(let instruction, _), .classify(let instruction, _),
             .agent(let instruction, _, _): instruction
        default: ""
        }
        let rendered = Template.render(instruction, resolve, text: \.modelText)
        // The source is data, clearly separated from the instruction. Lists
        // and fields reach the model as JSON.
        return instruction.contains("{{") ? rendered : "\(rendered)\n\nInput:\n\(source.modelText)"
    }

    private func decide(_ questions: [Question], about text: String, model id: ModelID) async throws -> Value {
        if let decisions = try await catalog.decisionModel(id) {
            return Answer.value(try await withTimeout(stepTimeout) { try await decisions.decide(questions, about: text) })
        }
        let model = try await catalog.model(id)
        return Answer.value(try await withTimeout(stepTimeout) {
            try await DecisionByLanguageModel.decide(questions, about: text, model: model)
        })
    }

    /// Opens a connection to a tool set's server.
    private func connect(_ kit: ToolKit, step: String) async throws -> any ToolServerConnection {
        guard let toolServers else { throw RelayError.stepFailed(step: step, reason: "tool servers can't be reached here") }
        do {
            return try await withTimeout(stepTimeout) { try await toolServers.connect(to: kit) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RelayError.stepFailed(step: step, reason: "\(kit.name): \(failureReason(error))")
        }
    }

    private func serverTools(_ kit: ToolKit, _ connection: any ToolServerConnection, step: String) async throws -> [ServerTool] {
        do {
            return try await withTimeout(stepTimeout) { try await connection.tools() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RelayError.stepFailed(step: step, reason: "\(kit.name): \(failureReason(error))")
        }
    }

    /// Shows the image and the instruction to a model that can see images.
    private func read(_ image: ImageValue, instruction: String, model id: ModelID) async throws -> Value {
        if try await catalog.decisionModel(id) != nil {
            throw InvalidOutput(reason: "\(id) answers questions; it can't read images")
        }
        let model = try await catalog.model(id)
        guard catalog.supportsImages(id) else {
            throw InvalidOutput(reason: "\(id) can't read images. Choose a model that can see them")
        }
        let work: @Sendable () async throws -> Value = {
            guard let picture = ImageCoding.picture(from: image.data) else {
                throw InvalidOutput(reason: "The image couldn't be opened")
            }
            let session = LanguageModelSession(model: model)
            let response = try await session.respond {
                instruction
                Attachment(picture)
            }
            return .text(response.content)
        }
        // Text recognition can't run away, but its first use in an app
        // prepares its model, which can take a minute on a Mac.
        if model is TextRecognitionModel { return try await work() }
        return try await withTimeout(stepTimeout, work)
    }

    private func generate(_ kind: Step.Kind, prompt: String, model id: ModelID,
                          tools: [any Tool] = []) async throws -> Value {
        // A decision model can classify (one choice question) but not write text.
        if let decisions = try await catalog.decisionModel(id) {
            guard case .classify(let instruction, let labels) = kind else {
                throw InvalidOutput(reason: "\(id) answers questions; it can't write text. Use it in Decide or Classify")
            }
            let question = Question("label", instruction.isEmpty ? "Which label fits?" : instruction,
                                    .choice(labels.map { Question.Option($0) }))
            let input = prompt.components(separatedBy: "\n\nInput:\n").last ?? prompt
            let answers = try await withTimeout(stepTimeout) { try await decisions.decide([question], about: input) }
            guard case .choice(let label)? = answers.first?.result, labels.contains(label) else {
                throw InvalidOutput(reason: "Expected one of \(labels)")
            }
            return .text(label)
        }
        let model = try await catalog.model(id)
        return try await withTimeout(stepTimeout) { try await Self.respond(kind, prompt: prompt, model: model, tools: tools) }
    }

    private static func respond(_ kind: Step.Kind, prompt: String, model: any LanguageModel,
                                tools: [any Tool]) async throws -> Value {
        let session = LanguageModelSession(model: model, tools: tools)
        switch kind {
        case .extract(_, let fields):
            let schema = try SchemaBuilder.object(named: "Result", fields: fields)
            return Value(try await session.respond(to: prompt, schema: schema).content)
        case .classify(_, let labels):
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
            if !tools.isEmpty {
                // Native streaming providers own the complete tool loop.
                // In particular Anthropic's non-streaming API is one round.
                var text: String?
                for try await snapshot in session.streamResponse(to: prompt) { text = snapshot.content }
                try Task.checkCancellation()
                guard let text else { throw InvalidOutput(reason: "The model returned no answer") }
                return .text(text)
            }
            return .text(try await session.respond(to: prompt).content)
        }
    }
}

/// What one step read, filled in as soon as it's known so a failure record
/// can include it.
final class StepTrace: Sendable {
    private let value = Mutex<String?>(nil)

    var input: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Turns a Use a Tool step's rendered text into the types a server tool
/// asks for: numbers, yes/no, lists. Empty optional arguments are left out.
enum ServerArguments {
    static func typed(_ rendered: [String: String], for tool: ServerTool) -> [String: Value] {
        var values: [String: Value] = [:]
        for (name, text) in rendered {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !tool.required.contains(name) { continue }
            let kind = tool.parameters.first { $0.name == name }?.kind ?? .text
            values[name] = value(trimmed, as: kind)
        }
        return values
    }

    private static func value(_ text: String, as kind: Field.Kind) -> Value {
        switch kind {
        case .number: return Double(text).map(Value.number) ?? .text(text)
        case .bool:
            switch text.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return .text(text)
            }
        case .list(let item):
            if let data = text.data(using: .utf8), let parsed = Value(json: data), case .list = parsed { return parsed }
            return .list(text.split(whereSeparator: \.isNewline).map { value(String($0).trimmingCharacters(in: .whitespaces), as: item) })
        case .text, .choice:
            // A JSON object or list written into a text field is sent as one.
            if text.hasPrefix("{") || text.hasPrefix("["), let data = text.data(using: .utf8), let parsed = Value(json: data) {
                return parsed
            }
            return .text(text)
        }
    }
}
