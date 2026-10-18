import Foundation

struct InvalidOutput: Error, CustomStringConvertible {
    var reason: String
    var description: String { reason }
}

public enum RelayError: Error, Equatable, Sendable {
    case unknownModel(ModelID)
    case missingModel(step: String)
    case unknownReference(String, step: String)
    case stepFailed(step: String, reason: String)
    case policyViolation(step: String, reason: String)
    case invalidContext(step: String, reason: String)
    case operationFailed(step: String, failure: WorkflowOperationFailure)
    case limitExceeded(WorkflowExecutionLimit)
    case invalidLimits
    /// A request step ran but the executor has no `RequestPerformer`.
    case requestsUnavailable(step: String)
    /// A request step needs `{{secret.NAME}}` and no secret has that name.
    case missingSecret(String, step: String)
    /// A request that changes something was not allowed by the `WritePolicy`.
    case writeNotAllowed(step: String)
}
