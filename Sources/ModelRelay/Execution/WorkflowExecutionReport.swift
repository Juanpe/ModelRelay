import Foundation

/// What one step did: its result, which model produced it and how long it took.
public struct StepRecord: Codable, Sendable, Hashable {
    public var step: String
    public var value: Value
    public var model: ModelID?
    public var usedFallback: Bool
    public var duration: Duration
    public var skipped: Bool
    /// Tools an agent step called, in order (empty for other steps).
    public var toolCalls: [String] = []
    /// Effective data restriction, including selected values and conversation history.
    public var dataAccess: WorkflowExecutionPolicy.DataAccess = .unrestricted
    public var conversation: String? = nil
    /// A host verified an interrupted leaf's result without rerunning it.
    public var recovered: Bool = false
    /// What the step read: the prompt a model was given, the text a decision
    /// was about, or the request it sent with secrets hidden. Nil for steps
    /// that read nothing of their own.
    public var input: String? = nil
    /// Why the step failed. The stream yields this record before throwing.
    public var failure: String? = nil
    public var failureInfo: WorkflowFailureInfo? = nil
}

public struct WorkflowExecutionReport: Sendable {
    public var output: Value
    public var records: [StepRecord]
    public var duration: Duration
    public var outputDataAccess: WorkflowExecutionPolicy.DataAccess = .unrestricted
    public let executionID: UUID
    public let workflowID: UUID
    public let usage: WorkflowExecutionUsage
}

public struct WorkflowExecutionUsage: Codable, Sendable, Hashable {
    public internal(set) var modelCalls: Int = 0
    public internal(set) var toolCalls: Int = 0
    public init() {}
}
