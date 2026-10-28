import Foundation

extension WorkflowExecutor {
    func recoveryDefinition(_ workflow: Workflow, revision: String) throws -> String {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecoveryError.invalidCheckpoint("a nonempty host revision is required")
        }
        try workflow.validateContexts()
        try workflow.validateApprovals(recoverable: true)
        try preflight(workflow)
        return try workflow.recoveryDefinition(kits: toolSources.declaredKits)
    }

    func validate(_ checkpoint: WorkflowExecutionCheckpoint, workflow: Workflow, revision: String) throws {
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

    func save(
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

    func advance(
        _ workflow: Workflow,
        checkpoint initial: WorkflowExecutionCheckpoint,
        approval: ApprovalDecision?,
        policy: WorkflowExecutionPolicy,
        store: any WorkflowExecutionCheckpointStore,
        control: ExecutionControl
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
        var scope: WorkflowExecutionScope = .init(saved: checkpoint.state, policy: checkpoint.policy, resources: resources, control: control)
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
