import Foundation

/// What request steps and agent tools need to make a call.
struct RequestContext: Sendable {
    var requests: (any RequestPerformer)?
    var secrets: (any SecretProvider)?
    var writePolicy: WritePolicy
    var timeout: Duration
    var policy: WorkflowExecutionPolicy = .unrestricted
    var control: ExecutionControl? = nil

    /// `trace`, when given, receives the request as sent, with secrets hidden.
    func perform(
        _ request: HTTPRequest,
        step: String,
        trace: StepTrace? = nil,
        toolName: String? = nil,
        onDispatch: (@Sendable () -> Void)? = nil,
        resolve: (String) -> Value?
    ) async throws -> Value {
        try Task.checkCancellation()
        try policy.checkNetwork(step: step)
        try policy.checkTool(changesSomething: request.method.isWrite, step: step)
        guard requests != nil else { throw RelayError.requestsUnavailable(step: step) }
        let templates = [request.url, request.body ?? ""] + request.headers.map(\.value)
        for ref in templates.flatMap({ Template.references(in: $0) }) where !ref.hasPrefix("secret.") {
            guard resolve(ref) != nil else { throw RelayError.unknownReference(ref, step: step) }
        }
        let name = toolName ?? step
        try control?.beginTool(name, step: step)
        do {
            let result = try await performBody(request, step: step, trace: trace, onDispatch: onDispatch, resolve: resolve)
            control?.emit(.toolCompleted, step: step, tool: name)
            return result
        } catch {
            control?.emit(.toolFailed, step: step, tool: name, category: failureCategory(error))
            throw error
        }
    }

    private func performBody(
        _ request: HTTPRequest,
        step: String,
        trace: StepTrace?,
        onDispatch: (@Sendable () -> Void)?,
        resolve: (String) -> Value?
    ) async throws -> Value {
        guard let requests else { throw RelayError.requestsUnavailable(step: step) }
        var values: [String: String] = [:]
        for name in RequestBuilder.secretNames(in: request) {
            guard let value = try await secrets?.secret(named: name) else {
                throw RelayError.missingSecret(name, step: step)
            }
            values[name] = value
        }
        let prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.prepare(request, secrets: values, resolve: resolve)
        } catch {
            throw operationFailure(step: step, error: error, secrets: Array(values.values))
        }
        trace?.input = prepared.description
        if request.method.isWrite { try await authorize(prepared, step: step) }
        // One attempt only: a write that timed out may still have happened.
        do {
            let response = try await withTimeout(timeout) {
                onDispatch?()
                return try await requests.perform(prepared)
            }
            let result = try RequestBuilder.value(from: response, reading: request.reading)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve the cause in memory; only the diagnostic is redacted.
            if case RelayError.limitExceeded = error { throw error }
            throw operationFailure(step: step, error: error, uncertain: request.method.isWrite, secrets: prepared.secrets)
        }
    }
}

extension RequestContext {
    /// Throws unless the write policy lets `prepared` (something that
    /// changes something) go ahead.
    func authorize(_ prepared: PreparedRequest, step: String) async throws {
        try policy.checkTool(changesSomething: true, step: step)
        let allowed = switch writePolicy {
        case .allow: true
        case .deny: false
        case let .ask(confirm): await confirm(prepared)
        }
        guard allowed else { throw RelayError.writeNotAllowed(step: step) }
    }
}
