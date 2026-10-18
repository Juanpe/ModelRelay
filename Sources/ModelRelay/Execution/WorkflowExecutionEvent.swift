import Foundation

/// Metadata only: never contains prompts, values, arguments, credentials or
/// raw error descriptions. Names/IDs are host-defined, not automatically PII-free.
public struct WorkflowExecutionEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case executionStarted, executionResumed, executionCompleted, executionFailed, executionCancelled
        case stepStarted, stepCompleted, stepSkipped, stepFailed
        case modelStarted, modelCompleted, modelFailed, fallbackSelected
        case toolStarted, toolCompleted, toolFailed
        case approvalRequired, approvalRejected, checkpointSaved, limitReached
    }

    public let executionID: UUID
    public let workflowID: UUID
    /// Each resume has a fresh invocation ID; sequence is ordered within it.
    public let invocationID: UUID
    public let sequence: Int
    public let kind: Kind
    public let step: String?
    public let model: ModelID?
    public let tool: String?
    public let failureCategory: WorkflowFailureCategory?
    public let checkpointGeneration: Int?
    public let limit: WorkflowExecutionLimit?
}
