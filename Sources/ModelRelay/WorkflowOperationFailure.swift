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

private func uncertainOutcome(_ error: any Error) -> Bool {
    if let tool = error as? LanguageModelSession.ToolCallError { return uncertainOutcome(tool.underlyingError) }
    if case let RelayError.operationFailed(_, failure) = error { return failure.info.outcomeUncertain }
    return false
}

struct OperationTimeout: Error, Sendable, CustomStringConvertible {
    let description: String
}

/// The raw server response error, accessible only by explicitly inspecting a
/// failure's rootCause. Its description may echo credentials; prefer failure.info
/// for diagnostics, where request secrets have been redacted.
public struct HTTPResponseFailure: Error, Sendable, CustomStringConvertible, WorkflowFailureClassifiable {
    public let status: Int
    public let description: String
    public var workflowFailureCategory: WorkflowFailureCategory {
        status == 401 ? .authenticationRequired : status == 403 ? .permissionDenied : .requestRejected
    }
}

func failureCategory(_ error: any Error) -> WorkflowFailureCategory {
    if let tool = error as? LanguageModelSession.ToolCallError { return failureCategory(tool.underlyingError) }
    if case let RelayError.operationFailed(_, failure) = error { return failure.info.category }
    if let value = error as? any WorkflowFailureClassifiable { return value.workflowFailureCategory }
    if error is WorkflowValidationError { return .validation }
    if error is OperationTimeout { return .timeout }
    if error is URLError { return .transport }
    if let native = error as? LanguageModelSession.GenerationError {
        switch native {
        case .assetsUnavailable, .rateLimited, .concurrentRequests: return .modelUnavailable
        case .decodingFailure, .unsupportedGuide, .unsupportedLanguageOrLocale, .exceededContextWindowSize: return .invalidOutput
        case .guardrailViolation, .refusal: return .requestRejected
        }
    }
    switch error {
    case RelayError.policyViolation, RelayError.writeNotAllowed: return .permissionDenied
    case RelayError.unknownModel, RelayError.missingModel: return .modelUnavailable
    case RelayError.limitExceeded: return .limitExceeded
    case RelayError.unknownReference, RelayError.invalidContext: return .validation
    case RelayError.stepFailed: return .validation
    case is InvalidOutput: return .invalidOutput
    default: return .unknown
    }
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
