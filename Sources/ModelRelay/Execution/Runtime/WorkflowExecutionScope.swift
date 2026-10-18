import Foundation

struct WorkflowExecutionScope: Sendable {
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

    init(
        input: Value,
        policy: WorkflowExecutionPolicy,
        resources: ExecutionResources,
        control: ExecutionControl
    ) {
        self.input = input
        self.policy = policy
        self.resources = resources
        self.control = control
        self.inputData = policy.data
        self.previousData = policy.data
        self.outputData = policy.data
        self.previous = input
    }

    mutating func record(_ record: StepRecord) {
        var record = record
        record.dataAccess = outputData
        if case let .conversation(name) = currentContext { record.conversation = name }
        records.append(record)
        control.emit(record)
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

extension WorkflowExecutionScope {
    init(
        saved: CheckpointValues,
        policy: WorkflowExecutionPolicy,
        resources: ExecutionResources,
        control: ExecutionControl
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
