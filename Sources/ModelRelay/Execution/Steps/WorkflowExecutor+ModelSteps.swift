import Foundation

extension WorkflowExecutor {
    func runDecisionStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        let source: Value = execution.source
        let trace: StepTrace = execution.trace
        guard case let .decide(questions) = step.kind else { throw InvalidOutput(reason: "Expected a decision step") }

        guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
        if let problem = Question.problem(in: questions) {
            throw RelayError.stepFailed(step: step.name, reason: problem)
        }

        let text = source.modelText
        trace.input = text

        do {
            let value = try await modelRuntime.decide(questions, about: text, model: primary, step: step, scope: scope)
            scope.record(execution.record(value, model: primary))
            return value
        } catch let error as RelayError where error == .unknownModel(primary) {
            throw error
        } catch {
            try rethrowExecutionControlError(error)
            guard let fallback = step.fallback else {
                throw operationFailure(step: step.name, error: error)
            }
            scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
            do {
                let value = try await modelRuntime.decide(questions, about: text, model: fallback, step: step, scope: scope)
                scope.record(execution.record(value, model: fallback, usedFallback: true))
                return value
            } catch {
                try rethrowExecutionControlError(error)
                throw operationFailure(step: step.name, error: error)
            }
        }
    }

    func runImageStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        let source: Value = execution.source
        let trace: StepTrace = execution.trace
        guard case let .readImage(instruction) = step.kind else { throw InvalidOutput(reason: "Expected an image step") }

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
            let value = try await modelRuntime.read(image, instruction: text, model: primary, step: step, scope: scope)
            scope.record(execution.record(value, model: primary))
            return value
        } catch let error as RelayError where error == .unknownModel(primary) {
            throw error
        } catch {
            try rethrowExecutionControlError(error)
            guard let fallback = step.fallback else {
                throw operationFailure(step: step.name, error: error)
            }
            scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
            do {
                let value = try await modelRuntime.read(image, instruction: text, model: fallback, step: step, scope: scope)
                scope.record(execution.record(value, model: fallback, usedFallback: true))
                return value
            } catch {
                try rethrowExecutionControlError(error)
                throw operationFailure(step: step.name, error: error)
            }
        }
    }

    func runPromptStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        let source: Value = execution.source
        let trace: StepTrace = execution.trace

        guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
        let prompt = WorkflowModelRuntime.prompt(for: step.kind, source: source, resolve: scope.resolve)
        trace.input = prompt

        do {
            let value = try await modelRuntime.generate(step.kind, prompt: prompt, model: primary, step: step, scope: scope)
            scope.record(execution.record(value, model: primary))
            return value
        } catch let error as RelayError where error == .unknownModel(primary) {
            throw error
        } catch {
            try rethrowExecutionControlError(error)
            guard let fallback = step.fallback else {
                throw operationFailure(step: step.name, error: error)
            }
            // One retry on the fallback model; never more (no retry loops).
            scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
            do {
                let value = try await modelRuntime.generate(step.kind, prompt: prompt, model: fallback, step: step, scope: scope)
                scope.record(execution.record(value, model: fallback, usedFallback: true))
                return value
            } catch {
                try rethrowExecutionControlError(error)
                throw operationFailure(step: step.name, error: error)
            }
        }
    }
}
