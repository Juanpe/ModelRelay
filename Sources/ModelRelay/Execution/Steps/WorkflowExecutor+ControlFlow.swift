import Foundation

extension WorkflowExecutor {
    func runIfStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        guard case let .ifEquals(reference, expected, then, otherwise) = step.kind else { throw InvalidOutput(reason: "Expected an if step") }

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
    }

    func runSwitchStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        guard case let .switchOn(reference, cases, otherwise) = step.kind else { throw InvalidOutput(reason: "Expected a switch step") }

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
    }

    func runParallelStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        guard case let .parallel(steps) = execution.step.kind else { throw InvalidOutput(reason: "Expected a parallel step") }

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
    }

    private static func flatten(_ step: Step) -> [Step] {
        switch step.kind {
        case let .ifEquals(_, _, then, otherwise): [step] + (then + otherwise).flatMap(flatten)
        case let .switchOn(_, cases, otherwise): [step] + (cases.flatMap(\.steps) + otherwise).flatMap(flatten)
        case let .parallel(steps): [step] + steps.flatMap(flatten)
        default: [step]
        }
    }
}
