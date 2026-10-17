import AnyLanguageModel
import Foundation
import Synchronization

struct InvalidOutput: Error, CustomStringConvertible {
    var reason: String
    var description: String { reason }
}

public enum RelayError: Error, Equatable, Sendable {
    case unknownModel(ModelID)
    case missingModel(step: String)
    case unknownReference(String, step: String)
    case stepFailed(step: String, reason: String)
    case policyViolation(step: String, reason: String)
    case invalidContext(step: String, reason: String)
    case operationFailed(step: String, failure: WorkflowOperationFailure)
    case limitExceeded(WorkflowExecutionLimit)
    case invalidLimits
    /// A request step ran but the executor has no `RequestPerformer`.
    case requestsUnavailable(step: String)
    /// A request step needs `{{secret.NAME}}` and no secret has that name.
    case missingSecret(String, step: String)
    /// A request that changes something was not allowed by the `WritePolicy`.
    case writeNotAllowed(step: String)
}

/// What one step did: its result, which model produced it and how long it took.
public struct StepRecord: Codable, Sendable, Hashable {
    public var step: String
    public var value: Value
    public var model: ModelID?
    public var usedFallback: Bool
    public var duration: Duration
    public var skipped: Bool
    /// Tools an agent step called, in order (empty for other steps).
    public var toolCalls: [String] = []
    /// Effective data restriction, including selected values and conversation history.
    public var dataAccess: WorkflowExecutionPolicy.DataAccess = .unrestricted
    public var conversation: String? = nil
    /// A host verified an interrupted leaf's result without rerunning it.
    public var recovered: Bool = false
    /// What the step read: the prompt a model was given, the text a decision
    /// was about, or the request it sent with secrets hidden. Nil for steps
    /// that read nothing of their own.
    public var input: String? = nil
    /// Why the step failed. The stream yields this record before throwing.
    public var failure: String? = nil
    public var failureInfo: WorkflowFailureInfo? = nil
}

public struct WorkflowExecutionReport: Sendable {
    public var output: Value
    public var records: [StepRecord]
    public var duration: Duration
    public var outputDataAccess: WorkflowExecutionPolicy.DataAccess = .unrestricted
    public let executionID: UUID
    public let workflowID: UUID
    public let usage: WorkflowExecutionUsage
}

/// Runs workflows. Each `run` is independent; cancelling the calling task
/// cancels the run. Model output is only ever data: it can fill a value, never
/// choose what the executor does next except through an explicit `ifEquals`.
public actor WorkflowExecutor {
    private let catalog: ModelCatalog
    private let stepTimeout: Duration
    private let context: RequestContext
    private let toolKits: [String: ToolKit]
    private let toolServers: (any ToolServerConnector)?
    private let policy: WorkflowExecutionPolicy
    private let limits: WorkflowExecutionLimits
    private let clock = ContinuousClock()

    /// `stepTimeout` bounds one model call or request. Small models occasionally
    /// run away; a call that takes longer counts as a failure (and tries the
    /// fallback model, if any). Request steps need `requests`; those that change
    /// something also need a `writePolicy` that allows them. Custom bodies
    /// use the same cooperative timeout and run once, without fallback.
    /// Tool sets with a server need `toolServers`.
    public init(
        catalog: ModelCatalog = ModelCatalog(),
        stepTimeout: Duration = .seconds(30),
        requests: (any RequestPerformer)? = nil,
        secrets: (any SecretProvider)? = nil,
        writePolicy: WritePolicy = .deny,
        toolKits: [ToolKit] = [],
        toolServers: (any ToolServerConnector)? = nil,
        policy: WorkflowExecutionPolicy = .unrestricted,
        limits: WorkflowExecutionLimits = .unlimited
    ) {
        self.catalog = catalog
        self.policy = policy
        self.limits = limits
        self.stepTimeout = stepTimeout
        self.toolServers = toolServers
        self.toolKits = Dictionary(toolKits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.context = RequestContext(requests: requests, secrets: secrets, writePolicy: writePolicy, timeout: stepTimeout)
    }

    public func run(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy = .unrestricted,
        limits: WorkflowExecutionLimits = .unlimited
    ) async throws -> WorkflowExecutionReport {
        try await runObserved(workflow, input: input, policy: policy, limits: limits, onStep: nil, onEvent: nil)
    }

    /// Starts immediately; consume updates once and await `result` for the report.
    public nonisolated func stream(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy = .unrestricted,
        limits: WorkflowExecutionLimits = .unlimited
    ) -> WorkflowExecutionStream<WorkflowExecutionReport> {
        WorkflowExecutionStream { onStep, onEvent in
            try await self.runObserved(workflow, input: input, policy: policy, limits: limits, onStep: onStep, onEvent: onEvent)
        }
    }

    private func runObserved(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy,
        limits: WorkflowExecutionLimits,
        onStep: (@Sendable (StepRecord) -> Void)?,
        onEvent: (@Sendable (WorkflowExecutionEvent) -> Void)?
    ) async throws -> WorkflowExecutionReport {
        try workflow.validateContexts()
        try workflow.validateApprovals(recoverable: false)
        try preflight(workflow)
        try self.limits.validate(); try limits.validate()

        let control = ExecutionControl(workflowID: workflow.id, limits: self.limits.narrowed(by: limits), observer: onEvent)
        defer { control.finish() }
        control.emit(.executionStarted)

        do {
            let report = try await control.withDeadline {
                try await self.execute(workflow, input: input, policy: policy, control: control, onStep: onStep)
            }
            control.emit(.executionCompleted)

            return report
        } catch {
            control.emit(error is CancellationError ? .executionCancelled : .executionFailed, category: failureCategory(error))
            throw error
        }
    }

    /// Does not load providers, retrieve credentials, or discover remote tools.
    public func validate(_ workflow: Workflow) -> [WorkflowValidationIssue] {
        workflow.validationIssues(catalog: catalog, kits: toolKits)
    }

    private func preflight(_ workflow: Workflow) throws {
        let issues = validate(workflow)
        if !issues.isEmpty { throw WorkflowValidationError(issues: issues) }
    }

    private func execute(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy,
        control: ExecutionControl,
        onStep: (@Sendable (StepRecord) -> Void)?
    ) async throws -> WorkflowExecutionReport {
        let resources = ExecutionResources()
        var scope = Scope(input: input, policy: self.policy.combined(with: policy), resources: resources, control: control, observer: onStep)

        do {
            let last = try await runSteps(workflow.steps, scope: &scope)

            let output: Value
            if let name = workflow.output {
                guard let value = scope.results[name] else { throw RelayError.unknownReference(name, step: "Output") }
                output = value
            } else { output = last }

            await resources.finish()

            return WorkflowExecutionReport(
                output: output,
                records: scope.records,
                duration: control.duration,
                outputDataAccess: workflow.output.flatMap { scope.valuePolicies[$0] } ?? scope.outputData,
                executionID: control.executionID,
                workflowID: workflow.id,
                usage: control.usage
            )
        } catch {
            await resources.finish()
            throw error
        }
    }

    // MARK: - Steps

    fileprivate struct Scope: Sendable {
        var input: Value
        var results: [String: Value] = [:]
        var valuePolicies: [String: WorkflowExecutionPolicy.DataAccess] = [:]
        var previousData: WorkflowExecutionPolicy.DataAccess
        var outputData: WorkflowExecutionPolicy.DataAccess
        let inputData: WorkflowExecutionPolicy.DataAccess
        var policy: WorkflowExecutionPolicy
        var currentContext: StepContext?
        let resources: ExecutionResources
        let control: ExecutionControl
        var records: [StepRecord] = []
        var previous: Value
        let observer: (@Sendable (StepRecord) -> Void)?

        init(
            input: Value,
            policy: WorkflowExecutionPolicy,
            resources: ExecutionResources,
            control: ExecutionControl,
            observer: (@Sendable (StepRecord) -> Void)? = nil
        ) {
            self.input = input
            self.policy = policy
            self.resources = resources
            self.control = control
            self.inputData = policy.data
            self.previousData = policy.data
            self.outputData = policy.data
            self.previous = input
            self.observer = observer
        }

        mutating func record(_ record: StepRecord) {
            var record = record
            record.dataAccess = outputData
            if case let .conversation(name) = currentContext { record.conversation = name }
            records.append(record)
            observer?(record)
            if record.skipped { control.emit(.stepSkipped, step: record.step) }
        }

        func dataPolicy(for reference: String) -> WorkflowExecutionPolicy.DataAccess {
            let base = reference.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            return base == "input" ? inputData : valuePolicies[base] ?? .unrestricted
        }

        func source(for step: Step) throws -> Value {
            if case let .handoff(references) = step.context {
                var values: [String: Value] = [:]
                for reference in references {
                    guard let value = resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
                    values[reference] = value
                }
                return .dictionary(values)
            }

            if let reference = step.input {
                guard let value = resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
                return value
            }

            return previous
        }

        /// `input`, `step` or `step.field`.
        func resolve(_ reference: String) -> Value? {
            let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
            guard let name = parts.first else { return nil }

            let base = name == "input" ? input : results[name]
            guard let base else { return nil }

            return parts.count == 2 ? base[parts[1]] : base
        }
    }

    private func runSteps(_ steps: [Step], scope: inout Scope) async throws -> Value {
        for step in steps {
            try Task.checkCancellation()
            let value = try await runRecordingFailure(step, scope: &scope)
            scope.accept(value, for: step)
        }

        return scope.previous
    }

    /// Runs a step; if a step that does work itself (not a block) fails, it
    /// gets a record saying why and with what input, then the error goes on.
    private func runRecordingFailure(_ step: Step, scope: inout Scope) async throws -> Value {
        let start = clock.now
        let trace = StepTrace()
        let inherited = scope.policy
        let previousContext = scope.currentContext
        defer { scope.policy = inherited; scope.currentContext = previousContext }

        let leaf = !Self.isBlock(step)
        if leaf { try await scope.control.acquire() }
        scope.control.emit(.stepStarted, step: step.name)

        do {
            try scope.control.check()
            for (template, secrets, arguments) in Workflow.templates(in: step) {
                for ref in Template.references(in: template) where !(secrets && ref.hasPrefix("secret.")) && !(arguments && ref.hasPrefix("args.")) {
                    guard scope.resolve(ref) != nil else { throw RelayError.unknownReference(ref, step: step.name) }
                }
            }

            scope.policy = await effectivePolicy(for: step, scope: scope)
            try Task.checkCancellation()
            scope.currentContext = step.context
            scope.outputData = scope.policy.data

            let value = try await runStep(step, scope: &scope, trace: trace)

            scope.control.emit(.stepCompleted, step: step.name)
            if leaf { await scope.control.release() }
            return value
        } catch is CancellationError {
            if leaf { await scope.control.release() }
            throw CancellationError()
        } catch {
            if !Self.isBlock(step) {
                scope.record(StepRecord(
                    step: step.name,
                    value: .null,
                    model: step.model,
                    usedFallback: false,
                    duration: clock.now - start,
                    skipped: false,
                    input: trace.input,
                    failure: failureReason(error),
                    failureInfo: .init(
                        category: failureCategory(error),
                        message: failureReason(error),
                        outcomeUncertain: Self.uncertain(error)
                    )
                ))
            }
            scope.control.emit(.stepFailed, step: step.name, category: failureCategory(error))
            if leaf { await scope.control.release() }
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
        let source = try scope.source(for: step)
        var context = self.context
        context.policy = scope.policy
        context.control = scope.control

        switch step.kind {
        case let .template(template):
            let value = Value.text(Template.render(template, scope.resolve))
            scope.record(StepRecord(
                step: step.name,
                value: value,
                model: nil,
                usedFallback: false,
                duration: clock.now - start,
                skipped: false
            ))
            return value

        case let .custom(body):
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
                throw operationFailure(step: step.name, error: error, uncertain: true)
            }
            scope.record(StepRecord(
                step: step.name,
                value: value,
                model: nil,
                usedFallback: false,
                duration: clock.now - start,
                skipped: false,
                input: trace.input
            ))

            return value

        case let .useTool(kitID, toolName, arguments):
            guard let kit = toolKits[kitID] else {
                throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(kitID)” isn't available")
            }
            let rendered = arguments.mapValues { Template.render($0, scope.resolve) }
            let value: Value
            if kit.server != nil {
                let connection = try await connect(kit, step: step.name, policy: scope.policy)
                guard let tool = try await serverTools(kit, connection, step: step.name).first(where: { $0.name == toolName }) else {
                    throw RelayError.stepFailed(step: step.name, reason: "\(kit.name) has no tool “\(toolName)”")
                }
                let typed = ServerArguments.typed(rendered, for: tool)
                let call = ServerCallDescription.prepared(kit: kit, tool: tool.name, arguments: typed)
                trace.input = call.description
                try scope.policy.checkTool(changesSomething: tool.changesSomething, step: step.name)
                try scope.control.beginTool(tool.name, step: step.name)
                var dispatched = false
                do {
                    if tool.changesSomething { try await context.authorize(call, step: step.name) }
                    dispatched = true
                    // One attempt only, like a request: the call may have happened.
                    value = try await withTimeout(stepTimeout) { try await connection.call(tool.name, arguments: typed) }
                    scope.control.emit(.toolCompleted, step: step.name, tool: tool.name)
                } catch is CancellationError {
                    scope.control.emit(.toolFailed, step: step.name, tool: tool.name)
                    throw CancellationError()
                } catch {
                    scope.control.emit(.toolFailed, step: step.name, tool: tool.name, category: failureCategory(error))
                    try Self.rethrowCancellation(error)
                    throw operationFailure(step: step.name, error: error, uncertain: dispatched && tool.changesSomething)
                }
            } else {
                guard let spec = kit.tools.first(where: { $0.name == toolName }) else {
                    throw RelayError.stepFailed(step: step.name, reason: "\(kit.name) has no tool “\(toolName)”")
                }
                value = try await context.perform(spec.request, step: step.name, trace: trace, toolName: spec.name) { reference in
                    if reference.hasPrefix("args.") { return rendered[String(reference.dropFirst("args.".count))].map(Value.text) }
                    return scope.resolve(reference)
                }
            }
            scope.record(StepRecord(
                step: step.name,
                value: value,
                model: nil,
                usedFallback: false,
                duration: clock.now - start,
                skipped: false,
                input: trace.input
            ))
            return value

        case let .request(request):
            let value = try await context.perform(request, step: step.name, trace: trace, resolve: scope.resolve)
            scope.record(StepRecord(
                step: step.name,
                value: value,
                model: nil,
                usedFallback: false,
                duration: clock.now - start,
                skipped: false,
                input: trace.input
            ))
            return value

        case let .ifEquals(reference, expected, then, otherwise):
            guard let value = scope.resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
            let branch = value.textValue == expected ? then : otherwise
            let skipped = value.textValue == expected ? otherwise : then
            for step in skipped.flatMap(Self.flatten) {
                scope.record(StepRecord(
                    step: step.name,
                    value: .null,
                    model: nil,
                    usedFallback: false,
                    duration: .zero,
                    skipped: true
                ))
            }
            return try await runSteps(branch, scope: &scope)

        case let .switchOn(reference, cases, otherwise):
            guard let value = scope.resolve(reference) else { throw RelayError.unknownReference(reference, step: step.name) }
            let key = value.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = cases.firstIndex { $0.value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame }
            let branch = chosen.map { cases[$0].steps } ?? otherwise
            var skipped = otherwise
            for (index, item) in cases.enumerated() where index != chosen {
                skipped += item.steps
            }
            if chosen == nil { skipped = cases.flatMap(\.steps) }
            for step in skipped.flatMap(Self.flatten) {
                scope.record(StepRecord(
                    step: step.name,
                    value: .null,
                    model: nil,
                    usedFallback: false,
                    duration: .zero,
                    skipped: true
                ))
            }
            return try await runSteps(branch, scope: &scope)

        case let .parallel(steps):
            let snapshot = scope
            let results = try await withThrowingTaskGroup(of: (Int, Value, [StepRecord], WorkflowExecutionPolicy.DataAccess).self) { group in
                for (index, child) in steps.enumerated() {
                    group.addTask {
                        var local = snapshot
                        local.records = []
                        let value = try await self.runRecordingFailure(child, scope: &local)
                        return (index, value, local.records, local.outputData)
                    }
                }
                var collected: [(Int, Value, [StepRecord], WorkflowExecutionPolicy.DataAccess)] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.0 < $1.0 }
            }
            var merged: [String: Value] = [:]
            for (index, value, records, data) in results {
                merged[steps[index].name] = value
                scope.results[steps[index].name] = value
                scope.valuePolicies[steps[index].name] = data
                scope.outputData = scope.outputData.combined(with: data)
                scope.records += records
            }
            return .dictionary(merged)

        case let .agent(_, ownTools, kitIDs):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            var specs = ownTools
            var servers: [(ToolKit, any ToolServerConnection, [ServerTool])] = []
            for id in scope.policy.tools == .denied ? [] : kitIDs ?? [] {
                guard let kit = toolKits[id] else {
                    throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(id)” isn't available")
                }
                if kit.server != nil {
                    let connection = try await connect(kit, step: step.name, policy: scope.policy)
                    servers.append((kit, connection, try await serverTools(kit, connection, step: step.name)))
                } else {
                    specs += kit.tools
                }
            }
            let prompt = Self.prompt(for: step.kind, source: source, resolve: scope.resolve)
            trace.input = prompt
            let snapshot = scope
            let log = ToolCallLog(limit: AgentTool.maxCallsPerStep)
            defer { log.finish() }
            specs = specs.filter { scope.policy.data != .localOnly && scope.policy.allowsTool(changesSomething: $0.request.method.isWrite) }
            var tools: [any Tool] = specs.map {
                RequestTool(spec: $0, step: step.name, context: context, log: log, resolve: { snapshot.resolve($0) })
            }
            for (kit, connection, list) in servers {
                tools += list.filter { scope.policy.allowsTool(changesSomething: $0.changesSomething) }.map { ServerToolCall(
                    tool: $0,
                    kit: kit,
                    connection: connection,
                    step: step.name,
                    context: context,
                    log: log
                ) }
            }
            var model = primary
            var usedFallback = false
            let value: Value
            do {
                value = try await generate(.prompt(instruction: ""), prompt: prompt, model: primary, tools: tools, step: step, scope: scope)
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                // A tool may already have changed something: only retry on the
                // fallback model when no tool was called.
                guard let fallback = step.fallback, log.calls.isEmpty else {
                    throw operationFailure(step: step.name, error: error, uncertain: log.mayHaveWritten)
                }
                scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
                do {
                    value = try await generate(.prompt(instruction: ""), prompt: prompt, model: fallback, tools: tools, step: step, scope: scope)
                    model = fallback
                    usedFallback = true
                } catch {
                    try Self.rethrowCancellation(error)
                    throw operationFailure(step: step.name, error: error, uncertain: log.mayHaveWritten)
                }
            }
            scope.record(StepRecord(
                step: step.name,
                value: value,
                model: model,
                usedFallback: usedFallback,
                duration: clock.now - start,
                skipped: false,
                toolCalls: log.calls,
                input: prompt
            ))
            return value

        case let .decide(questions):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            if let problem = Question.problem(in: questions) {
                throw RelayError.stepFailed(step: step.name, reason: problem)
            }
            let text = source.modelText
            trace.input = text
            do {
                let value = try await decide(questions, about: text, model: primary, step: step, scope: scope)
                scope.record(StepRecord(
                    step: step.name,
                    value: value,
                    model: primary,
                    usedFallback: false,
                    duration: clock.now - start,
                    skipped: false,
                    input: text
                ))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                guard let fallback = step.fallback else {
                    throw operationFailure(step: step.name, error: error)
                }
                scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
                do {
                    let value = try await decide(questions, about: text, model: fallback, step: step, scope: scope)
                    scope.record(StepRecord(
                        step: step.name,
                        value: value,
                        model: fallback,
                        usedFallback: true,
                        duration: clock.now - start,
                        skipped: false,
                        input: text
                    ))
                    return value
                } catch {
                    try Self.rethrowCancellation(error)
                    throw operationFailure(step: step.name, error: error)
                }
            }

        case let .readImage(instruction):
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            guard case let .image(image) = source else {
                throw RelayError.stepFailed(step: step.name, reason: "it needs an image, and got \(source.kindName)")
            }
            let text = Template.render(
                instruction.isEmpty ? ImageReading.defaultInstruction : instruction,
                scope.resolve,
                text: \.modelText
            )
            // The picture itself is never kept: the trace says what it was.
            let input = "\(text)\n\n[\(ImageReading.describe(image))]"
            trace.input = input
            do {
                let value = try await read(image, instruction: text, model: primary, step: step, scope: scope)
                scope.record(StepRecord(
                    step: step.name,
                    value: value,
                    model: primary,
                    usedFallback: false,
                    duration: clock.now - start,
                    skipped: false,
                    input: input
                ))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                guard let fallback = step.fallback else {
                    throw operationFailure(step: step.name, error: error)
                }
                scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
                do {
                    let value = try await read(image, instruction: text, model: fallback, step: step, scope: scope)
                    scope.record(StepRecord(
                        step: step.name,
                        value: value,
                        model: fallback,
                        usedFallback: true,
                        duration: clock.now - start,
                        skipped: false,
                        input: input
                    ))
                    return value
                } catch {
                    try Self.rethrowCancellation(error)
                    throw operationFailure(step: step.name, error: error)
                }
            }

        case .prompt, .extract, .classify:
            guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
            let prompt = Self.prompt(for: step.kind, source: source, resolve: scope.resolve)
            trace.input = prompt
            do {
                let value = try await generate(step.kind, prompt: prompt, model: primary, step: step, scope: scope)
                scope.record(StepRecord(
                    step: step.name,
                    value: value,
                    model: primary,
                    usedFallback: false,
                    duration: clock.now - start,
                    skipped: false,
                    input: prompt
                ))
                return value
            } catch let error as RelayError where error == .unknownModel(primary) {
                throw error
            } catch {
                try Self.rethrowCancellation(error)
                guard let fallback = step.fallback else {
                    throw operationFailure(step: step.name, error: error)
                }
                // One retry on the fallback model; never more (no retry loops).
                scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
                do {
                    let value = try await generate(step.kind, prompt: prompt, model: fallback, step: step, scope: scope)
                    scope.record(StepRecord(
                        step: step.name,
                        value: value,
                        model: fallback,
                        usedFallback: true,
                        duration: clock.now - start,
                        skipped: false,
                        input: prompt
                    ))
                    return value
                } catch {
                    try Self.rethrowCancellation(error)
                    throw operationFailure(step: step.name, error: error)
                }
            }
        }
    }

    private func effectivePolicy(for step: Step, scope: Scope) async -> WorkflowExecutionPolicy {
        var policy = scope.policy.combined(with: step.policy ?? .unrestricted)
        var references = Workflow.templates(in: step).flatMap { Template.references(in: $0.0) }
        if case let .handoff(values) = step.context { references += values }
        else if let input = step.input { references.append(input) }
        else { policy.data = policy.data.combined(with: scope.previousData) }
        switch step.kind {
        case let .ifEquals(value, _, _, _), let .switchOn(value, _, _): references.append(value)
        case .custom:
            // Custom bodies can read every result and the original input.
            policy.data = policy.data.combined(with: scope.inputData)
            for value in scope.valuePolicies.values {
                policy.data = policy.data.combined(with: value)
            }
        case let .agent(_, _, kits):
            for id in kits ?? [] {
                for tool in toolKits[id]?.tools ?? [] {
                    references += ([tool.request.url, tool.request.body ?? ""] + tool.request.headers.map(\.value))
                        .flatMap { Template.references(in: $0) }
                }
            }
        case let .useTool(kitID, toolName, _):
            if let tool = toolKits[kitID]?.tools.first(where: { $0.name == toolName }) {
                references += ([tool.request.url, tool.request.body ?? ""] + tool.request.headers.map(\.value))
                    .flatMap { Template.references(in: $0) }
            }
        default: break
        }
        for reference in references {
            policy.data = policy.data.combined(with: scope.dataPolicy(for: reference))
        }
        let history = await scope.resources.historyPolicy(step.context, models: [step.model, step.fallback].compactMap { $0 })
        policy.data = policy.data.combined(with: history)
        return policy
    }

    /// Cancellation is control flow, never a model failure to retry. Some
    /// providers wrap it, so also check the calling task's cancellation state.
    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if case RelayError.policyViolation = error { throw error }
        if case RelayError.invalidContext = error { throw error }
        if case RelayError.writeNotAllowed = error { throw error }
        if case RelayError.limitExceeded = error { throw error }
        if let tool = error as? LanguageModelSession.ToolCallError { try rethrowCancellation(tool.underlyingError) }
        if case let RelayError.operationFailed(_, failure) = error { try rethrowCancellation(failure.underlyingError) }
    }

    private static func uncertain(_ error: any Error) -> Bool {
        if case let RelayError.operationFailed(_, failure) = error { return failure.info.outcomeUncertain }
        if let tool = error as? LanguageModelSession.ToolCallError { return uncertain(tool.underlyingError) }
        return false
    }

    private static func flatten(_ step: Step) -> [Step] {
        switch step.kind {
        case let .ifEquals(_, _, then, otherwise): [step] + (then + otherwise).flatMap(flatten)
        case let .switchOn(_, cases, otherwise): [step] + (cases.flatMap(\.steps) + otherwise).flatMap(flatten)
        case let .parallel(steps): [step] + steps.flatMap(flatten)
        default: [step]
        }
    }

    private static func prompt(for kind: Step.Kind, source: Value, resolve: (String) -> Value?) -> String {
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

    private func decide(
        _ questions: [Question],
        about text: String,
        model id: ModelID,
        step: Step,
        scope: Scope
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
                    guard let decisions = try await resources.decisionModel(id, catalog: self.catalog) else { throw RelayError.unknownModel(id) }
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

    /// Opens a connection to a tool set's server.
    private func connect(_ kit: ToolKit, step: String, policy: WorkflowExecutionPolicy) async throws -> any ToolServerConnection {
        try policy.checkNetwork(step: step)
        try policy.checkTool(changesSomething: false, step: step)
        guard let toolServers else { throw RelayError.stepFailed(step: step, reason: "tool servers can't be reached here") }

        do {
            return try await withTimeout(stepTimeout) { try await toolServers.connect(to: kit) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw operationFailure(step: step, error: error)
        }
    }

    private func serverTools(_ kit: ToolKit, _ connection: any ToolServerConnection, step: String) async throws -> [ServerTool] {
        do {
            return try await withTimeout(stepTimeout) { try await connection.tools() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw operationFailure(step: step, error: error)
        }
    }

    /// Shows the image and the instruction to a model that can see images.
    private func read(
        _ image: ImageValue,
        instruction: String,
        model id: ModelID,
        step: Step,
        scope: Scope
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

    private func generate(
        _ kind: Step.Kind,
        prompt: String,
        model id: ModelID,
        tools: [any Tool] = [],
        step: Step,
        scope: Scope
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
        scope: Scope,
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

extension WorkflowExecutor {
    /// Starts a recoverable run. The host supplies durable, atomic CAS storage;
    /// ModelRelay stores no files. Keep `workflow.id` and `revision` stable for
    /// resume, and change the revision when executable dependencies change.
    /// A checkpoint is saved BEFORE every top-level step and AFTER it finishes.
    public func start(
        _ workflow: Workflow,
        input: Value,
        revision: String,
        policy: WorkflowExecutionPolicy = .unrestricted,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits = .unlimited
    ) async throws -> WorkflowExecutionOutcome {
        try await startObserved(
            workflow,
            input: input,
            revision: revision,
            policy: policy,
            store: store,
            limits: limits,
            onStep: nil,
            onEvent: nil
        )
    }

    /// Streams a recoverable start; the result may pause for approval.
    public nonisolated func startStream(
        _ workflow: Workflow,
        input: Value,
        revision: String,
        policy: WorkflowExecutionPolicy = .unrestricted,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits = .unlimited
    ) -> WorkflowExecutionStream<WorkflowExecutionOutcome> {
        WorkflowExecutionStream { onStep, onEvent in
            try await self.startObserved(
                workflow,
                input: input,
                revision: revision,
                policy: policy,
                store: store,
                limits: limits,
                onStep: onStep,
                onEvent: onEvent
            )
        }
    }

    private func startObserved(
        _ workflow: Workflow,
        input: Value,
        revision: String,
        policy: WorkflowExecutionPolicy,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits,
        onStep: (@Sendable (StepRecord) -> Void)?,
        onEvent: (@Sendable (WorkflowExecutionEvent) -> Void)?
    ) async throws -> WorkflowExecutionOutcome {
        let definition = try recoveryDefinition(workflow, revision: revision)
        let policy = self.policy.combined(with: policy)
        try self.limits.validate(); try limits.validate()

        let control = ExecutionControl(workflowID: workflow.id, limits: self.limits.narrowed(by: limits), observer: onEvent)
        defer { control.finish() }

        let resources = ExecutionResources()
        let scope = Scope(input: input, policy: policy, resources: resources, control: control, observer: onStep)
        let checkpoint = WorkflowExecutionCheckpoint(
            workflow: workflow,
            revision: revision,
            definition: definition,
            policy: policy,
            limits: control.limits,
            executionID: control.executionID,
            state: scope.saved(conversations: [], duration: .zero)
        )

        try Task.checkCancellation()
        control.emit(.executionStarted)

        do {
            return try await control.withDeadline {
                try await store.save(checkpoint, replacing: nil)
                control.emit(.checkpointSaved, generation: checkpoint.generation)
                return try await self.advance(
                    workflow,
                    checkpoint: checkpoint,
                    approval: nil,
                    policy: policy,
                    store: store,
                    control: control,
                    onStep: onStep
                )
            }
        } catch {
            control.emit(error is CancellationError ? .executionCancelled : .executionFailed, category: failureCategory(error))
            throw error
        }
    }

    /// Resumes confirmed work without replaying it. Recreates model resources
    /// lazily and restores native history only to the same model ID. An in-flight
    /// checkpoint is ambiguous, even after an error/cancellation: never retry it
    /// automatically. Approval applies only to this checkpoint's current gate.
    public func resume(
        _ workflow: Workflow,
        from checkpoint: WorkflowExecutionCheckpoint,
        revision: String,
        approval: ApprovalDecision? = nil,
        policy: WorkflowExecutionPolicy = .unrestricted,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits = .unlimited
    ) async throws -> WorkflowExecutionOutcome {
        try await resumeObserved(
            workflow,
            from: checkpoint,
            revision: revision,
            approval: approval,
            policy: policy,
            store: store,
            limits: limits,
            onStep: nil,
            onEvent: nil
        )
    }

    /// Streams a resume without replaying confirmed step records.
    public nonisolated func resumeStream(
        _ workflow: Workflow,
        from checkpoint: WorkflowExecutionCheckpoint,
        revision: String,
        approval: ApprovalDecision? = nil,
        policy: WorkflowExecutionPolicy = .unrestricted,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits = .unlimited
    ) -> WorkflowExecutionStream<WorkflowExecutionOutcome> {
        WorkflowExecutionStream { onStep, onEvent in
            try await self.resumeObserved(
                workflow,
                from: checkpoint,
                revision: revision,
                approval: approval,
                policy: policy,
                store: store,
                limits: limits,
                onStep: onStep,
                onEvent: onEvent
            )
        }
    }

    private func resumeObserved(
        _ workflow: Workflow,
        from checkpoint: WorkflowExecutionCheckpoint,
        revision: String,
        approval: ApprovalDecision?,
        policy: WorkflowExecutionPolicy,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits,
        onStep: (@Sendable (StepRecord) -> Void)?,
        onEvent: (@Sendable (WorkflowExecutionEvent) -> Void)?
    ) async throws -> WorkflowExecutionOutcome {
        try validate(checkpoint, workflow: workflow, revision: revision)
        if checkpoint.status == .running { throw RecoveryError.interrupted(step: workflow.steps[checkpoint.nextStep].name) }
        if approval != nil, checkpoint.status != .awaitingApproval {
            throw RecoveryError.invalidCheckpoint("there is no pending approval")
        }
        try self.limits.validate(); try limits.validate(); try checkpoint.limits.validate()

        let control = ExecutionControl(
            workflowID: workflow.id,
            executionID: checkpoint.executionID,
            limits: checkpoint.limits.narrowed(by: self.limits).narrowed(by: limits),
            usage: checkpoint.usage,
            duration: checkpoint.state.duration,
            observer: onEvent
        )
        defer { control.finish() }
        control.emit(.executionResumed)

        let operation: @Sendable () async throws -> WorkflowExecutionOutcome = {
            try await self.advance(
                workflow,
                checkpoint: checkpoint,
                approval: approval,
                policy: self.policy.combined(with: policy),
                store: store,
                control: control,
                onStep: onStep
            )
        }

        do {
            // Reading terminal/pending state or rejecting does not perform work.
            if checkpoint.status == .completed || checkpoint.status == .rejected ||
                (checkpoint.status == .awaitingApproval && approval != .approve) { return try await operation() }
            return try await control.withDeadline(operation)
        } catch {
            control.emit(error is CancellationError ? .executionCancelled : .executionFailed, category: failureCategory(error))
            throw error
        }
    }

    /// After independently verifying an interrupted LEAF operation, the host can
    /// supply its result without rerunning it. Does not perform a request or grant
    /// permissions. Blocks/model steps cannot be reconciled this way: their child
    /// results/native transcript cannot be reconstructed from one value.
    /// The host must first stop/fence the original worker; a running checkpoint
    /// alone does not establish that the worker has died.
    public func confirmCompletion(
        _ checkpoint: WorkflowExecutionCheckpoint,
        in workflow: Workflow,
        revision: String,
        value: Value,
        dataAccess: WorkflowExecutionPolicy.DataAccess = .unrestricted,
        elapsed: Duration? = nil,
        store: any WorkflowExecutionCheckpointStore
    ) async throws -> WorkflowExecutionCheckpoint {
        try validate(checkpoint, workflow: workflow, revision: revision)
        guard checkpoint.status == .running else {
            throw RecoveryError.invalidCheckpoint("only an interrupted step can be reconciled")
        }

        let step = workflow.steps[checkpoint.nextStep]
        switch step.kind {
        case .request, .useTool, .custom, .template: break
        default: throw RecoveryError.unsupported("blocks and model steps require reconciliation outside this run")
        }

        let resources = ExecutionResources(conversations: checkpoint.state.conversations)
        let policy = checkpoint.policy.combined(with: self.policy)
        try self.limits.validate(); try checkpoint.limits.validate()
        let limits = checkpoint.limits.narrowed(by: self.limits)
        guard elapsed.map({ $0 >= .zero }) ?? true else { throw RecoveryError.invalidCheckpoint("negative reconciliation duration") }
        if limits.maxDuration != nil, elapsed == nil {
            throw RecoveryError.unsupported("reconciling a duration-limited execution requires the interrupted attempt's elapsed duration")
        }
        let duration = checkpoint.state.duration + (elapsed ?? .zero)
        let control = ExecutionControl(
            workflowID: workflow.id,
            executionID: checkpoint.executionID,
            limits: limits,
            usage: checkpoint.usage,
            duration: duration,
            observer: nil
        )
        switch step.kind {
        case .request, .useTool: control.accountReconciledTool()
        default: break
        }
        var scope = Scope(saved: checkpoint.state, policy: policy, resources: resources, control: control, observer: nil)
        scope.outputData = await effectivePolicy(for: step, scope: scope).data.combined(with: dataAccess)
        var record = StepRecord(step: step.name, value: value, model: nil, usedFallback: false, duration: .zero, skipped: false)
        record.recovered = true
        scope.record(record)
        scope.accept(value, for: step)
        var next = checkpoint
        next.policy = policy
        next.limits = control.limits
        next.nextStep += 1
        next.step = workflow.steps.dropFirst(next.nextStep).first?.name
        next.status = next.nextStep == workflow.steps.count ? .completed : .ready
        next.approval = nil
        next.state = scope.saved(conversations: checkpoint.state.conversations, duration: duration)
        await resources.finish()
        return try await save(next, after: checkpoint, store: store)
    }

    private func recoveryDefinition(_ workflow: Workflow, revision: String) throws -> String {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecoveryError.invalidCheckpoint("a nonempty host revision is required")
        }
        try workflow.validateContexts()
        try workflow.validateApprovals(recoverable: true)
        try preflight(workflow)
        return try workflow.recoveryDefinition(kits: Array(toolKits.values))
    }

    private func validate(_ checkpoint: WorkflowExecutionCheckpoint, workflow: Workflow, revision: String) throws {
        let definition = try recoveryDefinition(workflow, revision: revision)
        guard checkpoint.schemaVersion == 2, checkpoint.generation >= 0,
              (0 ... workflow.steps.count).contains(checkpoint.nextStep),
              checkpoint.state.duration >= .zero, checkpoint.usage.modelCalls >= 0, checkpoint.usage.toolCalls >= 0
        else {
            throw RecoveryError.invalidCheckpoint("unsupported version or invalid position")
        }
        guard checkpoint.revision == revision else { throw RecoveryError.revisionMismatch }
        guard checkpoint.workflowID == workflow.id, checkpoint.definition == definition else {
            throw RecoveryError.definitionChanged
        }
        let expected = workflow.steps.dropFirst(checkpoint.nextStep).first?.name
        guard checkpoint.step == expected else { throw RecoveryError.invalidCheckpoint("step position does not match") }
        switch checkpoint.status {
        case .completed:
            guard checkpoint.nextStep == workflow.steps.count else { throw RecoveryError.invalidCheckpoint("incomplete result") }
        case .running, .rejected, .awaitingApproval:
            guard checkpoint.nextStep < workflow.steps.count else { throw RecoveryError.invalidCheckpoint("missing current step") }
            if checkpoint.status == .awaitingApproval, workflow.steps[checkpoint.nextStep].approval == nil {
                throw RecoveryError.invalidCheckpoint("missing approval gate")
            }
        case .ready: break
        }
        // A decoded checkpoint is trusted data, but reject duplicate native lanes
        // rather than silently selecting one history during restoration.
        let lanes = checkpoint.state.conversations.map { ExecutionResources.Key(name: $0.name, model: $0.model) }
        guard Set(lanes).count == lanes.count else { throw RecoveryError.invalidCheckpoint("duplicate conversation history") }
    }

    private func save(
        _ next: WorkflowExecutionCheckpoint,
        after previous: WorkflowExecutionCheckpoint,
        store: any WorkflowExecutionCheckpointStore,
        control: ExecutionControl? = nil
    ) async throws -> WorkflowExecutionCheckpoint {
        guard previous.generation < Int.max else { throw RecoveryError.invalidCheckpoint("generation overflow") }
        var next = next
        next.generation = previous.generation + 1
        if let control { next.state.duration = max(next.state.duration, control.duration) }

        try await store.save(next, replacing: previous.generation)
        control?.emit(.checkpointSaved, generation: next.generation)

        return next
    }

    private func advance(
        _ workflow: Workflow,
        checkpoint initial: WorkflowExecutionCheckpoint,
        approval: ApprovalDecision?,
        policy: WorkflowExecutionPolicy,
        store: any WorkflowExecutionCheckpointStore,
        control: ExecutionControl,
        onStep: (@Sendable (StepRecord) -> Void)?
    ) async throws -> WorkflowExecutionOutcome {
        var checkpoint = initial
        checkpoint.policy = checkpoint.policy.combined(with: policy)
        checkpoint.limits = control.limits

        if checkpoint.status == .completed {
            let report = try Self.report(workflow, checkpoint: checkpoint)
            control.emit(.executionCompleted)
            return .completed(report)
        }

        if checkpoint.status == .rejected { control.emit(.approvalRejected, step: checkpoint.step); return .rejected(checkpoint) }

        if checkpoint.status == .awaitingApproval {
            guard let approval else {
                if checkpoint.policy != initial.policy || checkpoint.limits != initial.limits {
                    checkpoint = try await save(checkpoint, after: initial, store: store, control: control)
                }
                control.emit(.approvalRequired, step: checkpoint.step)
                return .awaitingApproval(checkpoint)
            }

            if approval == .reject {
                var next = checkpoint
                next.status = .rejected
                let saved = try await save(next, after: checkpoint, store: store, control: control)
                control.emit(.approvalRejected, step: checkpoint.step)
                return .rejected(saved)
            }
        }

        let resources = ExecutionResources(conversations: checkpoint.state.conversations)
        var scope = Scope(saved: checkpoint.state, policy: checkpoint.policy, resources: resources, control: control, observer: onStep)
        var approved = checkpoint.status == .awaitingApproval && approval == .approve

        do {
            while checkpoint.nextStep < workflow.steps.count {
                try control.check()
                let step = workflow.steps[checkpoint.nextStep]
                if let reason = step.approval, !approved {
                    var next = checkpoint
                    next.status = .awaitingApproval
                    next.approval = reason
                    checkpoint = try await save(next, after: checkpoint, store: store, control: control)
                    control.emit(.approvalRequired, step: step.name)
                    await resources.finish()
                    return .awaitingApproval(checkpoint)
                }

                approved = false
                var running = checkpoint
                running.status = .running
                running.approval = nil
                checkpoint = try await save(running, after: checkpoint, store: store, control: control)

                // The claim above MUST be committed before any user/provider code.
                try Task.checkCancellation()
                let value = try await runRecordingFailure(step, scope: &scope)
                scope.accept(value, for: step)

                var next = checkpoint
                next.nextStep += 1
                next.step = workflow.steps.dropFirst(next.nextStep).first?.name
                next.status = next.nextStep == workflow.steps.count ? .completed : .ready
                next.state = scope.saved(conversations: await resources.snapshot(), duration: control.duration)
                checkpoint = try await save(next, after: checkpoint, store: store, control: control)
            }

            if checkpoint.status != .completed {
                var next = checkpoint
                next.status = .completed
                checkpoint = try await save(next, after: checkpoint, store: store, control: control)
            }

            await resources.finish()

            let report = try Self.report(workflow, checkpoint: checkpoint)
            control.emit(.executionCompleted)
            return .completed(report)
        } catch {
            // Never overwrite the durable running marker after a failure. Even a
            // transport error, timeout or failed post-step save is ambiguous.
            await resources.finish()
            throw error
        }
    }

    private static func report(_ workflow: Workflow, checkpoint: WorkflowExecutionCheckpoint) throws -> WorkflowExecutionReport {
        let state = checkpoint.state
        let output: Value
        if let name = workflow.output {
            guard let value = state.results[name] else { throw RelayError.unknownReference(name, step: "Output") }
            output = value
        } else { output = state.previous }

        return WorkflowExecutionReport(
            output: output,
            records: state.records,
            duration: state.duration,
            outputDataAccess: (workflow.output.flatMap { state.valuePolicies[$0] } ?? state.outputData).combined(with: checkpoint.policy.data),
            executionID: checkpoint.executionID,
            workflowID: workflow.id,
            usage: state.usage
        )
    }
}

private extension WorkflowExecutor.Scope {
    init(
        saved: CheckpointValues,
        policy: WorkflowExecutionPolicy,
        resources: ExecutionResources,
        control: ExecutionControl,
        observer: (@Sendable (StepRecord) -> Void)?
    ) {
        input = saved.input
        results = saved.results
        valuePolicies = saved.valuePolicies
        previous = saved.previous
        previousData = saved.previousData
        outputData = saved.outputData
        inputData = saved.inputData
        records = saved.records
        self.policy = policy
        self.resources = resources
        self.control = control
        self.observer = observer
    }

    func saved(conversations: [CheckpointConversation], duration: Duration) -> CheckpointValues {
        CheckpointValues(
            input: input,
            results: results,
            valuePolicies: valuePolicies,
            previous: previous,
            previousData: previousData,
            outputData: outputData,
            inputData: inputData,
            records: records,
            conversations: conversations,
            duration: duration,
            usage: control.usage
        )
    }

    mutating func accept(_ value: Value, for step: Step) {
        results[step.name] = value
        valuePolicies[step.name] = outputData
        previousData = outputData
        previous = value
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
        case let .list(item):
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
