import Foundation

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
            updates: nil
        )
    }

    /// Starts a recoverable execution with progress; the result may pause for approval.
    public nonisolated func startExecution(
        _ workflow: Workflow,
        input: Value,
        revision: String,
        policy: WorkflowExecutionPolicy = .unrestricted,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits = .unlimited
    ) -> WorkflowExecution<WorkflowExecutionOutcome> {
        WorkflowExecution { updates in
            try await self.startObserved(
                workflow,
                input: input,
                revision: revision,
                policy: policy,
                store: store,
                limits: limits,
                updates: updates
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
        updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation?
    ) async throws -> WorkflowExecutionOutcome {
        let definition = try recoveryDefinition(workflow, revision: revision)
        let policy = self.policy.combined(with: policy)
        try self.limits.validate(); try limits.validate()

        let control: ExecutionControl = .init(workflowID: workflow.id, limits: self.limits.narrowed(by: limits), updates: updates)
        defer { control.finish() }

        let resources = ExecutionResources()
        let scope: WorkflowExecutionScope = .init(input: input, policy: policy, resources: resources, control: control)
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
                    control: control
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
            updates: nil
        )
    }

    /// Resumes with progress without replaying confirmed step records.
    public nonisolated func resumeExecution(
        _ workflow: Workflow,
        from checkpoint: WorkflowExecutionCheckpoint,
        revision: String,
        approval: ApprovalDecision? = nil,
        policy: WorkflowExecutionPolicy = .unrestricted,
        store: any WorkflowExecutionCheckpointStore,
        limits: WorkflowExecutionLimits = .unlimited
    ) -> WorkflowExecution<WorkflowExecutionOutcome> {
        WorkflowExecution { updates in
            try await self.resumeObserved(
                workflow,
                from: checkpoint,
                revision: revision,
                approval: approval,
                policy: policy,
                store: store,
                limits: limits,
                updates: updates
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
        updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation?
    ) async throws -> WorkflowExecutionOutcome {
        try validate(checkpoint, workflow: workflow, revision: revision)
        if checkpoint.status == .running { throw RecoveryError.interrupted(step: workflow.steps[checkpoint.nextStep].name) }
        if approval != nil, checkpoint.status != .awaitingApproval {
            throw RecoveryError.invalidCheckpoint("there is no pending approval")
        }
        try self.limits.validate(); try limits.validate(); try checkpoint.limits.validate()

        let control = ExecutionControl(
            workflowID: workflow.id,
            limits: checkpoint.limits.narrowed(by: self.limits).narrowed(by: limits),
            executionID: checkpoint.executionID,
            usage: checkpoint.usage,
            duration: checkpoint.state.duration,
            updates: updates
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
                control: control
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
            limits: limits,
            executionID: checkpoint.executionID,
            usage: checkpoint.usage,
            duration: duration,
            updates: nil
        )
        switch step.kind {
        case .request, .useTool: control.accountReconciledTool()
        default: break
        }
        var scope: WorkflowExecutionScope = .init(saved: checkpoint.state, policy: policy, resources: resources, control: control)
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
}
