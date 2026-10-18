import Foundation

extension WorkflowExecutor {
    func runSteps(_ steps: [Step], scope: inout WorkflowExecutionScope) async throws -> Value {
        for step in steps {
            try Task.checkCancellation()
            let value = try await runRecordingFailure(step, scope: &scope)
            scope.accept(value, for: step)
        }

        return scope.previous
    }

    /// Runs a step; if a step that does work itself (not a block) fails, it
    /// gets a record saying why and with what input, then the error goes on.
    func runRecordingFailure(_ step: Step, scope: inout WorkflowExecutionScope) async throws -> Value {
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
                        outcomeUncertain: uncertainOutcome(error)
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

    private func runStep(_ step: Step, scope: inout WorkflowExecutionScope, trace: StepTrace) async throws -> Value {
        let start = clock.now
        let source = try scope.source(for: step)
        var context = self.context
        context.policy = scope.policy
        context.control = scope.control

        let execution: WorkflowStepExecution = .init(
            step: step, source: source, context: context, trace: trace, clock: clock, startedAt: start
        )

        switch step.kind {
        case let .template(template):
            let value = Value.text(Template.render(template, scope.resolve))
            scope.record(execution.record(value))

            return value

        case let .custom(body):
            return try await runCustomStep(body, execution: execution, scope: &scope)

        case .useTool:
            return try await runToolStep(execution, scope: &scope)

        case let .request(request):
            let value = try await context.perform(request, step: step.name, trace: trace, resolve: scope.resolve)
            scope.record(execution.record(value))

            return value

        case .ifEquals:
            return try await runIfStep(execution, scope: &scope)

        case .switchOn:
            return try await runSwitchStep(execution, scope: &scope)

        case .parallel:
            return try await runParallelStep(execution, scope: &scope)

        case .agent:
            return try await runAgentStep(execution, scope: &scope)

        case .decide:
            return try await runDecisionStep(execution, scope: &scope)

        case .readImage:
            return try await runImageStep(execution, scope: &scope)

        case .prompt, .extract, .classify:
            return try await runPromptStep(execution, scope: &scope)
        }
    }

    private func runCustomStep(_ body: CustomStepBody, execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        execution.trace.input = execution.source.textValue
        let values: CustomStepContext = .init(input: execution.source, workflowInput: scope.input, results: scope.results)
        let value: Value

        do {
            value = try await withTimeout(stepTimeout, message: "it ran longer than \(stepTimeout)") {
                try Task.checkCancellation()
                return try await body.call(values)
            }
        } catch {
            try rethrowExecutionControlError(error)
            throw operationFailure(step: execution.step.name, error: error, uncertain: true)
        }

        scope.record(execution.record(value))
        return value
    }
}
