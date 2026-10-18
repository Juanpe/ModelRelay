import AnyLanguageModel
import Foundation

public enum WorkflowFailureCategory: String, Codable, Sendable, Hashable {
    case validation, authenticationRequired, permissionDenied, modelUnavailable
    case invalidOutput, timeout, transport, requestRejected, limitExceeded, unknown
}

/// Optional classification for integrations/host errors without a dependency
/// from core to a provider or MCP package. The original error is still retained.
public protocol WorkflowFailureClassifiable: Error {
    var workflowFailureCategory: WorkflowFailureCategory { get }
}

/// Serializable diagnostic. Known request credentials are redacted, not arbitrary
/// sensitive data in provider/host error messages. Does not contain the raw cause.
public struct WorkflowFailureInfo: Codable, Sendable, Hashable {
    public let category: WorkflowFailureCategory
    public let message: String
    /// A dispatched write may have succeeded, even if its response was an error.
    public let outcomeUncertain: Bool
}

/// Original causes stay in memory for typed handling (including custom host
/// errors). Descriptions/records use only the redacted info, never dump the cause.
public struct WorkflowOperationFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let info: WorkflowFailureInfo
    public let underlyingError: any Error
    public var description: String { info.message }
    public var rootCause: any Error { deepestCause(underlyingError) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.info == rhs.info }
}

private func deepestCause(_ error: any Error) -> any Error {
    if let tool = error as? LanguageModelSession.ToolCallError { return deepestCause(tool.underlyingError) }
    if case let RelayError.operationFailed(_, failure) = error { return failure.rootCause }
    return error
}

func uncertainOutcome(_ error: any Error) -> Bool {
    if let tool = error as? LanguageModelSession.ToolCallError { return uncertainOutcome(tool.underlyingError) }
    if case let RelayError.operationFailed(_, failure) = error { return failure.info.outcomeUncertain }
    return false
}

/// Cancellation is control flow, never a model failure to retry. Some
/// providers wrap it, so also check the calling task's cancellation state.
func rethrowExecutionControlError(_ error: any Error) throws {
    if error is CancellationError || Task.isCancelled { throw CancellationError() }
    if case RelayError.policyViolation = error { throw error }
    if case RelayError.invalidContext = error { throw error }
    if case RelayError.writeNotAllowed = error { throw error }
    if case RelayError.limitExceeded = error { throw error }
    if let tool = error as? LanguageModelSession.ToolCallError { try rethrowExecutionControlError(tool.underlyingError) }
    if case let RelayError.operationFailed(_, failure) = error { try rethrowExecutionControlError(failure.underlyingError) }
}

func operationFailure(step: String, error: any Error, uncertain: Bool = false, secrets: [String] = []) -> RelayError {
    let existing: WorkflowOperationFailure? = if case let RelayError.operationFailed(_, value) = error { value } else { nil }
    let message = RequestBuilder.redact(failureReason(error), secrets: secrets)
    return .operationFailed(step: step, failure: WorkflowOperationFailure(
        info: .init(
            category: failureCategory(error),
            message: message,
            outcomeUncertain: uncertain || uncertainOutcome(error)
        ),
        underlyingError: existing?.underlyingError ?? error
    ))
}
