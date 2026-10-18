import Foundation

/// Coordinates independent workflow executions; model output remains data.
public actor WorkflowExecutor {
    let catalog: ModelCatalog
    let stepTimeout: Duration
    let context: RequestContext
    let toolKits: [String: ToolKit]
    let toolServers: (any ToolServerConnector)?
    let policy: WorkflowExecutionPolicy
    let limits: WorkflowExecutionLimits
    let clock = ContinuousClock()
    let modelRuntime: WorkflowModelRuntime

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
        self.modelRuntime = WorkflowModelRuntime(catalog: catalog, stepTimeout: stepTimeout)
        self.context = RequestContext(requests: requests, secrets: secrets, writePolicy: writePolicy, timeout: stepTimeout)
    }

    public func run(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy = .unrestricted,
        limits: WorkflowExecutionLimits = .unlimited
    ) async throws -> WorkflowExecutionReport {
        try await runObserved(workflow, input: input, policy: policy, limits: limits, updates: nil)
    }

    /// Starts immediately; consume updates once and await `result` for the report.
    public nonisolated func execute(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy = .unrestricted,
        limits: WorkflowExecutionLimits = .unlimited
    ) -> WorkflowExecution<WorkflowExecutionReport> {
        WorkflowExecution { updates in
            try await self.runObserved(workflow, input: input, policy: policy, limits: limits, updates: updates)
        }
    }

    private func runObserved(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy,
        limits: WorkflowExecutionLimits,
        updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation?
    ) async throws -> WorkflowExecutionReport {
        try workflow.validateContexts()
        try workflow.validateApprovals(recoverable: false)
        try preflight(workflow)
        try self.limits.validate(); try limits.validate()

        let control: ExecutionControl = .init(workflowID: workflow.id, limits: self.limits.narrowed(by: limits), updates: updates)
        defer { control.finish() }
        control.emit(.executionStarted)

        do {
            let report = try await control.withDeadline {
                try await self.runWorkflow(workflow, input: input, policy: policy, control: control)
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

    func preflight(_ workflow: Workflow) throws {
        let issues = validate(workflow)
        if !issues.isEmpty { throw WorkflowValidationError(issues: issues) }
    }

    private func runWorkflow(
        _ workflow: Workflow,
        input: Value,
        policy: WorkflowExecutionPolicy,
        control: ExecutionControl
    ) async throws -> WorkflowExecutionReport {
        let resources = ExecutionResources()
        var scope: WorkflowExecutionScope = .init(input: input, policy: self.policy.combined(with: policy), resources: resources, control: control)

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
}
