import AnyLanguageModel
import Foundation

/// Host-owned storage. A save must be atomic, durable before returning, and
/// compare-and-swap: nil creates a new execution; otherwise the stored generation
/// must equal `generation`. Throw `RecoveryError.checkpointConflict` on a
/// mismatch. Never implement this as an unconditional overwrite.
///
/// ModelRelay supplies no database, file storage, encryption or user identity.
/// Checkpoints contain sensitive input, results and native conversation history;
/// only load trusted snapshots and protect them like the original data.
public protocol WorkflowExecutionCheckpointStore: Sendable {
    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) async throws
}

/// Serializable execution state, not executable code or a serialized model.
/// Completed top-level steps are not replayed. A block is one recovery unit.
/// The host must keep workflow IDs stable and bump its revision when custom
/// bodies, model configuration or other executable dependencies change.
public struct WorkflowExecutionCheckpoint: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready, running, awaitingApproval, completed, rejected
    }

    public let schemaVersion: Int
    /// Identifies one execution, retained across approval pauses and resume.
    public let executionID: UUID
    /// Identifies the reusable definition; separate executions can share it.
    public let workflowID: UUID
    public let revision: String
    public internal(set) var generation: Int
    public internal(set) var status: Status
    /// Current/next top-level step. Nil after completion.
    public internal(set) var step: String?
    /// Developer-authored reason, not an automatically approved tool request.
    public internal(set) var approval: String?
    public internal(set) var policy: WorkflowExecutionPolicy
    public internal(set) var limits: WorkflowExecutionLimits
    public var usage: WorkflowExecutionUsage { state.usage }

    /// Confirmed values for the host's review UI. These are sensitive data,
    /// not sanitized telemetry. An in-flight step's partial results are absent.
    public var input: Value { state.input }
    public var results: [String: Value] { state.results }
    public var resultDataAccess: [String: WorkflowExecutionPolicy.DataAccess] { state.valuePolicies }
    public var records: [StepRecord] { state.records }

    let definition: String
    var nextStep: Int
    var state: CheckpointValues

    init(workflow: Workflow, revision: String, definition: String, policy: WorkflowExecutionPolicy,
         limits: WorkflowExecutionLimits, executionID: UUID, state: CheckpointValues) {
        schemaVersion = 2
        self.executionID = executionID
        workflowID = workflow.id
        self.revision = revision
        generation = 0
        status = .ready
        step = workflow.steps.first?.name
        approval = nil
        self.policy = policy
        self.limits = limits
        self.definition = definition
        nextStep = 0
        self.state = state
    }
}

public enum ApprovalDecision: Sendable {
    case approve, reject
}

/// Pausing is a successful return, not a suspended task. The caller may release
/// the executor and resume later with a newly configured instance.
public enum WorkflowExecutionOutcome: Sendable {
    case completed(WorkflowExecutionReport)
    case awaitingApproval(WorkflowExecutionCheckpoint)
    case rejected(WorkflowExecutionCheckpoint)
}

public enum RecoveryError: Error, Equatable, Sendable {
    case checkpointConflict
    case invalidCheckpoint(String)
    case definitionChanged
    case revisionMismatch
    /// The previous attempt may have had side effects. It is never replayed.
    case interrupted(step: String)
    case approvalRequired(step: String)
    case unsupported(String)
}

struct CheckpointConversation: Codable, Sendable {
    var name: String
    var model: ModelID
    var transcript: Transcript
    var data: WorkflowExecutionPolicy.DataAccess
}

struct CheckpointValues: Codable, Sendable {
    var input: Value
    var results: [String: Value]
    var valuePolicies: [String: WorkflowExecutionPolicy.DataAccess]
    var previous: Value
    var previousData: WorkflowExecutionPolicy.DataAccess
    var outputData: WorkflowExecutionPolicy.DataAccess
    var inputData: WorkflowExecutionPolicy.DataAccess
    var records: [StepRecord]
    var conversations: [CheckpointConversation]
    var duration: Duration
    var usage: WorkflowExecutionUsage
}
