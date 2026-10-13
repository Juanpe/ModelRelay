import Foundation
import FoundationModels

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
    private let clock = ContinuousClock()

    /// `stepTimeout` bounds one model call or request. Small models occasionally
    /// run away; a call that takes longer counts as a failure (and tries the
    /// fallback model, if any). Request steps need `requests`; those that change
    /// something also need a `writePolicy` that allows them.
    public init(catalog: ModelCatalog = ModelCatalog(), stepTimeout: Duration = .seconds(30),
                requests: (any RequestPerformer)? = nil, secrets: (any SecretProvider)? = nil,
                writePolicy: WritePolicy = .deny, toolKits: [ToolKit] = []) {
        self.catalog = catalog
        self.stepTimeout = stepTimeout
        self.toolKits = Dictionary(toolKits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.context = RequestContext(requests: requests, secrets: secrets, writePolicy: writePolicy, timeout: stepTimeout)
    }

    /// `onStep` is called as each step finishes (or is skipped), so a caller
    /// keeps what ran even if a later step fails, or shows progress live.
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
            let value = try await runStep(step, scope: &scope)
            scope.results[step.name] = value
            scope.previous = value
        }
        return scope.previous
    }

    private func runStep(_ step: Step, scope: inout Scope) async throws -> Value {
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

        case .request(let request):
            let value = try await context.perform(request, step: step.name, resolve: scope.resolve)
            scope.record(StepRecord(step: step.name, value: value, model: nil, usedFallback: false,
                                            duration: clock.now - start, skipped: false))
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
                        let value = try await self.runStep(child, scope: &local)
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
            for id in kitIDs ?? [] {
                guard let kit = toolKits[id] else {
                    throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(id)” isn't available")
                }
                specs += kit.tools
            }
            let prompt = Self.prompt(for: step.kind, source: source, resolve: scope.resolve)
            let snapshot = scope
            let log = ToolCallLog(limit: AgentTool.maxCallsPerStep)
            let tools: [any Tool] = specs.map {
                RequestTool(spec: $0, step: step.name, context: context, log: log, resolve: { snapshot.resolve($0) })
            }
            var model = primary
            var usedFallback = false
            let value: Value
            do {
                value = try await generate(.prompt(instruction: ""), prompt: prompt, model: primary, tools: tools)
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
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
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }
            scope.record(StepRecord(step: step.name, value: value, model: model, usedFallback: usedFallback,
                                            duration: clock.now - start, skipped: false, toolCalls: log.calls))
            return value

        case .decide(let questions):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            if let problem = Question.problem(in: questions) {
                throw RelayError.stepFailed(step: step.name, reason: problem)
            }
            let text = source.textValue
            do {
                let value = try await decide(questions, about: text, model: primary)
                scope.record(StepRecord(step: step.name, value: value, model: primary, usedFallback: false,
                                                duration: clock.now - start, skipped: false))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                guard let fallback = step.fallback else {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
                do {
                    let value = try await decide(questions, about: text, model: fallback)
                    scope.record(StepRecord(step: step.name, value: value, model: fallback, usedFallback: true,
                                                    duration: clock.now - start, skipped: false))
                    return value
                } catch {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }

        case .prompt, .extract, .classify:
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            let prompt = Self.prompt(for: step.kind, source: source, resolve: scope.resolve)
            do {
                let value = try await generate(step.kind, prompt: prompt, model: primary)
                scope.record(StepRecord(step: step.name, value: value, model: primary, usedFallback: false,
                                                duration: clock.now - start, skipped: false))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                guard let fallback = step.fallback else {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
                // One retry on the fallback model; never more (no retry loops).
                do {
                    let value = try await generate(step.kind, prompt: prompt, model: fallback)
                    scope.record(StepRecord(step: step.name, value: value, model: fallback, usedFallback: true,
                                                    duration: clock.now - start, skipped: false))
                    return value
                } catch {
                    throw RelayError.stepFailed(step: step.name, reason: failureReason(error))
                }
            }
        }
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
        let rendered = Template.render(instruction, resolve)
        // The source text is data, clearly separated from the instruction.
        return instruction.contains("{{") ? rendered : "\(rendered)\n\nInput:\n\(source.textValue)"
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
            return .text(try await session.respond(to: prompt).content)
        }
    }
}
