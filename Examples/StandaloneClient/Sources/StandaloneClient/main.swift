import Foundation
import ModelRelay

// The default path is deterministic: no model, network, credentials or UI.
// Pass --apple to opt into a real on-device model call instead.
let usesApple = CommandLine.arguments.contains("--apple")
let workflow = Workflow("Article summary", output: "result") {
    if usesApple {
        Step.prompt("summary", "Summarize the article in one sentence.", model: .appleOnDevice)
    } else {
        Step.template("summary", "Example summary of: {{input}}")
    }
    Step.parallel("format") {
        Step.template("message", "Summary: {{summary}}")
        Step.template("source", "Original: {{input}}")
    }
    Step.template("result", "{{format.message}}\n{{format.source}}")
}

guard workflow.referenceIssues.isEmpty else {
    fatalError("The example has invalid references: \(workflow.referenceIssues)")
}

let executor = WorkflowExecutor()
let issues = await executor.validate(workflow)
precondition(issues.isEmpty)
let execution = executor.execute(
    workflow,
    input: .text("Small models can power focused workflows."),
    limits: .init(maxModelCalls: usesApple ? 1 : 0, maxToolCalls: 0, maxConcurrentSteps: 2)
)
defer { execution.cancel() }
for try await update in execution.updates {
    switch update {
    case let .step(record): print("Finished \(record.step)")
    case let .event(event):
        if event.kind == .executionCompleted { print("Completed execution \(event.executionID)") }
    }
}

let report = try await execution.result
print(report.output.textValue)
precondition(report.usage.modelCalls == (usesApple ? 1 : 0))

// The same workflow is a plain Codable value, independent of this executable.
let encoded = try JSONEncoder().encode(workflow)
let restored = try JSONDecoder().decode(Workflow.self, from: encoded)
precondition(restored == workflow)

// Developer-defined bodies need no interpreter or executor registration.
let local = Workflow("Custom Swift") {
    Step.custom("normalize") { context in
        .text(context.input.textValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
    Step.template("result", "Custom: {{normalize}}")
}

let customReport = try await executor.run(local, input: .text("  native Swift  "))
precondition(customReport.output == .text("Custom: NATIVE SWIFT"))
print(customReport.output.textValue)
do {
    _ = try JSONEncoder().encode(local)
    fatalError("A compiled closure must not be silently serialized")
} catch is EncodingError {
    print("Custom bodies stay in memory; declarative workflows still round-trip.")
}

// Context/policy metadata remains Codable. No model runs while composing it.
let reviewRecipe = Workflow("Private conversation") {
    Step.prompt("draft", "Draft.", model: .appleOnDevice).withContext(.conversation("reviewer"))
    Step.agent("review", "Review.", model: .appleOnDevice)
        .withContext(.conversation("reviewer")).withPolicy(.readOnly)
    Step.prompt("handoff", "Use selected data.", model: .appleOnDevice).withContext(.handoff(["review"]))
}

_ = try JSONEncoder().encode(reviewRecipe)

let privateValues = Workflow("Labels") {
    Step.template("private", "Private data").withPolicy(.localOnly)
    Step.template("copy", "{{private}}")
}

let privateReport = try await executor.run(privateValues, input: .null)
precondition(privateReport.outputDataAccess == .localOnly)
print("Local-only labels propagate through results and templates.")

// The SDK supplies state/contracts, not a database. This demo store is only
// in-memory; a real host must make CAS saves durable before returning.
actor DemoCheckpoints: WorkflowExecutionCheckpointStore {
    private var saved: [UUID: Data] = [:]
    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) throws {
        let current = try saved[checkpoint.executionID].map { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: $0) }
        guard current?.generation == generation else { throw RecoveryError.checkpointConflict }
        saved[checkpoint.executionID] = try JSONEncoder().encode(checkpoint)
    }
}

let review = Workflow("Human review") {
    Step.custom("draft") { context in .text("Draft: " + context.input.textValue) }
    Step.template("approved", "Approved {{draft}}").requiringApproval("Review before continuing")
}

let checkpoints = DemoCheckpoints()
let pending = try await executor.start(review, input: .text("article"), revision: "example-v1", store: checkpoints, limits: .init(maxToolCalls: 0))
guard case let .awaitingApproval(checkpoint) = pending else { fatalError("Expected review") }
precondition(checkpoint.results["draft"] == .text("Draft: article"))
let restoredCheckpoint = try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: JSONEncoder().encode(checkpoint))
let resumed = try await WorkflowExecutor().resume(
    review,
    from: restoredCheckpoint,
    revision: "example-v1",
    approval: .approve,
    store: checkpoints
)
guard case let .completed(reviewed) = resumed else { fatalError("Expected completion") }
precondition(reviewed.output == .text("Approved Draft: article"))
print("Approval checkpoints round-trip without serializing custom code or replaying confirmed steps.")

enum BusinessRuleFailure: Error, WorkflowFailureClassifiable {
    case rejected
    var workflowFailureCategory: WorkflowFailureCategory { .validation }
}

let rejected = Workflow("Typed host errors") { Step.custom("validate") { _ in throw BusinessRuleFailure.rejected } }
do {
    _ = try await executor.run(rejected, input: .null)
    fatalError("Expected a business-rule failure")
} catch let RelayError.operationFailed(step, failure) {
    precondition(step == "validate")
    precondition(failure.rootCause as? BusinessRuleFailure == .rejected)
    precondition(failure.info.category == .validation)
    print("Original typed causes stay accessible without entering event payloads or checkpoints.")
}
