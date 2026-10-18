import AnyLanguageModel
import Foundation

/// A short, readable reason for a failed step: the request's own message for a
/// failed tool ("getWeather: The server answered HTTP 503"), never a dump of
/// the tool's internals.
func failureReason(_ error: any Error) -> String {
    if let toolError = error as? LanguageModelSession.ToolCallError {
        return "\(toolError.tool.name): \(failureReason(toolError.underlyingError))"
    }
    if case let RelayError.stepFailed(_, reason) = error { return reason }
    if case let RelayError.operationFailed(_, failure) = error { return failure.info.message }
    if let error = error as? WorkflowValidationError { return "Invalid workflow: " + error.issues.map { "\($0.step): \($0.detail)" }.joined(separator: "; ") }
    if case let RelayError.policyViolation(_, reason) = error { return reason }
    if case let RelayError.invalidContext(_, reason) = error { return reason }
    if case RelayError.writeNotAllowed = error { return "it wanted to change something and wasn't allowed" }
    if case let RelayError.missingSecret(name, _) = error { return "the key \(name) is missing" }
    if case let RelayError.unknownModel(id) = error { return "the model “\(id.rawValue)” isn't available" }
    if case RelayError.missingModel = error { return "it has no model" }
    if case let RelayError.unknownReference(reference, _) = error { return "“\(reference)” isn't available here" }
    if case RelayError.requestsUnavailable = error { return "requests can't be made here" }
    // An app's own errors (a Keychain failure, say) explain themselves.
    if let described = (error as? any LocalizedError)?.errorDescription { return described }
    return String(describing: error)
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
